//+------------------------------------------------------------------+
//| File: Engines/TrendEA.mq5                                        |
//| Type: Engine (MT5 events + execution)                            |
//| Ver : 0.5.1                                                      |
//|                                                                  |
//| Trend EA                                                         |
//|                                                                  |
//| Contract                                                         |
//| - This .mq5 contains ONLY MT5 event handlers + PlaceTrade()      |
//| - All utilities come from KurosawaHelpers.mqh                    |
//| - Strategy logic lives in Strategies/Trend.mqh                   |
//| - All distances are POINTS (not pips)                            |
//|                                                                  |
//| Why this file exists                                             |
//| - GitHub users: this is the "orchestrator" only.                 |
//|   It wires together:                                             |
//|     (1) Session/risk/spread/cooldown gates                       |
//|     (2) Strategy signal evaluation (closed-bar, shift=1)         |
//|     (3) Execution (position sizing + SL/TP + order send)         |
//|     (4) Position management (time-stop / trailing)               |
//|                                                                  |
//| Design rules                                                     |
//| - Closed-bar signals: decide on bar close to reduce noise        |
//| - Strategy is pure: no order sending, only returns signals       |
//| - Engine owns safety: risk limits and execution protections      |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>

// Umbrella include (Risk/Time/Trade/Signal/Tracking helpers)
#include "../Helpers/KurosawaHelpers.mqh"

// Strategy module (signal generation only)
#include "../Strategies/Trend.mqh"

// Inputs (Excel-aligned schema for presets)
#include "../Inputs/Trend_Inputs.mqh"

// Trade executor (MT5 standard)
CTrade trade;

// ------------------------------------------------------------------
// Indicator handle pack for this engine (created in OnInit, released in OnDeinit)
// ------------------------------------------------------------------
TrendIndicatorPack g_ind;

// ------------------------------------------------------------------
// Runtime state
// ------------------------------------------------------------------

// Symbol this EA will trade (resolved once in OnInit and reused everywhere)
string g_symbol = "";

// Tracks the last processed CLOSED bar time (so we evaluate once per bar)
datetime g_lastClosedBarTime = 0;

// Daily risk state (trades today, daily P/L snapshot, cooldown tracking, etc.)
DailyRiskState g_risk;

// Loss streak tracking comes from trade transaction handler
int      g_consecLosses  = 0;
datetime g_lastCloseTime = 0;

// Tracking: last deal IDs to avoid duplicate processing
ulong g_lastOpenDealId  = 0;
ulong g_lastCloseDealId = 0;

// Diagnostics counters (why trades were blocked, how many bars/signals/trades)
DailyDiag g_diag;

