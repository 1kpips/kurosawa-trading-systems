//+------------------------------------------------------------------+
//| File: Engines/TrendPullbackEA.mq5                                |
//| Type: Engine (MT5 events + execution)                            |
//| Ver : 0.3.0                                                      |
//|                                                                  |
//| Trend Pullback EA (Generic Engine)                               |
//|                                                                  |
//| Contract                                                         |
//| - This .mq5 contains ONLY MT5 event handlers + PlaceTrade()      |
//| - Shared infra: KurosawaHelpers.mqh (risk/gates/normalize/etc.)   |
//| - Tracking:   KurosawaTrack.mqh (OPEN/CLOSE + dedupe + streak)   |
//| - Strategy:   Strategies/TrendPullback.mqh (signal generation)   |
//| - Inputs:     Inputs/TrendPullbackEA_Inputs.mqh                  |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>

// Shared infra + tracking
#include "../Helpers/KurosawaHelpers.mqh"

// Strategy (signal generation only)
#include "../Strategies/TrendPullback.mqh"

// Inputs (Excel-aligned)
#include "../Inputs/TrendPullback_Inputs.mqh"

CTrade trade;

// ------------------------- Indicator Handles -----------------------
int hBiasEmaFast = INVALID_HANDLE;
int hBiasEmaSlow = INVALID_HANDLE;
int hEntryEma    = INVALID_HANDLE;
int hRsi         = INVALID_HANDLE;
int hAtr         = INVALID_HANDLE;

// ------------------------- Runtime State ---------------------------
datetime       g_lastClosedBarTime = 0;
DailyRiskState g_risk;

int      g_consecLosses    = 0;   // maintained by Track_OnTradeTransaction (and optional daily reset)
datetime g_lastCloseTime   = 0;

ulong    g_lastOpenDealId  = 0;
ulong    g_lastCloseDealId = 0;

// Diagnostics
DailyDiag g_diag;

//+------------------------------------------------------------------+
//| CreateIndicators_WithRetry                                       |
//+------------------------------------------------------------------+
bool CreateIndicators_WithRetry()
{
   // Preload entry TF series (tester can be lazy at init)
   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   const int need = 120;
   const int got  = CopyRates(_Symbol, InpTargetTf, 0, need, rates);
   if(got < need)
   {
      Print("INIT_FAILED: not enough history for ", _Symbol, " ", EnumToString(InpTargetTf),
            " bars=", got, " err=", GetLastError());
      return false;
   }

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

   // Retry loop (tester init race)
   for(int i=0; i<10; i++)
   {
      ResetLastError();

      if(hBiasEmaFast != INVALID_HANDLE) IndicatorRelease(hBiasEmaFast);
      if(hBiasEmaSlow != INVALID_HANDLE) IndicatorRelease(hBiasEmaSlow);
      if(hEntryEma    != INVALID_HANDLE) IndicatorRelease(hEntryEma);
      if(hRsi         != INVALID_HANDLE) IndicatorRelease(hRsi);
      if(hAtr         != INVALID_HANDLE) IndicatorRelease(hAtr);

      hBiasEmaFast = iMA(_Symbol, InpBiasTf,   InpBiasEmaFast, 0, MODE_EMA, PRICE_CLOSE);
      hBiasEmaSlow = iMA(_Symbol, InpBiasTf,   InpBiasEmaSlow, 0, MODE_EMA, PRICE_CLOSE);

      hEntryEma    = iMA(_Symbol, InpTargetTf, InpEntryEma,    0, MODE_EMA, PRICE_CLOSE);
      hRsi         = iRSI(_Symbol, InpTargetTf, InpRsiPeriod, PRICE_CLOSE);
      hAtr         = iATR(_Symbol, InpTargetTf, InpAtrPeriod);

      const bool ok =
         (hBiasEmaFast != INVALID_HANDLE) &&
         (hBiasEmaSlow != INVALID_HANDLE) &&
         (hEntryEma    != INVALID_HANDLE) &&
         (hRsi         != INVALID_HANDLE) &&
         (hAtr         != INVALID_HANDLE);

      if(ok) return true;

      const int err = GetLastError();
      Print("INIT_RETRY(", i, "): handle create failed. err=", err,
            " BiasFast=", hBiasEmaFast,
            " BiasSlow=", hBiasEmaSlow,
            " EntryEma=", hEntryEma,
            " RSI=", hRsi,
            " ATR=", hAtr,
            " biasTf=", EnumToString(InpBiasTf),
            " entryTf=", EnumToString(InpTargetTf));

      Sleep(200);
   }

   return false;
}

