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
//| - Uses UTC (TimeGMT) as the base clock for deterministic behavior  |
//| - Session window checks support midnight crossing                  |
//|                                                                    |
//| Notes for public users                                             |
//| - For session gating, we prefer UTC+offset over broker time.       |
//|   This makes behavior consistent across brokers and VPS setups.    |
//+--------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_TIME_MQH
#define KUROSAWA_TIME_MQH

// ------------------------------------------------------------------
// Clock helpers
// ------------------------------------------------------------------

// Returns "now" computed from UTC (TimeGMT) plus a fixed offset (hours).
// This does not perform DST adjustments.
datetime NowByOffsetHoursFixed(const int offsetHours)
{
   return TimeGMT() + (offsetHours * 3600);
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
// Session window (whole hours, supports midnight crossing)
// ------------------------------------------------------------------

// Returns true if the current time (UTC + fixed offset) is inside
// the session window [startHour, endHour).
//
// - Time base: UTC (TimeGMT), not broker time.
// - offsetHours: fixed offset, no DST handling.
// - startHour inclusive, endHour exclusive.
bool IsTimeWindowByOffsetHours(const int startHour, const int endHour, const int offsetHours)
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT() + offsetHours * 3600, dt);

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
