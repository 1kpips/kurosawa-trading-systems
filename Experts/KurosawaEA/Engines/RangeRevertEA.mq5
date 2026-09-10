//+------------------------------------------------------------------+
//| File: Engines/RangeRevertEA.mq5                                  |
//| Type: Engine (MT5 events + execution)                            |
//| Ver : 0.6.0                                                      |
//|                                                                  |
//| RangeRevert EA                                                   |
//|                                                                  |
//| Contract                                                         |
//| - This .mq5 contains ONLY MT5 event handlers + PlaceTrade()      |
//| - All utilities come from KurosawaHelpers.mqh                    |
//| - Strategy logic lives in Strategies/RangeRevert.mqh             |
//| - All distances are POINTS (not pips)                            |
//|                                                                  |
//| Why this file exists                                             |
//| - GitHub users: this is the "orchestrator" only. It wires:       |
//|     (1) Session/risk/spread/cooldown gates (Gates_CheckFlat)     |
//|     (2) Strategy signal evaluation (closed-bar, shift=1)         |
//|     (3) Execution via the shared Exec_PlaceTrade()               |
//|     (4) Position management (mid-band exit / time-stop)          |
//|                                                                  |
//| Design rules                                                     |
//| - Closed-bar signals: decide on bar close to reduce noise        |
//| - Strategy is pure: no order sending, only returns signals       |
//| - Engine owns safety: risk limits and execution protections      |
//| - One position per (symbol, magic)                               |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>

// Umbrella include (time/risk/execution helpers + shared executor/gate)
#include "../Helpers/KurosawaHelpers.mqh"

// Strategy module (signal generation only)
#include "../Strategies/RangeRevert.mqh"
#include "../Strategies/D1Reading.mqh"

// Inputs (Excel-aligned schema for presets)
#include "../Inputs/RangeRevert_Inputs.mqh"

// Trade executor (MT5 standard)
CTrade trade;

// ------------------------------------------------------------------
// Indicator handles (created in OnInit, released in OnDeinit)
// ------------------------------------------------------------------
int hAdx = INVALID_HANDLE;
D1Handles hD1;                 // D1 reading gate (0.6.0); unused when InpD1GateMode == 0
KillState g_kill;              // rolling-PF kill switch (0.7.0); inert when InpKillRollingTrades == 0
int hAtr = INVALID_HANDLE;
int hRsi = INVALID_HANDLE;
int hBb  = INVALID_HANDLE;

// ------------------------------------------------------------------
// Runtime state
// ------------------------------------------------------------------
string   g_symbol           = "";
datetime g_lastClosedBarTime = 0;
DailyRiskState g_risk;

int      g_consecLosses  = 0;

ulong    g_lastOpenDealId  = 0;
ulong    g_lastCloseDealId = 0;
datetime g_lastCloseTime   = 0;

DailyDiag g_diag;

//+------------------------------------------------------------------+
//| PlaceTrade                                                       |
//|                                                                  |
//| Thin wrapper over the shared executor (Helpers/KurosawaExecutor).|
//| RangeRevert uses requireTp=false: it sets a fixed ATR-based TP    |
//| but does NOT reject the entry if that TP is too close to satisfy  |
//| broker min-distance, because the mid-band exit + time-stop act as |
//| the real exits.                                                  |
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
   cfg.requireTp       = false;  // mean-reversion: mid-band/time-stop are the real exits
   cfg.maxSendRetries  = 2;

   return Exec_PlaceTrade(
      trade, sym, isBuy, slPts, tpPts, cfg, g_risk,
      g_diag.trades, g_diag.block_orderfail, g_diag.block_indfail, g_diag.block_stops
   );
}

