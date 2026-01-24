//+------------------------------------------------------------------+
//| File: NewYork_RangeRevert_USDCAD_M5.mq5                          |
//| EA  : NewYork_RangeRevert_USDCAD_M5                              |
//| Ver : 0.1.4-track                                                |
//|                                                                  |
//| New York Range Mean Reversion (USDCAD / M5)                      |
//| - Session: New York window expressed in JST (22:00 -> 05:00 JST) |
//| - Regime: trade only when ADX is quiet (range regime)            |
//| - Entry: Bollinger "re-entry" + RSI extreme (CLOSED bars)        |
//| - Safety: spread gate, cooldown, daily cap, loss streak          |
//| - Positioning: 1 position per EA instance (symbol + magic)       |
//| - Execution: market orders (price=0), SL/TP validated            |
//| - Tracking: OPEN/CLOSE + OnNewBar excursions via KurosawaTrack   |
//|                                                                  |
//| Notes                                                            |
//| - Attach ONLY to USDCAD M5 chart.                                |
//| - Signals use CLOSED bars (shift=1/2) for stability.             |
//| - If you see "adx blocks" too high, raise InpMaxAdxToTrade.      |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
#include "KurosawaHelpers.mqh"
#include "KurosawaTrack.mqh"

CTrade trade;

//==================== Identity ====================//
input int    InpMagic              = 2026011003;
input string InpEaId               = "ea-ny-rangerevert-usdcad-m5";
input string InpEaName             = "NewYork_RangeRevert_USDCAD_M5";
input string InpEaVersion          = "0.1.4";   // CHANGED

//==================== Session (JST) ====================//
// 22 -> 5 means 22:00 JST to 05:00 JST (cross-midnight supported by helper).
input int    InpJstStartHour       = 22;
input int    InpJstEndHour         = 5;
input int    InpJstUtcOffset       = 9;

//==================== Strategy: Range Reversion ====================//

// Bollinger Bands
// Period smaller -> bands react faster, more signals, more noise.
// Period larger  -> bands smoother, fewer signals, slower entries.
input int    InpBBPeriod           = 20;

// Deviation larger -> wider bands, fewer signals (often higher quality).
// Deviation smaller -> tighter bands, more signals, more chop.
input double InpBBDev              = 2.0;

// RSI extremes
// BuyBelow higher -> more buys (earlier), riskier.
// SellAbove lower -> more sells (earlier), riskier.
input int    InpRsiPeriod          = 14;
input double InpRsiBuyBelow        = 30.0;
input double InpRsiSellAbove       = 70.0;

// ADX quiet gate (avoid trending regimes)
// Lower max -> avoids trends more aggressively (fewer trades).
// Higher max -> more trades, but more trend-risk for mean reversion.
input int    InpAdxPeriod          = 14;
input bool   InpUseAdxGate         = true;   // NEW
input double InpMaxAdxToTrade      = 22.0;   // trade only when ADX <= this

// Entry strictness
// MinReentryPips higher -> requires clearer "back inside band" move (fewer trades).
// MinReentryPips lower  -> more trades, more noise.
input double InpMinReentryPips     = 0.0;    // NEW (0 = original behavior)

// Optional wick-based re-entry (helps catch spikes that close back in)
// true  -> uses Low/High for the "outside band" condition (more trades).
// false -> uses Close only (stricter).
input bool   InpUseWickSignal      = false;  // NEW default: close-only (more stable)

//==================== Risk & Safety ====================//

// Protective SL/TP (pips)
// Bigger SL -> fewer stopouts, larger loss per trade (fixed lot).
// Smaller TP -> higher hit rate, but costs matter more.
input double InpSlPips             = 12.0;
input double InpTpPips             = 8.0;

// Spread gate (points). 0 disables.
// Lower -> avoids bad fills, fewer trades during spread spikes.
input double InpMaxSpreadPoints    = 25.0;

// Frequency / risk stops
input int    InpMaxTradesPerDay    = 12;
input int    InpCooldownMinutes    = 10;
input int    InpMaxConsecLosses    = 3;

//==================== Tracking ====================//
input bool   InpTrackEnable        = true;
input bool   InpTrackSendOpen      = true;

