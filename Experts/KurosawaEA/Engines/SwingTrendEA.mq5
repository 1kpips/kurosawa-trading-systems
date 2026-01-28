//+------------------------------------------------------------------+
//| File: Engines/SwingTrendEA.mq5                                   |
//| Type: Engine (MT5 events + execution)                            |
//| Ver : 0.2.4                                                      |
//|                                                                  |
//| SwingTrend EA (Generic Engine)                                   |
//|                                                                  |
//| Contract                                                         |
//| - This .mq5 contains ONLY MT5 event handlers + PlaceTrade()      |
//| - All utilities come from KurosawaHelpers.mqh                    |
//| - Strategy logic lives in Strategies/SwingTrend.mqh              |
//| - All distances are POINTS (not pips)                            |
//|                                                                  |
//| Notes                                                            |
//| - Evaluates signals on CLOSED bar only (shift=1)                 |
//| - Strategy returns buy/sell + atr_points (points)                |
//| - Engine owns sizing, SL/TP, trailing, time-stop, risk guards    |
//| - Includes daily diagnostics + daily roll reporting              |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>

// Shared infra (umbrella include)
#include "../Helpers/KurosawaHelpers.mqh"

// Strategy (signal generation only)
#include "../Strategies/SwingTrend.mqh"

// Inputs (Excel-aligned schema)
#include "../Inputs/SwingTrend_Inputs.mqh"

CTrade trade;

// ------------------------------------------------------------------
// Deviation compatibility
// - Some engines use InpDeviationPoints, but SwingTrend_Inputs may not.
// - Keep compile-safe default.
// ------------------------------------------------------------------
#ifndef InpDeviationPoints
#define InpDeviationPoints 10
#endif

// ------------------------- Indicator Handles -----------------------
int hEmaFast = INVALID_HANDLE;
int hEmaSlow = INVALID_HANDLE;
int hRSI     = INVALID_HANDLE;
int hATR     = INVALID_HANDLE;
int hADX     = INVALID_HANDLE; // optional

// ------------------------- Runtime State ---------------------------
datetime       g_lastClosedBarTime = 0;
DailyRiskState g_risk;

int      g_consecLosses   = 0;
datetime g_lastCloseTime  = 0;

ulong    g_lastOpenDealId  = 0;
ulong    g_lastCloseDealId = 0;

// Diagnostics
DailyDiag g_diag;

// ------------------------------------------------------------------
// Engine symbol choice
// - If InpTargetPair is set, trade that symbol.
// - Otherwise trade chart symbol.
// ------------------------------------------------------------------
string EngineSymbol()
{
   return (StringLen(InpTargetPair) > 0 ? InpTargetPair : _Symbol);
}

// ------------------------------------------------------------------
// EnsureHistory
// - Preloads history for symbol/tf (tester can be lazy at init)
// ------------------------------------------------------------------
bool EnsureHistory(const string symbol, const ENUM_TIMEFRAMES tf, const int needBars)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   for(int i=0; i<20; i++)
   {
      ResetLastError();
      const int got = CopyRates(symbol, tf, 0, needBars, rates);
      if(got >= needBars)
         return true;

      Print("INIT_WAIT_HISTORY: symbol=", symbol,
            " tf=", EnumToString(tf),
            " got=", got,
            " need=", needBars,
            " err=", GetLastError());

      Sleep(250);
   }
   return false;
}

// ------------------------------------------------------------------
// ReleaseIndicators
// ------------------------------------------------------------------
void ReleaseIndicators()
{
   if(hEmaFast != INVALID_HANDLE) IndicatorRelease(hEmaFast);
   if(hEmaSlow != INVALID_HANDLE) IndicatorRelease(hEmaSlow);
   if(hRSI     != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hATR     != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hADX     != INVALID_HANDLE) IndicatorRelease(hADX);

   hEmaFast = INVALID_HANDLE;
   hEmaSlow = INVALID_HANDLE;
   hRSI     = INVALID_HANDLE;
   hATR     = INVALID_HANDLE;
   hADX     = INVALID_HANDLE;
}

