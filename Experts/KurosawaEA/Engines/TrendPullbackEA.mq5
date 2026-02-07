//+------------------------------------------------------------------+
//| File: Engines/TrendPullbackEA.mq5                                |
//| Type: Engine (MT5 events + execution)                            |
//| Ver : 0.5.0                                                      |
//|                                                                  |
//| Trend Pullback EA                                                |
//|                                                                  |
//| Contract                                                         |
//| - This .mq5 contains ONLY MT5 event handlers + PlaceTrade()      |
//| - Utilities come from KurosawaHelpers.mqh                        |
//| - Strategy logic lives in Strategies/TrendPullback.mqh           |
//| - Inputs live in Inputs/TrendPullback_Inputs.mqh                 |
//| - All distances are POINTS (not pips)                            |
//|                                                                  |
//| Engine responsibilities                                           |
//| - Session / spread / cooldown / daily loss / loss-streak gates   |
//| - One position per (symbol, magic)                               |
//| - Execution policy: sizing + SL/TP + order send                  |
//| - Optional position management: time-stop                        |
//|                                                                  |
//| Strategy responsibilities                                         |
//| - Closed-bar signal generation only (no order sending)           |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>

// Umbrella include (time/risk/execution/track/indicator factory)
#include "../Helpers/KurosawaHelpers.mqh"

// Strategy module (signal generation only)
#include "../Strategies/TrendPullback.mqh"

// Inputs (Excel-aligned schema for presets)
#include "../Inputs/TrendPullback_Inputs.mqh"

// Trade executor
CTrade trade;

// ------------------------------------------------------------------
// Indicator handles (created in OnInit, released in OnDeinit)
// ------------------------------------------------------------------
int hBiasEmaFast = INVALID_HANDLE;   // bias TF
int hBiasEmaSlow = INVALID_HANDLE;   // bias TF
int hEntryEma    = INVALID_HANDLE;   // entry TF
int hRsi         = INVALID_HANDLE;   // entry TF
int hAtr         = INVALID_HANDLE;   // entry TF

// ------------------------------------------------------------------
// Runtime state
// ------------------------------------------------------------------
string         g_symbol = "";
datetime       g_lastClosedBarTime = 0;

DailyRiskState g_risk;

int            g_consecLosses  = 0;
datetime       g_lastCloseTime = 0;

ulong          g_lastOpenDealId  = 0;
ulong          g_lastCloseDealId = 0;

DailyDiag      g_diag;

// ==================================================================
// Internal helpers (engine-local)
// ==================================================================
void _TPB_Indicators_Reset()
{
   hBiasEmaFast = INVALID_HANDLE;
   hBiasEmaSlow = INVALID_HANDLE;
   hEntryEma    = INVALID_HANDLE;
   hRsi         = INVALID_HANDLE;
   hAtr         = INVALID_HANDLE;
}

void _TPB_Indicators_Release()
{
   if(hBiasEmaFast != INVALID_HANDLE) IndicatorRelease(hBiasEmaFast);
   if(hBiasEmaSlow != INVALID_HANDLE) IndicatorRelease(hBiasEmaSlow);
   if(hEntryEma    != INVALID_HANDLE) IndicatorRelease(hEntryEma);
   if(hRsi         != INVALID_HANDLE) IndicatorRelease(hRsi);
   if(hAtr         != INVALID_HANDLE) IndicatorRelease(hAtr);

   _TPB_Indicators_Reset();
}

// Conservative history requirement based on the longest lookback used.
int _TPB_RequiredBarsForInit()
{
   int req = 200;
   req = (int)MathMax(req, InpBiasEmaFast + 10);
   req = (int)MathMax(req, InpBiasEmaSlow + 10);
   req = (int)MathMax(req, InpEntryEma    + 10);
   req = (int)MathMax(req, InpRsiPeriod   + 10);
   req = (int)MathMax(req, InpAtrPeriod   + 10);
   return req;
}

