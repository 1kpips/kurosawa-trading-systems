//+------------------------------------------------------------------+
//| File: Engines/FadeEA.mq5                                         |
//| Type: Engine (MT5 events + execution)                            |
//| Ver : 0.1.0                                                      |
//|                                                                  |
//| Fade EA - fades the D1 Breakout analyzer's strong readings.      |
//| Strategy logic lives in Strategies/Fade.mqh; this file owns MT5  |
//| events, gates, the pending-entry window, sizing, the disaster    |
//| stop and the bar-count exit.                                     |
//|                                                                  |
//| Timing                                                           |
//| - The reading is judged once, on the first tick of a new D1 bar  |
//|   (the analyzer's own moment). The entry is then PENDING: it is  |
//|   filled on the first tick the flat-state gates pass, up to      |
//|   InpEntryWindowMinutes after the bar open. The daily rollover   |
//|   spread would otherwise block every entry, and a consumed       |
//|   IsNewClosedBar would lose the signal for the day.              |
//| - Exit: at the open of the InpHoldBars-th bar after entry,       |
//|   measured in bars of InpTargetTf. No take-profit; the stop is a |
//|   wide disaster stop only. The study that justifies this engine  |
//|   measured a 5-day hold with no stop; tight stops hurt.          |
//| - All distances are POINTS.                                      |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
#include "../Helpers/KurosawaHelpers.mqh"
#include "../Strategies/Fade.mqh"
#include "../Inputs/Fade_Inputs.mqh"

CTrade trade;

int g_hATR = INVALID_HANDLE;

string   g_symbol            = "";
datetime g_lastClosedBarTime = 0;
DailyRiskState g_risk;
int      g_consecLosses  = 0;
datetime g_lastCloseTime = 0;
ulong    g_lastOpenDealId  = 0;
ulong    g_lastCloseDealId = 0;
DailyDiag g_diag;

// Pending entry (set on the bar's first tick, consumed by the first fill or the window end)
int      g_pendingDir   = 0;        // +1 buy, -1 sell, 0 none
datetime g_pendingUntil = 0;
double   g_pendingSlPts = 0.0;
string   g_pendingWhy   = "";

//+------------------------------------------------------------------+
bool PlaceTrade(const string sym, const bool isBuy, const double slPts)
{
   ExecConfig cfg;
   cfg.magic           = (ulong)InpMagic;
   cfg.eaName          = InpEaName;
   cfg.eaVersion       = InpEaVersion;
   cfg.deviationPoints = (int)InpDeviationPoints;
   cfg.useRiskSizing   = InpUseRiskSizing;
   cfg.riskPercent     = InpRiskPercent;
   cfg.fixedLot        = InpFixedLot;
   cfg.maxLotCap       = InpMaxLotCap;
   cfg.requireTp       = false;   // bar-count exit, no target
   cfg.maxSendRetries  = 2;

   return Exec_PlaceTrade(
      trade, sym, isBuy, slPts, 0.0, cfg, g_risk,
      g_diag.trades, g_diag.block_orderfail, g_diag.block_indfail, g_diag.block_stops
   );
}

