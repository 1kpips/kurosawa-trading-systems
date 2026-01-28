//+------------------------------------------------------------------+
//| File: Inputs/ScalpEA_Inputs.mqh                                  |
//| EA  : ScalpEA (generic engine preset via .set)                   |
//| Ver : 0.1.2                                                      |
//|                                                                  |
//| Notes                                                            |
//| - This EA uses POINTS for volatility + stops.                    |
//| - BB/RSI/ATR/ADX are consumed by Strategies/Scalp.mqh.           |
//| - Avoid "pips" wording: all distance parameters are POINTS.      |
//+------------------------------------------------------------------+
#property strict
#ifndef KUROSAWA_SCALP_INPUTS_MQH
#define KUROSAWA_SCALP_INPUTS_MQH

//==================================================================
// Identity / Meta
//==================================================================
input string InpZone               = "Tokyo";
input string InpEaName             = "Tokyo_Scalp_USDJPY_M5";
input int    InpMagic              = 2026012701;
input string InpEaId               = "ea-tokyo-scalp-usdjpy-m5";
input string InpEaVersion          = "0.3.22";

//==================================================================
// Target
//==================================================================
input string          InpTargetPair = "USDJPY";
input ENUM_TIMEFRAMES InpTargetTf   = PERIOD_M5;

//==================================================================
// Tracking
//==================================================================
input bool   InpTrackEnable         = true;
input bool   InpTrackSendOpen       = true;

//==================================================================
// Session (fixed UTC offset; JST=+9)
//==================================================================
input int    InpStartHour           = 9;
input int    InpEndHour             = 16;
input int    InpUtcOffset           = 9;

//==================================================================
// EMA / Direction (schema placeholders)
//==================================================================
input int    InpEmaFast             = 0;
input int    InpEmaSlow             = 0;
input bool   InpUseDirFilter        = false;
input int    InpEmaDir              = 0;

//==================================================================
// Min-move filter (OPTIONAL)
// If enabled, engine compares TP(move) vs spread * multiplier.
//==================================================================
input bool   InpUseMinMoveFilter    = true;
input double InpMinMoveSpreadMult   = 2.0;

//==================================================================
// Bollinger Bands (REQUIRED)
//==================================================================
input int    InpBbPeriod            = 20;
input double InpBbDev               = 2.0;

//==================================================================
// RSI (REQUIRED)
//==================================================================
input int    InpRsiPeriod           = 14;
input double InpRsiBuyBelow         = 32.0;
input double InpRsiSellAbove        = 70.0;

//==================================================================
// RSI cross confirm (OPTIONAL; used by Scalp.mqh when enabled)
//==================================================================
input bool   InpUseRsiCrossConfirm  = false;
input double InpRsiBuyCrossLevel    = 0.0;
input double InpRsiSellCrossLevel   = 0.0;

//==================================================================
// Wick / Edge quality filter (OPTIONAL; used by Scalp.mqh when enabled)
// All values are POINTS.
// - InpMinBandBreakPoints: minimum pierce depth beyond band (POINTS)
// - InpMinEdgeOverSpread : edge_points >= spread_points * k
//==================================================================
input bool   InpUseWickSignal       = true;
input double InpMinBandBreakPoints  = 10.0;
input double InpMinEdgeOverSpread   = 1.2;

//==================================================================
// ADX filter (OPTIONAL; used by Scalp.mqh when enabled)
// trade only within [min,max] where bound <=0 disables that side
//==================================================================
input bool   InpUseAdxFilter        = true;
input int    InpAdxPeriod           = 14;
input double InpMinAdxToTrade       = 6.0;
input double InpMaxAdxToTrade       = 30.0;

//==================================================================
// ATR window gate (POINTS) (REQUIRED by Scalp.mqh)
// 0 disables the bound
//==================================================================
input int    InpAtrPeriod           = 14;
input double InpAtrMinPoints        = 10.0;
input double InpAtrMaxPoints        = 70.0;

//==================================================================
// Fixed SL/TP (POINTS)
//==================================================================
input double InpSlPoints            = 55.0;
input double InpTpPoints            = 60.0;

//==================================================================
// Risk sizing
//==================================================================
input bool   InpUseRiskSizing       = false;
input double InpRiskPercent         = 0.30;
input double InpFixedLot            = 0.05;
input double InpMaxLotCap           = 1.0;

//==================================================================
// Frequency & Safety Guards
//==================================================================
input int    InpMaxTradesPerDay       = 8;
input int    InpMaxSpreadPoints       = 9999;

input int    InpMaxConsecLosses       = 3;
input bool   InpResetConsecLossDaily  = true;

input double InpDailyLossLimitPercent = 1.8;
input int    InpCooldownMinutes       = 10;
input int    InpMaxHoldMinutes        = 30;

//==================================================================
// Exit / Trailing (schema placeholder)
//==================================================================
input bool   InpUseMidBandExit       = true;
input bool   InpUseTrailing          = false;
input double InpTrailStartR          = 0.0;
input double InpTrailStepAtrMult     = 0.0;

//==================================================================
// ATR-based stop model (schema placeholder)
//==================================================================
input double InpSlAtrMult            = 0.0;
input double InpTpRMultiple          = 0.0;

//==================================================================
// Strategy specifics
//==================================================================
input bool   InpRequireReclaim       = true;

#endif // KUROSAWA_SCALP_INPUTS_MQH