//+------------------------------------------------------------------+
//| PlaceTrade                                                       |
//|                                                                  |
//| What it does                                                     |
//| - Converts a signal (BUY/SELL + SL/TP in POINTS) into an order.  |
//| - Calculates trade volume (risk-based sizing or fixed-lot).      |
//| - Builds price-based SL/TP from point distances.                 |
//| - Validates broker stop constraints (stops level / freeze level).|
//| - Sends a market order with a readable comment for logs.         |
//|                                                                  |
//| Inputs                                                           |
//| - sym   : traded symbol                                          |
//| - isBuy : true=BUY, false=SELL                                   |
//| - slPts : stop distance in POINTS                                |
//| - tpPts : take profit distance in POINTS                         |
//+------------------------------------------------------------------+
bool PlaceTrade(const string sym, const bool isBuy, const double slPts, const double tpPts)
{
   // Defensive: strategy or math must never send non-positive distances
   if(slPts <= 0.0 || tpPts <= 0.0)
      return false;

   // 1) Position sizing
   // Risk_CalcTradeVolume handles:
   // - Risk % sizing when enabled
   // - Fixed lot fallback
   // - Max lot cap enforcement
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
      // Treat as order fail because it blocks execution (e.g., tiny balance, invalid settings)
      g_diag.block_orderfail++;
      return false;
   }

   // 2) Get current prices for entry calculation
   const double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
   {
      g_diag.block_indfail++;
      return false;
   }

   const double entry = isBuy ? ask : bid;

   // 3) Convert points -> price
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

   // 4) Validate SL/TP vs broker constraints (stops level/freeze level)
   // EnsureStopsLevel may adjust SL/TP slightly if needed; returns false if impossible.
   if(!EnsureStopsLevel(sym, entry, sl, tp, isBuy, true))
   {
      g_diag.block_stops++;
      return false;
   }

   // 5) Configure executor (magic + slippage/deviation)
   trade.SetExpertMagicNumber((int)InpMagic);
   trade.SetDeviationInPoints((int)InpDeviationPoints);

   // 6) Send order with a readable comment to help users debug
   const string base = InpEaName + "|" + InpEaVersion;
   bool ok = false;

   if(isBuy) ok = trade.Buy(vol, sym, 0.0, sl, tp, base + "|BUY");
   else      ok = trade.Sell(vol, sym, 0.0, sl, tp, base + "|SELL");

   // 7) Post-send bookkeeping
   if(ok)
   {
      // Update daily risk state (cooldown + trades_today)
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
//| OnInit                                                           |
//|                                                                  |
//| What happens here                                                |
//| - Resolve the traded symbol once (InpTargetPair or chart symbol) |
//| - Create indicator handles for that symbol/timeframe             |
//| - Initialize risk state and bar-tracking state                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Resolve once and cache. This is the EA's immutable execution context.
   g_symbol = ResolveEngineSymbol(InpTargetPair, _Symbol);

   // Visual label on chart (helps users identify EA + magic + version)
   ShowEaLabel(InpEaName, InpEaId, (int)InpMagic, _Symbol, (ENUM_TIMEFRAMES)_Period);

   // Friendly warnings (preset expects a target, but user attached elsewhere)
   if(StringLen(InpTargetPair) > 0 && _Symbol != InpTargetPair)
      Print("Warning: Intended symbol=", InpTargetPair, ", attached chart symbol=", _Symbol);

   if(_Period != InpTargetTf)
      Print("Warning: Intended TF=", EnumToString(InpTargetTf), ", current chart TF=", EnumToString(_Period));

   // Create and validate indicator handles (retry + history preload inside helper)
   TrendIndicators_Reset(g_ind);

   if(!TrendIndicators_CreateWithRetry(
         g_symbol, InpTargetTf,
         InpEmaFast, InpEmaSlow,
         InpRsiPeriod, InpAtrPeriod,
         InpUseAdxFilter, InpAdxPeriod,
         g_ind))
   {
      Print("INIT_FAILED: indicator handles not ready. sym=", g_symbol, " tf=", EnumToString(InpTargetTf));
      return INIT_FAILED;
   }

   // Initialize daily risk state (resets internal counters / daily snapshot)
   Risk_Init(g_risk, TimeCurrent());

   // Set last closed bar time so we do not "burst" trade on start
   g_lastClosedBarTime = (datetime)iTime(g_symbol, InpTargetTf, 1);
   if(g_lastClosedBarTime <= 0)
      g_lastClosedBarTime = TimeCurrent();

   // Configure CTrade once
   trade.SetExpertMagicNumber((int)InpMagic);
   trade.SetDeviationInPoints((int)InpDeviationPoints);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//|                                                                  |
//| What happens here                                                |
//| - Print daily diagnostics snapshot (even if day is incomplete)   |
//| - Release indicator handles                                      |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Print the current (partial) day snapshot before exit
   PrintDailySummary(InpEaName, g_symbol, InpTargetTf, g_diag);

   // Always release indicator handles
   TrendIndicators_Release(g_ind);
}

