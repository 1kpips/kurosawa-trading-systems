//+------------------------------------------------------------------+
//| File: Inputs/RangeRevert_Inputs.mqh                              |
//| Ver : 0.3.1                                                      |
//|                                                                  |
//| Purpose                                                          |
//| Centralized input parameters for a generic Range Reversion EA.   |
//| This file defines INPUTS ONLY (no logic, no state).              |
//|                                                                  |
//| Design notes                                                     |
//| - Strategy-agnostic naming where possible                        |
//| - Excel / .set compatibility preserved                           |
//| - Session, regime, entry, exit, and risk knobs exposed           |
//|                                                                  |
//| Strategy summary                                                 |
//| - Mean-reversion in quiet / range-bound regimes                  |
//| - Entry: BB edge touch + RSI extreme (closed bar)                |
//| - Exit: BB mid-band and/or time stop                             |
//| - Risk: ATR-based SL with R-multiple TP                          |
//+------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_RANGEREVERT_INPUTS_MQH
#define KUROSAWA_RANGEREVERT_INPUTS_MQH

//==================================================================
// Identity / Meta
//==================================================================
input string InpTradeSession      = "London";   // semantic label only
input string InpEaName            = "RangeRevert";
input int    InpMagic             = 2026011704;
input string InpEaId              = "ea-rangerevert-generic";
input string InpEaVersion         = "0.3.1";

//==================================================================
// Target (intent only, engine warns if mismatched)
//==================================================================
input string          InpTargetPair = "";
input ENUM_TIMEFRAMES InpTargetTf   = PERIOD_M5;

//==================================================================
// Tracking / Telemetry
//==================================================================
input bool   InpTrackEnable       = true;
input bool   InpTrackSendOpen     = true;

//==================================================================
// Session window (local time via UTC offset)
//==================================================================
input int    InpStartHour         = 16;
input int    InpEndHour           = 1;     // midnight crossing supported
input int    InpUtcOffset         = 9;

//==================================================================
// EMA placeholders (not used by RangeRevert)
//==================================================================
input int    InpEmaFast           = 0;
input int    InpEmaSlow           = 0;
input bool   InpUseDirFilter      = false;
input int    InpEmaDir            = 0;

//==================================================================
// Bollinger Bands (USED)
//==================================================================
input int    InpBbPeriod          = 20;
input double InpBbDev             = 2.0;

//==================================================================
// Min-move placeholders (not used here, schema-aligned)
//==================================================================
input bool   InpUseMinMoveFilter  = false;
input double InpMinMoveSpreadMult = 0.0;

//==================================================================
// RSI (USED)
// Buy when RSI <= BuyBelow
// Sell when RSI >= SellAbove
//==================================================================
input int    InpRsiPeriod         = 14;
input double InpRsiBuyBelow       = 35.0;
input double InpRsiSellAbove      = 65.0;

//==================================================================
// Wick / edge placeholders (not used)
//==================================================================
input bool   InpUseWickSignal     = false;
input double InpMinBandBreakPoints  = 0.0;
input double InpMinEdgeOverSpread = 0.0;

//==================================================================
// ADX regime filter (USED)
// Quiet market gate: ADX must be <= Max
//==================================================================
input bool   InpUseAdxFilter      = true;
input int    InpAdxPeriod         = 14;
input double InpMinAdxToTrade     = 0.0;   // unused, keep 0
input double InpMaxAdxToTrade     = 22.0;

//==================================================================
// ATR regime filter (USED)
// NOTE: Values are treated as POINTS by the engine.
// Naming kept for Excel compatibility.
//==================================================================
input int    InpAtrPeriod         = 14;
input double InpAtrMinPoints       = 1.8;
input double InpAtrMaxPoints        = 6.0;

//==================================================================
// Fixed SL / TP placeholders (not used)
//==================================================================
input double InpSlPips            = 0.0;
input double InpTpPips            = 0.0;

//==================================================================
// Risk sizing / volume
//==================================================================
input bool   InpUseRiskSizing     = true;
input double InpRiskPercent       = 0.30;
input double InpFixedLot          = 0.05;
input double InpMaxLotCap         = 0.0;

//==================================================================
// Frequency & safety guards
//==================================================================
input int    InpMaxTradesPerDay      = 0;
input double InpMaxSpreadPoints      = 22.0;
input int    InpMaxConsecLosses      = 3;
input bool   InpResetConsecLossDaily = false;

input double InpDailyLossLimitPercent = 2.0;
input int    InpCooldownMinutes       = 20;
input int    InpMaxHoldMinutes        = 240;

//==================================================================
// Exit logic
//==================================================================
input bool   InpUseMidBandExit   = true;

// Trailing placeholders
input bool   InpUseTrailing      = false;
input double InpTrailStartR      = 0.0;
input double InpTrailStepAtrMult = 0.0;

//==================================================================
// ATR-based stop model (USED)
// SL = ATR * InpSlAtrMult
// TP = SL * InpTpRMultiple
//==================================================================
input double InpSlAtrMult        = 2.2;
input double InpTpRMultiple      = 1.0;

#endif // KUROSAWA_RANGEREVERT_INPUTS_MQH
