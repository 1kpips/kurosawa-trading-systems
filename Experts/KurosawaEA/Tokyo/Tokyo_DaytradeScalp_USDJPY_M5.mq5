//+------------------------------------------------------------------+
//| File: Tokyo_DaytradeScalp_USDJPY_M5.mq5                          |
//| EA  : Tokyo_DaytradeScalp_USDJPY_M5                              |
//| Ver : 0.1.4-track                                                |
//|                                                                  |
//| CHANGELOG (v0.1.4 / 2026-01-17):                                 |
//| - Add Option A tracking timeframe hooks (pass _Period)           |
//| - Call KurosawaTrack_OnNewBar() to log MFE/MAE + barsHeld        |
//| - Improve logging: daily summary + block counters                |
//| - Count blocks per evaluated bar (not per tick)                  |
//| - Robustness: normalize SL/TP, handle stop-level failures        |
//|                                                                  |
//| Strategy                                                         |
//| - Timeframe: M5 only (enforced)                                  |
//| - Trend filter: EMA(200)                                         |
//| - Entry: EMA(9/21) crossover in direction of EMA(200) trend      |
//| - Risk: fixed SL/TP in pips (via helper)                         |
//| - Session: Tokyo window (JST)                                    |
//| - Safety: spread limit, daily cap, cooldown, max hold time       |
//| - Tracking: OPEN/CLOSE + excursions via KurosawaTrack.mqh        |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
#include "KurosawaHelpers.mqh"
#include "KurosawaTrack.mqh"

CTrade trade;

//==================== Identity ====================//
input int    InpMagic              = 2026010505;
input string InpEaId               = "ea-tokyo-daytradescalp-usdjpy-m5";
input string InpEaName             = "Tokyo_DaytradeScalp_USDJPY_M5";
input string InpEaVersion          = "0.1.4"; // CHANGED

//==================== Strategy ====================//

// Fast EMA (entry trigger)
// Smaller (5–8): earlier entries, more trades, more whipsaws/noise.
// Larger (12–20): later entries, fewer trades, cleaner but can miss quick moves.
input int    InpEmaFast            = 9;

// Slow EMA (entry trigger baseline)
// Smaller (15–20): faster crossover changes, more trades, more false flips.
// Larger (25–40): slower flips, fewer trades, steadier signals.
input int    InpEmaSlow            = 21;

// Trend EMA (direction filter)
// Smaller (100–150): looser trend filter, more trades, more counter-trend risk.
// Larger (250–300): stricter filter, fewer trades, avoids chop but can be late.
// 200 is a common “big picture” line for M5 trend bias.
input int    InpEmaTrend           = 200;


//==================== Risk & Exits ====================//

// Stop-loss in pips (fixed distance)
// Larger SL: fewer stopouts, but losses are larger per trade (fixed-lot case).
// Smaller SL: more stopouts from noise/spread; needs very clean entries.
// For USDJPY, make sure SL comfortably exceeds typical spread + wiggle.
input double InpSlPips             = 6.0;

// Take-profit in pips (fixed distance)
// Larger TP: lower hit rate, bigger winners, more “almost TP then reverse”.
// Smaller TP: higher hit rate, but costs (spread/commission) matter more.
// If you see many “TP almost hit then reverse,” consider: slightly smaller TP or earlier trailing/partial logic.
input double InpTpPips             = 6.0;

// Daily trade cap
// Lower: prevents overtrading and clustered exposure.
// Higher: more opportunities but can amplify drawdown on bad regime days.
input int    InpMaxTradesPerDay    = 6;

// Cooldown between trades (minutes)
// Higher: avoids rapid-fire re-entry in chop; fewer trades.
// Lower: more trades; can get chopped if the market is oscillating around EMAs.
input int    InpCooldownMinutes    = 10;

// Max hold time (minutes)
// Smaller: “fails fast,” reduces time risk but can cut valid moves.
// Larger: allows more time to reach TP, but increases reversal/giveback risk.
input int    InpMaxHoldMinutes     = 60;

// Spread gate (points) — cost/quality filter
// Lower: avoids bad fills; fewer trades during spread spikes.
// Higher: more fills, but expectancy worsens if spread is large relative to TP.
// For USDJPY (3 digits), 1 pip = 10 points, so 25 points = 2.5 pips.
input double InpMaxSpreadPoints    = 25.0;   // 0 = disable


//==================== Session (JST) ====================//

// Trading window in JST (inclusive start, exclusive end depending on helper)
// Narrower window: avoids dead/noisy hours, fewer trades, often better quality.
// Wider window: more trades but includes weaker liquidity periods.
input int    InpJstStartHour       = 9;
input int    InpJstEndHour         = 23;

