//+------------------------------------------------------------------+
//| File: Helpers/KurosawaHelpers.mqh                                |
//| Type: Umbrella Include Library                                   |
//| Ver : 0.3.0                                                      |
//|                                                                  |
//| Description                                                      |
//| Single include entry-point for the Kurosawa EA shared libraries. |
//|                                                                  |
//| Why this file exists                                             |
//| - Engines should include ONE helper header only (this file).     |
//| - Helper modules remain modular internally (time/trade/signal..).|
//| - Include order is controlled here to keep compilation stable.   |
//|                                                                  |
//| How to use                                                       |
//| - Engine (.mq5) typically includes:                              |
//|     #include "../Helpers/KurosawaHelpers.mqh"                    |
//| - Do not include sub-helpers directly from engines unless you    |
//|   have a specific reason.                                        |
//|                                                                  |
//| Public repo safety                                               |
//| - No endpoints, no secrets, no WebRequest keys in this file.     |
//| - Tracking logic (if any) must remain optional and safe.         |
//|                                                                  |
//| Notes                                                            |
//| - This file should stay small: mostly #include directives.       |
//| - Keep any utility functions here truly "umbrella-level"         |
//|   (used by many engines, not strategy-specific).                 |
//+------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_HELPERS_UMBRELLA_MQH
#define KUROSAWA_HELPERS_UMBRELLA_MQH

// ------------------------------------------------------------------
// Include order matters
// - Lower-level utilities first
// - Higher-level modules later
// ------------------------------------------------------------------

// ------------------------------------------------------------
// Kurosawa helper modules (grouped by responsibility)
//
// Rule for this suite
// - Each helper file must be compile-able on its own.
// - No helper file should rely on symbols from another helper file.
// - If multiple helpers must cooperate (e.g., CopyBuffer + stops validation),
//   group them into the same file instead of cross-including.
// ------------------------------------------------------------

// 1) Time + session utilities (UTC offset clock, session windows)
#include "KurosawaTime.mqh"

// 2) Execution utilities bundle (self-contained)
//    - CopyBuffer wrapper (GetIndicatorValue)
//    - New closed bar detection (IsNewClosedBar)
//    - Spread helpers (SpreadOK)
//    - Stops/freeze validation (EnsureStopsLevel)
//    - Position scan + time-stop + ATR trailing (Position*)
//    - ResolveEngineSymbol + misc execution primitives
#include "KurosawaExecUtils.mqh"

// 3) Risk guards (self-contained)
//    - Daily baseline, daily loss limit, cooldown, loss-streak
//    - (Optionally) risk-based sizing if you keep it here
#include "KurosawaRiskManager.mqh"

// 4) Tracking (self-contained; optional)
#include "KurosawaTrack.mqh"

// 5) Indicator handle factory / packs (self-contained; optional)
#include "KurosawaIndicatorFactory.mqh"

// 6) Shared order executor + safety gate (composes Time + Exec + Risk)
//    - Exec_PlaceTrade(): one order path for all engines (sizing, SL/TP,
//      broker stops, filling mode, transient send-retry).
//    - Gates_CheckFlat(): one flat-state safety-gate check for all engines.
#include "KurosawaExecutor.mqh"

