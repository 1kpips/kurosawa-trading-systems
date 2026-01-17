//+------------------------------------------------------------------+
//| File: Tokyo_SwingTrend_USDJPY_H1.mq5                             |
//| EA  : Tokyo_SwingTrend_USDJPY_H1                                 |
//| Ver : 0.1.4-track                                                |
//|                                                                  |
//| CHANGELOG (v0.1.4 / 2026-01-17):                                 |
//| - Integrate Option A tracking timeframe hooks (pass _Period)     |
//| - Call KurosawaTrack_OnNewBar() so MFE/MAE + barsHeld are logged |
//| - Fix daily reset: DO NOT reset consecLosses daily (risk guard)  |
//| - Add daily summary print (consistent with other EAs)            |
//| - Safer HistorySelect window in tracking is handled in .mqh      |
//| - Small robustness: validate lot/SL distance, normalize prices   |
//|                                                                  |
//| Strategy                                                         |
//| - H1 only (enforced)                                             |
//| - Trend: EMA(50) vs EMA(200)                                     |
//| - Entry: RSI pullback (optional cross-back confirm)              |
//| - Filters: ATR min, optional ADX                                 |
//| - Risk: ATR SL + R-multiple TP                                   |
//| - Optional trailing: ATR step after R threshold                  |
//| - Session: Tokyo window (JST)                                    |
//| - Tracking: OPEN/CLOSE + local CSV excursions via KurosawaTrack  |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
#include "KurosawaHelpers.mqh"
#include "KurosawaTrack.mqh"

CTrade trade;

//==================== Identity ====================//
input int    InpMagic              = 2026011008;
input string InpEaId               = "ea-tokyo-swingtrend-usdjpy-h1";
input string InpEaName             = "Tokyo_SwingTrend_USDJPY_H1";
input string InpEaVersion          = "0.1.4"; // CHANGED

//==================== Session: Tokyo (JST) ====================//
input int    InpJstStartHour       = 9;
input int    InpJstEndHour         = 23;
input int    InpJstUtcOffset       = 9;

//==================== Strategy: Trend & Pullback ====================//

// Trend regime (fast)
// Smaller (20–34): trend reacts faster, more flips, more entries, more whipsaws.
// Larger (70–100): trend reacts slower, fewer entries, later entries, smoother but can miss early trend legs.
input int    InpEmaFast            = 50;     

// Trend regime (slow baseline)
// Smaller (100–150): trend filter loosens, more trades, more chop exposure.
// Larger (250–300): stricter filter, fewer trades, tends to avoid chop but may miss medium reversals.
input int    InpEmaSlow            = 200;    

// Pullback sensitivity
// Smaller (7–10): RSI swings more, more pullback triggers, more noise.
// Larger (20–28): RSI smoother, fewer triggers, later pullbacks only.
input int    InpRsiPeriod          = 14;   

// When NOT using cross-confirm: BUY pullback threshold (RSI <=)
// Higher (48–50): easier to qualify as pullback → more buy signals (but earlier / riskier).
// Lower (35–42): deeper pullback required → fewer trades, often better price but can miss.
input double InpRsiBuyPullback     = 45.0;   

// When NOT using cross-confirm: SELL pullback threshold (RSI >=)
// Lower (50–52): easier to qualify as pullback → more sell signals (but earlier / riskier).
// Higher (58–65): deeper pullback required → fewer sells, often better timing but missed entries.
input double InpRsiSellPullback    = 55.0;

// Cross-back confirmation:
// true  -> RSI must "return" across a level (reduces knife-catching, fewer but cleaner entries).
// false -> passive threshold entry (more trades, more early entries, more drawdown in reversals).
input bool   InpUseRsiCrossConfirm = true;   

// With cross-confirm: BUY only when RSI crosses UP above this after being below
// Higher (47–50): more confirmation → fewer trades, later entries, lower false positives.
// Lower (40–44): weaker confirmation → more trades, earlier entries, more fake-outs.
input double InpRsiBuyCrossLevel   = 45.0;  