//+------------------------------------------------------------------+
bool CreateIndicatorsWithRetry()
{
   const int need = InpLookbackBars + InpAtrAvgBars + InpAtrPeriod * 4 + 50;
   for(int attempt = 0; attempt < 5; attempt++)
   {
      EnsureHistory(g_symbol, InpTargetTf, need);
      if(g_hATR == INVALID_HANDLE) g_hATR = iATR(g_symbol, InpTargetTf, InpAtrPeriod);
      if(g_hATR != INVALID_HANDLE && BarsCalculated(g_hATR) > need) return true;
      Sleep(200);
   }
   return (g_hATR != INVALID_HANDLE && BarsCalculated(g_hATR) > 0);
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_symbol = ResolveEngineSymbol(InpTargetPair, _Symbol);
   ShowEaLabel(InpEaName, InpEaId, (int)InpMagic, _Symbol, (ENUM_TIMEFRAMES)_Period);

   if(!ChartMatchesTarget(InpTargetPair, InpTargetTf, InpStrictChartMatch))
      return INIT_PARAMETERS_INCORRECT;

   if(InpLookbackBars <= 0 || InpAtrPeriod <= 0 || InpAtrAvgBars <= 0 || InpHoldBars <= 0)
   {
      Print("INIT_FAILED: invalid inputs. Lookback=", InpLookbackBars, " AtrPeriod=", InpAtrPeriod,
            " AtrAvgBars=", InpAtrAvgBars, " HoldBars=", InpHoldBars);
      return INIT_FAILED;
   }

   if(!CreateIndicatorsWithRetry())
   {
      Print("INIT_FAILED: ATR handle not ready. sym=", g_symbol, " tf=", EnumToString(InpTargetTf));
      return INIT_FAILED;
   }

   Risk_Init(g_risk, TradingDayNow());

   g_lastClosedBarTime = (datetime)iTime(g_symbol, InpTargetTf, 1);
   if(g_lastClosedBarTime <= 0) g_lastClosedBarTime = TimeCurrent();

   trade.SetExpertMagicNumber((int)InpMagic);
   trade.SetDeviationInPoints((int)InpDeviationPoints);

   EventSetTimer(KUROSAWA_ENGINE_TIMER_SEC);

   Print("Init OK. ", InpEaName, " sym=", g_symbol, " tf=", EnumToString(InpTargetTf),
         " magic=", InpMagic, " build=", FADE_BUILD, " engineInput=", InpEaVersion, " preset=", InpPresetVersion,
         " fade>=", InpMinStrength, " hold=", InpHoldBars, " bars, stop=", InpDisasterStopAtr, " ATR");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   PrintDailySummary(InpEaName, g_symbol, InpTargetTf, g_diag);
   if(g_hATR != INVALID_HANDLE) { IndicatorRelease(g_hATR); g_hATR = INVALID_HANDLE; }
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   Track_OnTradeTransaction(
      InpTrackEnable, trans,
      InpEaId, InpEaName, InpEaVersion, InpPresetVersion,
      (int)InpMagic, InpTrackSendOpen,
      g_lastOpenDealId, g_lastCloseDealId, g_consecLosses, g_lastCloseTime,
      InpTargetTf, g_symbol
   );
}

//+------------------------------------------------------------------+
// Bars of InpTargetTf that have opened since the position was opened.
int BarsSinceOpen(const string sym)
{
   const datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
   if(openTime <= 0) return 0;
   const int shift = iBarShift(sym, InpTargetTf, openTime, false);
   return (shift < 0) ? 0 : shift;
}