//+------------------------------------------------------------------+
//| PlaceTrade                                                       |
//| - SL/TP are in POINTS                                            |
//| - Uses shared Risk_CalcTradeVolume (fallback fixed lot etc.)     |
//+------------------------------------------------------------------+
bool PlaceTrade(const bool isBuy, const double slPts, const double tpPts)
{
   if(slPts <= 0.0 || tpPts <= 0.0)
      return false;

   const double vol = Risk_CalcTradeVolume(
      _Symbol,
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

   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
   {
      g_diag.block_indfail++;
      return false;
   }

   const double entry = isBuy ? ask : bid;

   double sl = 0.0, tp = 0.0;
   if(isBuy)
   {
      sl = entry - slPts * _Point;
      tp = entry + tpPts * _Point;
   }
   else
   {
      sl = entry + slPts * _Point;
      tp = entry - tpPts * _Point;
   }

   if(!EnsureStopsLevel(_Symbol, entry, sl, tp, isBuy, true))
   {
      g_diag.block_stops++;
      return false;
   }

   trade.SetExpertMagicNumber((int)InpMagic);
   trade.SetDeviationInPoints(10);

   const string cmt = InpEaName + "|" + InpEaVersion;

   bool ok = false;
   if(isBuy) ok = trade.Buy(vol, _Symbol, 0.0, sl, tp, cmt + "|BUY");
   else      ok = trade.Sell(vol, _Symbol, 0.0, sl, tp, cmt + "|SELL");

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
   // Intent checks (warn-only)
   if(StringLen(InpTargetPair) > 0 && _Symbol != InpTargetPair)
      Print("Warning: Intended symbol=", InpTargetPair, ", current=", _Symbol);

   if(_Period != InpTargetTf)
      Print("Warning: Intended TF=", EnumToString(InpTargetTf), ", current=", EnumToString(_Period));

   // Ensure symbol is selected (tester/marketwatch safety)
   SymbolSelect(_Symbol, true);

   ShowEaLabel(
      InpEaName,
      InpEaId,
      (int)InpMagic,
      _Symbol,
      (ENUM_TIMEFRAMES)_Period
   );
   
   // Indicators
   if(!CreateIndicators_WithRetry())
   {
      Print("INIT_FAILED: indicators not ready after retries.",
            " BiasFast=", hBiasEmaFast, " BiasSlow=", hBiasEmaSlow,
            " EntryEma=", hEntryEma, " RSI=", hRsi, " ATR=", hAtr,
            " biasTf=", EnumToString(InpBiasTf),
            " entryTf=", EnumToString(InpTargetTf),
            " symbol=", _Symbol);
      return INIT_FAILED;
   }

   // Risk state init (daily counters etc.)
   Risk_Init(g_risk, TimeCurrent());

   // Prime last closed bar time (entry TF)
   g_lastClosedBarTime = (datetime)iTime(_Symbol, InpTargetTf, 1);
   if(g_lastClosedBarTime <= 0) g_lastClosedBarTime = TimeCurrent();

   trade.SetExpertMagicNumber((int)InpMagic);
   trade.SetDeviationInPoints(10);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hBiasEmaFast != INVALID_HANDLE) IndicatorRelease(hBiasEmaFast);
   if(hBiasEmaSlow != INVALID_HANDLE) IndicatorRelease(hBiasEmaSlow);
   if(hEntryEma    != INVALID_HANDLE) IndicatorRelease(hEntryEma);
   if(hRsi         != INVALID_HANDLE) IndicatorRelease(hRsi);
   if(hAtr         != INVALID_HANDLE) IndicatorRelease(hAtr);

   hBiasEmaFast = INVALID_HANDLE;
   hBiasEmaSlow = INVALID_HANDLE;
   hEntryEma    = INVALID_HANDLE;
   hRsi         = INVALID_HANDLE;
   hAtr         = INVALID_HANDLE;
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
      _Symbol
   );
}