// Create handles with retry (tester/terminal can be lazy at init).
bool _TPB_CreateIndicators_WithRetry(const string sym)
{
   // Validate required inputs (fail fast)
   if(InpBiasEmaFast < 2 || InpBiasEmaSlow < 2 ||
      InpEntryEma    < 2 || InpRsiPeriod   < 2 || InpAtrPeriod < 2)
   {
      Print("INIT_FAILED: invalid indicator inputs.",
            " BiasEmaFast=", InpBiasEmaFast,
            " BiasEmaSlow=", InpBiasEmaSlow,
            " EntryEma=", InpEntryEma,
            " RsiPeriod=", InpRsiPeriod,
            " AtrPeriod=", InpAtrPeriod);
      return false;
   }

   ResetLastError();
   if(!SymbolSelect(sym, true))
      Print("Warning: SymbolSelect failed for ", sym, " err=", GetLastError());

   const int need = _TPB_RequiredBarsForInit();

   // Ensure history on BOTH timeframes used by this engine
   if(!EnsureHistory(sym, InpBiasTf,   MathMax(need, 300))) return false;
   if(!EnsureHistory(sym, InpTargetTf, MathMax(need, 300))) return false;

   for(int i=0; i<10; i++)
   {
      _TPB_Indicators_Release();
      ResetLastError();

      hBiasEmaFast = iMA(sym, InpBiasTf,   InpBiasEmaFast, 0, MODE_EMA, PRICE_CLOSE);
      hBiasEmaSlow = iMA(sym, InpBiasTf,   InpBiasEmaSlow, 0, MODE_EMA, PRICE_CLOSE);

      hEntryEma    = iMA(sym, InpTargetTf, InpEntryEma,    0, MODE_EMA, PRICE_CLOSE);
      hRsi         = iRSI(sym, InpTargetTf, InpRsiPeriod, PRICE_CLOSE);
      hAtr         = iATR(sym, InpTargetTf, InpAtrPeriod);

      const bool ok =
         (hBiasEmaFast != INVALID_HANDLE) &&
         (hBiasEmaSlow != INVALID_HANDLE) &&
         (hEntryEma    != INVALID_HANDLE) &&
         (hRsi         != INVALID_HANDLE) &&
         (hAtr         != INVALID_HANDLE);

      if(ok) return true;

      Print("INIT_RETRY(", i, "): handle create failed. err=", GetLastError(),
            " BiasFast=", hBiasEmaFast,
            " BiasSlow=", hBiasEmaSlow,
            " EntryEma=", hEntryEma,
            " RSI=", hRsi,
            " ATR=", hAtr,
            " sym=", sym,
            " biasTf=", EnumToString(InpBiasTf),
            " entryTf=", EnumToString(InpTargetTf));

      Sleep(200);
   }

   return false;
}

bool _TPB_EnsureIndicatorsCalculated()
{
   if(hBiasEmaFast == INVALID_HANDLE || BarsCalculated(hBiasEmaFast) < 3) return false;
   if(hBiasEmaSlow == INVALID_HANDLE || BarsCalculated(hBiasEmaSlow) < 3) return false;
   if(hEntryEma    == INVALID_HANDLE || BarsCalculated(hEntryEma)    < 3) return false;
   if(hRsi         == INVALID_HANDLE || BarsCalculated(hRsi)         < 3) return false;
   if(hAtr         == INVALID_HANDLE || BarsCalculated(hAtr)         < 3) return false;
   return true;
}

//+------------------------------------------------------------------+
//| PlaceTrade                                                       |
//| - SL/TP are in POINTS                                            |
//| - Uses shared Risk_CalcTradeVolume (risk% or fixed lot fallback) |
//+------------------------------------------------------------------+
bool PlaceTrade(const string sym, const bool isBuy, const double slPts, const double tpPts)
{
   if(slPts <= 0.0 || tpPts <= 0.0)
      return false;

   // 1) Size
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

   // 2) Quote -> entry
   const double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
   {
      g_diag.block_indfail++;
      return false;
   }

   const double entry = isBuy ? ask : bid;

   // 3) Points -> price
   const double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(pt <= 0.0)
   {
      g_diag.block_indfail++;
      return false;
   }

   double sl = 0.0, tp = 0.0;

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

   // 4) Broker constraints
   if(!EnsureStopsLevel(sym, entry, sl, tp, isBuy, true))
   {
      g_diag.block_stops++;
      return false;
   }

   // 5) Send
   trade.SetExpertMagicNumber((int)InpMagic);
   trade.SetDeviationInPoints((int)InpDeviationPoints);

   const string base = InpEaName + "|" + InpEaVersion;

   bool ok = false;
   if(isBuy) ok = trade.Buy(vol, sym, 0.0, sl, tp, base + "|BUY");
   else      ok = trade.Sell(vol, sym, 0.0, sl, tp, base + "|SELL");

   if(ok)
   {
      Risk_OnTradePlaced(g_risk, TimeCurrent());
      g_diag.trades++;
      return true;
   }

   g_diag.block_orderfail++;
   return false;
}

