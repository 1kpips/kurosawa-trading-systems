//+------------------------------------------------------------------+
//| File: Tokyo_RangeRevert_USDJPY_M5.mq5                            |
//| EA  : Tokyo_RangeRevert_USDJPY_M5                                |
//| Ver : 0.1.6-track                                                |
//|                                                                  |
//| Tokyo Range Mean Reversion (USDJPY / M5)                         |
//| - Session (JST): 09:00 -> 23:00                                  |
//| - Entry: BB edge break + RSI extreme + ADX quiet                 |
//| - Exit : Mid-band touch (optional) OR MaxHoldMinutes             |
//| - Safety: Spread gate, cooldown, daily cap, loss streak          |
//| - Positioning: 1 position per EA instance (Magic)                |
//| - Tracking: OPEN/CLOSE + OnNewBar excursions via KurosawaTrack   |
//|                                                                  |
//| Fix focus (why it didn't trade)                                  |
//| - Make ADX gate actually evaluate the ADX MAIN line (buffer 0)   |
//| - Make iBands buffers explicit (Upper=0, Middle=1, Lower=2)      |
//| - Count blocks per evaluated bar (not per tick)                  |
//| - Add optional "soft" ADX gate (filter strength)                 |
//| - Keep signals on CLOSED bar (shift=1)                           |
//| - Mid-band exit uses CURRENT band (shift=0)                      |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
#include "KurosawaHelpers.mqh"
#include "KurosawaTrack.mqh"

CTrade trade;

//==================== Identity ====================//
input int    InpMagic              = 2026010606;
input string InpEaId               = "ea-tokyo-range-usdjpy-m5";
input string InpEaName             = "Tokyo_RangeRevert_USDJPY_M5";
input string InpEaVersion          = "0.1.6";

//==================== Session (JST) ====================//
input int    InpJstStartHour       = 9;
input int    InpJstEndHour         = 23;
input int    InpJstUtcOffset       = 9;

//==================== Strategy: Range Reversion ====================//

// Bollinger Bands period
// Smaller (12–18): bands react faster → more touches/breaks → more trades, more noise.
// Larger (24–40): bands smoother → fewer signals, often higher “true stretch” quality.
input int    InpBBPeriod           = 20;

// Bollinger deviation (band width)
// Larger (2.2–2.8): wider bands → fewer signals, stronger extremes, often better quality.
// Smaller (1.6–2.0): tighter bands → more signals, but more “normal movement” looks like extremes.
input double InpBBDev              = 2.0;


// RSI settings for “extreme” confirmation
// RSI period:
// Smaller (7–10): more reactive → more extreme readings → more trades, more false extremes.
// Larger (14–21): smoother → fewer extremes, cleaner confirmation but later.
input int    InpRsiPeriod          = 14;

// BuyBelow (oversold threshold)
// Higher (38–45): easier to qualify as oversold → more buys, earlier entries, higher noise risk.
// Lower (25–33): deeper oversold required → fewer buys, often better price but can miss.
input double InpRsiBuyBelow        = 35.0;

// SellAbove (overbought threshold)
// Lower (55–62): easier to qualify as overbought → more sells, earlier entries, higher noise risk.
// Higher (67–75): deeper overbought required → fewer sells, often better timing but can miss.
input double InpRsiSellAbove       = 65.0;


// ADX settings (market regime filter)
// ADX measures “trend strength” (not direction).
// For mean-reversion, we prefer *quiet/weak-trend* regimes.
// If ADX is high, price is trending and “reversion” entries get run over.
input int    InpAdxPeriod          = 14;

// ADX quiet gate switch
// true  -> avoid trending regimes (safer for mean reversion, but can block trades).
// false -> trade regardless of trend strength (more trades, higher blow-up risk in trends).
input bool   InpUseAdxGate         = true;

// Max ADX allowed to trade (quiet threshold)
// Lower (18–25): very strict → fewer trades, avoids trends strongly.
// Higher (30–40): looser → more trades, but more “trend phases” included.
// If your logs show many "adx blocks", raise this gradually (e.g., 32 → 35 → 38).
input double InpMaxAdxToTrade      = 35.0;      // CHANGED default: 35 (was 28)


// Signal mode: close vs wick-based
// true  -> wick signal (High/Low can pierce band) → more signals, faster fills, more noise.
// false -> close-only (Close must pierce band) → fewer signals, cleaner but later.
input bool   InpUseWickSignal      = true;