void OnTick()
{
   const datetime now = TimeCurrent();

   // Daily reset (do not reset loss streak unless configured)
   DailyResetIfNewDay(g_risk, now, g_consecLosses, InpResetConsecLossDaily);

   // ------------------------------------------------------------
   // 1) Manage open position first (optional max-hold exit)
   // ------------------------------------------------------------
   if(PositionExists(_Symbol, (int)InpMagic))
   {
      if(InpMaxHoldMinutes > 0)
      {
         if(PositionSelectByMagic(_Symbol, (long)InpMagic))
         {
            const datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
            if(MinutesHeld(openTime, now) >= InpMaxHoldMinutes)
               trade.PositionClose(_Symbol);
         }
      }
      return;
   }

   // ------------------------------------------------------------
   // 2) Gates (only when flat)
   // ------------------------------------------------------------
   if(!IsTimeWindowByOffsetHours(InpStartHour, InpEndHour, InpUtcOffset))
   {
      g_diag.block_session++;
      return;
   }

   if(!SpreadOK(_Symbol, InpMaxSpreadPoints))
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

   // ------------------------------------------------------------
   // 3) Once per NEW CLOSED bar (entry TF)
   // ------------------------------------------------------------
   if(!IsNewClosedBar(_Symbol, InpTargetTf, g_lastClosedBarTime))
      return;

   Track_OnNewBar(InpTrackEnable, (int)InpMagic, _Symbol, InpTargetTf);
   g_diag.bars++;

   // ------------------------------------------------------------
   // 4) Strategy evaluation (handles-based, shift=1)
   // ------------------------------------------------------------
   TrendPullbackInputs inps;
   inps.atr_min_points        = InpAtrMinPoints;
   inps.atr_max_points        = InpAtrMaxPoints;
   inps.rsi_buy_max           = InpRsiBuyBelow;
   inps.rsi_sell_min          = InpRsiSellAbove;
   inps.bias_min_gap_points   = InpBiasMinGapPoints;

   TrendPullbackSignal sig;

   const TrendPullbackResult sres = TrendPullback_EvaluateHandles(
      hBiasEmaFast, hBiasEmaSlow,
      hEntryEma,
      hRsi,
      hAtr,
      _Symbol,
      InpTargetTf,
      1,           // shift=1 (latest closed bar on entry TF)
      _Point,
      inps,
      sig
   );

   if(sres != TRENDPB_OK)
   {
      if(sres == TRENDPB_BLOCK_ATR)          g_diag.block_atr++;
      else if(sres == TRENDPB_BLOCK_NO_BIAS) g_diag.block_nobias++;
      else if(sres == TRENDPB_BLOCK_NO_SIGNAL) g_diag.block_nosignal++;
      else                                   g_diag.block_indfail++;
      return;
   }

   if(sig.buy == sig.sell)
   {
      g_diag.block_ambig++;
      return;
   }

   g_diag.signals++;

   // ------------------------------------------------------------
   // 5) Stops/targets from ATR points (signal carries atr_points)
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
   // 6) Place trade
   // ------------------------------------------------------------
   if(sig.buy)  PlaceTrade(true,  slPts, tpPts);
   else         PlaceTrade(false, slPts, tpPts);
}