//==================== Handles & State ====================//
int hBB  = INVALID_HANDLE;
int hRSI = INVALID_HANDLE;
int hADX = INVALID_HANDLE;

datetime g_lastBarTime   = 0;
datetime g_lastCloseTime = 0;

int g_tradesToday  = 0;   // resets daily
int g_lossStreak   = 0;   // updated by tracker on CLOSE (we pass it in)
int g_lastJstYmd   = 0;

// Tracking dedupe (required by KurosawaTrack wrapper)
ulong g_lastOpenDealId   = 0;
ulong g_lastClosedDealId = 0;

// Diagnostics (daily)
int g_diagBars      = 0;
int g_diagSignal    = 0;
int g_diagTradeSent = 0;

// Block counters (per evaluated bar)
int g_blockSession   = 0;
int g_blockSpread    = 0;
int g_blockCooldown  = 0;
int g_blockHasPos    = 0;
int g_blockLoss      = 0;
int g_blockMaxDay    = 0;
int g_blockAdx       = 0;
int g_blockNoSignal  = 0;
int g_blockStops     = 0;
int g_blockOrderFail = 0;

//+------------------------------------------------------------------+
//| Local gates                                                      |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   const datetime t0 = iTime(_Symbol, _Period, 0);
   if(t0 == g_lastBarTime) return false;
   g_lastBarTime = t0;
   return true;
}

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

void PrintDailySummary()
{
   PrintFormat(
      "Daily Summary: Bars=%d Signals=%d Trades=%d | Blocks session=%d spread=%d adx=%d cooldown=%d haspos=%d loss=%d maxday=%d nosignal=%d stops=%d orderfail=%d",
      g_diagBars, g_diagSignal, g_diagTradeSent,
      g_blockSession, g_blockSpread, g_blockAdx, g_blockCooldown,
      g_blockHasPos, g_blockLoss, g_blockMaxDay, g_blockNoSignal,
      g_blockStops, g_blockOrderFail
   );
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
   g_blockCooldown  = 0;
   g_blockHasPos    = 0;
   g_blockLoss      = 0;
   g_blockMaxDay    = 0;
   g_blockAdx       = 0;
   g_blockNoSignal  = 0;
   g_blockStops     = 0;
   g_blockOrderFail = 0;
}

