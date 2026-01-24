//+------------------------------------------------------------------+
//| File: London_ScalpHigh_EURUSD_M1.mq5                             |
//| EA  : London_ScalpHigh_EURUSD_M1                                 |
//| Ver : 0.1.3-track                                                |
//|                                                                  |
//| EURUSD London High-Frequency Scalp (M1)                          |
//| - Entry: EMA(5/13) crossover on CLOSED bars (shift=1/2)          |
//| - Optional trend filter: Close(1) vs EMA(Trend)(1)               |
//| - Safety: session gate (JST 16:00 -> 01:00), spread, cooldown,   |
//|          daily cap, loss streak, 1 position per magic            |
//| - Execution: market orders (price=0), SL/TP validated            |
//| - Logging: daily summary + block counters (actionable)           |
//| - Tracking: OPEN/CLOSE + CSV ledger via KurosawaTrack.mqh        |
//|                                                                  |
//| Notes                                                            |
//| - Attach ONLY to EURUSD M1 chart.                                |
//| - Allow WebRequest URL in MT5 options (tracker uses it).         |
//| - Do not hardcode API keys in public repos.                      |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
#include "KurosawaHelpers.mqh"
#include "KurosawaTrack.mqh"

CTrade trade;

//==================== Identity ====================//
input int    InpMagic              = 2026011001;
input string InpEaId               = "ea-london-scalphigh-eurusd-m1";
input string InpEaName             = "London_ScalpHigh_EURUSD_M1";
input string InpEaVersion          = "0.1.3";

//==================== Session (London expressed in JST) ====================//
// London ≒ JST 16:00 -> 01:00 (cross-midnight supported)
input int    InpJstStartHour       = 16;
input int    InpJstEndHour         = 1;
input int    InpJstUtcOffset       = 9;

//==================== Strategy ====================//
// EMA crossover on CLOSED bars:
// - uses bar2 -> bar1 transition (shift=2 and shift=1) for stable signals
input int    InpEmaFast            = 5;
input int    InpEmaSlow            = 13;

// Optional direction filter (higher timeframe-like bias using EMA50 on same TF)
input bool   InpUseTrendFilter     = true;
input int    InpEmaTrend           = 50;

//==================== Stops & Targets (pips) ====================//
input double InpSlPips             = 5.0;
input double InpTpPips             = 3.0;

//==================== Frequency & Safety ====================//
input int    InpMaxTradesPerDay    = 25;
input int    InpCooldownMinutes    = 2;

// Use ONE loss streak variable per EA.
// We will use tracker-updated g_consecLosses as the single source of truth.
input int    InpMaxConsecLosses    = 3;

//==================== Execution Guards ====================//
input double InpMaxSpreadPoints    = 20.0; // 0 = disable

//==================== Tracking ====================//
input bool   InpTrackEnable        = true;
input bool   InpTrackSendOpen      = true;

//==================== Indicator Handles & Runtime State ====================//
int hFast  = INVALID_HANDLE;
int hSlow  = INVALID_HANDLE;
int hTrend = INVALID_HANDLE;

datetime g_lastBarTime   = 0;
datetime g_lastCloseTime = 0;

int g_tradesToday = 0;
int g_lastJstYmd  = 0;

// Tracking dedupe guards / shared state
ulong g_lastOpenDealId   = 0;
ulong g_lastCloseDealId  = 0;
int   g_consecLosses     = 0;   // Updated by KurosawaTrack on CLOSE
// NOTE: This EA uses g_consecLosses only. No separate local loss streak.

// Diagnostics (daily)
int g_diagBars      = 0;
int g_diagSignal    = 0;
int g_diagTradeSent = 0;

// Block counters (daily, counted per evaluated BAR)
int g_blockSession   = 0;
int g_blockSpread    = 0;
int g_blockMaxDay    = 0;
int g_blockLoss      = 0;
int g_blockCooldown  = 0;
int g_blockHasPos    = 0;
int g_blockNoSignal  = 0;
int g_blockStops     = 0;
int g_blockOrderFail = 0;

