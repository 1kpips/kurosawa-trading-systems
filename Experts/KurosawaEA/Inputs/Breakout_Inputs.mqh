//+------------------------------------------------------------------+
//| File: Inputs/Breakout_Inputs.mqh                                 |
//| Type: Input schema for Engines/BreakoutEA.mq5                    |
//| Ver : 0.1.0                                                      |
//|                                                                  |
//| ALL HOURS IN THIS ENGINE ARE BROKER SERVER HOURS. InpUtcOffset   |
//| is 0 on purpose: the range window, the entry window and the      |
//| flat-at hour all sit on one clock, the same one the tester uses. |
//| OANDA Japan server = UTC+3 summer / UTC+2 winter.                |
//+------------------------------------------------------------------+
#property strict

//--- Identity
input string InpZone          = "NewYork";
input string InpEaName        = "NewYork_Breakout_EURJPY_M15";
input int    InpMagic         = 2026090913;
input string InpEaId          = "ea-ny-breakout-eurjpy-m15";
// 0.1.0 = first build (2026-09-09)
input string InpEaVersion     = "0.1.0";
input string InpPresetVersion = "0.1.0";

//--- Target chart
input string          InpTargetPair = "EURJPY";
input ENUM_TIMEFRAMES InpTargetTf   = PERIOD_M15;
input bool            InpStrictChartMatch = true;

//--- Tracking
input bool InpTrackEnable   = true;
input bool InpTrackSendOpen = true;

//--- Entry window (server hours; InpUtcOffset stays 0)
input int InpStartHour = 15;
input int InpEndHour   = 21;
input int InpUtcOffset = 0;

//--- Execution
input int InpDeviationPoints = 20;   // slippage tolerance (points)

//--- Range window (server hours) - the session the break is measured against
input int InpRangeStartHour = 7;
input int InpRangeEndHour   = 13;

//--- Break definition
input double InpBreakBufferAtr   = 0.2;    // close must clear the range by this many ATR
input double InpMaxRangeAtr      = 3.0;    // 0 = off: skip the day if the range is wider than this
input bool   InpRequireFreshBreak = true;  // previous close still inside the buffered range
input bool   InpAllowLongs       = true;
input bool   InpAllowShorts      = true;

//--- ADX
input bool   InpUseAdxFilter     = true;
input int    InpAdxPeriod        = 14;
input double InpMinAdxToTrade    = 20.0;
input double InpMaxAdxToTrade    = 0.0;
input bool   InpRequireAdxRising = true;

//--- ATR (points)
input int    InpAtrPeriod    = 14;
input double InpAtrMinPoints = 20.0;   // floor so the stop cannot collapse below the spread
input double InpAtrMaxPoints = 0.0;

//--- Sizing
input bool   InpUseRiskSizing = false;
input double InpRiskPercent   = 0.25;
input double InpFixedLot      = 0.01;
input double InpMaxLotCap     = 0.0;

//--- Gates
input int    InpMaxTradesPerDay       = 2;     // one per side
input int    InpMaxSpreadPoints       = 30;
input int    InpMaxConsecLosses       = 3;
input bool   InpResetConsecLossDaily  = true;
input double InpDailyLossLimitPercent = 2.0;
input int    InpCooldownMinutes       = 0;
input int    InpMaxHoldMinutes        = 0;     // 0 = off; InpFlatAtHour is the time exit
input int    InpFlatAtHour            = 23;    // server hour: close any open position (-1 = off)

//--- Exits
input double InpSlAtrMult   = 1.2;   // stop = min(this x ATR, distance back to the range midpoint), floor 0.5 ATR
input double InpTpRMultiple = 2.0;
input bool   InpUseTrailing      = false;
input double InpTrailStartR      = 0.0;
input double InpTrailStepAtrMult = 0.0;
