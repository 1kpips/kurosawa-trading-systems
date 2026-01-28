//+------------------------------------------------------------------+
//| File: KurosawaRiskManager.mqh                                    |
//| Type: Include Library                                            |
//| Ver : 0.1.0                                                      |
//|                                                                  |
//| Description                                                      |
//| Centralized risk-guard utilities shared across the Kurosawa EA   |
//| suite. Designed to keep EAs consistent and avoid per-EA drift i  |
//| safety logic.                                                    |
//|                                                                  |
//| Scope                                                            |
//| - Daily equity baseline management                               |
//| - Daily loss limit checks                                        |
//| - Cooldown between trades                                        |
//| - Loss-streak protection gates                                   |
//|                                                                  |
//| Notes                                                            |
//| - Include via #include, no external dependencies required        |
//| - Public repo safe: no endpoints, no secrets                     |
//| - Functions are deterministic given inputs (time/equity/state    |
//|                                                                  |
//| Design choices                                                   |
//| - Daily reset only refreshes equity baseline by default          |
//| - Consecutive loss counters should be owned by tracking module   |
//|   or EA state, not reset here unless explicitly requested        |
//+------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_RISK_MANAGER_MQH
#define KUROSAWA_RISK_MANAGER_MQH

//+------------------------------------------------------------------+
//| Data structures                                                  |
//+------------------------------------------------------------------+

struct DailyRiskState
{
   int      day_of_year;        // broker/server day-of-year by TimeCurrent() unless caller supplies nowTime
   double   day_start_equity;   // equity snapshot at start of day
   datetime last_trade_time;    // last time a trade was placed (for cooldown)
   int      trades_today;
};

// Optional policy bundle for a single "should we trade" gate.
// You can use the individual functions directly if preferred.
struct RiskPolicy
{
   double daily_loss_limit_percent; // e.g., 2.0 means block after -2.0 percent intraday equity drop
   int    cooldown_minutes;         // minimum minutes between trades
   int    max_consecutive_losses;   // block when consecLosses >= this value
};

//+------------------------------------------------------------------+
//| Internal helpers                                                 |
//+------------------------------------------------------------------+

int DayOfYear(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.day_of_year;
}

double SafePct(const double numerator, const double denominator)
{
   if(denominator <= 0.0) return 0.0;
   return (numerator / denominator) * 100.0;
}

//+------------------------------------------------------------------+
//| State initialization                                             |
//+------------------------------------------------------------------+

// Initializes state. Call once in OnInit after inputs are known.
void Risk_Init(DailyRiskState &st, const datetime nowTime)
{
   st.day_of_year      = DayOfYear(nowTime);
   st.day_start_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   st.last_trade_time  = 0;
   st.trades_today     = 0;
}

// Ensures the daily equity baseline exists, used when migrating older EAs.
void Risk_EnsureBaseline(DailyRiskState &st, const datetime nowTime)
{
   if(st.day_start_equity <= 0.0)
   {
      st.day_of_year      = DayOfYear(nowTime);
      st.day_start_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   }

   if(st.day_of_year < 0)
      st.day_of_year = DayOfYear(nowTime);
}

// Refreshes daily equity baseline when day changes.
// By default, this does not reset consecutive losses.
// If you want to reset consecLosses daily for a specific EA, pass a reference and set resetLossStreakDaily=true.
bool DailyResetIfNewDay(DailyRiskState &st,
                                    const datetime nowTime,
                                    int &consecLosses,
                                    const bool resetLossStreakDaily)
{
   const int d = DayOfYear(nowTime);

   if(d == st.day_of_year)
      return false;

   st.day_of_year      = d;
   st.day_start_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   st.trades_today = 0;
   
   if(resetLossStreakDaily)
      consecLosses = 0;

   return true;
}

//+------------------------------------------------------------------+
//| Daily loss limit                                                 |
//+------------------------------------------------------------------+

// Returns intraday drawdown percent based on the stored day_start_equity.
// Positive values mean drawdown from the daily baseline.
double Risk_DailyDrawdownPercent(const DailyRiskState &st, const double currentEquity)
{
   if(st.day_start_equity <= 0.0) return 0.0;

   const double ddMoney = st.day_start_equity - currentEquity;
   return SafePct(ddMoney, st.day_start_equity);
}

// Calculates position size (lots) so that a stop-loss hit
// results in approximately `riskPercent` loss of equity.
//
// Parameters:
// - symbol: trading symbol
// - slPoints: stop-loss distance in POINTS
// - riskPercent: percent of equity to risk (e.g. 0.5 = 0.5%)
// - maxLotCap: optional hard cap (<= 0 disables)
//
// Returns normalized volume, or 0 on failure.
double CalcLotRawByRiskPoints(const string symbol,
                              const double slPoints,
                              const double riskPercent,
                              const double maxLotCap = 0.0)
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

   // money per "point" per 1.0 lot
   const double valuePerPointPerLot = tickValue * (pointSize / tickSize);
   if(valuePerPointPerLot <= 0.0) return 0.0;

   double lots = riskMoney / (slPoints * valuePerPointPerLot);

   if(maxLotCap > 0.0 && lots > maxLotCap)
      lots = maxLotCap;

   return lots;
}