// With cross-confirm: SELL only when RSI crosses DOWN below this after being above
// Lower (50–53): more confirmation (because must cross lower) → fewer sells, later entries.
// Higher (56–60): easier to cross below → more sells, earlier entries, more fake-outs.
input double InpRsiSellCrossLevel  = 55.0;   

//==================== Market Quality Filters ====================//

// Volatility measurement window
// Smaller (7–10): ATR reacts faster → filter responds quickly to volatility changes.
// Larger (20–28): ATR smoother → fewer sudden "on/off" switches.
input int    InpAtrPeriod          = 14;     

// Minimum volatility to trade (ATR in pips)
// Higher (10–15): avoids dead hours, fewer trades, generally cleaner moves.
// Lower (3–6): more trades in quiet markets, higher chop risk (esp. USDJPY).
input double InpAtrMinPips         = 8.0;   

// Trend-strength gate
// true  -> fewer trades, avoids weak trends.
// false -> more trades, but more range conditions sneak in.
input bool   InpUseAdxFilter       = true;   

// ADX measurement window
// Smaller: more reactive but noisy; larger: smoother but late.
input int    InpAdxPeriod          = 14;     

// Required trend strength (if enabled)
// Higher (22–28): fewer trades, higher trend quality, may miss early trend starts.
// Lower (14–18): more trades, but more sideways market participation.
input double InpMinAdxToTrade      = 18.0;

//==================== Stops & Exit Management ====================//

// Stop distance = ATR * multiplier
// Higher (2.5–3.5): wider SL, fewer stopouts, larger loss per trade, smaller lot (risk sizing), longer holds.
// Lower (1.2–1.8): tighter SL, more stopouts, bigger lot (risk sizing), more sensitive to noise.
input double InpSlAtrMult          = 2.0;    

// Target distance = SL distance * R multiple
// Higher (2.0–3.0): bigger winners but lower hit rate, more "almost TP then reverse" without management.
// Lower (1.0–1.4): higher hit rate, smaller winners, tends to smooth equity.
input double InpTpRMultiple        = 1.4;    

// Enable trailing logic after price moves in favor
// true  -> protects winners, may cut big trends early if too aggressive.
// false -> cleaner distribution, relies on TP/time stop; can give back large open profit.
input bool   InpUseTrailing        = true;   

// Start trailing once price moves >= 1.5R
// Higher (1.8–2.5): gives trades room; more full TP hits; bigger drawdown on reversals.
// Lower (0.8–1.2): protects earlier; more small wins; more "stop-out after partial move".
input double InpTrailStartR        = 1.2;   

// Trailing gap = ATR * step multiplier
// Higher (1.3–2.0): looser trailing; stays in trends; gives back more before exit.
// Lower (0.6–1.0): tighter trailing; exits earlier; reduces giveback but increases churn. 
input double InpTrailStepAtrMult   = 1.1;    

// Time stop
// Smaller (24–72): exits sooner; reduces weekend/news exposure; may cut valid swings.
// Larger (120–240): allows long trends; increases carry/overnight risks and reversal giveback.
input int    InpMaxHoldHours       = 96;     

//==================== Risk & Safety ====================//

// Spread gate (points)
// Lower: avoids bad fills; fewer trades during spread spikes.
// Higher: more fills; but worsens expectancy (esp. scalps/entries near threshold).
input double InpMaxSpreadPoints    = 20;   

// Daily activity cap
// Lower: prevents overtrading and clustering; may miss multi-signal days.
// Higher: more opportunities; more correlated exposure in one session.
input int    InpMaxTradesPerDay    = 4;      

// Stop trading after N consecutive losses
// Lower (2): more conservative; avoids tilt regimes but may stop right before regime improves.
// Higher (4–6): trades through rough patches; bigger drawdown tails.
input int    InpMaxConsecLosses    = 3;      

// Flatten into weekend
// true  -> avoids weekend gaps; may exit profitable trends early.
// false -> can capture weekend continuation; risk of gap against SL/TP.
input bool   InpCloseBeforeWeekend = true;   

