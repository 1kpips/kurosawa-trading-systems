//+------------------------------------------------------------------+
//| File: Helpers/KurosawaRiskManager.mqh                            |
//| Type: Include Library                                            |
//| Ver : 0.3.0                                                      |
//|                                                                  |
//| Description                                                      |
//| Centralized risk-guard utilities for the Kurosawa EA suite.      |
//|                                                                  |
//| Goals                                                            |
//| - Keep risk logic consistent across engines (no per-EA drift)    |
//| - Be self-contained (no other helper dependencies)               |
//| - Prefer deterministic behavior (caller passes "now" when needed)|
//|                                                                  |
//| Scope                                                            |
//| - Daily equity baseline + daily reset                            |
//| - Daily loss limit gate                                          |
//| - Cooldown gate                                                  |
//| - Loss streak gate                                               |
//| - (Optional) position sizing helpers                             |
//+------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_RISK_MANAGER_MQH
#define KUROSAWA_RISK_MANAGER_MQH

// ------------------------------------------------------------------
// Data structures
// ------------------------------------------------------------------

struct DailyRiskState
{
   int      day_of_year;        // day-of-year snapshot for the current "risk day"
   double   day_start_equity;   // equity snapshot at start of day (persisted, see below)
   datetime day_start_server;   // start of the risk day in SERVER time, for the deal-history query
   datetime last_trade_time;    // last time a trade was placed (cooldown)
   int      trades_today;       // count of trades placed today
};

// ------------------------------------------------------------------
// Internal helpers (self-contained)
// ------------------------------------------------------------------

int _DayOfYear(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.day_of_year;
}

double _SafePct(const double numerator, const double denominator)
{
   if(denominator <= 0.0) return 0.0;
   return (numerator / denominator) * 100.0;
}

// ------------------------------------------------------------------
// Persisted day-start equity
// ------------------------------------------------------------------
// The baseline lives in a terminal global variable, one per account per
// trading day, so OnInit can no longer move it. It used to re-snapshot on
// every OnInit - recompile, input change, timeframe change, restart - and
// each of those handed the EA a fresh full daily loss allowance measured
// from the already-drawn-down equity.
//
// The key is per ACCOUNT, not per EA: equity is account-wide, so the first
// Kurosawa EA to see a new day fixes the baseline and every chart measures
// from it. An EA attached mid-afternoon inherits the morning's number.
//
// Terminal globals survive a restart and expire after four weeks unread, so
// old days clean themselves up. The tester emulates its own empty set per
// run, so a backtest behaves exactly as before.

string _DayEquityKey(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return StringFormat("KRS_DAYEQ_%I64d_%04d%02d%02d",
                       AccountInfoInteger(ACCOUNT_LOGIN), dt.year, dt.mon, dt.day);
}

// Returns the stored baseline for the trading day of `t`, creating it from
// current equity if none exists. Returns 0 - and stores nothing - while the
// terminal is not yet connected, so a 0 is never pinned as the day's baseline.
double _DayStartEquity(const datetime t)
{
   if(AccountInfoInteger(ACCOUNT_LOGIN) == 0) return 0.0;

   const string k = _DayEquityKey(t);
   if(GlobalVariableCheck(k))
   {
      const double stored = GlobalVariableGet(k);
      if(stored > 0.0) return stored;
   }

   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > 0.0) GlobalVariableSet(k, eq);
   return eq;
}

// Midnight of `nowTime`'s day, expressed on the server clock. `nowTime` is the
// caller's trading-day clock (server time plus a whole-hour offset); the
// offset is recovered from the difference rather than imported, so this file
// stays self-contained.
datetime _DayStartServer(const datetime nowTime)
{
   const datetime server = TimeTradeServer();
   const long offsetSec  = (long)MathRound((double)(nowTime - server) / 3600.0) * 3600;
   return (datetime)(nowTime - (nowTime % 86400) - offsetSec);
}

// Closed P/L on the whole account since `fromServer`: profit + swap + commission
// of every exit deal, every magic. Same definition as Portfolio_RealizedToday.
double _RealizedSince(const datetime fromServer)
{
   if(fromServer <= 0) return 0.0;
   if(!HistorySelect(fromServer, TimeTradeServer() + 60)) return 0.0;

   double sum = 0.0;
   const int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
   {
      const ulong t = HistoryDealGetTicket(i);
      if(t == 0) continue;
      const long entry = HistoryDealGetInteger(t, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT && entry != DEAL_ENTRY_OUT_BY) continue;
      sum += HistoryDealGetDouble(t, DEAL_PROFIT)
           + HistoryDealGetDouble(t, DEAL_SWAP)
           + HistoryDealGetDouble(t, DEAL_COMMISSION);
   }
   return sum;
}

// ------------------------------------------------------------------
// State initialization / reset
// ------------------------------------------------------------------

