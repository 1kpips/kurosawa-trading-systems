//+------------------------------------------------------------------+
//| File: Tokyo_SwingTrend_USDJPY_H1.mq5                             |
//| EA  : Tokyo_SwingTrend_USDJPY_H1                                 |
//| Ver : 0.1.3-track                                                |
//|                                                                  |
//| CHANGELOG (v0.1.3 / 2026-01-15):                                 |
//| - Add equity-risk position sizing (replaces GetMinLot)           |
//| - Make TP more realistic for pullback entries (default 1.6R)     |
//| - Reduce trailing stop "hunt" risk (default start 1.5R, step 1.1)|
//| - Optional RSI "cross-back" confirmation to improve timing       |
//| - Add comments marking changes clearly                           |
//|                                                                  |
//| Tokyo Swing Trend (H1)                                           |
//| - Trend filter: EMA(50) vs EMA(200)                              |
//| - Entry: RSI pullback in trend direction                         |
//| - Volatility filter: ATR must exceed minimum                     |
//| - Optional quality filter: ADX >= threshold                      |
//| - Risk: ATR-based SL, R-multiple TP                              |
//| - Optional trailing: ATR step after R threshold                  |
//| - Session: Tokyo window in JST (fixed offset, no DST)            |
//| - Tracking: OPEN/CLOSE via KurosawaTrack.mqh                     |
//|                                                                  |
//| Notes                                                            |
//| - Signals use CLOSED BAR values (shift=1)                        |
//| - Entry evaluated once per NEW BAR                               |
//| - Market execution (price=0)                                     |
//| - KurosawaHelpers.mqh provides time window, stops validation,    |
//|   volume helpers, and position helpers                           |
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
input string InpEaVersion          = "0.1.3"; // CHANGED: version bump

//==================== Session: Tokyo (JST) ====================//
input int    InpJstStartHour       = 9;
input int    InpJstEndHour         = 23;
input int    InpJstUtcOffset       = 9;

//==================== Strategy: Trend & Pullback ====================//
input int    InpEmaFast            = 50;
input int    InpEmaSlow            = 200;

input int    InpRsiPeriod          = 14;
input double InpRsiBuyPullback     = 45.0; // buy pullback threshold (RSI <=)
input double InpRsiSellPullback    = 55.0; // sell pullback threshold (RSI >=)

// CHANGED: Optional "cross-back" confirmation to reduce passive catching of falling knives
input bool   InpUseRsiCrossConfirm = true;
input double InpRsiBuyCrossLevel   = 45.0; // buy only when RSI crosses UP above this after dipping below
input double InpRsiSellCrossLevel  = 55.0; // sell only when RSI crosses DOWN below this after rising above

//==================== Market Quality Filters ====================//
input int    InpAtrPeriod          = 14;
input double InpAtrMinPips         = 8.0;   // ignore very low-volatility hours

input bool   InpUseAdxFilter       = true;
input int    InpAdxPeriod          = 14;
input double InpMinAdxToTrade      = 18.0;  // require trend strength if enabled

//==================== Stops & Exit Management ====================//
input double InpSlAtrMult          = 2.0;   // SL distance = ATR * this

// CHANGED: More realistic target for pullback entries on H1 (was 2.5R)
input double InpTpRMultiple        = 1.6;   // TP distance = SL distance * this

input bool   InpUseTrailing        = true;

// CHANGED: Reduce trailing stop hunting (was start 1.0R, step 0.7*ATR)
input double InpTrailStartR        = 1.5;   // begin trailing once price moves >= 1.5R
input double InpTrailStepAtrMult   = 1.1;   // trailing step = ATR * this

input int    InpMaxHoldHours       = 96;    // time stop

//==================== Risk & Safety ====================//
input double InpMaxSpreadPoints    = 20;
input int    InpMaxTradesPerDay    = 4;
input int    InpMaxConsecLosses    = 3;

input bool   InpCloseBeforeWeekend = true;
input int    InpFridayCloseHourJst = 22;

// CHANGED: Risk-based position sizing (replaces GetMinLot)
// Risk percent is per trade based on SL distance.
input double InpRiskPercent        = 0.50; // 0.50% equity risk per trade (0.25-0.75 recommended)

//==================== Tracking ====================//
input bool   InpTrackEnable        = true;
input bool   InpTrackSendOpen      = true;

//==================== Indicator Handles & Runtime State ====================//
int hEmaFast = INVALID_HANDLE;
int hEmaSlow = INVALID_HANDLE;
int hRsi     = INVALID_HANDLE;
int hAtr     = INVALID_HANDLE;
int hAdx     = INVALID_HANDLE;

datetime g_lastBarTime   = 0;
datetime g_lastCloseTime = 0;

int g_tradesToday     = 0;
int g_consecLosses    = 0;
int g_lastJstYmd      = 0;

// Duplicate guards for tracking callbacks
ulong g_lastOpenDealId   = 0;
ulong g_lastClosedDealId = 0;