//+------------------------------------------------------------------+
//| Init / Deinit                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   if(_Period != PERIOD_M5)
   {
      Print("CRITICAL: Attach this EA to an M5 chart.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);

   hBB  = iBands(_Symbol, _Period, InpBBPeriod, 0, InpBBDev, PRICE_CLOSE);
   hRSI = iRSI(_Symbol, _Period, InpRsiPeriod, PRICE_CLOSE);
   hADX = iADX(_Symbol, _Period, InpAdxPeriod);

   if(hBB == INVALID_HANDLE || hRSI == INVALID_HANDLE || hADX == INVALID_HANDLE)
   {
      Print("CRITICAL: Failed to create indicator handles.");
      return INIT_FAILED;
   }

   g_lastJstYmd = JstYmd(NowJst(InpJstUtcOffset));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hBB  != INVALID_HANDLE) IndicatorRelease(hBB);
   if(hRSI != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hADX != INVALID_HANDLE) IndicatorRelease(hADX);
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1) Daily reset (JST) + summary
   ResetDailyIfNeeded();

   // 2) Evaluate once per new bar (so counters are meaningful)
   if(!IsNewBar()) return;
   g_diagBars++;

   // 2.1) Tracking excursion update (if your tracker supports it)
   KurosawaTrack_OnNewBar(InpTrackEnable, InpMagic, _Symbol, (ENUM_TIMEFRAMES)_Period);

   // 3) Session gate (New York window expressed in JST)
   if(!IsEntryTimeJST(InpJstStartHour, InpJstEndHour, InpJstUtcOffset))
   {
      g_blockSession++;
      return;
   }

   // 4) Quotes + spread gate
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return;

   if(!SpreadOK(ask, bid))
   {
      g_blockSpread++;
      return;
   }

   // 5) Risk gates
   if(g_tradesToday >= InpMaxTradesPerDay) { g_blockMaxDay++; return; }
   if(g_lossStreak  >= InpMaxConsecLosses) { g_blockLoss++;   return; }
   if(!CooldownOK())                      { g_blockCooldown++; return; }

   // 6) One position per EA instance
   if(PositionExists(_Symbol, InpMagic)) { g_blockHasPos++; return; }

   // 7) Regime gate (range only)
   if(InpUseAdxGate)
   {
      if(!IsTrendQuiet(hADX, InpMaxAdxToTrade)) { g_blockAdx++; return; }
   }

   // 8) Indicator reads on CLOSED bars (shift=1/2)
   // Bands buffers: 0=upper, 1=middle, 2=lower
   double upper1[1], mid1[1], lower1[1];
   if(CopyBuffer(hBB, 0, 1, 1, upper1) != 1) return;
   if(CopyBuffer(hBB, 1, 1, 1, mid1)   != 1) return;
   if(CopyBuffer(hBB, 2, 1, 1, lower1) != 1) return;

   const double upper = upper1[0];
   const double mid   = mid1[0];
   const double lower = lower1[0];
   if(upper <= lower) return;

   double rsi1buf[1];
   if(CopyBuffer(hRSI, 0, 1, 1, rsi1buf) != 1) return;
   const double rsi1 = rsi1buf[0];

   // Closed bar prices
   const double c1 = iClose(_Symbol, _Period, 1); // last closed
   const double c2 = iClose(_Symbol, _Period, 2); // two bars ago
   const double l2 = iLow(_Symbol,  _Period, 2);
   const double h2 = iHigh(_Symbol, _Period, 2);

   // 9) Re-entry logic (mean reversion trigger)
   // Buy: bar2 was outside/below lower band, and bar1 re-enters above lower band, with RSI oversold.
   // Sell: bar2 was outside/above upper band, and bar1 re-enters below upper band, with RSI overbought.
   const double outsideLow2  = (InpUseWickSignal ? l2 : c2);
   const double outsideHigh2 = (InpUseWickSignal ? h2 : c2);

   const double reentryMin = PipsToPrice(_Symbol, InpMinReentryPips);

   const bool buySig  =
      (outsideLow2  < lower) &&
      (c1 > (lower + reentryMin)) &&
      (rsi1 <= InpRsiBuyBelow) &&
      ((mid - c1) > 0.0); // sanity: there is “room” to mid

   const bool sellSig =
      (outsideHigh2 > upper) &&
      (c1 < (upper - reentryMin)) &&
      (rsi1 >= InpRsiSellAbove) &&
      ((c1 - mid) > 0.0);

   if(!buySig && !sellSig)
   {
      g_blockNoSignal++;
      return;
   }
   g_diagSignal++;

   // 10) SL/TP distances
   const double slDist = PipsToPrice(_Symbol, InpSlPips);
   const double tpDist = PipsToPrice(_Symbol, InpTpPips);
   if(slDist <= 0.0 || tpDist <= 0.0) return;

   const double lot = GetMinLot(_Symbol); // fixed lot for simplicity
   if(lot <= 0.0) return;

   const string cmtBase = InpEaName + "|" + InpEaVersion;

   // 11) Execute (market execution)
   if(buySig)
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
         PrintFormat("ORDER_FAIL BUY: retcode=%d", trade.ResultRetcode());
         return;
      }

      g_tradesToday++;
      g_diagTradeSent++;
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

      if(!trade.Sell(lot, _Symbol, 0, sl, tp, cmtBase + "|SELL"))
      {
         g_blockOrderFail++;
         PrintFormat("ORDER_FAIL SELL: retcode=%d", trade.ResultRetcode());
         return;
      }

      g_tradesToday++;
      g_diagTradeSent++;
   }
}

//+------------------------------------------------------------------+
//| Transaction Monitoring & Tracking (via KurosawaTrack.mqh)         |
//| - Keep this wrapper in EA (MQL5 event entrypoint)                |
//| - All tracking logic is inside KurosawaTrack.mqh                 |
//| - We pass timeframe for consistent reporting (Option A)          |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& req,
                        const MqlTradeResult& res)
{
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
      g_lossStreak,
      g_lastCloseTime,
      (ENUM_TIMEFRAMES)_Period, _Symbol  
   );
}
