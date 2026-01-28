//+------------------------------------------------------------------+
//| File: Inputs/TrendPullbackEA_Inputs.mqh                          |
//| EA  : TrendPullbackEA (generic engine preset via .set)           |
//| Ver : 0.3.0                                                      |
//|                                                                  |
//| Notes                                                            |
//| - Repo-wide schema inputs (Excel-aligned).                       |
//| - Strategy logic uses EMA-bias (HTF) + EMA reclaim (LTF) + RSI.  |
//| - Volatility + stops are points-based in engine/strategy.        |
//| - Some inputs are placeholders to keep one unified column set.   |
//+------------------------------------------------------------------+
#property strict
#ifndef KUROSAWA_TRENDPULLBACKEA_INPUTS_MQH
#define KUROSAWA_TRENDPULLBACKEA_INPUTS_MQH

//==================================================================
// Identity / Meta
//==================================================================
input string InpZone               = "NewYork";
input string InpEaName             = "TrendPullbackEA";
input int    InpMagic              = 2026011703;
input string InpEaId               = "engine-trendpullback";
input string InpEaVersion          = "0.3.0";

//==================================================================
// Target
//==================================================================
input string          InpTargetPair = "EURUSD";
input ENUM_TIMEFRAMES InpTargetTf   = PERIOD_M5;

//==================================================================
// Tracking
//==================================================================
input bool   InpTrackEnable         = true;
input bool   InpTrackSendOpen       = true;

//==================================================================
// Session (fixed UTC offset; JST=+9)
//==================================================================
input int    InpStartHour           = 22;
input int    InpEndHour             = 5;
input int    InpUtcOffset           = 9;

//==================================================================
// EMA / Direction (schema placeholder; not used by this engine)
//==================================================================
input int    InpEmaFast             = 0;
input int    InpEmaSlow             = 0;
input bool   InpUseDirFilter        = false;
input int    InpEmaDir              = 0;

//==================================================================
// Min-move filter (schema placeholder; not used)
//==================================================================
input bool   InpUseMinMoveFilter    = false;
input double InpMinMoveSpreadMult   = 0.0;

//==================================================================
// Bollinger Bands (schema placeholder; not used)
//==================================================================
input int    InpBbPeriod            = 0;
input double InpBbDev               = 0.0;

//==================================================================
// RSI (USED by TrendPullback strategy)
//==================================================================
input int    InpRsiPeriod           = 14;
input double InpRsiBuyBelow         = 45.0;  // buy when RSI <= this
input double InpRsiSellAbove        = 55.0;  // sell when RSI >= this

//==================================================================
// RSI cross confirm (schema placeholder; not used)
//==================================================================
input bool   InpUseRsiCrossConfirm  = false;
input int    InpRsiBuyCrossLevel    = 0;
input int    InpRsiSellCrossLevel   = 0;

//==================================================================
// Wick signal (schema placeholder; not used)
//==================================================================
input bool   InpUseWickSignal       = false;
input double InpMinBandBreakPips    = 0.0;
input double InpMinEdgeOverSpread   = 0.0;

//==================================================================
// ADX filter (schema placeholder; not used)
//==================================================================
input bool   InpUseAdxFilter        = false;
input int    InpAdxPeriod           = 0;
input double InpMinAdxToTrade       = 0.0;
input double InpMaxAdxToTrade       = 0.0;

//==================================================================
// ATR window gate (POINTS) (USED)
//==================================================================
input int    InpAtrPeriod           = 14;
input double InpAtrMinPoints        = 0.0;   // 0 = disabled
input double InpAtrMaxPoints        = 0.0;   // 0 = disabled

//==================================================================
// Fixed SL/TP (POINTS) (schema placeholder; not used by this EA)
//==================================================================
input double InpSlPoints            = 0.0;
input double InpTpPoints            = 0.0;

//==================================================================
// Risk sizing (USED)
//==================================================================
input bool   InpUseRiskSizing       = true;
input double InpRiskPercent         = 0.35;
input double InpFixedLot            = 0.05;
input double InpMaxLotCap           = 0.0;

//==================================================================
// Frequency & Safety Guards (USED by engine)
//==================================================================
input int    InpMaxTradesPerDay      = 0;      // 0 = disabled
input int    InpMaxSpreadPoints      = 20;

input int    InpMaxConsecLosses      = 3;
input bool   InpResetConsecLossDaily = false;

input double InpDailyLossLimitPercent = 2.0;
input int    InpCooldownMinutes      = 45;
input int    InpMaxHoldMinutes       = 0;      // 0 = disabled

//==================================================================
// Exit / Trailing (schema placeholder; not used)
//==================================================================
input bool   InpUseMidBandExit       = false;

input bool   InpUseTrailing          = false;
input double InpTrailStartR          = 0.0;
input double InpTrailStepAtrMult     = 0.0;

//==================================================================
// ATR-based stop model (USED)
//==================================================================
input double InpSlAtrMult            = 2.2;   // SL(points) = ATR(points) * mult
input double InpTpRMultiple          = 1.4;   // TP(points) = SL(points) * R

//==================================================================
// Strategy-specific (non-schema but stable across TrendPullback)
//==================================================================

// Higher-TF bias
input ENUM_TIMEFRAMES InpBiasTf      = PERIOD_M15;
input int    InpBiasEmaFast          = 50;
input int    InpBiasEmaSlow          = 200;

// Entry reclaim EMA (on entry TF)
input int    InpEntryEma             = 20;

// Bias strength (points). 0 = classic fast>slow bias
input double InpBiasMinGapPoints     = 0.0;

// Optional market-activity range filter
input bool            InpUseMarketRangeFilter    = true;
input ENUM_TIMEFRAMES InpRangeTf                = PERIOD_M5;

input int             InpRangeWindowStartHour   = 8;
input int             InpRangeWindowStartMinute = 0;
input int             InpRangeWindowEndHour     = 12;
input int             InpRangeWindowEndMinute   = 0;

input int             InpRangeMinPoints         = 35;
input int             InpRangeMaxPoints         = 0;     // 0 = disabled
input bool            InpRangeRequireWindowDone = true;

#endif // KUROSAWA_TRENDPULLBACKEA_INPUTS_MQH
