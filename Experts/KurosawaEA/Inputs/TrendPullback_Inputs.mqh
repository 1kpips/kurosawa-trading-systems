//+------------------------------------------------------------------+
//| File: Inputs/TrendPullback_Inputs.mqh                            |
//| EA  : TrendPullbackEA                                            |
//| Ver : 0.4.1                                                      |
//|                                                                  |
//| Notes                                                            |
//| - Inputs-only file for TrendPullbackEA (preset via .set).        |
//| - Strategy: HTF EMA bias + LTF EMA reclaim + RSI confirm.        |
//| - All distance-based values are in POINTS (_Point units).        |
//| - No unused schema placeholders are defined here.                |
//+------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_TRENDPULLBACKEA_INPUTS_MQH
#define KUROSAWA_TRENDPULLBACKEA_INPUTS_MQH

// ==================================================================
// Identity / Meta
// Columns: InpZone, InpEaName, InpMagic, InpEaId, InpEaVersion
// ==================================================================
input string InpZone      = "NewYork";
input string InpEaName    = "NewYork_TrendPullback_EURUSD_M5";
// Magic must be unique per RUNNING INSTANCE - see the registry in
// Helpers/KurosawaHelpers.mqh. Two EAs sharing a magic on one symbol will
// enumerate and close each other's positions.
input int    InpMagic     = 2026090303;
input string InpEaId      = "ea-ny-trendpullback-eurusd-m5";
// 0.4.2 = engine clock -> broker server time (2026-09-09)
// Compile-time build. InpEaVersion is an INPUT and a .set can override it; this constant is what actually
// runs, and the Init line prints both so a mismatch is visible in the log (AB t-67a9014).
#define TRENDPULLBACK_BUILD "0.4.3"
input string InpEaVersion = "0.4.2";
// The TUNE version - one set of parameter values. Bumped on ANY parameter
// change. Distinct from InpEaVersion above, which is the ENGINE build.
// Presets and backtests on 1kpips.com key on this field, not on InpEaVersion.
input string InpPresetVersion = "0.1.0";

// ==================================================================
// Target
// Columns: InpTargetPair, InpTargetTf
// ==================================================================
input string          InpTargetPair = "EURUSD";
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
// Session (fixed UTC offset; JST=+9)
// Columns: InpStartHour, InpEndHour, InpUtcOffset
// ==================================================================
input int InpStartHour = 22;
input int InpEndHour   = 5;
input int InpUtcOffset = 9;

// ==================================================================
// Execution (order tolerance)
// Columns: InpDeviationPoints
// ==================================================================
input int InpDeviationPoints = 20; // slippage tolerance (points)

// ==================================================================
// RSI confirm (entry timing)
// Columns: InpRsiPeriod, InpRsiBuyBelow, InpRsiSellAbove
// ==================================================================
input int    InpRsiPeriod    = 14;
input double InpRsiBuyBelow  = 45.0;
input double InpRsiSellAbove = 55.0;

// ==================================================================
// ATR window gate (POINTS)
// Columns: InpAtrPeriod, InpAtrMinPoints, InpAtrMaxPoints
// - If InpAtrMaxPoints <= 0, max gate is disabled
// ==================================================================
input int    InpAtrPeriod    = 14;
input double InpAtrMinPoints = 0.0;
input double InpAtrMaxPoints = 0.0;

// ==================================================================
// Risk sizing
// Columns: InpUseRiskSizing, InpRiskPercent, InpFixedLot, InpMaxLotCap
// ==================================================================
input bool   InpUseRiskSizing = true;
input double InpRiskPercent   = 0.35;
input double InpFixedLot      = 0.05;
input double InpMaxLotCap     = 0.0;

// ==================================================================
// Frequency & Safety Guards
// Columns: InpMaxTradesPerDay, InpMaxSpreadPoints, InpMaxConsecLosses,
//          InpResetConsecLossDaily, InpDailyLossLimitPercent,
//          InpCooldownMinutes, InpMaxHoldMinutes
// ==================================================================
input int    InpMaxTradesPerDay       = 0;   // 0 = unlimited (engine policy)
input int    InpMaxSpreadPoints       = 20;

input int    InpMaxConsecLosses       = 3;
// Must stay true: consecLosses only resets on a win, so with this false the EA
// halts permanently after N losses - it cannot win because it cannot trade.
input bool   InpResetConsecLossDaily  = true;

input double InpDailyLossLimitPercent = 2.0;
input int    InpCooldownMinutes       = 45;
input int    InpMaxHoldMinutes        = 0;   // 0 = disabled

// ==================================================================
// Trailing (optional; engine-managed)
// Columns: InpUseTrailing, InpTrailStartR, InpTrailStepAtrMult
// ==================================================================
input bool   InpUseTrailing      = false;
input double InpTrailStartR      = 0.0;
input double InpTrailStepAtrMult = 0.0;

// ==================================================================
// ATR-based stop model
// Columns: InpSlAtrMult, InpTpRMultiple
// ==================================================================
input double InpSlAtrMult   = 2.2;
input double InpTpRMultiple = 1.4;

// ==================================================================
// Strategy-specific (TrendPullback)
// ==================================================================

// Higher-TF bias
// Columns: InpBiasTf, InpBiasEmaFast, InpBiasEmaSlow, InpBiasMinGapPoints
input ENUM_TIMEFRAMES InpBiasTf           = PERIOD_M15;
input int             InpBiasEmaFast      = 50;
input int             InpBiasEmaSlow      = 200;
input double          InpBiasMinGapPoints = 0.0; // 0 = classic fast>slow bias

// Entry reclaim EMA (on entry TF)
// Column: InpEntryEma
input int InpEntryEma = 20;

#endif // KUROSAWA_TRENDPULLBACKEA_INPUTS_MQH