//+------------------------------------------------------------------+
//| MT5 Events                                                       |
//+------------------------------------------------------------------+
int OnInit()
{
   // Resolve once and cache. This is the EA's immutable execution context.
   g_symbol = ResolveEngineSymbol(InpTargetPair, _Symbol);

   ShowEaLabel(InpEaName, InpEaId, (int)InpMagic, _Symbol, (ENUM_TIMEFRAMES)_Period);

   // Refuse to run on a chart that does not match the preset target. Without
   // this the EA silently trades InpTargetPair while displaying a different
   // instrument, and the mismatch was only a warning that scrolled past.
   // INIT_PARAMETERS_INCORRECT, not INIT_FAILED: a chart mismatch is a wrong-input
   // condition, so MT5 keeps the EA on the chart and re-opens the properties
   // dialog. INIT_FAILED detaches the EA outright, which leaves nothing to press
   // F7 on and forces a full re-attach just to correct a single field.
   if(!ChartMatchesTarget(InpTargetPair, InpTargetTf, InpStrictChartMatch))
      return INIT_PARAMETERS_INCORRECT;

   // History readiness gate (prevents empty buffers on startup)
   const int reqBars = RR_RequiredBarsForInit(
      InpBbPeriod, InpAtrPeriod, InpRsiPeriod,
      InpUseAdxFilter, InpMaxAdxToTrade, InpAdxPeriod
   );

   if(!RR_EnsureHistoryReady(g_symbol, InpTargetTf, reqBars))
   {
      Print("INIT_FAILED: not enough history. bars=", Bars(g_symbol, InpTargetTf),
            " required=", reqBars, " tf=", EnumToString(InpTargetTf), " sym=", g_symbol);
      return INIT_FAILED;
   }

   // Indicator handles on target timeframe
   hAtr = iATR(g_symbol, InpTargetTf, InpAtrPeriod);
   hRsi = iRSI(g_symbol, InpTargetTf, InpRsiPeriod, PRICE_CLOSE);
   hBb  = iBands(g_symbol, InpTargetTf, InpBbPeriod, 0, InpBbDev, PRICE_CLOSE);

   const bool needAdx = (InpUseAdxFilter && InpMaxAdxToTrade > 0.0);
   hAdx = needAdx ? iADX(g_symbol, InpTargetTf, InpAdxPeriod) : INVALID_HANDLE;

   if(hAtr == INVALID_HANDLE || hRsi == INVALID_HANDLE || hBb == INVALID_HANDLE
      || (needAdx && hAdx == INVALID_HANDLE))
   {
      Print("INIT_FAILED: indicator handle creation failed.",
            " hAtr=", hAtr, " hRsi=", hRsi, " hBb=", hBb, " hAdx=", hAdx,
            " tf=", EnumToString(InpTargetTf), " sym=", g_symbol);
      return INIT_FAILED;
   }

   // D1 reading gate handles (only when the gate is on; the proven presets run with it off)
   D1Handles_Reset(hD1);
   if(InpD1GateMode != 0)
   {
      if(InpD1GateMode < 0 || InpD1GateMode > 6 || InpD1Rule < 0 || InpD1Rule > 1)
      {
         Print("INIT_PARAMETERS_INCORRECT: InpD1GateMode must be 0-6 and InpD1Rule 0-1 (got ", InpD1GateMode, "/", InpD1Rule, ")");
         return INIT_PARAMETERS_INCORRECT;
      }
      EnsureHistory(g_symbol, PERIOD_D1, 120);
      if(!D1Handles_Create(g_symbol, (D1Rule)InpD1Rule, hD1))
      {
         Print("INIT_FAILED: D1 reading handles not ready. sym=", g_symbol);
         return INIT_FAILED;
      }
   }

   Kill_Reset(g_kill);

   Risk_Init(g_risk, TradingDayNow());   // seed risk day on the unified UTC trading-day clock

   // Set last closed bar time so we do not "burst" trade on start
   g_lastClosedBarTime = (datetime)iTime(g_symbol, InpTargetTf, 1);
   if(g_lastClosedBarTime <= 0)
      g_lastClosedBarTime = TimeCurrent();

   trade.SetExpertMagicNumber((int)InpMagic);
   trade.SetDeviationInPoints((int)InpDeviationPoints);

   // Heartbeat: drive OnTick from a timer too, so position management does not
   // depend on this chart's tick flow (see KurosawaHelpers.mqh).
   EventSetTimer(KUROSAWA_ENGINE_TIMER_SEC);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();

   PrintDailySummary(InpEaName, g_symbol, InpTargetTf, g_diag);

   D1Handles_Release(hD1);
   if(hAdx != INVALID_HANDLE) IndicatorRelease(hAdx);
   if(hAtr != INVALID_HANDLE) IndicatorRelease(hAtr);
   if(hRsi != INVALID_HANDLE) IndicatorRelease(hRsi);
   if(hBb  != INVALID_HANDLE) IndicatorRelease(hBb);

   hAdx = INVALID_HANDLE;
   hAtr = INVALID_HANDLE;
   hRsi = INVALID_HANDLE;
   hBb  = INVALID_HANDLE;
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
      InpPresetVersion,

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

   // A) Daily reporting roll (prints prior day summary once per day)
   DailyRollIfNeeded(InpEaName, sym, InpTargetTf, g_diag, TradingDayYmd());

   // B) Risk reset (optionally resets streak on a new day)
   DailyResetIfNewDay(g_risk, TradingDayNow(), g_consecLosses, InpResetConsecLossDaily);

   // ----------------------------------------------------------------
   // 1) If we already have a position, do position management only.
   // ----------------------------------------------------------------
   if(PositionExists(sym, (long)InpMagic))
   {
      g_diag.block_haspos++;

      // Sample MFE/MAE for the open position. Self-gates on a new bar, so it is
      // safe to call every tick. This must live HERE: Track_OnNewBar returns
      // immediately when no position exists, and the old call site sat below
      // the flat-state gates, so it only ever ran while FLAT - dead code, which
      // is why every closed-trade row had mfe/mae/bars_held at zero.
      Track_OnNewBar(InpTrackEnable, (int)InpMagic, sym, InpTargetTf);

      // Select once so we can read type safely.
      if(!PositionSelectByMagic(sym, (long)InpMagic))
         return;

      const long posType = (long)PositionGetInteger(POSITION_TYPE);
      const bool isBuy    = (posType == POSITION_TYPE_BUY);

      // Mid-band exit (optional) — closes by ticket (hedging-safe)
      if(RR_CheckMidBandExitAndClose(trade, sym, (long)InpMagic, hBb, InpUseMidBandExit, isBuy))
         return;

      // Time-stop close (optional)
      if(RR_CheckMaxHoldAndClose(trade, sym, (long)InpMagic, InpMaxHoldMinutes, now))
         return;

      return;
   }

   // ----------------------------------------------------------------
   // 1b) Kill switch (0.7.0): is the edge still there? Rolling PF of this
   //     instance's last N closed trades. Pauses new entries, never exits.
   //     Counted under 'loss' in the daily summary.
   // ----------------------------------------------------------------
   if(!Kill_EntriesAllowed(g_kill, sym, (long)InpMagic,
                           InpKillRollingTrades, InpKillMinPf, InpKillPauseDays, InpKillProbationTrades,
                           g_lastCloseDealId, now, InpEaName))
   {
      g_diag.block_loss++;
      return;
   }

   // ----------------------------------------------------------------
   // 2) Safety gates (only when flat) — shared logic in Gates_CheckFlat.
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

   // Avoid early CopyBuffer failures (RangeRevert-specific readiness check)
   if(!RR_EnsureIndicatorsCalculated(hAtr, hRsi, hBb, hAdx))
   {
      g_diag.block_indfail++;
      return;
   }

   // ----------------------------------------------------------------
   // 3) Only run strategy once per NEW CLOSED bar (shift=1).
   // ----------------------------------------------------------------
   if(!IsNewClosedBar(sym, InpTargetTf, g_lastClosedBarTime))
      return;

   g_diag.bars++;

   // ----------------------------------------------------------------
   // 4) Build strategy inputs from EA inputs (pure strategy call)
   // ----------------------------------------------------------------
   RangeRevertInputs sin;
   sin.bb_period            = InpBbPeriod;
   sin.bb_dev               = InpBbDev;

   sin.rsi_period           = InpRsiPeriod;
   sin.rsi_buy_below        = InpRsiBuyBelow;
   sin.rsi_sell_above       = InpRsiSellAbove;

   sin.use_adx_filter       = InpUseAdxFilter;
   sin.adx_period           = InpAdxPeriod;
   sin.adx_max_to_trade     = InpMaxAdxToTrade;

   sin.atr_period           = InpAtrPeriod;
   sin.atr_min_points       = InpAtrMinPoints;
   sin.atr_max_points       = InpAtrMaxPoints;

   sin.require_reclaim      = InpRequireReclaim;
   sin.min_band_break_points = InpMinBandBreakPoints;
   sin.min_edge_over_spread = InpMinEdgeOverSpread;

   RangeRevertSignal ss;

   // Use traded symbol point size, not _Point
   const double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(pt <= 0.0)
   {
      g_diag.block_indfail++;
      return;
   }

   // Broker-reported spread in POINTS (reliable in tester + live, unlike
   // ask/bid which can read 0 in the Strategy Tester). Passed into the
   // strategy so signal evaluation stays deterministic and free of live reads.
   const double spreadPts = (double)SymbolInfoInteger(sym, SYMBOL_SPREAD);

   const RangeRevertResult res = RangeRevert_EvaluateHandles(
      hAtr, hRsi, hBb, hAdx,
      sym, InpTargetTf, 1, pt, spreadPts,
      sin, ss
   );

   if(res != RANGEREVERT_OK)
   {
      if(res == RANGEREVERT_ERROR_DATA)        g_diag.block_indfail++;
      else if(res == RANGEREVERT_BLOCK_ATR)    g_diag.block_atr++;
      else if(res == RANGEREVERT_BLOCK_ADX)    g_diag.block_adx++;
      else if(res == RANGEREVERT_BLOCK_AMBIG)  g_diag.block_ambig++;
      else                                     g_diag.block_nosignal++;
      return;
   }

   // Defensive: should never be both true at OK
   if(ss.buy && ss.sell)
   {
      g_diag.block_ambig++;
      return;
   }

   // Direction switches (0.6.0). Counted under 'wick' in the daily summary,
   // the one counter nothing else in this engine uses.
   if((ss.buy && !InpAllowLongs) || (ss.sell && !InpAllowShorts))
   {
      g_diag.block_wick++;
      return;
   }

   // D1 reading gate (0.6.0): a side may trade only AGAINST an extended daily
   // reading. Counted under 'nobias' in the daily summary.
   if(InpD1GateMode != 0)
   {
      string d1dir; int d1str; string why;
      if(!D1_Read(g_symbol, (D1Rule)InpD1Rule, hD1, 1, d1dir, d1str))
      {
         g_diag.block_indfail++;
         return;
      }
      if(!D1_SideAllowed(ss.buy, (D1GateMode)InpD1GateMode, InpD1MinStrength, d1dir, d1str, why))
      {
         g_diag.block_nobias++;
         return;
      }
   }

   g_diag.signals++;

   // ----------------------------------------------------------------
   // 5) Execution policy: build SL/TP from ATR points (POINTS)
   // ----------------------------------------------------------------
   const double atrPts = ss.atr_points;
   if(!MathIsValidNumber(atrPts) || atrPts <= 0.0)
   {
      g_diag.block_indfail++;
      return;
   }

   const double slPts = atrPts * InpSlAtrMult;
   const double tpPts = slPts  * InpTpRMultiple;

   if(slPts <= 0.0 || tpPts <= 0.0)
   {
      g_diag.block_stops++;
      return;
   }

   // ----------------------------------------------------------------
   // 6) Execute
   // ----------------------------------------------------------------
   if(ss.buy)       PlaceTrade(sym, true,  slPts, tpPts);
   else if(ss.sell) PlaceTrade(sym, false, slPts, tpPts);
}

//+------------------------------------------------------------------+
//| OnTimer                                                          |
//|                                                                  |
//| Same body as OnTick. MT5 serializes EA events on one thread, so  |
//| this cannot run concurrently with OnTick, and the once-per-closed |
//| -bar guard keeps entries from firing twice.                      |
//+------------------------------------------------------------------+
void OnTimer()
{
   OnTick();
}
//+------------------------------------------------------------------+