// Call once in OnInit (or immediately after attaching EA).
void Risk_Init(DailyRiskState &st, const datetime nowTime)
{
   st.day_of_year      = _DayOfYear(nowTime);
   st.day_start_equity = _DayStartEquity(nowTime);
   st.day_start_server = _DayStartServer(nowTime);
   st.last_trade_time  = 0;
   st.trades_today     = 0;
}

// Defensive: ensure baseline exists (useful if an older EA version had uninitialized state).
void Risk_EnsureBaseline(DailyRiskState &st, const datetime nowTime)
{
   if(st.day_start_equity <= 0.0)
   {
      st.day_of_year      = _DayOfYear(nowTime);
      st.day_start_equity = _DayStartEquity(nowTime);
      st.day_start_server = _DayStartServer(nowTime);
   }

   if(st.day_of_year <= 0)
      st.day_of_year = _DayOfYear(nowTime);
}

// Resets daily baseline when a new day is detected.
// - Resets trades_today
// - Optionally resets loss streak if your EA wants that behavior
// Same day with no baseline yet (OnInit ran before the terminal connected):
// fills the baseline and keeps the counters, so the guard is not off all day.
bool DailyResetIfNewDay(
   DailyRiskState &st,
   const datetime nowTime,
   int &consecLosses,
   const bool resetLossStreakDaily
)
{
   const int d = _DayOfYear(nowTime);
   if(d == st.day_of_year)
   {
      if(st.day_start_equity <= 0.0)
         st.day_start_equity = _DayStartEquity(nowTime);
      return false;
   }

   st.day_of_year      = d;
   st.day_start_equity = _DayStartEquity(nowTime);
   st.day_start_server = _DayStartServer(nowTime);
   st.trades_today     = 0;

   if(resetLossStreakDaily)
      consecLosses = 0;

   return true;
}

// ------------------------------------------------------------------
// Daily loss limit
// ------------------------------------------------------------------

// Intraday drawdown percent from day_start_equity.
// Positive value means currentEquity is below day_start_equity.
double Risk_DailyDrawdownPercent(const DailyRiskState &st, const double currentEquity)
{
   if(st.day_start_equity <= 0.0) return 0.0;

   const double ddMoney = st.day_start_equity - currentEquity;
   return _SafePct(ddMoney, st.day_start_equity);
}

// Realized loss today as a percent of day_start_equity. Positive = a loss.
double Risk_DailyRealizedLossPercent(const DailyRiskState &st)
{
   if(st.day_start_equity <= 0.0) return 0.0;
   return _SafePct(-_RealizedSince(st.day_start_server), st.day_start_equity);
}

// Returns true if daily loss limit has not been breached.
// If dailyLossLimitPercent <= 0, the gate is disabled.
//
// Measured on REALIZED P/L (closed deals today, whole account), not equity.
// Equity counts floating P/L, so an open winner on another chart hid losses
// already booked - and an open loser elsewhere blocked an EA that had lost
// nothing. The gate runs only while this EA is flat, so in the tester (one
// instance, no other positions) the two agree except on a day that opened
// with a position carried over midnight: its realized result now counts in
// full, where equity only counted the move since the snapshot.
bool DailyLossLimitOK(const DailyRiskState &st, const double dailyLossLimitPercent)
{
   if(dailyLossLimitPercent <= 0.0) return true;
   if(st.day_start_equity <= 0.0)   return true;

   // Block once the realized loss reaches the limit
   return (Risk_DailyRealizedLossPercent(st) < dailyLossLimitPercent);
}

// ------------------------------------------------------------------
// Cooldown
// ------------------------------------------------------------------

// Returns true if enough time has passed since last_trade_time.
// Caller provides nowTime so behavior is deterministic.
bool CooldownOK(const DailyRiskState &st, const int cooldownMinutes, const datetime nowTime)
{
   if(cooldownMinutes <= 0)   return true;
   if(st.last_trade_time == 0) return true;

   const long needSec = (long)cooldownMinutes * 60;
   const long elapsed = (long)(nowTime - st.last_trade_time);

   return (elapsed >= needSec);
}

// Call only after a trade was successfully placed.
void Risk_OnTradePlaced(DailyRiskState &st, const datetime nowTime)
{
   st.last_trade_time = nowTime;
   st.trades_today++;
}

// ------------------------------------------------------------------
// Loss-streak protection
// ------------------------------------------------------------------

bool LossStreakOK(const int consecLosses, const int maxConsecutiveLosses)
{
   if(maxConsecutiveLosses <= 0) return true;
   return (consecLosses < maxConsecutiveLosses);
}

// ------------------------------------------------------------------
// (Optional) position sizing helpers
// If you want "risk sizing belongs to execution", move these into ExecUtils.
// ------------------------------------------------------------------