// ------------------------------------------------------------------
// CreateIndicators_WithRetry
// - Creates handles for the traded symbol, not chart symbol
// ------------------------------------------------------------------
bool CreateIndicators_WithRetry(const string sym)
{
   ResetLastError();
   if(!SymbolSelect(sym, true))
      Print("Warning: SymbolSelect failed for ", sym, " err=", GetLastError());

   if(!EnsureHistory(sym, InpTargetTf, 300))
      return false;

   // Validate parameters (hard fail)
   if(InpEmaFast < 2 || InpEmaSlow < 2 || InpRsiPeriod < 2 || InpAtrPeriod < 2)
   {
      Print("INIT_FAILED: invalid indicator inputs.",
            " EmaFast=", InpEmaFast,
            " EmaSlow=", InpEmaSlow,
            " RsiPeriod=", InpRsiPeriod,
            " AtrPeriod=", InpAtrPeriod);
      return false;
   }

   if(InpUseAdxFilter && InpAdxPeriod < 2)
   {
      Print("INIT_FAILED: invalid ADX inputs. AdxPeriod=", InpAdxPeriod);
      return false;
   }

   for(int i=0; i<10; i++)
   {
      ReleaseIndicators();
      ResetLastError();

      hEmaFast = iMA(sym, InpTargetTf, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
      hEmaSlow = iMA(sym, InpTargetTf, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
      hRSI     = iRSI(sym, InpTargetTf, InpRsiPeriod, PRICE_CLOSE);
      hATR     = iATR(sym, InpTargetTf, InpAtrPeriod);

      if(InpUseAdxFilter)
         hADX = iADX(sym, InpTargetTf, InpAdxPeriod);
      else
         hADX = INVALID_HANDLE;

      const bool baseOk = (hEmaFast != INVALID_HANDLE &&
                           hEmaSlow != INVALID_HANDLE &&
                           hRSI     != INVALID_HANDLE &&
                           hATR     != INVALID_HANDLE);

      const bool adxOk  = (!InpUseAdxFilter || hADX != INVALID_HANDLE);

      if(baseOk && adxOk)
         return true;

      Print("INIT_RETRY(", i, "): handle create failed. err=", GetLastError(),
            " EmaFast=", hEmaFast,
            " EmaSlow=", hEmaSlow,
            " RSI=", hRSI,
            " ATR=", hATR,
            " ADX=", hADX,
            " sym=", sym,
            " tf=", EnumToString(InpTargetTf));

      Sleep(200);
   }

   return false;
}

//+------------------------------------------------------------------+
//| ManageTrailingIfEnabled                                          |
//| - ATR-step trailing (price) starting at TrailStartR              |
//| - Validates stops level before modify and counts failures        |
//+------------------------------------------------------------------+
void ManageTrailingIfEnabled(const string sym)
{
   if(!InpUseTrailing) return;

   if(!PositionSelectByMagic(sym, (long)InpMagic))
      return;

   const long  type  = (long)PositionGetInteger(POSITION_TYPE);
   const bool  isBuy = (type == POSITION_TYPE_BUY);

   const double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   const double slCur = PositionGetDouble(POSITION_SL);
   const double tpCur = PositionGetDouble(POSITION_TP);

   if(entry <= 0.0 || slCur <= 0.0) return;

   // ATR is in PRICE, step is in PRICE
   double atrPrice = 0.0;
   if(!GetIndicatorValue(hATR, 0, 1, atrPrice))
   {
      g_diag.block_indfail++;
      return;
   }
   if(atrPrice <= 0.0)
   {
      g_diag.block_indfail++;
      return;
   }

   const double step = atrPrice * InpTrailStepAtrMult;
   if(step <= 0.0) return;

   const double riskRef = isBuy ? (entry - slCur) : (slCur - entry);
   if(riskRef <= 0.0) return;

   const double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   const double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
   {
      g_diag.block_indfail++;
      return;
   }

   const double px     = isBuy ? bid : ask;
   const double profit = isBuy ? (px - entry) : (entry - px);

   if(profit < (InpTrailStartR * riskRef))
      return;

   double slNew = slCur;

   if(isBuy)
   {
      const double cand = px - step;
      if(cand > slCur) slNew = cand;
   }
   else
   {
      const double cand = px + step;
      if(cand < slCur) slNew = cand;
   }

   slNew = NormalizeDouble(slNew, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));
   if(slNew == slCur) return;

   double slTry = slNew;
   double tpTry = tpCur;

   if(!EnsureStopsLevel(sym, entry, slTry, tpTry, isBuy, false))
   {
      g_diag.block_stops++;
      return;
   }

   if(!trade.PositionModify(sym, slTry, tpTry))
      g_diag.block_orderfail++;
}

//+------------------------------------------------------------------+
//| CheckMaxHoldExit                                                 |
//+------------------------------------------------------------------+
void CheckMaxHoldExit(const string sym, const datetime now)
{
   if(InpMaxHoldMinutes <= 0) return;

   if(!PositionSelectByMagic(sym, (long)InpMagic))
      return;

   const datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
   const int heldMin = MinutesHeld(openTime, now);

   if(heldMin >= InpMaxHoldMinutes)
   {
      if(!trade.PositionClose(sym))
         g_diag.block_orderfail++;
   }
}

//+------------------------------------------------------------------+
//| PlaceTrade                                                       |
//| - ATR-based SL (points) + R-multiple TP (points)                 |
//+------------------------------------------------------------------+
bool PlaceTrade(const string sym, const bool isBuy, const double slPts, const double tpPts)
{
   if(slPts <= 0.0 || tpPts <= 0.0)
      return false;

   const double vol = Risk_CalcTradeVolume(
      sym,
      slPts,
      InpUseRiskSizing,
      InpRiskPercent,
      InpFixedLot,
      InpMaxLotCap
   );

   if(vol <= 0.0)
   {
      g_diag.block_orderfail++;
      return false;
   }

   const double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
   {
      g_diag.block_indfail++;
      return false;
   }

   const double entry = isBuy ? ask : bid;

   const double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(pt <= 0.0)
   {
      g_diag.block_indfail++;
      return false;
   }

   double sl = 0.0;
   double tp = 0.0;

   if(isBuy)
   {
      sl = entry - slPts * pt;
      tp = entry + tpPts * pt;
   }
   else
   {
      sl = entry + slPts * pt;
      tp = entry - tpPts * pt;
   }

   if(!EnsureStopsLevel(sym, entry, sl, tp, isBuy, true))
   {
      g_diag.block_stops++;
      return false;
   }

   trade.SetExpertMagicNumber((int)InpMagic);
   trade.SetDeviationInPoints((int)InpDeviationPoints);

   const string cmt = InpEaName + "|" + InpEaVersion;

   bool ok = false;
   if(isBuy) ok = trade.Buy(vol, sym, 0.0, sl, tp, cmt + "|BUY");
   else      ok = trade.Sell(vol, sym, 0.0, sl, tp, cmt + "|SELL");

   if(ok)
   {
      Risk_OnTradePlaced(g_risk, TimeCurrent());
      g_diag.trades++;
   }
   else
   {
      g_diag.block_orderfail++;
   }

   return ok;
}

//+------------------------------------------------------------------+
//| MT5 Events                                                       |
//+------------------------------------------------------------------+
int OnInit()
{
   const string sym = EngineSymbol();

   Print("INIT_PARAMS: sym=", sym,
         " chartSym=", _Symbol,
         " chartTf=", EnumToString(_Period),
         " targetTf=", EnumToString(InpTargetTf),
         " EmaFast=", InpEmaFast,
         " EmaSlow=", InpEmaSlow,
         " RSIPeriod=", InpRsiPeriod,
         " ATRPeriod=", InpAtrPeriod,
         " UseAdx=", (InpUseAdxFilter ? "true":"false"),
         " AdxPeriod=", InpAdxPeriod);

   ShowEaLabel(
      InpEaName,
      InpEaId,
      (int)InpMagic,
      _Symbol,
      (ENUM_TIMEFRAMES)_Period
   );

   if(StringLen(InpTargetPair) > 0 && _Symbol != InpTargetPair)
      Print("Warning: Intended symbol=", InpTargetPair, ", attached chart symbol=", _Symbol);

   if(_Period != InpTargetTf)
      Print("Warning: Intended TF=", EnumToString(InpTargetTf), ", current chart TF=", EnumToString(_Period));

   if(!CreateIndicators_WithRetry(sym))
   {
      Print("INIT_FAILED: indicators not ready after retries.",
            " EmaFast=", hEmaFast,
            " EmaSlow=", hEmaSlow,
            " RSI=", hRSI,
            " ATR=", hATR,
            " ADX=", hADX,
            " tf=", EnumToString(InpTargetTf),
            " sym=", sym);
      return INIT_FAILED;
   }

   Risk_Init(g_risk, TimeCurrent());

   g_lastClosedBarTime = (datetime)iTime(sym, InpTargetTf, 1);
   if(g_lastClosedBarTime <= 0)
      g_lastClosedBarTime = TimeCurrent();

   trade.SetExpertMagicNumber((int)InpMagic);
   trade.SetDeviationInPoints((int)InpDeviationPoints);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   const string sym = EngineSymbol();

   // Print the current (partial) day snapshot before exit
   PrintDailySummary(InpEaName, sym, InpTargetTf, g_diag);

   ReleaseIndicators();
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   const string sym = EngineSymbol();

   Track_OnTradeTransaction(
      InpTrackEnable,
      trans,

      InpEaId,
      InpEaName,
      InpEaVersion,

      (int)InpMagic,
      InpTrackSendOpen,

      g_lastOpenDealId,
      g_lastCloseDealId,
      g_consecLosses,
      g_lastCloseTime,

      InpTargetTf,
      sym
   );
}

void OnTick()
{
   const string   sym = EngineSymbol();
   const datetime now = TimeCurrent();

   // Daily reporting roll (prints prior day summary once per day)
   DailyRollIfNeeded(InpEaName, sym, InpTargetTf, g_diag, NowYmdJst());

   // Risk reset (optionally resets streak)
   DailyResetIfNewDay(g_risk, now, g_consecLosses, InpResetConsecLossDaily);

   // 1) Manage open position first
   if(PositionExists(sym, (int)InpMagic))
   {
      CheckMaxHoldExit(sym, now);
      ManageTrailingIfEnabled(sym);
      return;
   }

   // 2) Gates (only when flat)
   if(!IsTimeWindowByOffsetHours(InpStartHour, InpEndHour, InpUtcOffset))
   {
      g_diag.block_session++;
      return;
   }

   if(!SpreadOK(sym, InpMaxSpreadPoints))
   {
      g_diag.block_spread++;
      return;
   }

   if(!CooldownOK(g_risk, InpCooldownMinutes))
   {
      g_diag.block_cooldown++;
      return;
   }

   if(!DailyLossLimitOK(g_risk, InpDailyLossLimitPercent))
   {
      g_diag.block_maxday++;
      return;
   }

   if(!LossStreakOK(g_consecLosses, InpMaxConsecLosses))
   {
      g_diag.block_loss++;
      return;
   }

   if(InpMaxTradesPerDay > 0 && g_risk.trades_today >= InpMaxTradesPerDay)
   {
      g_diag.block_maxtrades++;
      return;
   }

   // 3) Once per NEW CLOSED bar
   if(!IsNewClosedBar(sym, InpTargetTf, g_lastClosedBarTime))
      return;

   Track_OnNewBar(InpTrackEnable, (int)InpMagic, sym, InpTargetTf);
   g_diag.bars++;

   // 4) Strategy evaluation (handles-based, shift=1)
   SwingTrendInputs inps;
   inps.rsi_buy_below     = InpRsiBuyBelow;
   inps.rsi_sell_above    = InpRsiSellAbove;

   inps.atr_min_points    = InpAtrMinPoints;
   inps.atr_max_points    = InpAtrMaxPoints;

   inps.use_adx_filter    = InpUseAdxFilter;
   inps.adx_min_to_trade  = InpMinAdxToTrade;
   inps.adx_max_to_trade  = InpMaxAdxToTrade;
   inps.require_ema_slope = InpRequireEmaSlope;

   SwingTrendSignal sig;

   // IMPORTANT: use traded symbol point, not _Point
   const double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(pt <= 0.0)
   {
      g_diag.block_indfail++;
      return;
   }

   const SwingTrendResult sres = SwingTrend_EvaluateHandles(
      hEmaFast,
      hEmaSlow,
      hRSI,
      hATR,
      hADX,
      1,     // shift=1
      pt,    // point for sym
      inps,
      sig
   );

   if(sres != SWINGTREND_OK)
   {
      if(sres == SWINGTREND_BLOCK_ATR)             g_diag.block_atr++;
      else if(sres == SWINGTREND_BLOCK_ADX)        g_diag.block_adx++;
      else if(sres == SWINGTREND_BLOCK_NO_SIGNAL)  g_diag.block_nosignal++;
      else                                         g_diag.block_indfail++;
      return;
   }

   if(sig.buy == sig.sell)
   {
      g_diag.block_ambig++;
      return;
   }

   g_diag.signals++;

   // 5) ATR-based SL/TP (POINTS)
   const double slPts = sig.atr_points * InpSlAtrMult;
   const double tpPts = slPts * InpTpRMultiple;

   if(slPts <= 0.0 || tpPts <= 0.0)
   {
      g_diag.block_stops++;
      return;
   }

   // 6) Place order
   if(sig.buy)  PlaceTrade(sym, true,  slPts, tpPts);
   else         PlaceTrade(sym, false, slPts, tpPts);
}