//+------------------------------------------------------------------+
//| OnTradeTransaction                                               |
//|                                                                  |
//| Why this matters                                                 |
//| - In MT5, the most reliable way to update streak/PnL-related     |
//|   state is from trade transactions (deals closing, etc.).        |
//| - We centralize streak updates here so the logic is consistent   |
//|   across all engines.                                            |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| OnTick                                                           |
//|                                                                  |
//| Engine flow (high level)                                         |
//| 1) Daily roll/reset bookkeeping                                  |
//| 2) If position exists: manage it (time-stop / trailing)          |
//| 3) If flat: apply safety gates (session/spread/cooldown/loss)    |
//| 4) Once per closed bar: evaluate strategy                        |
//| 5) If signal: compute SL/TP distances and place trade            |
//+------------------------------------------------------------------+
void OnTick()
{
   const string   sym = g_symbol;
   const datetime now = TimeCurrent();

   // A) Daily reporting roll (prints prior day summary once per day)
   DailyRollIfNeeded(InpEaName, sym, InpTargetTf, g_diag, NowYmdJst());

   // B) Risk reset (optionally resets streak on a new day)
   DailyResetIfNewDay(g_risk, now, g_consecLosses, InpResetConsecLossDaily);

   // ----------------------------------------------------------------
   // 1) If we already have a position, do position management only.
   //    This EA is designed for "one position per magic per symbol".
   // ----------------------------------------------------------------
   if(PositionExists(sym, (int)InpMagic))
   {
      // Time-stop: close if held too long
      if(InpMaxHoldMinutes > 0)
      {
         const bool closed = Position_CheckMaxHoldExit(
            trade, sym, (long)InpMagic, InpMaxHoldMinutes, now
         );

         if(closed)
            return; // position is gone, do not open a new trade on same tick
      }

      // Trailing: ATR-step trailing after profit reaches TrailStartR
      if(InpUseTrailing)
      {
         Position_ManageAtrTrailing(
            trade,
            sym,
            (long)InpMagic,
            g_ind.hATR,
            InpTrailStartR,
            InpTrailStepAtrMult,
            g_diag.block_indfail,
            g_diag.block_stops,
            g_diag.block_orderfail
         );
      }

      return;
   }

   // ----------------------------------------------------------------
   // 2) Safety gates (only when flat)
   //    These prevent trading during bad conditions.
   // ----------------------------------------------------------------

   // Session window gate
   if(!IsTimeWindowByOffsetHours(InpStartHour, InpEndHour, InpUtcOffset))
   {
      g_diag.block_session++;
      return;
   }

   // Spread gate (avoid wide spread conditions)
   if(!SpreadOK(sym, InpMaxSpreadPoints))
   {
      g_diag.block_spread++;
      return;
   }

   // Cooldown gate (avoid rapid-fire re-entry)
   if(!CooldownOK(g_risk, InpCooldownMinutes, now))
   {
      g_diag.block_cooldown++;
      return;
   }

   // Daily loss limit gate (capital protection)
   if(!DailyLossLimitOK(g_risk, InpDailyLossLimitPercent))
   {
      g_diag.block_maxday++;
      return;
   }

   // Loss streak gate (avoid continuing in a bad regime)
   if(!LossStreakOK(g_consecLosses, InpMaxConsecLosses))
   {
      g_diag.block_loss++;
      return;
   }

   // Max trades per day gate
   if(InpMaxTradesPerDay > 0 && g_risk.trades_today >= InpMaxTradesPerDay)
   {
      g_diag.block_maxtrades++;
      return;
   }

   // ----------------------------------------------------------------
   // 3) Only run strategy once per NEW CLOSED bar.
   //    This avoids noisy intrabar signals and makes backtests stable.
   // ----------------------------------------------------------------
   if(!IsNewClosedBar(sym, InpTargetTf, g_lastClosedBarTime))
      return;

   Track_OnNewBar(InpTrackEnable, (int)InpMagic, sym, InpTargetTf);
   g_diag.bars++;

   // ----------------------------------------------------------------
   // 4) Build strategy inputs from EA inputs.
   //    Strategy stays pure: it only consumes handles + inputs.
   // ----------------------------------------------------------------
   TrendInputs inps;
   inps.rsi_buy_below     = InpRsiBuyBelow;
   inps.rsi_sell_above    = InpRsiSellAbove;

   inps.atr_min_points    = InpAtrMinPoints;
   inps.atr_max_points    = InpAtrMaxPoints;

   inps.use_adx_filter    = InpUseAdxFilter;
   inps.adx_min_to_trade  = InpMinAdxToTrade;
   inps.adx_max_to_trade  = InpMaxAdxToTrade;

   inps.require_ema_slope = InpRequireEmaSlope;

   TrendSignal sig;

   // Important: use the traded symbol point size, not _Point (chart symbol may differ)
   const double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(pt <= 0.0)
   {
      g_diag.block_indfail++;
      return;
   }

   // Evaluate signal using indicator handles on CLOSED bar (shift=1)
   const TrendResult sres = Trend_EvaluateHandles(
      g_ind.hEmaFast,
      g_ind.hEmaSlow,
      g_ind.hRSI,
      g_ind.hATR,
      g_ind.hADX,
      1,   // shift=1 -> last closed bar
      pt,  // point size for the traded symbol
      inps,
      sig
   );

   // Strategy can return “blocked by filters” vs “no signal” vs “indicator error”
   if(sres != TREND_OK)
   {
      if(sres == TREND_BLOCK_ATR)             g_diag.block_atr++;
      else if(sres == TREND_BLOCK_ADX)        g_diag.block_adx++;
      else if(sres == TREND_BLOCK_NO_SIGNAL)  g_diag.block_nosignal++;
      else                                    g_diag.block_indfail++;
      return;
   }

   // Defensive: should never be both true or both false at TREND_OK
   if(sig.buy == sig.sell)
   {
      g_diag.block_ambig++;
      return;
   }

   g_diag.signals++;

   // ----------------------------------------------------------------
   // 5) Convert ATR signal into SL/TP distances in POINTS.
   //    We keep SL/TP distance logic in engine because it is execution policy.
   // ----------------------------------------------------------------
   const double slPts = sig.atr_points * InpSlAtrMult;
   const double tpPts = slPts * InpTpRMultiple;

   if(slPts <= 0.0 || tpPts <= 0.0)
   {
      g_diag.block_stops++;
      return;
   }

   // ----------------------------------------------------------------
   // 6) Execute
   // ----------------------------------------------------------------
   if(sig.buy)  PlaceTrade(sym, true,  slPts, tpPts);
   else         PlaceTrade(sym, false, slPts, tpPts);
}
