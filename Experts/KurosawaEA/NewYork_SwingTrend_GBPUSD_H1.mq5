//+------------------------------------------------------------------+
//| File: NewYork_SwingTrend_GBPUSD_H1.mq5                           |
//| EA  : NewYork_SwingTrend_GBPUSD_H1                               |
//| Ver : 0.1.4-track                                                |
//|                                                                  |
//| New York Swing Trend (GBPUSD / H1)                               |
//| - Trend: EMA(fast) vs EMA(slow) on last CLOSED bar (shift=1)     |
//| - Entry: RSI pullback in trend direction (closed bar)            |
//| - Stops: ATR-based SL/TP, optional ATR trailing                  |
//| - Session: New York window expressed in JST (22:00 -> 05:00)     |
//| - Safety: spread gate, cooldown, daily cap, loss streak          |
//| - Risk exits: optional max-hold close, optional weekend flatten  |
//| - Positioning: 1 position per EA instance (symbol + magic)       |
//| - Execution: market orders (price=0)                             |
//| - Tracking: OPEN/CLOSE + OnNewBar excursions via KurosawaTrack   |
//|                                                                  |
//| Notes                                                            |
//| - Attach ONLY to GBPUSD H1 chart.                                |
//| - Signals use CLOSED BAR (shift=1) for stability.                |
//| - Trailing uses CURRENT ATR (shift=0) for responsiveness.        |
//| - WebRequest URL allowlist is handled by tracker file setup.     |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
#include "KurosawaHelpers.mqh"
#include "KurosawaTrack.mqh"

CTrade trade;

//==================== Identity ====================//
input int    InpMagic              = 2026011004;
input string InpEaId               = "ea-ny-swingtrend-gbpusd-h1";
input string InpEaName             = "NewYork_SwingTrend_GBPUSD_H1";
input string InpEaVersion          = "0.1.4";   // CHANGED

//==================== Session (JST) ====================//
// 22 -> 5 means 22:00 JST to 05:00 JST (cross-midnight supported by helper).
input int    InpJstStartHour       = 22;
input int    InpJstEndHour         = 5;
input int    InpJstUtcOffset       = 9;

//==================== Strategy: Trend & Pullback ====================//

// Trend regime (fast/slow)
// Smaller fast or smaller slow -> reacts faster, more flips, more trades.
// Larger slow -> stricter trend filter, fewer trades, can miss early turns.
input int    InpEmaFast            = 50;
input int    InpEmaSlow            = 200;

// RSI pullback (mean pullback inside trend)
// Lower buy threshold -> deeper pullback required (fewer, often better price).
// Higher buy threshold -> more buys, earlier, more noise.
// Higher sell threshold -> deeper pullback required (fewer, often better price).
input int    InpRsiPeriod          = 14;
input double InpRsiBuyPullback     = 45.0; // uptrend AND RSI <= this -> BUY candidate
input double InpRsiSellPullback    = 55.0; // downtrend AND RSI >= this -> SELL candidate

// Optional cross-back confirmation (reduces “knife catching”)
// true  -> RSI must cross back across a level (fewer but cleaner entries).
// false -> simple threshold pullback (more trades, more early entries).
input bool   InpUseRsiCrossConfirm = true;
input double InpRsiBuyCrossLevel   = 45.0; // BUY when RSI crosses UP above this (after being below)
input double InpRsiSellCrossLevel  = 55.0; // SELL when RSI crosses DOWN below this (after being above)

//==================== Stops: ATR ====================//

// ATR window
// Smaller -> reacts faster, noisier stops.
// Larger  -> smoother, slower-changing stops.
input int    InpAtrPeriod          = 14;

// SL/TP multipliers
// Higher SL mult -> wider SL, fewer stopouts, larger loss per trade (fixed lot).
// Higher TP mult -> bigger winners, lower hit rate, more “almost then reverse”.
input double InpAtrSlMult          = 2.0;
input double InpAtrTpMult          = 3.0;

//==================== Management ====================//

// Trailing
// Start trailing after price moves in favor by ATR * StartMult.
// Trailing gap from price = ATR * StepMult.
input bool   InpUseTrailing        = true;
input double InpTrailStartAtrMult  = 1.5;
input double InpTrailStepAtrMult   = 1.0;

