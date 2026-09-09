//+--------------------------------------------------------------------+
//| File: Helpers/KurosawaTime.mqh                                     |
//| Type: Include Library                                              |
//| Ver : 0.2.0                                                        |
//|                                                                    |
//| Description                                                        |
//| Time and session utilities for the Kurosawa EA suite.              |
//|                                                                    |
//| Design                                                             |
//| - Self-contained: no dependency on other Kurosawa helper files     |
//| - Base clock is BROKER SERVER time (TimeTradeServer), NOT TimeGMT  |
//| - Session window checks support midnight crossing                  |
//|                                                                    |
//| Why server time (changed 2026-09-09, was TimeGMT)                  |
//| - In the Strategy Tester TimeGMT() IS server time, so every        |
//|   backtest gated sessions in server hours. Live, TimeGMT() is real |
//|   UTC. On OANDA Japan (UTC+2/+3) that is a 2-3 h shift between     |
//|   what was tested and what would run. One clock in both places is  |
//|   the only way "proven in the tester" means anything live.         |
//| - Consequence: InpUtcOffset is hours added to SERVER time, and a   |
//|   session is pinned to server hours (which follow the broker's NY  |
//|   DST convention). Label sessions in server time, not UTC.         |
//+--------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_TIME_MQH
#define KUROSAWA_TIME_MQH

// ------------------------------------------------------------------
// Clock helpers
// ------------------------------------------------------------------

// The one clock every engine gates on. TimeTradeServer() is the broker's
// clock in both the tester and live; TimeGMT() is not (see header).
datetime EngineClock()
{
   return TimeTradeServer();
}

// Returns "now" on the engine clock plus a fixed offset (hours).
// This does not perform DST adjustments.
datetime NowByOffsetHoursFixed(const int offsetHours)
{
   return EngineClock() + (offsetHours * 3600);
}

// Converts a datetime into an integer YYYYMMDD.
int DateYmd(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.year * 10000 + dt.mon * 100 + dt.day;
}

// Convenience: current date (YYYYMMDD) in UTC+fixed offset.
int NowYmdByOffsetHoursFixed(const int offsetHours)
{
   return DateYmd(NowByOffsetHoursFixed(offsetHours));
}

// ------------------------------------------------------------------
// Unified "trading day" clock
// ------------------------------------------------------------------
// ONE definition of when the trading day rolls over, shared by BOTH
// the risk manager (daily loss limit / trade counters) and the daily
// report roll. Built on the engine clock (server time) so the tester and
// live agree on when a day ends.
//
//   0 = server midnight (OANDA Japan: 21:00/22:00 UTC, i.e. the NY close)
//   9 = server + 9h     -- change here to move the boundary suite-wide
#define KUROSAWA_TRADING_DAY_UTC_OFFSET 0

// "Now" on the trading-day clock (for day-of-year detection in risk).
datetime TradingDayNow()
{
   return NowByOffsetHoursFixed(KUROSAWA_TRADING_DAY_UTC_OFFSET);
}

// Current trading-day date as YYYYMMDD (for the daily report roll).
int TradingDayYmd()
{
   return NowYmdByOffsetHoursFixed(KUROSAWA_TRADING_DAY_UTC_OFFSET);
}

// ------------------------------------------------------------------
// Session window (whole hours, supports midnight crossing)
// ------------------------------------------------------------------
// DST WARNING (by design): these windows use a FIXED UTC offset and do
// NOT auto-adjust for daylight saving. So a window pinned to a local
// market session (e.g. London open) drifts by 1 hour twice a year when
// that region flips DST but the fixed offset does not. This is a
// deliberate tradeoff for determinism/reproducibility across brokers.
// To track a wall-clock session precisely, adjust the EA's InpUtcOffset
// (or start/end hours) seasonally. UTC-anchored windows are unaffected.

// Returns true if the current time (engine clock + fixed offset) is inside
// the session window [startHour, endHour).
//
// - Time base: broker server time (EngineClock), same in tester and live.
// - offsetHours: fixed offset, no DST handling.
// - startHour inclusive, endHour exclusive.
bool IsTimeWindowByOffsetHours(const int startHour, const int endHour, const int offsetHours)
{
   MqlDateTime dt;
   TimeToStruct(EngineClock() + offsetHours * 3600, dt);

   // Normal window (e.g., 9 -> 17)
   if(startHour <= endHour)
      return (dt.hour >= startHour && dt.hour < endHour);

   // Midnight-crossing window (e.g., 22 -> 5)
   return (dt.hour >= startHour || dt.hour < endHour);
}

// Minutes of day (00:00 -> 0, 23:59 -> 1439).
int MinutesOfDay(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.hour * 60 + dt.min;
}

// ------------------------------------------------------------------
// Compatibility wrappers (kept to avoid mass refactors)
// ------------------------------------------------------------------
datetime NowJst(const int offsetHours) { return NowByOffsetHoursFixed(offsetHours); }
int      JstYmd(const datetime t)      { return DateYmd(t); }

// ------------------------------------------------------------------
// Parsing helpers
// ------------------------------------------------------------------
ENUM_TIMEFRAMES TimeframeFromString(const string tf)
{
   if(tf == "M1")  return PERIOD_M1;
   if(tf == "M2")  return PERIOD_M2;
   if(tf == "M3")  return PERIOD_M3;
   if(tf == "M4")  return PERIOD_M4;
   if(tf == "M5")  return PERIOD_M5;
   if(tf == "M6")  return PERIOD_M6;
   if(tf == "M10") return PERIOD_M10;
   if(tf == "M12") return PERIOD_M12;
   if(tf == "M15") return PERIOD_M15;
   if(tf == "M20") return PERIOD_M20;
   if(tf == "M30") return PERIOD_M30;
   if(tf == "H1")  return PERIOD_H1;
   if(tf == "H2")  return PERIOD_H2;
   if(tf == "H3")  return PERIOD_H3;
   if(tf == "H4")  return PERIOD_H4;
   if(tf == "H6")  return PERIOD_H6;
   if(tf == "H8")  return PERIOD_H8;
   if(tf == "H12") return PERIOD_H12;
   if(tf == "D1")  return PERIOD_D1;
   if(tf == "W1")  return PERIOD_W1;
   if(tf == "MN1") return PERIOD_MN1;

   // Fallback: current chart timeframe
   return (ENUM_TIMEFRAMES)_Period;
}

#endif // KUROSAWA_TIME_MQH
//+--------------------------------------------------------------------+