// JST hour to stop/close on Friday (if enabled)
// Earlier: safer, less liquidity risk; may cut too soon.
// Later: more time to hit TP; more spread / whipsaw risk into market close.
input int    InpFridayCloseHourJst = 22;     

// Equity risk per trade (%)
// Higher (0.75–1.0): faster growth, much larger drawdowns.
// Lower (0.10–0.30): smoother equity, slower growth.
// With ATR SL, risk sizing will auto-adjust lot smaller when SL is wide.
input double InpRiskPercent        = 0.30;   

//==================== Tracking ====================//

input bool   InpTrackEnable        = true;   // Master tracking switch
input bool   InpTrackSendOpen      = true;   // Send OPEN events too (useful to reconstruct incomplete closes)

//==================== Indicator Handles & State ====================//

int hEmaFast = INVALID_HANDLE;              // EMA fast handle
int hEmaSlow = INVALID_HANDLE;              // EMA slow handle
int hRsi     = INVALID_HANDLE;              // RSI handle
int hAtr     = INVALID_HANDLE;              // ATR handle
int hAdx     = INVALID_HANDLE;              // ADX handle

datetime g_lastBarTime   = 0;               // New-bar guard; ensures 1 evaluation per bar
datetime g_lastCloseTime = 0;               // Used for cooldown / logging if you implement it

int g_tradesToday     = 0;                  // Resets daily (JST) to enforce InpMaxTradesPerDay

int g_consecLosses    = 0;                  // NOTE: if KurosawaTrack increments on CLOSE, do NOT reset daily.
                                             // Resetting daily hides streak risk; leave it persistent to stop bad regimes.

int g_lastJstYmd      = 0;                  // JST day marker for daily reset

ulong g_lastOpenDealId   = 0;               // Duplicate guard (OPEN)
ulong g_lastClosedDealId = 0;               // Duplicate guard (CLOSE)

int g_diagBars      = 0;                    // Diagnostics for logs (bars evaluated)
int g_diagSignal    = 0;                    // Diagnostics for logs (signals found)
int g_diagTradeSent = 0;                    // Diagnostics for logs (orders placed)


//+------------------------------------------------------------------+
//| Utility: clamp                                                  |
//+------------------------------------------------------------------+
double ClampDouble(const double v, const double lo, const double hi)
{
   if(v < lo) return lo;
   if(v > hi) return hi;
   return v;
}

//+------------------------------------------------------------------+
//| Risk-based lot sizing                                            |
//+------------------------------------------------------------------+
double CalcRiskLotBySLDistance(const string symbol, const double sl_distance_price, const double risk_percent)
{
   if(sl_distance_price <= 0.0) return 0.0;

   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0) return 0.0;

   const double risk_money = equity * (risk_percent / 100.0);
   if(risk_money <= 0.0) return 0.0;

   double tick_value = 0.0;
   double tick_size  = 0.0;
   if(!SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE, tick_value)) return 0.0;
   if(!SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE,  tick_size))  return 0.0;
   if(tick_value <= 0.0 || tick_size <= 0.0) return 0.0;

   const double money_per_1lot = (sl_distance_price / tick_size) * tick_value;
   if(money_per_1lot <= 0.0) return 0.0;

   double vol = risk_money / money_per_1lot;

   double vmin = 0.0, vmax = 0.0, vstep = 0.0;
   if(!SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN,  vmin))  return 0.0;
   if(!SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX,  vmax))  return 0.0;
   if(!SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP, vstep)) return 0.0;
   if(vmin <= 0.0 || vmax <= 0.0 || vstep <= 0.0) return 0.0;

   vol = ClampDouble(vol, vmin, vmax);

   // floor to step (avoid rounding up risk)
   vol = MathFloor(vol / vstep) * vstep;
   if(vol < vmin) vol = vmin;

   return NormalizeDouble(vol, 2);
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
   hAdx     = iADX(_Symbol, _Period, InpAdxPeriod);

   if(hEmaFast == INVALID_HANDLE || hEmaSlow == INVALID_HANDLE ||
      hRsi     == INVALID_HANDLE || hAtr     == INVALID_HANDLE ||
      hAdx     == INVALID_HANDLE)
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
   if(hAdx     != INVALID_HANDLE) IndicatorRelease(hAdx);
}

