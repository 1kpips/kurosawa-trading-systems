//+------------------------------------------------------------------+
//| File: Engines/TokyoFixEA.mq5                                     |
//| Type: Engine (MT5 events + execution)                            |
//| Ver : 0.1.0                                                      |
//|                                                                  |
//| Tokyo fix flow fade. Day logic and the clock conversion live in  |
//| Strategies/TokyoFix.mqh; this file owns MT5 events, gates, the   |
//| one-attempt-per-day entry, sizing, the pip stop and the clock    |
//| exit.                                                            |
//|                                                                  |
//| Timing                                                           |
//| - Entry: first tick at or after fix + InpEntryDelayMin (JST), on |
//|   a day InpDayFilter admits, once per JST day. If no fill within |
//|   InpEntryWindowMin the day is skipped (logged).                 |
//| - Exit: first tick at or after entry time + InpHoldMinutes. No   |
//|   take-profit. InpStopPips is a protective stop only.            |
//| - Everything the tester sees is on the server clock; JST is      |
//|   derived from it, so a backtest and a live chart agree.         |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
#include "../Helpers/KurosawaHelpers.mqh"
#include "../Strategies/TokyoFix.mqh"
#include "../Inputs/TokyoFix_Inputs.mqh"

CTrade trade;

string   g_symbol            = "";
datetime g_lastClosedBarTime = 0;
DailyRiskState g_risk;
int      g_consecLosses  = 0;
datetime g_lastCloseTime = 0;
ulong    g_lastOpenDealId  = 0;
ulong    g_lastCloseDealId = 0;
DailyDiag g_diag;

int      g_lastJstYmdTried = 0;   // one attempt per JST day
datetime g_exitAtServer    = 0;   // clock exit for the open position (server time)

