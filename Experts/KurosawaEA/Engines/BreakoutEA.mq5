//+------------------------------------------------------------------+
//| File: Engines/BreakoutEA.mq5                                     |
//| Type: Engine (MT5 events + execution)                            |
//| Ver : 0.1.0                                                      |
//|                                                                  |
//| Breakout EA - London-range breakout, traded in the New York      |
//| window. Strategy logic lives in Strategies/Breakout.mqh; this    |
//| file owns MT5 events, gates, the day state (one attempt per side |
//| per day), sizing, SL/TP and the flat-at-hour exit.               |
//|                                                                  |
//| Clock: everything is broker server time. InpUtcOffset must be 0. |
//| All distances are POINTS.                                        |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
#include "../Helpers/KurosawaHelpers.mqh"
#include "../Strategies/Breakout.mqh"
#include "../Inputs/Breakout_Inputs.mqh"

CTrade trade;

// Indicator handles
int g_hATR = INVALID_HANDLE;
int g_hADX = INVALID_HANDLE;

// Runtime state
string   g_symbol           = "";
datetime g_lastClosedBarTime = 0;
DailyRiskState g_risk;
int      g_consecLosses  = 0;
datetime g_lastCloseTime = 0;
ulong    g_lastOpenDealId  = 0;
ulong    g_lastCloseDealId = 0;
DailyDiag g_diag;

// Day state: one attempt per side per server day. Set on the SIGNAL, not on
// the fill, so a rejected order does not get a second try on the next bar.
int  g_dayYmd    = 0;
bool g_longDone  = false;
bool g_shortDone = false;

//+------------------------------------------------------------------+
datetime ServerDayStart()
{
   const datetime now = EngineClock();
   return now - (datetime)(now % 86400);
}

int ServerHour()
{
   MqlDateTime dt;
   TimeToStruct(EngineClock(), dt);
   return dt.hour;
}

void RollDayStateIfNeeded()
{
   const int ymd = DateYmd(EngineClock());
   if(ymd != g_dayYmd)
   {
      g_dayYmd    = ymd;
      g_longDone  = false;
      g_shortDone = false;
   }
}

//+------------------------------------------------------------------+
bool PlaceTrade(const string sym, const bool isBuy, const double slPts, const double tpPts)
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
   cfg.requireTp       = true;
   cfg.maxSendRetries  = 2;

   return Exec_PlaceTrade(
      trade, sym, isBuy, slPts, tpPts, cfg, g_risk,
      g_diag.trades, g_diag.block_orderfail, g_diag.block_indfail, g_diag.block_stops
   );
}

