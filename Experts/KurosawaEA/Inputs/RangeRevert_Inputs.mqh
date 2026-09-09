//+------------------------------------------------------------------+
//| File: Inputs/RangeRevert_Inputs.mqh                              |
//| Ver : 0.4.2                                                      |
//|                                                                  |
//| Purpose                                                          |
//| Inputs-only file for the Kurosawa EA suite (Excel-aligned).      |
//|                                                                  |
//| Units & conventions                                              |
//| - ALL distance-based values are in POINTS                        |
//| - POINTS are in _Point units for the current symbol              |
//|                                                                  |
//| Notes                                                            |
//| - This file defines ONLY inputs (no logic).                      |
//| - Keep column names consistent across the suite.                 |
//| - RangeRevert uses BB/RSI/ADX/ATR + ATR-based stops.             |
//+------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_RANGEREVERT_INPUTS_MQH
#define KUROSAWA_RANGEREVERT_INPUTS_MQH

// ==================================================================
// Identity / Meta
// Columns: InpZone, InpEaName, InpMagic, InpEaId, InpEaVersion
// ==================================================================
input string InpZone      = "London";
input string InpEaName    = "London_RangeRevert_USDJPY_M5";
// Magic must be unique per RUNNING INSTANCE - see the registry in
// Helpers/KurosawaHelpers.mqh. Two EAs sharing a magic on one symbol will
// enumerate and close each other's positions.
input int    InpMagic     = 2026090302;
input string InpEaId      = "ea-london-rangerevert-usdjpy-m5";
// 0.5.1 = engine clock -> broker server time (2026-09-09); tester-identical to 0.5.0
// 0.6.0 = direction switches + D1 reading gate (2026-09-09); identical to 0.5.1 with the gate off
input string InpEaVersion = "0.6.0";
// The TUNE version - one set of parameter values. Bumped on ANY parameter
// change. Distinct from InpEaVersion above, which is the ENGINE build.
// Presets and backtests on 1kpips.com key on this field, not on InpEaVersion.
input string InpPresetVersion = "0.1.0";

// ==================================================================
// Target (intent only; engine warns if mismatched)
// Columns: InpTargetPair, InpTargetTf
// ==================================================================
input string          InpTargetPair = "USDJPY";
input ENUM_TIMEFRAMES InpTargetTf   = PERIOD_M5;
// ==================================================================
// Safety: refuse to run on a chart that does not match the target
// Columns: InpStrictChartMatch
// ==================================================================
input bool InpStrictChartMatch = true;


// ==================================================================
// Tracking
// Columns: InpTrackEnable, InpTrackSendOpen
// ==================================================================
input bool InpTrackEnable   = true;
input bool InpTrackSendOpen = true;

// ==================================================================
// Session (local time via fixed UTC offset; midnight-crossing supported)
// Columns: InpStartHour, InpEndHour, InpUtcOffset
// ==================================================================
input int InpStartHour = 16;
input int InpEndHour   = 1;
input int InpUtcOffset = 9;

// ==================================================================
// EMA trend bias placeholders (schema-aligned; not used by RangeRevert)
// Columns: InpEmaFast, InpEmaSlow, InpUseDirFilter, InpEmaDir
// ==================================================================
input int  InpEmaFast      = 0;
input int  InpEmaSlow      = 0;
input bool InpUseDirFilter = false;
input int  InpEmaDir       = 0;

// ==================================================================
// Min-move/Bollinger schema fields
// Columns: InpUseMinMoveFilter, InpBbPeriod, InpMinMoveSpreadMult, InpBbDev
// Note: RangeRevert uses BB, but does not use the min-move filter.
// ==================================================================
input bool   InpUseMinMoveFilter  = false;
input int    InpBbPeriod          = 20;
input double InpMinMoveSpreadMult = 0.0;
input double InpBbDev             = 2.0;

// ==================================================================
// RSI
// Columns: InpUseRsiCrossConfirm, InpRsiBuyCrossLevel, InpRsiSellCrossLevel,
//          InpRsiPeriod, InpRsiBuyBelow, InpRsiSellAbove
// Note: RangeRevert uses threshold confirmation, not cross-confirm.
// ==================================================================
input bool   InpUseRsiCrossConfirm = false;
input double InpRsiBuyCrossLevel   = 0.0;
input double InpRsiSellCrossLevel  = 0.0;

input int    InpRsiPeriod    = 14;
input double InpRsiBuyBelow  = 30.0;
input double InpRsiSellAbove = 70.0;

// ==================================================================
// Wick / Edge quality (optional, POINTS + multiplier)
// Columns: InpUseWickSignal, InpMinBandBreakPips, InpMinEdgeOverSpread
//
// Important:
// - Suite standard is POINTS, so we store the value in POINTS.
// - We keep the schema name "InpMinBandBreakPips" for compatibility,
//   but the unit is POINTS in this suite.
// - RangeRevert currently uses InpMinBandBreakPips (as POINTS) and
//   InpMinEdgeOverSpread. InpUseWickSignal is a schema flag.
// ==================================================================
input bool   InpUseWickSignal      = false;
input double InpMinBandBreakPoints  = 0.0;   
input double InpMinEdgeOverSpread  = 0.0;  