//+------------------------------------------------------------------+
double PipPoints(const string sym)
{
   const int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   return (digits == 3 || digits == 5) ? 10.0 : 1.0;
}

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
   cfg.requireTp       = false;   // clock exit, no target
   cfg.maxSendRetries  = 2;

   return Exec_PlaceTrade(
      trade, sym, isBuy, slPts, 0.0, cfg, g_risk,
      g_diag.trades, g_diag.block_orderfail, g_diag.block_indfail, g_diag.block_stops
   );
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_symbol = ResolveEngineSymbol(InpTargetPair, _Symbol);
   ShowEaLabel(InpEaName, InpEaId, (int)InpMagic, _Symbol, (ENUM_TIMEFRAMES)_Period);

   if(!ChartMatchesTarget(InpTargetPair, InpTargetTf, InpStrictChartMatch))
      return INIT_PARAMETERS_INCORRECT;

   if(InpFixHour < 0 || InpFixHour > 23 || InpFixMinute < 0 || InpFixMinute > 59 ||
      InpHoldMinutes <= 0 || InpEntryWindowMin <= 0 || (InpSide != -1 && InpSide != 1) || InpStopPips < 0.0)
   {
      Print("INIT_FAILED: invalid inputs. fix=", InpFixHour, ":", InpFixMinute, " hold=", InpHoldMinutes,
            " window=", InpEntryWindowMin, " side=", InpSide, " stopPips=", InpStopPips);
      return INIT_FAILED;
   }

   Risk_Init(g_risk, TradingDayNow());

   g_lastClosedBarTime = (datetime)iTime(g_symbol, InpTargetTf, 1);
   if(g_lastClosedBarTime <= 0) g_lastClosedBarTime = TimeCurrent();

   trade.SetExpertMagicNumber((int)InpMagic);
   trade.SetDeviationInPoints((int)InpDeviationPoints);

   EventSetTimer(KUROSAWA_ENGINE_TIMER_SEC);

   const datetime jst = TFix_ServerToJst(EngineClock());
   Print("Init OK. ", InpEaName, " id=", InpEaId, " sym=", g_symbol, " tf=", EnumToString(InpTargetTf),
         " magic=", InpMagic, " build=", TOKYOFIX_BUILD, " engineInput=", InpEaVersion, " preset=", InpPresetVersion,
         " fix=", InpFixHour, ":", InpFixMinute, " JST +", InpEntryDelayMin, "min hold=", InpHoldMinutes,
         "min side=", InpSide, " days=", EnumToString(InpDayFilter), " jpHolidays=", (InpSkipJpHolidays ? "skip" : "trade"), " stop=", InpStopPips, " pips",
         " portfolio=", InpPortfolioMaxPositions, "/", InpPortfolioMaxRiskPercent, "/", InpPortfolioDailyLossPct, "/", InpPortfolioMaxPerCurrency,
         " (server ", TimeToString(EngineClock(), TIME_DATE | TIME_MINUTES), " = JST ", TimeToString(jst, TIME_DATE | TIME_MINUTES), ")");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   PrintDailySummary(InpEaName, g_symbol, InpTargetTf, g_diag);
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
   const datetime now = EngineClock();
   const datetime jst = TFix_ServerToJst(now);

   DailyRollIfNeeded(InpEaName, sym, InpTargetTf, g_diag, TradingDayYmd());
   DailyResetIfNewDay(g_risk, TradingDayNow(), g_consecLosses, InpResetConsecLossDaily);
   if(IsNewClosedBar(sym, InpTargetTf, g_lastClosedBarTime)) g_diag.bars++;

   // ----------------------------------------------------------------
   // 1) Position management: the clock exit
   // ----------------------------------------------------------------
   if(PositionExists(sym, (long)InpMagic))
   {
      g_diag.block_haspos++;
      Track_OnNewBar(InpTrackEnable, (int)InpMagic, sym, InpTargetTf);

      if(g_exitAtServer > 0 && now >= g_exitAtServer && PositionSelectByMagic(sym, (long)InpMagic))
      {
         const ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
         if(trade.PositionClose(ticket)) { g_exitAtServer = 0; return; }
         g_diag.block_orderfail++;
      }
      if(InpMaxHoldMinutes > 0 && Position_CheckMaxHoldExit(trade, sym, (long)InpMagic, InpMaxHoldMinutes, now))
         return;
      return;
   }
   g_exitAtServer = 0;

   // ----------------------------------------------------------------
   // 2) Is it the entry moment? Once per JST day.
   // ----------------------------------------------------------------
   const int ymd     = TFix_Ymd(jst);
   const int minutes = TFix_MinutesOfDay(jst);
   const int entryAt = InpFixHour * 60 + InpFixMinute + InpEntryDelayMin;
   if(minutes < entryAt || minutes >= entryAt + InpEntryWindowMin) return;
   if(ymd == g_lastJstYmdTried) return;

   string why;
   if(!TFix_DayAllowed(jst, InpDayFilter, InpSkipJpHolidays, why))
   {
      g_lastJstYmdTried = ymd;      // decided for today
      g_diag.block_nosignal++;
      return;
   }

   // ----------------------------------------------------------------
   // 3) Flat-state gates (shared). Spread/cooldown just wait for the next
   //    tick inside the window; the hard limits consume the day.
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
         case GATE_BLOCK_MAXDAY:    g_diag.block_maxday++;    g_lastJstYmdTried = ymd; break;
         case GATE_BLOCK_LOSS:      g_diag.block_loss++;      g_lastJstYmdTried = ymd; break;
         case GATE_BLOCK_MAXTRADES: g_diag.block_maxtrades++; g_lastJstYmdTried = ymd; break;
         default: break;
      }
      return;
   }

   // ----------------------------------------------------------------
   // 4) One attempt. Success or a rejected send both consume the day.
   // ----------------------------------------------------------------
   const bool   isBuy = (InpSide > 0);
   const double slPts = (InpStopPips > 0.0) ? InpStopPips * PipPoints(sym) : 0.0;
   // ----------------------------------------------------------------
   // 4b) Portfolio cap (account-level; KurosawaPortfolio.mqh). Refuses the
   //    entry when the account as a whole is full; never touches positions.
   // ----------------------------------------------------------------
   {
      PortfolioLimits lim;
      lim.maxPositions     = InpPortfolioMaxPositions;
      lim.maxRiskPercent   = InpPortfolioMaxRiskPercent;
      lim.dailyLossPercent = InpPortfolioDailyLossPct;
      lim.maxPerCurrency   = InpPortfolioMaxPerCurrency;
      string pwhy;
      if(!Portfolio_HasRoom(sym, Portfolio_RiskMoney(sym, InpFixedLot, slPts), lim, pwhy))
      {
         g_diag.block_portfolio++;
         if(g_diag.block_portfolio == 1) Print("PORTFOLIO_BLOCK ", InpEaName, " ", sym, ": ", pwhy);
         g_lastJstYmdTried = ymd; return;
      }
   }

   g_lastJstYmdTried = ymd;
   g_diag.signals++;
   Print("TOKYOFIX_ENTRY ", (isBuy ? "BUY" : "SELL"), " ", sym, " ", why, " jst=", TimeToString(jst, TIME_DATE | TIME_MINUTES),
         " exit in ", InpHoldMinutes, "min slPts=", DoubleToString(slPts, 0));
   if(PlaceTrade(sym, isBuy, slPts))
      g_exitAtServer = now + (datetime)(InpHoldMinutes * 60);
}

//+------------------------------------------------------------------+
void OnTimer()
{
   OnTick();
}
//+------------------------------------------------------------------+