//+------------------------------------------------------------------+
bool CreateIndicatorsWithRetry()
{
   const int need = MathMax(InpAtrPeriod, InpAdxPeriod) * 4 + 100;
   for(int attempt = 0; attempt < 5; attempt++)
   {
      EnsureHistory(g_symbol, InpTargetTf, need);

      if(g_hATR == INVALID_HANDLE) g_hATR = iATR(g_symbol, InpTargetTf, InpAtrPeriod);
      if(g_hADX == INVALID_HANDLE && InpUseAdxFilter) g_hADX = iADX(g_symbol, InpTargetTf, InpAdxPeriod);

      const bool atrOk = (g_hATR != INVALID_HANDLE && BarsCalculated(g_hATR) > 0);
      const bool adxOk = (!InpUseAdxFilter || (g_hADX != INVALID_HANDLE && BarsCalculated(g_hADX) > 0));
      if(atrOk && adxOk) return true;

      Sleep(200);
   }
   return false;
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_symbol = ResolveEngineSymbol(InpTargetPair, _Symbol);
   ShowEaLabel(InpEaName, InpEaId, (int)InpMagic, _Symbol, (ENUM_TIMEFRAMES)_Period);

   if(!ChartMatchesTarget(InpTargetPair, InpTargetTf, InpStrictChartMatch))
      return INIT_PARAMETERS_INCORRECT;

   if(InpUtcOffset != 0)
   {
      Print("INIT_PARAMETERS_INCORRECT: BreakoutEA works in broker server hours; set InpUtcOffset=0 (got ", InpUtcOffset, ")");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpRangeEndHour <= InpRangeStartHour || InpRangeEndHour > InpStartHour)
   {
      Print("INIT_PARAMETERS_INCORRECT: range window ", InpRangeStartHour, "-", InpRangeEndHour,
            " must close before the entry window opens at ", InpStartHour);
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpAtrPeriod <= 0 || (InpUseAdxFilter && InpAdxPeriod <= 0))
   {
      Print("INIT_FAILED: invalid indicator inputs. AtrPeriod=", InpAtrPeriod, " AdxPeriod=", InpAdxPeriod);
      return INIT_FAILED;
   }

   if(!CreateIndicatorsWithRetry())
   {
      Print("INIT_FAILED: indicator handles not ready. sym=", g_symbol, " tf=", EnumToString(InpTargetTf));
      return INIT_FAILED;
   }

   Risk_Init(g_risk, TradingDayNow());

   g_lastClosedBarTime = (datetime)iTime(g_symbol, InpTargetTf, 1);
   if(g_lastClosedBarTime <= 0) g_lastClosedBarTime = TimeCurrent();

   RollDayStateIfNeeded();

   trade.SetExpertMagicNumber((int)InpMagic);
   trade.SetDeviationInPoints((int)InpDeviationPoints);

   EventSetTimer(KUROSAWA_ENGINE_TIMER_SEC);

   Print("Init OK. ", InpEaName, " sym=", g_symbol, " tf=", EnumToString(InpTargetTf),
         " magic=", InpMagic, " build=", BREAKOUT_BUILD, " engineInput=", InpEaVersion, " preset=", InpPresetVersion,
         " range=", InpRangeStartHour, "-", InpRangeEndHour, " entry=", InpStartHour, "-", InpEndHour,
         " flatAt=", InpFlatAtHour, " (server hours)");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   PrintDailySummary(InpEaName, g_symbol, InpTargetTf, g_diag);
   if(g_hATR != INVALID_HANDLE) { IndicatorRelease(g_hATR); g_hATR = INVALID_HANDLE; }
   if(g_hADX != INVALID_HANDLE) { IndicatorRelease(g_hADX); g_hADX = INVALID_HANDLE; }
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
void OnTick()
{
   const string   sym = g_symbol;
   const datetime now = TimeCurrent();

   DailyRollIfNeeded(InpEaName, sym, InpTargetTf, g_diag, TradingDayYmd());
   DailyResetIfNewDay(g_risk, TradingDayNow(), g_consecLosses, InpResetConsecLossDaily);
   RollDayStateIfNeeded();

   // ----------------------------------------------------------------
   // 1) Position management
   // ----------------------------------------------------------------
   if(PositionExists(sym, (long)InpMagic))
   {
      g_diag.block_haspos++;
      Track_OnNewBar(InpTrackEnable, (int)InpMagic, sym, InpTargetTf);

      // Flat-at-hour: the time exit of this system. NY close, no overnight.
      if(InpFlatAtHour >= 0 && ServerHour() >= InpFlatAtHour)
      {
         if(PositionSelectByMagic(sym, (long)InpMagic))
         {
            const ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
            if(trade.PositionClose(ticket)) return;
            g_diag.block_orderfail++;
         }
      }

      if(InpMaxHoldMinutes > 0)
      {
         if(Position_CheckMaxHoldExit(trade, sym, (long)InpMagic, InpMaxHoldMinutes, now))
            return;
      }

      if(InpUseTrailing)
      {
         Position_ManageAtrTrailing(trade, sym, (long)InpMagic, g_hATR,
                                    InpTrailStartR, InpTrailStepAtrMult,
                                    g_diag.block_indfail, g_diag.block_stops, g_diag.block_orderfail);
      }
      return;
   }

   // ----------------------------------------------------------------
   // 2) Flat-state gates (shared)
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
         case GATE_BLOCK_MAXDAY:    g_diag.block_maxday++;    break;
         case GATE_BLOCK_LOSS:      g_diag.block_loss++;      break;
         case GATE_BLOCK_MAXTRADES: g_diag.block_maxtrades++; break;
         default: break;
      }
      return;
   }

   // Both sides already attempted today: nothing left to do until tomorrow.
   if(g_longDone && g_shortDone) return;

   // ----------------------------------------------------------------
   // 3) Once per closed bar
   // ----------------------------------------------------------------
   if(!IsNewClosedBar(sym, InpTargetTf, g_lastClosedBarTime))
      return;

   g_diag.bars++;

   const double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(pt <= 0.0) { g_diag.block_indfail++; return; }

   BreakoutInputs inps;
   inps.range_start_hour   = InpRangeStartHour;
   inps.range_end_hour     = InpRangeEndHour;
   inps.break_buffer_atr   = InpBreakBufferAtr;
   inps.max_range_atr      = InpMaxRangeAtr;
   inps.atr_min_points     = InpAtrMinPoints;
   inps.atr_max_points     = InpAtrMaxPoints;
   inps.use_adx_filter     = InpUseAdxFilter;
   inps.adx_min_to_trade   = InpMinAdxToTrade;
   inps.adx_max_to_trade   = InpMaxAdxToTrade;
   inps.require_adx_rising = InpRequireAdxRising;
   inps.require_fresh_break = InpRequireFreshBreak;
   inps.allow_longs        = InpAllowLongs  && !g_longDone;
   inps.allow_shorts       = InpAllowShorts && !g_shortDone;

   BreakoutSignal sig;
   const BreakoutResult res = Breakout_EvaluateHandles(
      g_hATR, g_hADX, sym, InpTargetTf, 1, pt, ServerDayStart(), inps, sig
   );

   if(res != BREAKOUT_OK)
   {
      // block_nobias doubles as "no usable range today" (no bars / too wide) -
      // the closest existing counter; the daily summary labels it nobias.
      if(res == BREAKOUT_BLOCK_NO_RANGE || res == BREAKOUT_BLOCK_RANGE_WIDE) g_diag.block_nobias++;
      else if(res == BREAKOUT_BLOCK_ATR)        g_diag.block_atr++;
      else if(res == BREAKOUT_BLOCK_ADX)        g_diag.block_adx++;
      else if(res == BREAKOUT_BLOCK_NO_SIGNAL)  g_diag.block_nosignal++;
      else if(res == BREAKOUT_BLOCK_AMBIG)      g_diag.block_ambig++;
      else                                      g_diag.block_indfail++;
      return;
   }

   if(sig.buy == sig.sell) { g_diag.block_ambig++; return; }

   g_diag.signals++;
   if(sig.buy) g_longDone = true; else g_shortDone = true;

   // ----------------------------------------------------------------
   // 4) Stop: min(SlAtrMult x ATR, distance back to the range midpoint),
   //    floored at 0.5 ATR so it can never sit inside the spread.
   // ----------------------------------------------------------------
   double slPts = sig.atr_points * InpSlAtrMult;
   const double midDistPts = MathAbs(sig.close1 - sig.range_mid) / pt;
   if(midDistPts > 0.0 && midDistPts < slPts) slPts = midDistPts;
   slPts = MathMax(slPts, 0.5 * sig.atr_points);

   const double tpPts = slPts * InpTpRMultiple;
   if(slPts <= 0.0 || tpPts <= 0.0) { g_diag.block_stops++; return; }

   PlaceTrade(sym, sig.buy, slPts, tpPts);
}

//+------------------------------------------------------------------+
void OnTimer()
{
   OnTick();
}
//+------------------------------------------------------------------+