//+------------------------------------------------------------------+
//| Small local gates                                                |
//+------------------------------------------------------------------+
bool CooldownOK()
{
   if(InpCooldownMinutes <= 0) return true;
   if(g_lastCloseTime <= 0)    return true;
   return (TimeCurrent() - g_lastCloseTime) >= (InpCooldownMinutes * 60);
}

bool SpreadOK(const double ask, const double bid)
{
   if(InpMaxSpreadPoints <= 0.0) return true;
   return ((ask - bid) / _Point) <= InpMaxSpreadPoints;
}

bool IsNewBar()
{
   const datetime bar0 = iTime(_Symbol, PERIOD_M1, 0);
   if(bar0 == g_lastBarTime) return false;
   g_lastBarTime = bar0;
   return true;
}

//+------------------------------------------------------------------+
//| Daily summary / reset                                            |
//+------------------------------------------------------------------+
void PrintDailySummary()
{
   PrintFormat(
      "Daily Summary: Bars=%d Signals=%d Trades=%d | Blocks session=%d spread=%d cooldown=%d haspos=%d loss=%d maxday=%d nosignal=%d stops=%d orderfail=%d",
      g_diagBars, g_diagSignal, g_diagTradeSent,
      g_blockSession, g_blockSpread, g_blockCooldown,
      g_blockHasPos, g_blockLoss, g_blockMaxDay, g_blockNoSignal,
      g_blockStops, g_blockOrderFail
   );

   // Single loss streak source (tracker-updated)
   PrintFormat("Streaks | trackConsecLoss=%d", g_consecLosses);
}

void ResetDailyIfNeeded()
{
   const int ymd = JstYmd(NowJst(InpJstUtcOffset));
   if(ymd == g_lastJstYmd) return;

   if(g_lastJstYmd != 0)
      PrintDailySummary();

   g_lastJstYmd  = ymd;
   g_tradesToday = 0;

   g_diagBars      = 0;
   g_diagSignal    = 0;
   g_diagTradeSent = 0;

   g_blockSession   = 0;
   g_blockSpread    = 0;
   g_blockMaxDay    = 0;
   g_blockLoss      = 0;
   g_blockCooldown  = 0;
   g_blockHasPos    = 0;
   g_blockNoSignal  = 0;
   g_blockStops     = 0;
   g_blockOrderFail = 0;

   // Keep tracker streak across days by default.
   // If you want a "daily reset" of loss streak instead, uncomment:
   // g_consecLosses = 0;
}