// Diagnostics (optional)
int g_diagBars      = 0;
int g_diagSignal    = 0;
int g_diagTradeSent = 0;

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
//| CHANGED: Risk-based lot sizing                                   |
//| - Calculates volume so that SL distance risks InpRiskPercent      |
//| - Uses SYMBOL_TRADE_TICK_VALUE / SYMBOL_TRADE_TICK_SIZE           |
//| - Normalizes to volume step and respects min/max volume           |
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

   // How much money is lost per 1.0 lot if price moves by sl_distance_price
   // money_per_1lot = (sl_distance / tick_size) * tick_value
   const double money_per_1lot = (sl_distance_price / tick_size) * tick_value;
   if(money_per_1lot <= 0.0) return 0.0;

   double vol = risk_money / money_per_1lot;

   // Respect broker volume constraints
   double vmin = 0.0, vmax = 0.0, vstep = 0.0;
   if(!SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN,  vmin))  return 0.0;
   if(!SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX,  vmax))  return 0.0;
   if(!SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP, vstep)) return 0.0;
   if(vmin <= 0.0 || vmax <= 0.0 || vstep <= 0.0) return 0.0;

   vol = ClampDouble(vol, vmin, vmax);

   // Normalize to step (floor to avoid accidental over-risk due to rounding up)
   vol = MathFloor(vol / vstep) * vstep;

   // Safety: if flooring pushed below minimum, snap to minimum
   if(vol < vmin) vol = vmin;

   // Normalize decimal digits for volume display (not critical but tidy)
   vol = NormalizeDouble(vol, 2);

   return vol;
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

   // Friday after configured JST hour, plus all day Saturday
   return ((dt.day_of_week == 5 && dt.hour >= InpFridayCloseHourJst) || (dt.day_of_week == 6));
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
         return; // one position per EA
      }
   }
}

//+------------------------------------------------------------------+
//| Trailing management                                              |
//+------------------------------------------------------------------+
// Trailing uses current ATR and starts after price has moved >= InpTrailStartR * initial risk.
// Step size = ATR * InpTrailStepAtrMult.
void ManageTrailing()
{
   if(!PositionSelectByMagic(_Symbol, (long)InpMagic)) return;

   double atr[1];
   if(CopyBuffer(hAtr, 0, 0, 1, atr) != 1) return; // shift=0 ok for trailing
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
   // 1) Daily reset (JST)
   const int ymd = JstYmd(NowJst(InpJstUtcOffset));
   if(ymd != g_lastJstYmd)
   {
      g_lastJstYmd      = ymd;
      g_tradesToday     = 0;
      g_consecLosses    = 0;
      g_diagBars        = 0;
      g_diagSignal      = 0;
      g_diagTradeSent   = 0;
   }

   // 2) Pre-weekend flatten (optional)
   if(InpCloseBeforeWeekend && IsWeekendWindow())
   {
      if(PositionExists(_Symbol, InpMagic))
         trade.PositionClose(_Symbol);
      return;
   }

   // 3) Time stop exit
   CheckHoldTimeExit();

   // 4) Trailing (optional)
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

   // 7) Spread gate
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return;

   if(InpMaxSpreadPoints > 0.0 && ((ask - bid) / _Point) > InpMaxSpreadPoints)
      return;

   // 8) Risk gates
   if(g_tradesToday >= InpMaxTradesPerDay) return;
   if(g_consecLosses >= InpMaxConsecLosses) return;
   if(PositionExists(_Symbol, InpMagic)) return;

   // 9) Read CLOSED BAR (shift=1) indicator values
   // CHANGED: For RSI cross confirmation we also read shift=2 when enabled.
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

   // 12) Signal logic (pullback + optional confirmation)
   bool buySig = false;
   bool sellSig = false;

   if(!InpUseRsiCrossConfirm)
   {
      // Original passive thresholds
      buySig  = (uptrend   && rsi_1 <= InpRsiBuyPullback);
      sellSig = (downtrend && rsi_1 >= InpRsiSellPullback);
   }
   else
   {
      // CHANGED: "Cross-back" confirmation
      // Buy: RSI was below level on bar-2, then crossed above on bar-1 while in uptrend
      // Sell: RSI was above level on bar-2, then crossed below on bar-1 while in downtrend
      buySig  = (uptrend   && rsi_2 <= InpRsiBuyCrossLevel  && rsi_1 > InpRsiBuyCrossLevel);
      sellSig = (downtrend && rsi_2 >= InpRsiSellCrossLevel && rsi_1 < InpRsiSellCrossLevel);
   }

   if(!buySig && !sellSig) return;
   g_diagSignal++;

   // 13) Build ATR-based SL/TP
   const double slDist = atr_1 * InpSlAtrMult;
   const string cmt    = InpEaName + "|" + InpEaVersion;

   // CHANGED: Risk-based lot sizing using SL distance
   const double lot = CalcRiskLotBySLDistance(_Symbol, slDist, InpRiskPercent);
   if(lot <= 0.0) return;

   if(buySig)
   {
      double sl = ask - slDist;
      double tp = ask + (slDist * InpTpRMultiple);

      if(EnsureStopsLevel(_Symbol, ask, sl, tp, true, true))
      {
         if(trade.Buy(lot, _Symbol, 0, sl, tp, cmt + "|BUY"))
         {
            g_tradesToday++;
            g_diagTradeSent++;
         }
      }
   }
   else // sellSig
   {
      double sl = bid + slDist;
      double tp = bid - (slDist * InpTpRMultiple);

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
//| Transaction Monitoring & Tracking (via KurosawaTrack.mqh)         |
//| - Keep this wrapper in EA (MQL5 event entrypoint)                |
//| - All tracking logic is inside KurosawaTrack.mqh                 |
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
      g_lastCloseTime
   );
}