// Time stop (hours) for swing protection
// 0 disables. Smaller -> fails faster; larger -> lets trends run.
input int    InpMaxHoldHours       = 96;

//==================== Risk & Safety ====================//

// Spread gate (points)
// Lower -> avoids poor fills, fewer trades during spread spikes.
// 0 disables.
input double InpMaxSpreadPoints    = 20;

// Daily cap and cooldown
// Cooldown is from *last CLOSE time* (updated by trade transaction tracking).
input int    InpMaxTradesPerDay    = 4;
input int    InpCooldownMinutes    = 60;

// Stop trading after N consecutive losses (updated by tracker on CLOSE)
// Keep persistent across days (do NOT reset daily), otherwise you hide regime risk.
input int    InpMaxConsecLosses    = 3;

// Weekend flatten
input bool   InpCloseBeforeWeekend = true;
input int    InpFridayCloseHourJst = 22;

//==================== Tracking ====================//
input bool   InpTrackEnable        = true;
input bool   InpTrackSendOpen      = true;

//==================== Handles ====================//
int hEmaFast = INVALID_HANDLE;
int hEmaSlow = INVALID_HANDLE;
int hRsi     = INVALID_HANDLE;
int hAtr     = INVALID_HANDLE;

//==================== Runtime State ====================//
datetime g_lastBarTime   = 0;   // new-bar guard
datetime g_lastCloseTime = 0;   // cooldown anchor (updated by tracking wrapper)

int g_tradesToday  = 0;         // resets daily (JST)
int g_consecLosses = 0;         // updated by tracker on CLOSE (do NOT reset daily)
int g_lastJstYmd   = 0;

// Tracking dedupe (prevent duplicate posts)
ulong g_lastOpenDealId   = 0;
ulong g_lastClosedDealId = 0;

// Diagnostics (per day)
int g_diagBars      = 0;
int g_diagSignal    = 0;
int g_diagTradeSent = 0;

// Block counters (per evaluated BAR)
int g_blockSession   = 0;
int g_blockSpread    = 0;
int g_blockCooldown  = 0;
int g_blockHasPos    = 0;
int g_blockLoss      = 0;
int g_blockMaxDay    = 0;
int g_blockNoSignal  = 0;
int g_blockStops     = 0;
int g_blockOrderFail = 0;

//+------------------------------------------------------------------+
//| Local helpers                                                    |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   const datetime t0 = iTime(_Symbol, _Period, 0);
   if(t0 == g_lastBarTime) return false;
   g_lastBarTime = t0;
   return true;
}

bool SpreadOK(const double ask, const double bid)
{
   if(InpMaxSpreadPoints <= 0.0) return true;
   return ((ask - bid) / _Point) <= InpMaxSpreadPoints;
}

bool CooldownOK()
{
   if(InpCooldownMinutes <= 0) return true;
   if(g_lastCloseTime <= 0)    return true;
   return (TimeCurrent() - g_lastCloseTime) >= (InpCooldownMinutes * 60);
}

bool IsWeekendWindowJst()
{
   MqlDateTime dt;
   TimeToStruct(NowJst(InpJstUtcOffset), dt);
   // 5=Friday, 6=Saturday
   return ((dt.day_of_week == 5 && dt.hour >= InpFridayCloseHourJst) || (dt.day_of_week == 6));
}

void PrintDailySummary()
{
   PrintFormat(
      "--- DAILY SUMMARY [%d] --- Bars:%d Signals:%d TradesSent:%d TradesToday:%d ConsecLoss:%d",
      g_lastJstYmd, g_diagBars, g_diagSignal, g_diagTradeSent, g_tradesToday, g_consecLosses
   );

   PrintFormat(
      "Blocks | session=%d spread=%d cooldown=%d haspos=%d loss=%d maxday=%d nosignal=%d stops=%d orderfail=%d",
      g_blockSession, g_blockSpread, g_blockCooldown, g_blockHasPos,
      g_blockLoss, g_blockMaxDay, g_blockNoSignal, g_blockStops, g_blockOrderFail
   );
}