// JST offset from UTC (Japan = +9)
input int    InpJstUtcOffset       = 9;

//==================== Tracking ====================//
input bool   InpTrackEnable        = true;   // Master tracking switch
input bool   InpTrackSendOpen      = true;   // Send OPEN events too

//==================== Handles & State ====================//
int hEmaFast  = INVALID_HANDLE;
int hEmaSlow  = INVALID_HANDLE;
int hEmaTrend = INVALID_HANDLE;

datetime g_lastBarTime   = 0;
datetime g_lastCloseTime = 0;

int g_tradesToday = 0;
int g_lastJstYmd  = 0;

// Tracking guards/state (shared pattern across EAs)
ulong g_lastOpenDealId   = 0;
ulong g_lastClosedDealId = 0;
int   g_consecLosses     = 0; // updated by KurosawaTrack on CLOSE; do not reset daily

// Diagnostics (daily counters)
int g_diagBars      = 0;
int g_diagSignal    = 0;
int g_diagTradeSent = 0;

// Block counters (counted per evaluated BAR)
int g_blockSession   = 0;
int g_blockSpread    = 0;
int g_blockMaxDay    = 0;
int g_blockCooldown  = 0;
int g_blockHasPos    = 0;
int g_blockNoSignal  = 0;
int g_blockStops     = 0;
int g_blockOrderFail = 0;

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
bool CooldownOK()
{
   if(InpCooldownMinutes <= 0) return true;
   if(g_lastCloseTime <= 0)    return true;
   return (TimeCurrent() - g_lastCloseTime) >= (InpCooldownMinutes * 60);
}

void PrintDailySummary()
{
   PrintFormat(
      "--- DAILY SUMMARY [%d] --- Bars:%d Signals:%d Trades:%d TradesToday:%d ConsecLoss:%d",
      g_lastJstYmd, g_diagBars, g_diagSignal, g_diagTradeSent, g_tradesToday, g_consecLosses
   );

   PrintFormat(
      "Daily Blocks | session=%d spread=%d maxday=%d cooldown=%d haspos=%d nosignal=%d stops=%d orderfail=%d",
      g_blockSession, g_blockSpread, g_blockMaxDay, g_blockCooldown,
      g_blockHasPos, g_blockNoSignal, g_blockStops, g_blockOrderFail
   );
}

void ResetDailyIfNeeded()
{
   const int ymd = JstYmd(NowJst(InpJstUtcOffset));
   if(ymd == g_lastJstYmd) return;

   if(g_lastJstYmd != 0)
      PrintDailySummary();

   g_lastJstYmd    = ymd;
   g_tradesToday   = 0;

   g_diagBars      = 0;
   g_diagSignal    = 0;
   g_diagTradeSent = 0;

   g_blockSession   = 0;
   g_blockSpread    = 0;
   g_blockMaxDay    = 0;
   g_blockCooldown  = 0;
   g_blockHasPos    = 0;
   g_blockNoSignal  = 0;
   g_blockStops     = 0;
   g_blockOrderFail = 0;

   // NOTE: do NOT reset g_consecLosses here (risk guard)
}

void CheckTimeExit()
{
   if(InpMaxHoldMinutes <= 0) return;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      const datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      if((TimeCurrent() - openTime) >= (InpMaxHoldMinutes * 60))
      {
         trade.PositionClose(ticket);

         // NOTE: g_lastCloseTime is updated on DEAL close in OnTradeTransaction.
         // We avoid setting it here to prevent cooldown being anchored early.
         return; // one position per EA
      }
   }
}