// ------------------------------------------------------------------
// Magic number registry
// ------------------------------------------------------------------
// A magic identifies ONE RUNNING INSTANCE, not one strategy. Every engine
// finds, modifies and closes positions by (symbol, magic), so two EAs sharing a
// magic on the same symbol will manage each other's trades: one's exit closes
// the other's entry. This is silent - nothing errors, the trades just behave
// inexplicably.
//
// Assigned 2026-09-03. Format yyyymmdd + a 2-digit slot.
//
//   2026090301   TrendEA           EURUSD M15
//   2026090302   RangeRevertEA     USDJPY M5
//   2026090303   TrendPullbackEA   EURUSD M5
//   2026090304   RangeRevertEA     EURUSD M1   (preset variant)
//
// Assigned 2026-09-04 (preset .set files only, no engine default):
//   2026090401   RangeRevertEA     EURUSD M15  (London_RangeRevert_EURUSD_M15.set)
//   2026090402   RangeRevertEA     any    M15  (RangeRevert_Multi_M15.set, screening)
//
// Assigned 2026-09-07, multi-pair screening sets (InpTargetPair empty):
//   2026090701   RangeRevertEA     any    M5   (RangeRevert_Multi_M5.set)
//   2026090702   TrendPullbackEA   any    M5   (TrendPullback_Multi_M5.set)
//   2026090703   TrendPullbackEA   any    M15  (TrendPullback_Multi_M15.set)
//   2026090704   TrendEA           any    M15  (Trend_Multi_M15.set)
//   2026090705   TrendEA           any    H1   (Trend_Multi_H1.set)
// Assigned 2026-09-09, per-pair RangeRevert presets (proven-track candidates):
//   2026090901   RangeRevertEA     GBPUSD M15  (London_RangeRevert_GBPUSD_M15.set)
//   2026090902   RangeRevertEA     USDJPY M15  (London_RangeRevert_USDJPY_M15.set)
//   2026090903   RangeRevertEA     EURJPY M15  (London_RangeRevert_EURJPY_M15.set)
//   2026090904   RangeRevertEA     GBPJPY M15  (London_RangeRevert_GBPJPY_M15.set)
// Assigned 2026-09-09, New York session instances (run beside the London ones):
//   2026090905   RangeRevertEA     EURUSD M15  (NewYork_RangeRevert_EURUSD_M15.set)
//   2026090906   RangeRevertEA     USDJPY M15  (NewYork_RangeRevert_USDJPY_M15.set)
//   2026090907   RangeRevertEA     EURJPY M15  (NewYork_RangeRevert_EURJPY_M15.set)
// Assigned 2026-09-09, Tokyo session instances (JPY pairs):
//   2026090908   RangeRevertEA     USDJPY M15  (Tokyo_RangeRevert_USDJPY_M15.set)
//   2026090909   RangeRevertEA     EURJPY M15  (Tokyo_RangeRevert_EURJPY_M15.set)
//   2026090910   RangeRevertEA     GBPJPY M15  (Tokyo_RangeRevert_GBPJPY_M15.set)
//   2026090911   RangeRevertEA     any    M30  (RangeRevert_Multi_M30.set, timeframe probe)
//
// Take a NEW slot for every additional chart, including a second instance of
// the same engine on a different pair. The retired 20260117xx / 20260210xx
// numbers collided three ways across the engine defaults, the tester .set files
// and the (non-compiling) presets - do not reuse them.
// ------------------------------------------------------------------

// ------------------------------------------------------------------
// Engine heartbeat
// ------------------------------------------------------------------
// Engines do their work in OnTick, but tick flow is not a dependable clock:
// - ResolveEngineSymbol() lets the traded symbol differ from the chart symbol,
//   in which case OnTick fires on the CHART's ticks, not the traded
//   instrument's - so the time-stop and the trailing stop would run on the
//   wrong feed.
// - A quiet market or a stalled chart subscription stops ticks altogether.
// Position management must not depend on either, so every engine also drives
// OnTick from a timer. The signal analyzers already do this; the engines, where
// a missed exit actually costs money, did not.
#define KUROSAWA_ENGINE_TIMER_SEC 5

// ------------------------------------------------------------------
// Chart UI: EA identity label
// ------------------------------------------------------------------
// Purpose
// - Lightweight on-chart label for humans.
// - Helps debugging: you can immediately confirm which preset/magic
//   is attached to a chart.
//
// Notes
// - Uses Comment() so it works in Strategy Tester and live charts.
// - Intentionally simple: no objects, no fonts, no graphical state.
// ------------------------------------------------------------------
void ShowEaLabel(
   const string eaName,
   const string eaId,
   const int    magic,
   const string symbol,
   const ENUM_TIMEFRAMES tf
)
{
   Comment(
      "EA: ", eaName, "\n",
      "ID: ", eaId, "\n",
      "Magic: ", magic, "\n",
      "Symbol: ", symbol, "\n",
      "TF: ", EnumToString(tf)
   );
}

#endif // KUROSAWA_HELPERS_UMBRELLA_MQH
//+------------------------------------------------------------------+