// Convenience alias (engine/strategy can use this name if you prefer)
input int    InpDeviationPoints    = 20;


// ==================================================================
// ADX regime filter
// Columns: InpUseAdxFilter, InpAdxPeriod, InpMinAdxToTrade, InpMaxAdxToTrade
//
// Note:
// - RangeRevert uses the MAX gate (avoid trend): trade only if ADX <= max.
// - InpMinAdxToTrade kept as schema placeholder.
// ==================================================================
input bool   InpUseAdxFilter   = true;
input int    InpAdxPeriod      = 14;
input double InpMinAdxToTrade  = 0.0;
input double InpMaxAdxToTrade  = 22.0;

// ==================================================================
// ATR window (POINTS)
// Columns: InpAtrPeriod, InpAtrMinPips   (schema), but suite uses InpAtrMinPips name
//
// Your suite standard list uses: InpAtrPeriod, InpAtrMinPips
// However your engines have been using InpAtrMinPoints/InpAtrMaxPoints.
// To stay aligned across your suite, keep the existing names you already
// use in code: InpAtrMinPoints / InpAtrMaxPoints.
// ==================================================================
input int    InpAtrPeriod    = 14;
input double InpAtrMinPoints = 50.0;   
input double InpAtrMaxPoints = 300.0;  

// ==================================================================
// Fixed SL/TP (POINTS) (schema placeholder; not used by RangeRevert)
// Columns: InpSlPips, InpTpPips  (suite list) but engines use Points.
// Keep as Points for consistency with your engines.
// ==================================================================
input double InpSlPoints = 0.0;
input double InpTpPoints = 0.0;

// ==================================================================
// Risk sizing
// Columns: InpUseRiskSizing, InpRiskPercent, InpFixedLot, InpMaxLotCap
// ==================================================================
input bool   InpUseRiskSizing = true;
input double InpRiskPercent   = 0.30;
input double InpFixedLot      = 0.05;
input double InpMaxLotCap     = 0.0;

// ==================================================================
// Frequency & Safety Guards
// Columns: InpMaxTradesPerDay, InpMaxSpreadPoints, InpMaxConsecLosses,
//          InpResetConsecLossDaily, InpDailyLossLimitPercent,
//          InpCooldownMinutes, InpMaxHoldMinutes
// ==================================================================
input int    InpMaxTradesPerDay       = 10;
input int    InpMaxSpreadPoints       = 30;

input int    InpMaxConsecLosses       = 3;
// Must stay true: consecLosses only resets on a win, so with this false the EA
// halts permanently after N losses - it cannot win because it cannot trade.
input bool   InpResetConsecLossDaily  = true;

input double InpDailyLossLimitPercent = 2.0;
input int    InpCooldownMinutes       = 20;
input int    InpMaxHoldMinutes        = 240;

// ==================================================================
// Exit Options / Trailing (schema-aligned)
// Columns: InpUseMidBandExit, InpUseTrailing, InpTrailStartR, InpTrailStepAtrMult
// ==================================================================
input bool   InpUseMidBandExit   = true;

input bool   InpUseTrailing      = false;
input double InpTrailStartR      = 0.0;
input double InpTrailStepAtrMult = 0.0;

// ==================================================================
// ATR-based stop model
// Columns: InpSlAtrMult, InpTpRMultiple
// ==================================================================
input double InpSlAtrMult   = 2.2;
input double InpTpRMultiple = 1.0;

// ==================================================================
// Strategy-specific (schema-aligned field)
// Columns: InpRequireReclaim
// ==================================================================
input bool InpRequireReclaim = false;

#endif // KUROSAWA_RANGEREVERT_INPUTS_MQH

// ------------------------------------------------------------------
// Direction switches and the D1 reading gate (added 0.6.0, 2026-09-09)
// ------------------------------------------------------------------
// Columns: InpAllowLongs, InpAllowShorts, InpD1GateMode, InpD1MinStrength, InpD1Rule
//
// Shorts were worthless unconditionally (~790 across 8 pair-windows, net ~0)
// and the proven presets switch them off. The D1 readings are contrarian
// (forward-return study 2026-09-09): a strong LONG reading means the move is
// extended. The gate lets a side trade only AGAINST such a reading:
//   InpD1GateMode  0 off | 1 shorts need extended-UP | 2 longs need extended-DOWN | 3 both
//   InpD1MinStrength  reading strength required (analyzer scale, 0-100)
//   InpD1Rule      0 Breakout (20-bar range + ATR expansion) | 1 DailyTrend (EMA20/50 + ADX)
// Defaults reproduce 0.5.1 exactly: both sides allowed, gate off.
input bool InpAllowLongs     = true;
input bool InpAllowShorts    = true;
input int  InpD1GateMode     = 0;
input int  InpD1MinStrength  = 70;
input int  InpD1Rule         = 0;