void ResetDailyIfNeeded()
{
   const int ymd = JstYmd(NowJst(InpJstUtcOffset));
   if(ymd == g_lastJstYmd) return;

   if(g_lastJstYmd != 0)
      PrintDailySummary();

   g_lastJstYmd   = ymd;
   g_tradesToday  = 0;

   g_diagBars      = 0;
   g_diagSignal    = 0;
   g_diagTradeSent = 0;

   g_blockSession   = 0;
   g_blockSpread    = 0;
   g_blockCooldown  = 0;
   g_blockHasPos    = 0;
   g_blockLoss      = 0;
   g_blockMaxDay    = 0;
   g_blockNoSignal  = 0;
   g_blockStops     = 0;
   g_blockOrderFail = 0;

   // NOTE: do NOT reset g_consecLosses here (risk guard must persist).
}

void EnforceMaxHoldHours()
{
   if(InpMaxHoldHours <= 0) return;
   if(!PositionSelectByMagic(_Symbol, (long)InpMagic)) return;

   const datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
   if(opened <= 0) return;

   if((TimeCurrent() - opened) >= (InpMaxHoldHours * 3600))
   {
      trade.PositionClose(_Symbol);
      // Ideally updated by CLOSE tracking, but keep local anchor to avoid re-entry spam.
      g_lastCloseTime = TimeCurrent();
   }
}

void ApplyAtrTrailing(const double atrNow)
{
   if(!InpUseTrailing) return;
   if(atrNow <= 0.0)   return;

   if(!PositionSelectByMagic(_Symbol, (long)InpMagic)) return;

   const long   posType = PositionGetInteger(POSITION_TYPE);
   const double open    = PositionGetDouble(POSITION_PRICE_OPEN);
   const double slNow   = PositionGetDouble(POSITION_SL);
   const double tpNow   = PositionGetDouble(POSITION_TP);

   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0) return;

   if(posType == POSITION_TYPE_BUY)
   {
      // Start trailing only after meaningful favorable move
      if((bid - open) < (atrNow * InpTrailStartAtrMult)) return;

      double proposedSl = NormalizeDouble(bid - (atrNow * InpTrailStepAtrMult), _Digits);

      // Validate with broker stop levels (and keep TP)
      double slTmp = proposedSl;
      double tpTmp = tpNow;
      if(!EnsureStopsLevel(_Symbol, bid, slTmp, tpTmp, true, true)) return;

      if(slNow <= 0.0 || slTmp > slNow)
         trade.PositionModify(_Symbol, slTmp, tpNow);
   }
   else if(posType == POSITION_TYPE_SELL)
   {
      if((open - ask) < (atrNow * InpTrailStartAtrMult)) return;

      double proposedSl = NormalizeDouble(ask + (atrNow * InpTrailStepAtrMult), _Digits);

      double slTmp = proposedSl;
      double tpTmp = tpNow;
      if(!EnsureStopsLevel(_Symbol, ask, slTmp, tpTmp, false, true)) return;

      if(slNow <= 0.0 || slTmp < slNow)
         trade.PositionModify(_Symbol, slTmp, tpNow);
   }
}

