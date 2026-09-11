//+------------------------------------------------------------------+
//| File: Inputs/TokyoFix_Inputs.mqh                                 |
//| Type: Input schema for Engines/TokyoFixEA.mq5                    |
//| Ver : 0.1.0                                                      |
//|                                                                  |
//| One trade per admitted day: enter at the 09:55 JST fix, exit on  |
//| the clock InpHoldMinutes later. No take-profit; a fixed pip stop |
//| is the only protection, and the study says it barely matters.   |
//| Times are JST (Japan has no DST); the engine converts from the   |
//| broker's server clock itself. InpUtcOffset is NOT used for the   |
//| fix time - it only feeds the shared session gate, left wide open. |
//+------------------------------------------------------------------+
#property strict

//--- Identity
input string InpZone          = "Tokyo";
input string InpEaName        = "Tokyo_Fix_USDJPY_M5";
input int    InpMagic         = 2026091004;
input string InpEaId          = "ea-tokyofix-usdjpy-m5";
// 0.1.0 = first build (2026-09-10)
// Compile-time build. InpEaVersion is an INPUT and a .set can override it; this constant is what actually
// runs, and the Init line prints both so a mismatch is visible in the log.
// 0.2.0 = Japanese holiday calendar (2026-09-11): InpSkipJpHolidays; identical to 0.1.0 when false
// 0.2.1 = portfolio cap inputs (2026-09-11); identical to 0.2.0 when all four are 0
#define TOKYOFIX_BUILD "0.2.1"
input string InpEaVersion     = "0.1.0";
input string InpPresetVersion = "0.1.0";

//--- Target chart
input string          InpTargetPair = "USDJPY";
input ENUM_TIMEFRAMES InpTargetTf   = PERIOD_M5;
input bool            InpStrictChartMatch = true;

//--- Tracking
input bool InpTrackEnable   = true;
input bool InpTrackSendOpen = true;

//--- Session gate (wide open on purpose; the fix clock below is what times the trade)
input int InpStartHour = 0;
input int InpEndHour   = 24;
input int InpUtcOffset = 0;

//--- The fix (JST)
input int    InpFixHour          = 9;     // Tokyo fix 09:55 JST
input int    InpFixMinute        = 55;
input int    InpEntryDelayMin    = 0;     // enter this many minutes after the fix (0 = at the fix)
input int    InpEntryWindowMin   = 10;    // give up if not filled within this many minutes after entry time
input int    InpHoldMinutes      = 25;    // exit on the clock: fix + delay + hold (study peak: 25)
input TokyoFixDayFilter InpDayFilter = TFIX_GOTOBI_MONTHEND;
input int    InpSide             = -1;    // -1 = short (the measured effect), +1 = long (control)
input double InpStopPips         = 20.0;  // protective stop in pips (0 = none); MAE 90th pct was 16 pips
input bool   InpSkipJpHolidays   = true;  // no banks, no fix: skip JP holidays and roll gotobi flows back past them

//--- Execution
input int InpDeviationPoints = 20;

//--- Sizing
input bool   InpUseRiskSizing = false;
input double InpRiskPercent   = 0.25;
input double InpFixedLot      = 0.01;
input double InpMaxLotCap     = 0.0;

//--- Gates
input int    InpMaxTradesPerDay       = 1;
input int    InpMaxSpreadPoints       = 15;   // 1.5 pips; the fix spread is ~0.3
input int    InpMaxConsecLosses       = 0;    // 0 = off: one trade a day is not a streak system
input bool   InpResetConsecLossDaily  = true;
input double InpDailyLossLimitPercent = 3.0;
input int    InpCooldownMinutes       = 0;
input int    InpMaxHoldMinutes        = 0;    // 0 = off; the clock exit is InpHoldMinutes
input bool   InpUseTrailing      = false;
input double InpTrailStartR      = 0.0;
input double InpTrailStepAtrMult = 0.0;

// ------------------------------------------------------------------
// Portfolio (account-level) cap - see Helpers/KurosawaPortfolio.mqh
// ------------------------------------------------------------------
// Every instance on the account evaluates the same four numbers before it sends an
// order, so the seven charts share one budget without talking to each other.
// 0 = that limit is off. The tester runs one instance, so the caps never bind there
// and a filed backtest is unchanged. Live sets carry 4 / 1.0 / 2.0 / 3.
input int    InpPortfolioMaxPositions   = 0;    // open positions on the account, all symbols
input double InpPortfolioMaxRiskPercent = 0.0;  // open distance-to-stop money + this trade, % of balance
input double InpPortfolioDailyLossPct   = 0.0;  // realized today + floating, all magics, % of day-start balance
input int    InpPortfolioMaxPerCurrency = 0;    // open positions sharing this trade's base or quote currency
