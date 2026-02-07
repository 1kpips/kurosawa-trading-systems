//+------------------------------------------------------------------+
//| File: Helpers/KurosawaRiskManager.mqh                            |
//| Type: Include Library                                            |
//| Ver : 0.2.0                                                      |
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
   double   day_start_equity;   // equity snapshot at start of day
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
// State initialization / reset
// ------------------------------------------------------------------

// Call once in OnInit (or immediately after attaching EA).
void Risk_Init(DailyRiskState &st, const datetime nowTime)
{
   st.day_of_year      = _DayOfYear(nowTime);
   st.day_start_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   st.last_trade_time  = 0;
   st.trades_today     = 0;
}

// Defensive: ensure baseline exists (useful if an older EA version had uninitialized state).
void Risk_EnsureBaseline(DailyRiskState &st, const datetime nowTime)
{
   if(st.day_start_equity <= 0.0)
   {
      st.day_of_year      = _DayOfYear(nowTime);
      st.day_start_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   }

   if(st.day_of_year <= 0)
      st.day_of_year = _DayOfYear(nowTime);
}

// Resets daily baseline when a new day is detected.
// - Resets trades_today
// - Optionally resets loss streak if your EA wants that behavior
bool DailyResetIfNewDay(
   DailyRiskState &st,
   const datetime nowTime,
   int &consecLosses,
   const bool resetLossStreakDaily
)
{
   const int d = _DayOfYear(nowTime);
   if(d == st.day_of_year)
      return false;

   st.day_of_year      = d;
   st.day_start_equity = AccountInfoDouble(ACCOUNT_EQUITY);
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

// Returns true if daily loss limit has not been breached.
// If dailyLossLimitPercent <= 0, the gate is disabled.
bool DailyLossLimitOK(const DailyRiskState &st, const double dailyLossLimitPercent)
{
   if(dailyLossLimitPercent <= 0.0) return true;
   if(st.day_start_equity <= 0.0)   return true;

   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   const double ddPct = Risk_DailyDrawdownPercent(st, eq);

   // Block once drawdown reaches the limit
   return (ddPct < dailyLossLimitPercent);
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

double Risk_NormalizeVolume(const string symbol, const double vol)
{
   const double vmin = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   const double vmax = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   const double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(vmin <= 0.0 || vmax <= 0.0 || step <= 0.0)
      return vol;

   double v = MathMax(vmin, MathMin(vmax, vol));
   v = MathFloor(v / step) * step;

   if(v < vmin) v = vmin;
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

   double vol = 0.0;

   if(useRiskSizing && riskPercent > 0.0)
   {
      vol = CalcLotRawByRiskPoints(symbol, slPoints, riskPercent, maxLotCap);
      if(vol > 0.0)
         vol = Risk_NormalizeVolume(symbol, vol);
   }

   if(vol <= 0.0 && fixedLot > 0.0)
      vol = Risk_NormalizeVolume(symbol, fixedLot);

   if(vol <= 0.0)
      vol = Risk_MinLot(symbol);

   return vol;
}

#endif // KUROSAWA_RISK_MANAGER_MQH
