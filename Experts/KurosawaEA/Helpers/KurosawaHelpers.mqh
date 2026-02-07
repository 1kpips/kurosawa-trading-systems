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