// ==================================================================
// MT5 Events
// ==================================================================
int OnInit()
{
   // Resolve traded symbol once (preset may specify a target pair)
   g_symbol = ResolveEngineSymbol(InpTargetPair, _Symbol);

   // Chart label for humans
   ShowEaLabel(InpEaName, InpEaId, (int)InpMagic, _Symbol, (ENUM_TIMEFRAMES)_Period);

   // Warn-only intent checks
   if(StringLen(InpTargetPair) > 0 && _Symbol != InpTargetPair)
      Print("Warning: Intended symbol=", InpTargetPair, ", attached chart symbol=", _Symbol);

   if(_Period != InpTargetTf)
      Print("Warning: Intended TF=", EnumToString(InpTargetTf), ", current chart TF=", EnumToString(_Period));

   // Create indicator handles (bias TF + entry TF)
   _TPB_Indicators_Reset();
   if(!_TPB_CreateIndicators_WithRetry(g_symbol))
   {
      Print("INIT_FAILED: indicators not ready after retries.",
            " sym=", g_symbol,
            " biasTf=", EnumToString(InpBiasTf),
            " entryTf=", EnumToString(InpTargetTf));
      return INIT_FAILED;
   }

   // Init risk state
   Risk_Init(g_risk, TimeCurrent());

   // Prime last closed bar time (entry TF)
   g_lastClosedBarTime = (datetime)iTime(g_symbol, InpTargetTf, 1);
   if(g_lastClosedBarTime <= 0) g_lastClosedBarTime = TimeCurrent();

   trade.SetExpertMagicNumber((int)InpMagic);
   trade.SetDeviationInPoints((int)InpDeviationPoints);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   PrintDailySummary(InpEaName, g_symbol, InpTargetTf, g_diag);
   _TPB_Indicators_Release();
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
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
      g_symbol
   );
}

void OnTick()
{
   const string   sym = g_symbol;
   const datetime now = TimeCurrent();

   DailyRollIfNeeded(InpEaName, sym, InpTargetTf, g_diag, NowYmdJst());
   DailyResetIfNewDay(g_risk, now, g_consecLosses, InpResetConsecLossDaily);

   // ------------------------------------------------------------
   // 1) Position management (one position per symbol+magic)
   // ------------------------------------------------------------
   if(PositionExists(sym, (int)InpMagic))
   {
      g_diag.block_haspos++;

      // Optional time-stop exit
      if(InpMaxHoldMinutes > 0)
      {
         Position_CheckMaxHoldExit(
            trade,
            sym,
            (long)InpMagic,
            InpMaxHoldMinutes,
            now
         );
      }
      return;
   }

   // ------------------------------------------------------------
   // 2) Safety gates (only when flat)
   // ------------------------------------------------------------
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

   if(!CooldownOK(g_risk, InpCooldownMinutes, now))
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

   if(!_TPB_EnsureIndicatorsCalculated())
   {
      g_diag.block_indfail++;
      return;
   }

   // ------------------------------------------------------------
   // 3) Evaluate once per NEW CLOSED bar (entry TF)
   // ------------------------------------------------------------
   if(!IsNewClosedBar(sym, InpTargetTf, g_lastClosedBarTime))
      return;

   Track_OnNewBar(InpTrackEnable, (int)InpMagic, sym, InpTargetTf);
   g_diag.bars++;

   // ------------------------------------------------------------
   // 4) Strategy evaluation (handles-based, shift=1)
   // ------------------------------------------------------------
   TrendPullbackInputs inps;
   inps.atr_min_points      = InpAtrMinPoints;
   inps.atr_max_points      = InpAtrMaxPoints;
   inps.rsi_buy_max         = InpRsiBuyBelow;
   inps.rsi_sell_min        = InpRsiSellAbove;
   inps.bias_min_gap_points = InpBiasMinGapPoints;

   TrendPullbackSignal sig;

   const double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(pt <= 0.0)
   {
      g_diag.block_indfail++;
      return;
   }

   const TrendPullbackResult sres = TrendPullback_EvaluateHandles(
      hBiasEmaFast, hBiasEmaSlow,
      hEntryEma,
      hRsi,
      hAtr,
      sym,
      InpTargetTf,
      1,      // shift=1 => latest closed bar on entry TF
      pt,     // point size for traded symbol
      inps,
      sig
   );

   if(sres != TRENDPB_OK)
   {
      if(sres == TRENDPB_BLOCK_ATR)            g_diag.block_atr++;
      else if(sres == TRENDPB_BLOCK_NO_BIAS)   g_diag.block_nobias++;
      else if(sres == TRENDPB_BLOCK_NO_SIGNAL) g_diag.block_nosignal++;
      else                                     g_diag.block_indfail++;
      return;
   }

   if(sig.buy == sig.sell)
   {
      g_diag.block_ambig++;
      return;
   }

   g_diag.signals++;

   // ------------------------------------------------------------
   // 5) Execution policy: SL/TP from ATR points
   // ------------------------------------------------------------
   const double atrPts = sig.atr_points;
   const double slPts  = atrPts * InpSlAtrMult;
   const double tpPts  = slPts  * InpTpRMultiple;

   if(slPts <= 0.0 || tpPts <= 0.0)
   {
      g_diag.block_stops++;
      return;
   }

   // ------------------------------------------------------------
   // 6) Execute
   // ------------------------------------------------------------
   if(sig.buy)  PlaceTrade(sym, true,  slPts, tpPts);
   else         PlaceTrade(sym, false, slPts, tpPts);
}
//+------------------------------------------------------------------+