//+------------------------------------------------------------------+
//| Init / Deinit                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   if(_Period != PERIOD_M1)
   {
      Print("CRITICAL: Attach this EA to an M1 chart.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);

   hFast  = iMA(_Symbol, PERIOD_M1, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   hSlow  = iMA(_Symbol, PERIOD_M1, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   hTrend = (InpUseTrendFilter ? iMA(_Symbol, PERIOD_M1, InpEmaTrend, 0, MODE_EMA, PRICE_CLOSE) : INVALID_HANDLE);

   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE || (InpUseTrendFilter && hTrend == INVALID_HANDLE))
   {
      Print("CRITICAL: Failed to create EMA handles.");
      return INIT_FAILED;
   }

   g_lastJstYmd = JstYmd(NowJst(InpJstUtcOffset));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hFast  != INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow  != INVALID_HANDLE) IndicatorRelease(hSlow);
   if(hTrend != INVALID_HANDLE) IndicatorRelease(hTrend);

   // Print summary when EA is removed (useful during testing)
   PrintDailySummary();
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   // 0) Daily reset
   ResetDailyIfNeeded();

   // 1) New bar gate first (so block counters are per evaluated bar)
   if(!IsNewBar()) return;
   g_diagBars++;

   // 2) Session gate (JST window; can cross midnight)
   if(!IsEntryTimeJST(InpJstStartHour, InpJstEndHour, InpJstUtcOffset))
   {
      g_blockSession++;
      return;
   }

   // 3) Quote & spread gate
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return;

   if(!SpreadOK(ask, bid))
   {
      g_blockSpread++;
      return;
   }

   // 4) Risk gates
   if(g_tradesToday >= InpMaxTradesPerDay) { g_blockMaxDay++; return; }
   if(g_consecLosses >= InpMaxConsecLosses){ g_blockLoss++; return; }
   if(!CooldownOK())                      { g_blockCooldown++; return; }
   if(PositionExists(_Symbol, InpMagic))   { g_blockHasPos++; return; }

   // 5) Read EMAs from CLOSED bars
   // shift=1,count=2 => f[0]=bar1, f[1]=bar2
   double f[2], s[2];
   if(CopyBuffer(hFast, 0, 1, 2, f) != 2) return;
   if(CopyBuffer(hSlow, 0, 1, 2, s) != 2) return;

   // Closed-bar crossover (bar2 -> bar1)
   const bool crossUp   = (f[1] <= s[1] && f[0] > s[0]);
   const bool crossDown = (f[1] >= s[1] && f[0] < s[0]);

   if(!crossUp && !crossDown)
   {
      g_blockNoSignal++;
      return;
   }
   g_diagSignal++;

   // 6) Optional trend filter (Close(1) vs EMAtrend(1))
   bool trendUp = true, trendDown = true;
   if(InpUseTrendFilter)
   {
      double t[1];
      if(CopyBuffer(hTrend, 0, 1, 1, t) != 1) return;

      const double close1 = iClose(_Symbol, PERIOD_M1, 1);
      trendUp   = (close1 > t[0]);
      trendDown = (close1 < t[0]);
   }

   // 7) SL/TP distances
   const double slDist = PipsToPrice(_Symbol, InpSlPips);
   const double tpDist = PipsToPrice(_Symbol, InpTpPips);
   if(slDist <= 0.0 || tpDist <= 0.0) return;

   // 8) Fixed baseline lot (min lot) for HFT stability
   const double lot = GetMinLot(_Symbol);
   const string cmtBase = InpEaName + "|" + InpEaVersion;

   // 9) Execute (market), validate stops/freeze levels
   if(crossUp && trendUp)
   {
      double sl = NormalizeDouble(ask - slDist, _Digits);
      double tp = NormalizeDouble(ask + tpDist, _Digits);

      if(!EnsureStopsLevel(_Symbol, ask, sl, tp, true, true))
      {
         g_blockStops++;
         return;
      }

      if(!trade.Buy(lot, _Symbol, 0, sl, tp, cmtBase + "|BUY"))
      {
         g_blockOrderFail++;
         return;
      }

      g_tradesToday++;
      g_diagTradeSent++;
   }
   else if(crossDown && trendDown)
   {
      double sl = NormalizeDouble(bid + slDist, _Digits);
      double tp = NormalizeDouble(bid - tpDist, _Digits);

      if(!EnsureStopsLevel(_Symbol, bid, sl, tp, false, true))
      {
         g_blockStops++;
         return;
      }

      if(!trade.Sell(lot, _Symbol, 0, sl, tp, cmtBase + "|SELL"))
      {
         g_blockOrderFail++;
         return;
      }

      g_tradesToday++;
      g_diagTradeSent++;
   }
   else
   {
      // Cross happened but trend filter blocked it
      g_blockNoSignal++;
      return;
   }
}

//+------------------------------------------------------------------+
//| Transaction Monitoring & Tracking (via KurosawaTrack.mqh)         |
//| - Keep this wrapper identical across EAs                          |
//| - Let the tracker update loss streak + lastCloseTime              |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Transaction Monitoring & Tracking (via KurosawaTrack.mqh)         |
//| - Keep this wrapper identical across EAs                          |
//| - Let the tracker update loss streak + lastCloseTime              |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& req,
                        const MqlTradeResult& res)
{
   
   KurosawaTrack_OnTradeTransaction(
      InpTrackEnable,               // 1
      trans,                        // 2
      InpEaId,                      // 3
      InpEaName,                    // 4
      InpEaVersion,                 // 5
      (int)InpMagic,                // 6 
      InpTrackSendOpen,             // 7
      g_lastOpenDealId,             // 8
      g_lastCloseDealId,            // 9
      g_consecLosses,               // 10
      g_lastCloseTime,              // 11
      (ENUM_TIMEFRAMES)_Period,     // 12
      _Symbol                       // 13
   );
}