// Entry quality filters (cost/edge sanity)
// Minimum band break (pips) beyond the outer band to count as a real “stretch”
// Higher (0.8–1.5): fewer trades, stronger extremes only.
// Lower (0.3–0.7): more trades, but more fake-outs.
input double InpMinBandBreakPips   = 0.6;       // CHANGED slightly looser (was 0.8)

// Minimum distance to mid-band relative to spread (edge-over-spread multiple)
// Idea: if the potential reversion distance is not big compared to spread, expectancy suffers.
// Higher (1.6–2.5): fewer trades, better cost profile.
// Lower (1.0–1.4): more trades, but spread can dominate.
input double InpMinEdgeOverSpread  = 1.2;       // CHANGED slightly looser (was 1.4)


//==================== Exits & Operation ====================//

// Mid-band exit
// true  -> exit when price reverts to middle band (dynamic TP). Often higher hit rate, shorter holds.
// false -> use fixed TP in pips (InpTpPips).
input bool   InpUseMidBandExit     = true;


// Protective SL/TP (pips)
// Stop-loss in pips
// Larger SL: fewer stopouts, but bigger losses per trade (fixed-lot case).
// Smaller SL: more stopouts from noise/spread, especially on USDJPY.
input double InpSlPips             = 10.0;

// Fixed TP in pips (used only when MidBandExit is OFF)
// Larger TP: fewer wins but bigger winners.
// Smaller TP: higher win rate, but costs matter more.
input double InpTpPips             = 6.0;       // Used only when MidBandExit is OFF


// Daily trade cap
// Lower: avoids overtrading / clustering.
// Higher: more opportunities, but can stack correlated losses in bad regimes.
input int    InpMaxTradesPerDay    = 30;

// Cooldown between entries (minutes)
// Higher: fewer re-entries during chop; reduces churn.
// Lower: more trades; can get chopped on repeated band touches.
input int    InpCooldownMinutes    = 3;

// Time stop (minutes)
// Smaller: “fails fast,” reduces time risk but may cut valid reversion.
// Larger: allows more time to mean-revert, but increases reversal and overnight risk.
input int    InpMaxHoldMinutes     = 120;


// Spread gate (points)
// Lower: avoids poor fills; fewer trades during spread spikes.
// Higher: more fills, but expectancy worsens if spread is large vs edge.
// USDJPY (3 digits): 1 pip = 10 points, so 25 points = 2.5 pips.
input double InpMaxSpreadPoints    = 25.0;


// Loss-streak safety stop
// Lower (2): very conservative; may stop right before conditions improve.
// Higher (4–6): trades through bad patches; larger drawdown tail risk.
input int    InpMaxConsecLosses    = 3;

//==================== Tracking ====================//
input bool   InpTrackEnable        = true;
input bool   InpTrackSendOpen      = true;

//==================== Indicator Handles & Runtime State ====================//
int hBB  = INVALID_HANDLE;
int hRSI = INVALID_HANDLE;
int hADX = INVALID_HANDLE;

datetime g_lastBarTime   = 0;
datetime g_lastCloseTime = 0;

int g_tradesToday = 0;
int g_lossStreak  = 0;
int g_lastJstYmd  = 0;

// Tracking guards/state (shared with KurosawaTrack)
ulong g_lastOpenDealId   = 0;
ulong g_lastClosedDealId = 0;
int   g_consecLosses     = 0; // updated by KurosawaTrack on CLOSE, do not reset daily

// Diagnostics (per day)
int g_diagBars      = 0;
int g_diagSignal    = 0;
int g_diagTradeSent = 0;

// Block counters (per day, counted per evaluated BAR)
int g_blockSession   = 0;
int g_blockSpread    = 0;
int g_blockMaxDay    = 0;
int g_blockLoss      = 0;
int g_blockCooldown  = 0;
int g_blockHasPos    = 0;
int g_blockAdx       = 0;
int g_blockNoSignal  = 0;
int g_blockStops     = 0;
int g_blockOrderFail = 0;

// Optional debug counters to pinpoint "no signal" cause
int g_dbgBandTouchFail = 0;
int g_dbgRsiFail       = 0;
int g_dbgEdgeFail      = 0;

//+------------------------------------------------------------------+
//| Guards                                                           |
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
   const double spreadPts = (ask - bid) / _Point;
   return (spreadPts <= InpMaxSpreadPoints);
}