//+------------------------------------------------------------------+
//| Weekend window (JST)                                             |
//+------------------------------------------------------------------+
bool IsWeekendWindow()
{
   MqlDateTime dt;
   TimeToStruct(NowJst(InpJstUtcOffset), dt);
   return ((dt.day_of_week == 5 && dt.hour >= InpFridayCloseHourJst) || (dt.day_of_week == 6));
}

//+------------------------------------------------------------------+
//| Daily summary                                                    |
//+------------------------------------------------------------------+
void PrintDailySummary()
{
   PrintFormat("--- DAILY SUMMARY [%d] --- Bars:%d Signals:%d Trades:%d ConsecLoss:%d",
               g_lastJstYmd, g_diagBars, g_diagSignal, g_diagTradeSent, g_consecLosses);
}

//+------------------------------------------------------------------+
//| Time-stop exit                                                   |
//+------------------------------------------------------------------+
void CheckHoldTimeExit()
{
   if(InpMaxHoldHours <= 0) return;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(!PositionSelectByTicket(ticket)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      const datetime openT = (datetime)PositionGetInteger(POSITION_TIME);
      if((TimeCurrent() - openT) >= (InpMaxHoldHours * 3600))
      {
         trade.PositionClose(ticket);
         g_lastCloseTime = TimeCurrent();
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| Trailing management                                              |
//+------------------------------------------------------------------+
void ManageTrailing()
{
   if(!PositionSelectByMagic(_Symbol, (long)InpMagic)) return;

   double atr[1];
   if(CopyBuffer(hAtr, 0, 0, 1, atr) != 1) return;
   const double atrNow = atr[0];
   if(atrNow <= 0.0) return;

   const long   posType = PositionGetInteger(POSITION_TYPE);
   const double open    = PositionGetDouble(POSITION_PRICE_OPEN);
   const double sl      = PositionGetDouble(POSITION_SL);
   const double tp      = PositionGetDouble(POSITION_TP);

   if(sl <= 0.0) return;

   const double initialRisk = MathAbs(open - sl);
   if(initialRisk <= 0.0) return;

   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(posType == POSITION_TYPE_BUY)
   {
      if((bid - open) < (initialRisk * InpTrailStartR)) return;

      const double step  = atrNow * InpTrailStepAtrMult;
      const double newSl = NormalizeDouble(bid - step, _Digits);

      if(newSl > sl)
         trade.PositionModify(_Symbol, newSl, tp);
   }
   else if(posType == POSITION_TYPE_SELL)
   {
      if((open - ask) < (initialRisk * InpTrailStartR)) return;

      const double step  = atrNow * InpTrailStepAtrMult;
      const double newSl = NormalizeDouble(ask + step, _Digits);

      if(newSl < sl)
         trade.PositionModify(_Symbol, newSl, tp);
   }
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1) Daily rollover (JST)
   const int ymd = JstYmd(NowJst(InpJstUtcOffset));
   if(ymd != g_lastJstYmd)
   {
      PrintDailySummary();

      g_lastJstYmd    = ymd;
      g_tradesToday   = 0;
      g_diagBars      = 0;
      g_diagSignal    = 0;
      g_diagTradeSent = 0;
      // NOTE: do NOT reset g_consecLosses here
   }

   // 2) Pre-weekend flatten
   if(InpCloseBeforeWeekend && IsWeekendWindow())
   {
      if(PositionExists(_Symbol, InpMagic))
         trade.PositionClose(_Symbol);
      return;
   }

   // 3) Time stop exit
   CheckHoldTimeExit();

   // 4) Trailing
   if(InpUseTrailing)
      ManageTrailing();

   // 5) Session gate
   if(!IsEntryTimeJST(InpJstStartHour, InpJstEndHour, InpJstUtcOffset))
      return;

   // 6) New bar gate
   const datetime bar0 = iTime(_Symbol, _Period, 0);
   if(bar0 == g_lastBarTime) return;

   g_lastBarTime = bar0;
   g_diagBars++;

   // 6.1) Tracking excursion update (Option A)
   // Caller supplies timeframe: use _Period (H1) for swing system review numbers.
   KurosawaTrack_OnNewBar(InpTrackEnable, InpMagic, _Symbol, (ENUM_TIMEFRAMES)_Period);

   // 7) Spread gate
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return;

   if(InpMaxSpreadPoints > 0.0 && ((ask - bid) / _Point) > InpMaxSpreadPoints)
      return;

   // 8) Risk gates
   if(g_tradesToday >= InpMaxTradesPerDay)     return;
   if(g_consecLosses >= InpMaxConsecLosses)    return;
   if(PositionExists(_Symbol, InpMagic))       return;

   // 9) Read CLOSED BAR values (shift=1)
   double emaF1[1], emaS1[1], rsi1[1], atr1[1], adx1[1];
   if(CopyBuffer(hEmaFast, 0, 1, 1, emaF1) != 1) return;
   if(CopyBuffer(hEmaSlow, 0, 1, 1, emaS1) != 1) return;
   if(CopyBuffer(hRsi,     0, 1, 1, rsi1)  != 1) return;
   if(CopyBuffer(hAtr,     0, 1, 1, atr1)  != 1) return;
   if(CopyBuffer(hAdx,     0, 1, 1, adx1)  != 1) return;

   const double emaFast_1 = emaF1[0];
   const double emaSlow_1 = emaS1[0];
   const double rsi_1     = rsi1[0];
   const double atr_1     = atr1[0];
   const double adx_1     = adx1[0];

   double rsi_2 = rsi_1;
   if(InpUseRsiCrossConfirm)
   {
      double rsi2buf[1];
      if(CopyBuffer(hRsi, 0, 2, 1, rsi2buf) != 1) return;
      rsi_2 = rsi2buf[0];
   }

   // 10) Quality filters
   if(atr_1 < PipsToPrice(_Symbol, InpAtrMinPips)) return;
   if(InpUseAdxFilter && adx_1 < InpMinAdxToTrade) return;

   // 11) Trend definition
   const bool uptrend   = (emaFast_1 > emaSlow_1);
   const bool downtrend = (emaFast_1 < emaSlow_1);

   // 12) Signal logic
   bool buySig  = false;
   bool sellSig = false;

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

   if(!buySig && !sellSig) return;
   g_diagSignal++;

   // 13) Build ATR-based SL/TP
   const double slDist = atr_1 * InpSlAtrMult;
   if(slDist <= 0.0) return;

   const string cmt = InpEaName + "|" + InpEaVersion;

   const double lot = CalcRiskLotBySLDistance(_Symbol, slDist, InpRiskPercent);
   if(lot <= 0.0) return;

   // 14) Place order
   if(buySig)
   {
      double sl = NormalizeDouble(ask - slDist, _Digits);
      double tp = NormalizeDouble(ask + (slDist * InpTpRMultiple), _Digits);

      if(EnsureStopsLevel(_Symbol, ask, sl, tp, true, true))
      {
         if(trade.Buy(lot, _Symbol, 0, sl, tp, cmt + "|BUY"))
         {
            g_tradesToday++;
            g_diagTradeSent++;
         }
      }
   }
   else
   {
      double sl = NormalizeDouble(bid + slDist, _Digits);
      double tp = NormalizeDouble(bid - (slDist * InpTpRMultiple), _Digits);

      if(EnsureStopsLevel(_Symbol, bid, sl, tp, false, true))
      {
         if(trade.Sell(lot, _Symbol, 0, sl, tp, cmt + "|SELL"))
         {
            g_tradesToday++;
            g_diagTradeSent++;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Tracking callback                                                 |
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
      (ENUM_TIMEFRAMES)_Period,_Symbol
   );
}
