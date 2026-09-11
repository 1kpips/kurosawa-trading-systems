//+------------------------------------------------------------------+
//| File: Engines/LondonFixEA.mq5                                    |
//| Type: Engine (MT5 events + execution)                            |
//| Ver : 0.1.0                                                      |
//|                                                                  |
//| London 16:00 fix, month-end fade. Clock conversion and the side  |
//| rule live in Strategies/LondonFix.mqh (calendar helpers in       |
//| Strategies/TokyoFix.mqh); this file owns MT5 events, gates, the  |
//| one-attempt-per-day entry, sizing, the pip stop and the clock    |
//| exit.                                                            |
//|                                                                  |
//| Timing                                                           |
//| - At the first tick at or after fix + InpEntryDelayMin (London), |
//|   on a day InpDayFilter admits, measure the move from the open   |
//|   of the M5 bar InpPreWindowMin before the fix to the current    |
//|   price, and trade AGAINST it (FIX_SIDE_FADE_PRE). Once per day. |
//| - Exit: first tick at or after entry + InpHoldMinutes. No take-  |
//|   profit; InpStopPips is a protective stop only.                 |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
#include "../Helpers/KurosawaHelpers.mqh"
#include "../Strategies/LondonFix.mqh"
#include "../Inputs/LondonFix_Inputs.mqh"

CTrade trade;

string   g_symbol            = "";
datetime g_lastClosedBarTime = 0;
DailyRiskState g_risk;
int      g_consecLosses  = 0;
datetime g_lastCloseTime = 0;
ulong    g_lastOpenDealId  = 0;
ulong    g_lastCloseDealId = 0;
DailyDiag g_diag;

int      g_lastLdnYmdTried = 0;   // one attempt per London day
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
      InpHoldMinutes <= 0 || InpEntryWindowMin <= 0 || InpPreWindowMin <= 0 ||
      (InpSide != -1 && InpSide != 1) || InpStopPips < 0.0 || InpSkipJpHolidays)
   {
      Print("INIT_FAILED: invalid inputs. fix=", InpFixHour, ":", InpFixMinute, " hold=", InpHoldMinutes,
            " window=", InpEntryWindowMin, " pre=", InpPreWindowMin, " side=", InpSide, " stopPips=", InpStopPips,
            " skipJpHolidays=", InpSkipJpHolidays, " (must be false on a London clock)");
      return INIT_FAILED;
   }

   Risk_Init(g_risk, TradingDayNow());

   g_lastClosedBarTime = (datetime)iTime(g_symbol, InpTargetTf, 1);
   if(g_lastClosedBarTime <= 0) g_lastClosedBarTime = TimeCurrent();

   trade.SetExpertMagicNumber((int)InpMagic);
   trade.SetDeviationInPoints((int)InpDeviationPoints);

   EventSetTimer(KUROSAWA_ENGINE_TIMER_SEC);

   const datetime ldn = LFix_ServerToLondon(EngineClock());
   Print("Init OK. ", InpEaName, " id=", InpEaId, " sym=", g_symbol, " tf=", EnumToString(InpTargetTf),
         " magic=", InpMagic, " build=", LONDONFIX_BUILD, " engineInput=", InpEaVersion, " preset=", InpPresetVersion,
         " fix=", InpFixHour, ":", InpFixMinute, " London +", InpEntryDelayMin, "min hold=", InpHoldMinutes,
         "min sideMode=", EnumToString(InpSideMode), " pre=", InpPreWindowMin, "min minPre=", InpMinPreMovePips,
         " days=", EnumToString(InpDayFilter), " stop=", InpStopPips, " pips",
         " (server ", TimeToString(EngineClock(), TIME_DATE | TIME_MINUTES), " = London ", TimeToString(ldn, TIME_DATE | TIME_MINUTES), ")");
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
   const datetime ldn = LFix_ServerToLondon(now);

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
   // 2) Is it the entry moment? Once per London day.
   // ----------------------------------------------------------------
   const int ymd     = TFix_Ymd(ldn);
   const int minutes = TFix_MinutesOfDay(ldn);
   const int entryAt = InpFixHour * 60 + InpFixMinute + InpEntryDelayMin;
   if(minutes < entryAt || minutes >= entryAt + InpEntryWindowMin) return;
   if(ymd == g_lastLdnYmdTried) return;

   string why;
   if(!TFix_DayAllowed(ldn, InpDayFilter, false, why))
   {
      g_lastLdnYmdTried = ymd;      // decided for today
      g_diag.block_nosignal++;
      return;
   }

   // ----------------------------------------------------------------
   // 3) The pre-fix move: open of the M5 bar InpPreWindowMin before the
   //    fix (server time) to the current bid.
   // ----------------------------------------------------------------
   const datetime fixServer = now - (datetime)((minutes - (InpFixHour * 60 + InpFixMinute)) * 60);
   const datetime preServer = fixServer - (datetime)(InpPreWindowMin * 60);
   const int shift = iBarShift(sym, PERIOD_M5, preServer, false);
   const double preOpen = (shift >= 0) ? iOpen(sym, PERIOD_M5, shift) : 0.0;
   const double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   const double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(preOpen <= 0.0 || bid <= 0.0 || pt <= 0.0) { g_diag.block_indfail++; return; }
   const double preMovePips = (bid - preOpen) / (pt * PipPoints(sym));

   const int side = LFix_Side(InpSideMode, InpSide, preMovePips, InpMinPreMovePips);
   if(side == 0)
   {
      g_lastLdnYmdTried = ymd;
      g_diag.block_nosignal++;
      Print("LONDONFIX_SKIP ", sym, " ", why, " pre-move ", DoubleToString(preMovePips, 1), " pips < ", InpMinPreMovePips);
      return;
   }

   // ----------------------------------------------------------------
   // 4) Flat-state gates (shared). Spread/cooldown wait for the next tick
   //    inside the window; the hard limits consume the day.
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
         case GATE_BLOCK_MAXDAY:    g_diag.block_maxday++;    g_lastLdnYmdTried = ymd; break;
         case GATE_BLOCK_LOSS:      g_diag.block_loss++;      g_lastLdnYmdTried = ymd; break;
         case GATE_BLOCK_MAXTRADES: g_diag.block_maxtrades++; g_lastLdnYmdTried = ymd; break;
         default: break;
      }
      return;
   }

   // ----------------------------------------------------------------
   // 5) One attempt. Success or a rejected send both consume the day.
   // ----------------------------------------------------------------
   const bool   isBuy = (side > 0);
   const double slPts = (InpStopPips > 0.0) ? InpStopPips * PipPoints(sym) : 0.0;
   // ----------------------------------------------------------------
   // 5b) Portfolio cap (account-level; KurosawaPortfolio.mqh). Refuses the
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
         g_lastLdnYmdTried = ymd; return;
      }
   }

   g_lastLdnYmdTried = ymd;
   g_diag.signals++;
   Print("LONDONFIX_ENTRY ", (isBuy ? "BUY" : "SELL"), " ", sym, " ", why, " london=", TimeToString(ldn, TIME_DATE | TIME_MINUTES),
         " pre-move ", DoubleToString(preMovePips, 1), " pips over ", InpPreWindowMin, "min, exit in ", InpHoldMinutes, "min slPts=", DoubleToString(slPts, 0));
   if(PlaceTrade(sym, isBuy, slPts))
      g_exitAtServer = now + (datetime)(InpHoldMinutes * 60);
}

//+------------------------------------------------------------------+
void OnTimer()
{
   OnTick();
}
//+------------------------------------------------------------------+