// IMPORTANT FIX: ensure ADX gate reads ADX MAIN line (buffer 0)
// Some helper implementations accidentally read DI buffers, which changes meaning.
bool AdxQuietOK()
{
   if(!InpUseAdxGate) return true;

   double adxMain[1];
   if(CopyBuffer(hADX, 0, 1, 1, adxMain) != 1)  // buffer 0 = ADX main line, shift=1 closed bar
      return false;

   return (adxMain[0] <= InpMaxAdxToTrade);
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

   PrintFormat("Signal Debug | bandFail=%d rsiFail=%d edgeFail=%d", g_dbgBandTouchFail, g_dbgRsiFail, g_dbgEdgeFail);
   PrintFormat("Streaks | localLossStreak=%d trackConsecLoss=%d", g_lossStreak, g_consecLosses);
}

void ResetDailyIfNeeded()
{
   const int ymd = JstYmd(NowJst(InpJstUtcOffset));
   if(ymd == g_lastJstYmd) return;

   if(g_lastJstYmd != 0)
      PrintDailySummary();

   g_lastJstYmd  = ymd;
   g_tradesToday = 0;
   g_lossStreak  = 0;

   g_diagBars      = 0;
   g_diagSignal    = 0;
   g_diagTradeSent = 0;

   g_blockSession   = 0;
   g_blockSpread    = 0;
   g_blockMaxDay    = 0;
   g_blockLoss      = 0;
   g_blockCooldown  = 0;
   g_blockHasPos    = 0;
   g_blockAdx       = 0;
   g_blockNoSignal  = 0;
   g_blockStops     = 0;
   g_blockOrderFail = 0;

   g_dbgBandTouchFail = 0;
   g_dbgRsiFail       = 0;
   g_dbgEdgeFail      = 0;

   // NOTE: do not reset g_consecLosses here (tracking-based risk state)
}