//+------------------------------------------------------------------+
void OnTick()
{
   const string   sym = g_symbol;
   const datetime now = TimeCurrent();

   DailyRollIfNeeded(InpEaName, sym, InpTargetTf, g_diag, TradingDayYmd());
   DailyResetIfNewDay(g_risk, TradingDayNow(), g_consecLosses, InpResetConsecLossDaily);

   // ----------------------------------------------------------------
   // 1) Position management: the bar-count exit
   // ----------------------------------------------------------------
   if(PositionExists(sym, (long)InpMagic))
   {
      g_diag.block_haspos++;
      g_pendingDir = 0;   // a position supersedes any pending entry
      Track_OnNewBar(InpTrackEnable, (int)InpMagic, sym, InpTargetTf);

      if(PositionSelectByMagic(sym, (long)InpMagic))
      {
         if(BarsSinceOpen(sym) >= InpHoldBars)
         {
            const ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
            if(trade.PositionClose(ticket)) return;
            g_diag.block_orderfail++;
         }
      }

      if(InpMaxHoldMinutes > 0 && Position_CheckMaxHoldExit(trade, sym, (long)InpMagic, InpMaxHoldMinutes, now))
         return;

      if(InpUseTrailing)
         Position_ManageAtrTrailing(trade, sym, (long)InpMagic, g_hATR, InpTrailStartR, InpTrailStepAtrMult,
                                    g_diag.block_indfail, g_diag.block_stops, g_diag.block_orderfail);
      return;
   }

   // ----------------------------------------------------------------
   // 2) New closed bar -> judge the reading once, arm a pending entry
   // ----------------------------------------------------------------
   if(IsNewClosedBar(sym, InpTargetTf, g_lastClosedBarTime))
   {
      g_diag.bars++;
      g_pendingDir = 0;

      const double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
      if(pt <= 0.0) { g_diag.block_indfail++; }
      else
      {
         FadeInputs inps;
         inps.lookback_bars = InpLookbackBars;
         inps.atr_period    = InpAtrPeriod;
         inps.atr_avg_bars  = InpAtrAvgBars;
         inps.min_atr_ratio = InpMinAtrRatio;
         inps.min_strength  = InpMinStrength;
         inps.allow_longs   = InpAllowLongs;
         inps.allow_shorts  = InpAllowShorts;

         FadeSignal sig;
         const FadeResult res = Fade_EvaluateHandles(g_hATR, sym, InpTargetTf, 1, pt, inps, sig);

         if(res == FADE_OK)
         {
            bool atrOk = true;
            if(InpAtrMinPoints > 0.0 && sig.atr_points < InpAtrMinPoints) atrOk = false;
            if(InpAtrMaxPoints > 0.0 && sig.atr_points > InpAtrMaxPoints) atrOk = false;
            if(!atrOk) g_diag.block_atr++;
            else
            {
               g_diag.signals++;
               g_pendingDir   = sig.buy ? +1 : -1;
               g_pendingSlPts = sig.atr_points * InpDisasterStopAtr;
               g_pendingUntil = (datetime)iTime(sym, InpTargetTf, 0) + (datetime)(InpEntryWindowMinutes * 60);
               g_pendingWhy   = StringFormat("reading=%s strength=%d distByAtr=%.2f atrRatio=%.2f",
                                             sig.reading, sig.strength, sig.dist_by_atr, sig.atr_ratio);
               Print("FADE_SIGNAL ", (sig.buy ? "BUY" : "SELL"), " ", sym, " ", g_pendingWhy,
                     " slPts=", DoubleToString(g_pendingSlPts, 1), " until=", TimeToString(g_pendingUntil));
            }
         }
         else if(res == FADE_BLOCK_NO_READING) g_diag.block_nosignal++;
         else if(res == FADE_BLOCK_WEAK)       g_diag.block_nobias++;    // "not strong enough" - closest counter
         else if(res == FADE_BLOCK_SIDE)       g_diag.block_ambig++;
         else                                  g_diag.block_indfail++;
      }
   }

   if(g_pendingDir == 0) return;

   if(now > g_pendingUntil)
   {
      Print("FADE_EXPIRED ", sym, " unfilled within ", InpEntryWindowMinutes, " min: ", g_pendingWhy);
      g_pendingDir = 0;
      g_diag.block_stops++;   // recorded as a stops/fill problem in the summary
      return;
   }

   // ----------------------------------------------------------------
   // 3) Flat-state gates (shared). Spread is the usual blocker right at the
   //    rollover; the pending entry simply waits for the next tick.
   // ----------------------------------------------------------------
   const GateResult gate = Gates_CheckFlat(
      sym, g_risk, g_consecLosses,
      InpStartHour, InpEndHour, InpUtcOffset,
      InpMaxSpreadPoints, InpCooldownMinutes,
      InpDailyLossLimitPercent, InpMaxConsecLosses, InpMaxTradesPerDay,
      now
   );
   if(gate != GATE_OK)
   {
      switch(gate)
      {
         case GATE_BLOCK_SESSION:   g_diag.block_session++;   break;
         case GATE_BLOCK_SPREAD:    g_diag.block_spread++;    break;
         case GATE_BLOCK_COOLDOWN:  g_diag.block_cooldown++;  break;
         case GATE_BLOCK_MAXDAY:    g_diag.block_maxday++;    g_pendingDir = 0; break;
         case GATE_BLOCK_LOSS:      g_diag.block_loss++;      g_pendingDir = 0; break;
         case GATE_BLOCK_MAXTRADES: g_diag.block_maxtrades++; g_pendingDir = 0; break;
         default: break;
      }
      return;
   }

   // ----------------------------------------------------------------
   // 4) Fill the pending entry. Success or a rejected send both consume it;
   //    one attempt per reading, like the analyzer posts once per bar.
   // ----------------------------------------------------------------
   const bool isBuy = (g_pendingDir > 0);
   const double slPts = g_pendingSlPts;
   g_pendingDir = 0;
   if(slPts <= 0.0) { g_diag.block_stops++; return; }
   PlaceTrade(sym, isBuy, slPts);
}

//+------------------------------------------------------------------+
void OnTimer()
{
   OnTick();
}
//+------------------------------------------------------------------+
