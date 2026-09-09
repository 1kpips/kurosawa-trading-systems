//+------------------------------------------------------------------+
//| File: Inputs/Fade_Inputs.mqh                                     |
//| Type: Input schema for Engines/FadeEA.mq5                        |
//| Ver : 0.1.0                                                      |
//|                                                                  |
//| D1 engine. The session gate is left wide open (0-24, offset 0): |
//| a daily signal fires at the bar open and is filled within        |
//| InpEntryWindowMinutes, once the rollover spread has narrowed.    |
//+------------------------------------------------------------------+
#property strict

//--- Identity
input string InpZone          = "Daily";
input string InpEaName        = "Fade_USDJPY_D1";
input int    InpMagic         = 2026090915;
input string InpEaId          = "ea-fade-usdjpy-d1";
// 0.1.0 = first build (2026-09-09)
input string InpEaVersion     = "0.1.0";
input string InpPresetVersion = "0.1.0";

//--- Target chart
input string          InpTargetPair = "USDJPY";
input ENUM_TIMEFRAMES InpTargetTf   = PERIOD_D1;
input bool            InpStrictChartMatch = true;

//--- Tracking
input bool InpTrackEnable   = true;
input bool InpTrackSendOpen = true;

//--- Session gate (wide open on purpose; server hours)
input int InpStartHour = 0;
input int InpEndHour   = 24;
input int InpUtcOffset = 0;

//--- Execution
input int InpDeviationPoints     = 30;   // slippage tolerance (points)
input int InpEntryWindowMinutes  = 240;  // a signal may be filled up to this long after the bar open

//--- The analyzer's rule (must match Signals/D1_Signal_Breakout.mq5)
input int    InpLookbackBars = 20;
input int    InpAtrPeriod    = 14;
input int    InpAtrAvgBars   = 20;
input double InpMinAtrRatio  = 1.0;

//--- The fade
input int    InpMinStrength    = 80;    // fade readings at or above this
input int    InpHoldBars       = 5;     // exit at the open of the Nth bar after entry
input double InpDisasterStopAtr = 3.0;  // wide protective stop (ATR multiple); the exit is the hold, not the stop
input bool   InpAllowLongs     = true;
input bool   InpAllowShorts    = true;

//--- ATR (points) - floor only
input double InpAtrMinPoints = 0.0;
input double InpAtrMaxPoints = 0.0;

//--- Sizing
input bool   InpUseRiskSizing = false;
input double InpRiskPercent   = 0.25;
input double InpFixedLot      = 0.01;
input double InpMaxLotCap     = 0.0;

//--- Gates
input int    InpMaxTradesPerDay       = 1;
input int    InpMaxSpreadPoints       = 40;   // rollover spreads are wide; the entry window waits them out
input int    InpMaxConsecLosses       = 0;    // 0 = off: a 5-day fade is not a streak system
input bool   InpResetConsecLossDaily  = true;
input double InpDailyLossLimitPercent = 3.0;
input int    InpCooldownMinutes       = 0;
input int    InpMaxHoldMinutes        = 0;    // 0 = off; InpHoldBars is the time exit
input bool   InpUseTrailing      = false;
input double InpTrailStartR      = 0.0;
input double InpTrailStepAtrMult = 0.0;