double Risk_MinLot(const string symbol)
{
   const double vmin = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   const double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(vmin <= 0.0)
      return 0.01; // last-resort fallback

   if(step > 0.0)
      return MathCeil(vmin / step) * step;

   return vmin;
}

// Lenient normalize (used for an EXPLICIT fixed lot): floor to the step grid within
// [vmin, vmax], and raise a sub-minimum lot up to vmin. Returns 0 if broker volume
// constraints cannot be read (reject rather than send an unvalidated lot).
double Risk_NormalizeVolume(const string symbol, const double vol)
{
   const double vmin = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   const double vmax = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   const double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(vmin <= 0.0 || vmax <= 0.0 || step <= 0.0)
      return 0.0; // cannot validate broker constraints -> reject

   if(vol <= 0.0) return 0.0;

   // Epsilon before flooring. In binary floating point 0.29 / 0.01 is
   // 28.999999999999996, so a plain MathFloor drops a whole volume step: an
   // explicit InpFixedLot of 0.29 would trade 0.28 forever. With step = 0.1 the
   // same effect turns 0.3 into 0.2, a 33% sizing error.
   const double steps = MathFloor(MathMin(vmax, vol) / step + 1e-8);
   double v = NormalizeDouble(steps * step, 8);

   if(v < vmin) v = vmin;   // an explicit fixed lot may be raised to the broker minimum
   if(v > vmax) v = vmax;   // ...but never past the broker maximum
   return v;
}

// Strict normalize (used for RISK-BASED sizing): floor to the step grid within
// [vmin, vmax], but if the result is below the broker minimum, return 0 (REJECT).
// This prevents silently oversizing a risk-based lot up to min-lot, which would make
// realized risk exceed the configured risk %.
double Risk_NormalizeVolumeStrict(const string symbol, const double vol)
{
   const double vmin = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   const double vmax = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   const double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(vmin <= 0.0 || vmax <= 0.0 || step <= 0.0)
      return 0.0; // cannot validate broker constraints -> reject

   if(vol <= 0.0) return 0.0;

   // Epsilon before flooring - see Risk_NormalizeVolume. Without it a risk-based
   // lot is under-delivered by a full step, and on a broker where step == vmin a
   // computed lot that should equal vmin floors to 0 and the trade is refused
   // with nothing in the log to explain why.
   const double steps = MathFloor(MathMin(vmax, vol) / step + 1e-8);
   const double v = NormalizeDouble(steps * step, 8);

   if(v < vmin) return 0.0;  // risk-based lot below broker min -> refuse (do NOT oversize)
   return v;
}

double CalcLotRawByRiskPoints(
   const string symbol,
   const double slPoints,
   const double riskPercent,
   const double maxLotCap = 0.0
)
{
   if(slPoints <= 0.0 || riskPercent <= 0.0) return 0.0;

   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0) return 0.0;

   const double riskMoney = equity * (riskPercent / 100.0);
   if(riskMoney <= 0.0) return 0.0;

   const double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   const double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0) return 0.0;

   const double pointSize = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(pointSize <= 0.0) return 0.0;

   // Money per 1 point per 1.0 lot
   const double valuePerPointPerLot = tickValue * (pointSize / tickSize);
   if(valuePerPointPerLot <= 0.0) return 0.0;

   double lots = riskMoney / (slPoints * valuePerPointPerLot);

   if(maxLotCap > 0.0 && lots > maxLotCap)
      lots = maxLotCap;

   return lots;
}

double Risk_CalcTradeVolume(
   const string symbol,
   const double slPoints,
   const bool   useRiskSizing,
   const double riskPercent,
   const double fixedLot,
   const double maxLotCap
)
{
   if(slPoints <= 0.0)
      return 0.0;

   if(useRiskSizing)
   {
      // Risk-based sizing is fail-safe: it never falls back to a fixed/min lot.
      if(riskPercent <= 0.0)
         return 0.0; // risk sizing requested but no risk% -> stand down

      const double raw = CalcLotRawByRiskPoints(symbol, slPoints, riskPercent, maxLotCap);
      if(raw <= 0.0)
         return 0.0; // sizing data unavailable / calc failed -> stand down (no fixed fallback)

      // Strict: returns 0.0 if the risk-based lot is below the broker minimum, so we
      // never oversize. (maxLotCap was already applied inside CalcLotRawByRiskPoints.)
      return Risk_NormalizeVolumeStrict(symbol, raw);
   }

   // Explicit fixed-lot mode.
   if(fixedLot > 0.0)
   {
      double vol = Risk_NormalizeVolume(symbol, fixedLot);
      if(maxLotCap > 0.0 && vol > maxLotCap)
         vol = Risk_NormalizeVolume(symbol, maxLotCap); // honor the cap on the fixed-lot path too
      return vol;
   }

   return 0.0; // nothing valid to size -> skip
}

#endif // KUROSAWA_RISK_MANAGER_MQH