//+------------------------------------------------------------------+
//| Init / Deinit                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   if(_Period != PERIOD_M5)
   {
      Print("CRITICAL: This EA must be attached to an M5 chart.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);

   hEmaFast  = iMA(_Symbol, _Period, InpEmaFast,  0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow  = iMA(_Symbol, _Period, InpEmaSlow,  0, MODE_EMA, PRICE_CLOSE);
   hEmaTrend = iMA(_Symbol, _Period, InpEmaTrend, 0, MODE_EMA, PRICE_CLOSE);

   if(hEmaFast == INVALID_HANDLE || hEmaSlow == INVALID_HANDLE || hEmaTrend == INVALID_HANDLE)
   {
      Print("CRITICAL: Failed to create EMA handles.");
      return INIT_FAILED;
   }

   g_lastJstYmd = JstYmd(NowJst(InpJstUtcOffset));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hEmaFast  != INVALID_HANDLE) IndicatorRelease(hEmaFast);
   if(hEmaSlow  != INVALID_HANDLE) IndicatorRelease(hEmaSlow);
   if(hEmaTrend != INVALID_HANDLE) IndicatorRelease(hEmaTrend);
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1) Daily rollover (JST)
   ResetDailyIfNeeded();

   // 2) Exit management every tick
   CheckTimeExit();

   // 3) New bar gate (evaluate once per M5 bar)
   const datetime bar0 = iTime(_Symbol, _Period, 0);
   if(bar0 == g_lastBarTime) return;

   g_lastBarTime = bar0;
   g_diagBars++;

   // 3.1) Tracking excursion update (Option A)
   KurosawaTrack_OnNewBar(InpTrackEnable, InpMagic, _Symbol, (ENUM_TIMEFRAMES)_Period);

   // 4) Session gate (counted per evaluated bar)
   if(!IsEntryTimeJST(InpJstStartHour, InpJstEndHour, InpJstUtcOffset))
   {
      g_blockSession++;
      return;
   }

   // 5) Quotes + spread gate
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return;

   if(InpMaxSpreadPoints > 0.0)
   {
      const double spreadPoints = (ask - bid) / _Point;
      if(spreadPoints > InpMaxSpreadPoints)
      {
         g_blockSpread++;
         return;
      }
   }

   // 6) Risk / frequency gates
   if(g_tradesToday >= InpMaxTradesPerDay) { g_blockMaxDay++; return; }
   if(!CooldownOK())                      { g_blockCooldown++; return; }
   if(PositionExists(_Symbol, InpMagic))  { g_blockHasPos++; return; }

   // 7) Indicator reads (CLOSED bars, shift=1/2)
   double f[2], s[2], tr[1];
   if(CopyBuffer(hEmaFast,  0, 1, 2, f)  != 2) return;
   if(CopyBuffer(hEmaSlow,  0, 1, 2, s)  != 2) return;
   if(CopyBuffer(hEmaTrend, 0, 1, 1, tr) != 1) return;

   const bool crossUp   = (f[1] <= s[1] && f[0] > s[0]);
   const bool crossDown = (f[1] >= s[1] && f[0] < s[0]);

   // Trend filter uses close(1) vs EMA200(1)
   const double close1  = iClose(_Symbol, _Period, 1);
   const bool trendUp   = (close1 > tr[0]);
   const bool trendDown = (close1 < tr[0]);

   if(crossUp || crossDown) g_diagSignal++;

   const bool goBuy  = (crossUp   && trendUp);
   const bool goSell = (crossDown && trendDown);

   if(!goBuy && !goSell)
   {
      g_blockNoSignal++;
      return;
   }

   // 8) Build SL/TP
   const double slDist = PipsToPrice(_Symbol, InpSlPips);
   const double tpDist = PipsToPrice(_Symbol, InpTpPips);
   if(slDist <= 0.0 || tpDist <= 0.0) return;

   const double lot = GetMinLot(_Symbol);
   const string cmt = InpEaName + "|" + InpEaVersion;

   // 9) Place order (market execution: price=0)
   if(goBuy)
   {
      double sl = NormalizeDouble(ask - slDist, _Digits);
      double tp = NormalizeDouble(ask + tpDist, _Digits);

      if(!EnsureStopsLevel(_Symbol, ask, sl, tp, true, true))
      {
         g_blockStops++;
         return;
      }

      if(!trade.Buy(lot, _Symbol, 0, sl, tp, cmt + "|BUY"))
      {
         g_blockOrderFail++;
         PrintFormat("ORDER_FAIL BUY: retcode=%d", trade.ResultRetcode());
         return;
      }
   }
   else
   {
      double sl = NormalizeDouble(bid + slDist, _Digits);
      double tp = NormalizeDouble(bid - tpDist, _Digits);

      if(!EnsureStopsLevel(_Symbol, bid, sl, tp, false, true))
      {
         g_blockStops++;
         return;
      }

      if(!trade.Sell(lot, _Symbol, 0, sl, tp, cmt + "|SELL"))
      {
         g_blockOrderFail++;
         PrintFormat("ORDER_FAIL SELL: retcode=%d", trade.ResultRetcode());
         return;
      }
   }

   g_tradesToday++;
   g_diagTradeSent++;
}

//+------------------------------------------------------------------+
//| Transaction Monitoring & Tracking (via KurosawaTrack.mqh)         |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& req,
                        const MqlTradeResult& res)
{
   // NOTE: Option A. EA passes timeframe explicitly for reporting consistency.
   KurosawaTrack_OnTradeTransaction(
      InpTrackEnable,
      trans,
      InpEaId,
      InpEaName,
      InpEaVersion,
      InpMagic,
      InpTrackSendOpen,
      g_lastOpenDealId,
      g_lastClosedDealId,
      g_consecLosses,
      g_lastCloseTime,
      (ENUM_TIMEFRAMES)_Period, _Symbol
   );
}
