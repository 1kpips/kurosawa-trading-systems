//+--------------------------------------------------------------------+
//| File: KurosawaHelpers.mqh                                          |
//| Type: Include Library                                              |
//| Ver : 0.2.0                                                        |
//|                                                                    |
//| Description                                                        |
//| Umbrella include for the Kurosawa EA shared libraries.             |
//|                                                                    |
//| Purpose                                                            |
//| - Keep EA source files clean: include ONE header                   |
//| - Internals remain modular (time/trade/signal/position/risk)       |
//|                                                                    |
//| Modules                                                            |
//| - KurosawaTime.mqh                                                 |
//| - KurosawaTradeUtils.mqh                                           |
//| - KurosawaSignalUtils.mqh                                          |
//| - KurosawaPositionUtils.mqh                                        |
//| - KurosawaRiskManager.mqh                                          |
//|                                                                    |
//| Notes                                                              |
//| - This file contains no logic, only #include directives            |
//| - Public repo safe: no endpoints, no secrets                       |
//+--------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_HELPERS_UMBRELLA_MQH
#define KUROSAWA_HELPERS_UMBRELLA_MQH

// For tracking
#include "KurosawaTrack.mqh"

// Time + session utilities (Tokyo/London/New York DST policy included)
#include "KurosawaTime.mqh"

// Broker-safe utilities: spread, stops, volume, pips/price conversion
#include "KurosawaTradeUtils.mqh"

// Closed-bar + CopyBuffer helpers, plus simple regime helpers
#include "KurosawaSignalUtils.mqh"

// Position scan helpers by symbol + magic
#include "KurosawaPositionUtils.mqh"

// Centralized risk guards: daily baseline, daily loss, cooldown, loss-streak gates
#include "KurosawaRiskManager.mqh"

// ------------------------------------------------------------
// Chart UI: EA identity label (Comment-based)
// ------------------------------------------------------------
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
//+--------------------------------------------------------------------+