//+------------------------------------------------------------------+
//| Init / Deinit                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   if(_Period != PERIOD_H1)
   {
      Print("CRITICAL: Attach this EA to an H1 chart.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);

   hEmaFast = iMA(_Symbol, _Period, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow = iMA(_Symbol, _Period, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   hRsi     = iRSI(_Symbol, _Period, InpRsiPeriod, PRICE_CLOSE);
   hAtr     = iATR(_Symbol, _Period, InpAtrPeriod);

   if(hEmaFast == INVALID_HANDLE || hEmaSlow == INVALID_HANDLE ||
      hRsi     == INVALID_HANDLE || hAtr     == INVALID_HANDLE)
   {
      Print("CRITICAL: Indicator handle creation failed.");
      return INIT_FAILED;
   }

   g_lastJstYmd = JstYmd(NowJst(InpJstUtcOffset));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hEmaFast != INVALID_HANDLE) IndicatorRelease(hEmaFast);
   if(hEmaSlow != INVALID_HANDLE) IndicatorRelease(hEmaSlow);
   if(hRsi     != INVALID_HANDLE) IndicatorRelease(hRsi);
   if(hAtr     != INVALID_HANDLE) IndicatorRelease(hAtr);
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1) Daily rollover (JST) + daily summary
   ResetDailyIfNeeded();

   // 2) Weekend protection (optional)
   if(InpCloseBeforeWeekend && IsWeekendWindowJst())
   {
      if(PositionSelectByMagic(_Symbol, (long)InpMagic))
      {
         trade.PositionClose(_Symbol);
         g_lastCloseTime = TimeCurrent();
      }
      return;
   }

   // 3) Time stop (optional)
   EnforceMaxHoldHours();

   // 4) Trailing (optional) using CURRENT ATR (shift=0)
   double atr0[1];
   if(CopyBuffer(hAtr, 0, 0, 1, atr0) == 1)
      ApplyAtrTrailing(atr0[0]);

   // 5) Evaluate once per new bar (so counters make sense)
   if(!IsNewBar()) return;
   g_diagBars++;

   // 5.1) Tracking excursion update (Option A: caller supplies timeframe)
   KurosawaTrack_OnNewBar(InpTrackEnable, InpMagic, _Symbol, (ENUM_TIMEFRAMES)_Period);

   // 6) Session gate (counted per evaluated bar)
   if(!IsEntryTimeJST(InpJstStartHour, InpJstEndHour, InpJstUtcOffset))
   {
      g_blockSession++;
      return;
   }

   // 7) Quotes + spread gate (counted per evaluated bar)
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return;

   if(!SpreadOK(ask, bid))
   {
      g_blockSpread++;
      return;
   }

   // 8) Risk gates (counted per evaluated bar)
   if(g_tradesToday >= InpMaxTradesPerDay) { g_blockMaxDay++; return; }
   if(g_consecLosses >= InpMaxConsecLosses){ g_blockLoss++;   return; }
   if(!CooldownOK())                       { g_blockCooldown++; return; }
   if(PositionExists(_Symbol, InpMagic))    { g_blockHasPos++; return; }

   // 9) Read CLOSED BAR values (shift=1)
   double f1[1], s1[1], r1[1], a1[1];
   if(CopyBuffer(hEmaFast, 0, 1, 1, f1) != 1) return;
   if(CopyBuffer(hEmaSlow, 0, 1, 1, s1) != 1) return;
   if(CopyBuffer(hRsi,     0, 1, 1, r1) != 1) return;
   if(CopyBuffer(hAtr,     0, 1, 1, a1) != 1) return;

   const double emaF_1 = f1[0];
   const double emaS_1 = s1[0];
   const double rsi_1  = r1[0];
   const double atr_1  = a1[0];
   if(atr_1 <= 0.0) return;

   double rsi_2 = rsi_1;
   if(InpUseRsiCrossConfirm)
   {
      double r2[1];
      if(CopyBuffer(hRsi, 0, 2, 1, r2) != 1) return;
      rsi_2 = r2[0];
   }

   const bool uptrend   = (emaF_1 > emaS_1);
   const bool downtrend = (emaF_1 < emaS_1);

   bool buySig = false, sellSig = false;

   if(!InpUseRsiCrossConfirm)
   {
      buySig  = (uptrend   && rsi_1 <= InpRsiBuyPullback);
      sellSig = (downtrend && rsi_1 >= InpRsiSellPullback);
   }
   else
   {
      buySig  = (uptrend   && rsi_2 <= InpRsiBuyCrossLevel  && rsi_1 > InpRsiBuyCrossLevel);
      sellSig = (downtrend && rsi_2 >= InpRsiSellCrossLevel && rsi_1 < InpRsiSellCrossLevel);
   }

   if(!buySig && !sellSig)
   {
      g_blockNoSignal++;
      return;
   }
   g_diagSignal++;

   // 10) ATR-based SL/TP (based on closed-bar ATR)
   const double slDist = atr_1 * InpAtrSlMult;
   const double tpDist = atr_1 * InpAtrTpMult;
   if(slDist <= 0.0 || tpDist <= 0.0) return;

   // Fixed lot (simple). If you want risk sizing, we can add CalcRiskLotBySLDistance like the swing template.
   const double lot = GetMinLot(_Symbol);
   if(lot <= 0.0) return;

   const string cmtBase = InpEaName + "|" + InpEaVersion;

   // 11) Execute (market execution: price=0)
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
//| Transaction Monitoring & Tracking (via KurosawaTrack.mqh)        |
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
      g_consecLosses,
      g_lastCloseTime,
      (ENUM_TIMEFRAMES)_Period, _Symbol  
   );
}