//+------------------------------------------------------------------+
//| Initialization / Deinitialization                                |
//+------------------------------------------------------------------+
int OnInit()
{
   if(_Period != PERIOD_M5)
   {
      Print("CRITICAL: Attach to M5 chart only.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);

   hBB  = iBands(_Symbol, _Period, InpBBPeriod, 0, InpBBDev, PRICE_CLOSE); // buffers: 0=upper,1=mid,2=lower
   hRSI = iRSI(_Symbol, _Period, InpRsiPeriod, PRICE_CLOSE);
   hADX = iADX(_Symbol, _Period, InpAdxPeriod); // buffers: 0=ADX,1=+DI,2=-DI

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
//| Exit Management                                                  |
//+------------------------------------------------------------------+
void CheckMeanReversionExits()
{
   // Mid-band exit uses CURRENT band (shift=0) so you do not wait one extra bar
   double midNow = 0.0;
   if(InpUseMidBandExit)
   {
      double bbM[1];
      if(CopyBuffer(hBB, 1, 0, 1, bbM) != 1) return; // buffer 1 = middle band
      midNow = bbM[0];
      if(midNow <= 0.0) return;
   }

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      const long type = PositionGetInteger(POSITION_TYPE);
      const datetime openT = (datetime)PositionGetInteger(POSITION_TIME);

      // 1) Time stop
      if(InpMaxHoldMinutes > 0 && (TimeCurrent() - openT) >= (InpMaxHoldMinutes * 60))
      {
         trade.PositionClose(ticket);
         g_lastCloseTime = TimeCurrent();
         return;
      }

      // 2) Mid-band exit
      if(InpUseMidBandExit)
      {
         const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(bid <= 0.0 || ask <= 0.0) return;

         if((type == POSITION_TYPE_BUY  && bid >= midNow) ||
            (type == POSITION_TYPE_SELL && ask <= midNow))
         {
            trade.PositionClose(ticket);
            g_lastCloseTime = TimeCurrent();
            return;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| OnTick: Main Execution                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   ResetDailyIfNeeded();

   // Exit management every tick
   CheckMeanReversionExits();

   // New bar gate (evaluate once per M5 bar)
   const datetime t0 = iTime(_Symbol, _Period, 0);
   if(t0 == g_lastBarTime) return;

   g_lastBarTime = t0;
   g_diagBars++;

   // Tracking excursions update (Option A: caller passes timeframe)
   KurosawaTrack_OnNewBar(InpTrackEnable, InpMagic, _Symbol, (ENUM_TIMEFRAMES)_Period);

   // Session gate (counted per evaluated bar)
   if(!IsEntryTimeJST(InpJstStartHour, InpJstEndHour, InpJstUtcOffset))
   {
      g_blockSession++;
      return;
   }

   // Quotes & spread gate
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return;

   if(!SpreadOK(ask, bid))
   {
      g_blockSpread++;
      return;
   }

   // Risk gates
   if(g_tradesToday >= InpMaxTradesPerDay) { g_blockMaxDay++; return; }
   if(g_lossStreak  >= InpMaxConsecLosses) { g_blockLoss++; return; }
   if(!CooldownOK())                      { g_blockCooldown++; return; }

   // One position per EA instance
   if(PositionExists(_Symbol, InpMagic)) { g_blockHasPos++; return; }

   // Regime gate (ADX quiet)
   if(!AdxQuietOK()) { g_blockAdx++; return; }

   // Read indicators on last closed bar (shift=1)
   double bbU[1], bbM[1], bbL[1], rsi[1];
   if(CopyBuffer(hBB,  0, 1, 1, bbU) != 1) return; // upper
   if(CopyBuffer(hBB,  1, 1, 1, bbM) != 1) return; // middle
   if(CopyBuffer(hBB,  2, 1, 1, bbL) != 1) return; // lower
   if(CopyBuffer(hRSI, 0, 1, 1, rsi) != 1) return;

   const double upper1 = bbU[0];
   const double mid1   = bbM[0];
   const double lower1 = bbL[0];
   const double rsi1   = rsi[0];

   // Closed bar price references
   const double c1 = iClose(_Symbol, _Period, 1);
   const double h1 = iHigh(_Symbol,  _Period, 1);
   const double l1 = iLow(_Symbol,   _Period, 1);

   // Entry quality thresholds
   const double minBreak = PipsToPrice(_Symbol, InpMinBandBreakPips);

   const double spreadPrice = (ask - bid);
   const double minEdge     = spreadPrice * InpMinEdgeOverSpread;

   // Choose reference for band touch/break
   const double refLow  = (InpUseWickSignal ? l1 : c1);
   const double refHigh = (InpUseWickSignal ? h1 : c1);

   const bool bandBuy  = (refLow  < (lower1 - minBreak));
   const bool bandSell = (refHigh > (upper1 + minBreak));

   const bool rsiBuy   = (rsi1 <= InpRsiBuyBelow);
   const bool rsiSell  = (rsi1 >= InpRsiSellAbove);

   const bool edgeBuy  = ((mid1 - c1) > minEdge);
   const bool edgeSell = ((c1 - mid1) > minEdge);

   // Signals
   const bool buySig  = (bandBuy  && rsiBuy  && edgeBuy);
   const bool sellSig = (bandSell && rsiSell && edgeSell);

   if(!buySig && !sellSig)
   {
      // Debug why
      if(!(bandBuy || bandSell)) g_dbgBandTouchFail++;
      else if(!(rsiBuy || rsiSell)) g_dbgRsiFail++;
      else if(!(edgeBuy || edgeSell)) g_dbgEdgeFail++;

      g_blockNoSignal++;
      return;
   }
   g_diagSignal++;

   // SL/TP distances
   const double slDist = PipsToPrice(_Symbol, InpSlPips);
   const double tpDist = PipsToPrice(_Symbol, InpTpPips);
   if(slDist <= 0.0) return;

   // Fixed lot for this EA (simple, predictable)
   const double lot = GetMinLot(_Symbol);

   const string cmtBase = InpEaName + "|" + InpEaVersion;

   if(buySig)
   {
      double sl = NormalizeDouble(ask - slDist, _Digits);
      double tp = (InpUseMidBandExit ? 0.0 : NormalizeDouble(ask + tpDist, _Digits));

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
      double tp = (InpUseMidBandExit ? 0.0 : NormalizeDouble(bid - tpDist, _Digits));

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
//| Trade Transaction Handler                                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& req,
                        const MqlTradeResult& res)
{
   // Local loss streak + cooldown anchor (based on DEAL closes)
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      const datetime now = TimeCurrent();
      HistorySelect(now - 86400, now + 60);

      if(HistoryDealSelect(trans.deal))
      {
         if((int)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) == InpMagic)
         {
            const long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);

            if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY || entry == DEAL_ENTRY_INOUT)
            {
               const double profit =
                  HistoryDealGetDouble(trans.deal, DEAL_PROFIT) +
                  HistoryDealGetDouble(trans.deal, DEAL_SWAP) +
                  HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

               g_lossStreak    = (profit < 0.0) ? (g_lossStreak + 1) : 0;
               g_lastCloseTime = TimeCurrent();
            }
         }
      }
   }

   // Tracking (Option A: timeframe is provided by caller)
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