double Risk_NormalizeVolume(const string symbol, const double vol)
{
   const double vmin = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   const double vmax = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   const double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(vmin <= 0 || vmax <= 0 || step <= 0) return vol;

   double v = MathMax(vmin, MathMin(vmax, vol));
   v = MathFloor(v / step) * step;

   if(v < vmin) v = vmin;
   return v;
}
// Returns true if daily loss limit has not been breached.
bool DailyLossLimitOK(const DailyRiskState &st, const double dailyLossLimitPercent)
{
   if(dailyLossLimitPercent <= 0.0) return true;
   if(st.day_start_equity <= 0.0)   return true;

   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   const double ddPct = Risk_DailyDrawdownPercent(st, eq);

   return (ddPct < dailyLossLimitPercent);
}

//+------------------------------------------------------------------+
//| Cooldown                                                         |
//+------------------------------------------------------------------+

bool CooldownOK(const DailyRiskState &st,
                            const int cooldownMinutes)
{
   if(cooldownMinutes <= 0) return true;
   if(st.last_trade_time == 0) return true;

   const datetime nowTime = TimeCurrent();

   const long needSec = (long)cooldownMinutes * 60;
   const long elapsed = (long)(nowTime - st.last_trade_time);

   return (elapsed >= needSec);
}

// Call this only after a trade was successfully placed.
void Risk_OnTradePlaced(DailyRiskState &st, const datetime nowTime)
{
   st.last_trade_time = nowTime;
   st.trades_today++; 
}

//+------------------------------------------------------------------+
//| Loss-streak protection                                           |
//+------------------------------------------------------------------+

bool LossStreakOK(const int consecLosses, const int maxConsecutiveLosses)
{
   if(maxConsecutiveLosses <= 0) return true;
   return (consecLosses < maxConsecutiveLosses);
}

//+------------------------------------------------------------------+
//| Calculate final trade volume based on risk policy                |
//|                                                                  |
//| Returns normalized volume, or 0 if no valid volume can be found  |
//+------------------------------------------------------------------+
double Risk_CalcTradeVolume(const string symbol,
                            const double slPoints,
                            const bool   useRiskSizing,
                            const double riskPercent,
                            const double fixedLot,
                            const double maxLotCap)
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

//+------------------------------------------------------------------+
//| Rebuild consecutive loss streak from trade history               |
//|                                                                  |
//| Purpose                                                          |
//| - Restores risk-guard state after terminal / EA restart          |
//| - Counts *consecutive* losing OUT deals for this symbol+magic    |
//| - Stops at first winning trade                                   |
//| - Capped to avoid deep history scans                             |
//|                                                                  |
//| Notes                                                            |
//| - This does NOT imply overnight position holding                 |
//| - Intended to be called once in OnInit                           |
//| - Daily reset logic may still zero the streak later              |
//+------------------------------------------------------------------+
int Risk_LoadConsecLossesFromHistory(const string symbol,
                                    const long   magic,
                                    const int    daysBack,
                                    const int    maxConsecLossesCap)
{
   // Defensive defaults
   if(daysBack <= 0 || maxConsecLossesCap <= 0)
      return 0;

   int consecLosses = 0;

   const datetime to   = TimeCurrent();
   const datetime from = to - (datetime)daysBack * 24 * 3600;

   // If history is unavailable, fail safely (no streak)
   if(!HistorySelect(from, to))
      return 0;

   const long total = HistoryDealsTotal();

   // Walk backwards through history
   for(long i = total - 1; i >= 0; --i)
   {
      const ulong deal = HistoryDealGetTicket((int)i);
      if(deal == 0)
         continue;

      // Strict EA identity filters
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != symbol)
         continue;

      if(HistoryDealGetInteger(deal, DEAL_MAGIC) != magic)
         continue;

      if(HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;

      // Net P/L including costs
      const double profit =
           HistoryDealGetDouble(deal, DEAL_PROFIT)
         + HistoryDealGetDouble(deal, DEAL_SWAP)
         + HistoryDealGetDouble(deal, DEAL_COMMISSION);

      if(profit < 0.0)
      {
         consecLosses++;

         // Hard cap to avoid unnecessary scanning
         if(consecLosses >= maxConsecLossesCap)
            break;
      }
      else
      {
         // First win breaks the streak
         break;
      }
   }

   return consecLosses;
}

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

#endif // KUROSAWA_RISK_MANAGER_MQH
