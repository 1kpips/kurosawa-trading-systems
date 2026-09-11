//+------------------------------------------------------------------+
//| File: Inputs/LondonFix_Inputs.mqh                                |
//| Type: Input schema for Engines/LondonFixEA.mq5                   |
//| Ver : 0.1.0                                                      |
//|                                                                  |
//| One trade per admitted day: at the 16:00 London fix, trade       |
//| AGAINST the move of the previous InpPreWindowMin minutes, exit   |
//| on the clock InpHoldMinutes later. No take-profit; a fixed pip   |
//| stop only. Times are London wall-clock; the engine converts from |
//| the broker's server clock itself (NY DST and UK DST both exact). |
//+------------------------------------------------------------------+
#property strict

//--- Identity
input string InpZone          = "London";
input string InpEaName        = "London_Fix_GBPUSD_M5";
input int    InpMagic         = 2026091008;
input string InpEaId          = "ea-londonfix-gbpusd-m5";
// 0.1.0 = first build (2026-09-11)
// Compile-time build. InpEaVersion is an INPUT and a .set can override it; this constant is what actually
// runs, and the Init line prints both so a mismatch is visible in the log.
#define LONDONFIX_BUILD "0.1.0"
input string InpEaVersion     = "0.1.0";
input string InpPresetVersion = "0.1.0";

//--- Target chart
input string          InpTargetPair = "GBPUSD";
input ENUM_TIMEFRAMES InpTargetTf   = PERIOD_M5;
input bool            InpStrictChartMatch = true;

//--- Tracking
input bool InpTrackEnable   = true;
input bool InpTrackSendOpen = true;

//--- Session gate (wide open on purpose; the fix clock below is what times the trade)
input int InpStartHour = 0;
input int InpEndHour   = 24;
input int InpUtcOffset = 0;

//--- The fix (London time)
input int    InpFixHour          = 16;    // WM/Reuters 4pm London fix
input int    InpFixMinute        = 0;
input int    InpEntryDelayMin    = 0;     // enter this many minutes after the fix (0 = at the fix)
input int    InpEntryWindowMin   = 10;    // give up if not filled within this many minutes after entry time
input int    InpHoldMinutes      = 30;    // exit on the clock (study peak: 30)
input TokyoFixDayFilter InpDayFilter = TFIX_MONTHEND_ONLY;   // the effect is month-end only
input FixSideMode InpSideMode    = FIX_SIDE_FADE_PRE;        // against the pre-fix move
input int    InpSide             = -1;    // used only when InpSideMode = FIX_SIDE_FIXED
input int    InpPreWindowMin     = 60;    // the move measured into the fix: 15:00 -> 16:00
input double InpMinPreMovePips   = 0.0;   // skip the day when the pre-move is smaller than this (0 = never skip)
input double InpStopPips         = 20.0;  // protective stop in pips (0 = none); MAE 90th pct was 21 pips
input bool   InpSkipJpHolidays   = false; // not a Tokyo clock; kept for the shared calendar code (must stay false)

//--- Execution
input int InpDeviationPoints = 20;

//--- Sizing
input bool   InpUseRiskSizing = false;
input double InpRiskPercent   = 0.25;
input double InpFixedLot      = 0.01;
input double InpMaxLotCap     = 0.0;

//--- Gates
input int    InpMaxTradesPerDay       = 1;
input int    InpMaxSpreadPoints       = 20;   // 2 pips; the 16:00 spread is ~0.8
input int    InpMaxConsecLosses       = 0;    // 0 = off: one trade a month is not a streak system
input bool   InpResetConsecLossDaily  = true;
input double InpDailyLossLimitPercent = 3.0;
input int    InpCooldownMinutes       = 0;
input int    InpMaxHoldMinutes        = 0;    // 0 = off; the clock exit is InpHoldMinutes
input bool   InpUseTrailing      = false;
input double InpTrailStartR      = 0.0;
input double InpTrailStepAtrMult = 0.0;
