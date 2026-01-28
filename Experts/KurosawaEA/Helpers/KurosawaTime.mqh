//+--------------------------------------------------------------------+
//| File: KurosawaTime.mqh                                             |
//| Type: Include Library                                              |
//| Ver : 0.1.0                                                        |
//|                                                                    |
//| Description                                                        |
//| Time utilities for the Kurosawa EA suite.                          |
//|                                                                    |
//| Scope                                                              |
//| - UTC offset clock helpers                                         |
//| - DST-aware clock for London and New York (project specific)       |
//| - Session time window checks (supports midnight crossing)          |
//| - Simple date/time helpers (YYYYMMDD, minutes-of-day)              |
//|                                                                    |
//| DST policy (project specific)                                      |
//| - Tokyo:   no DST                                                  |
//| - London:  EU/UK DST (last Sun Mar -> last Sun Oct)                |
//| - New York:US DST (2nd Sun Mar -> 1st Sun Nov)                     |
//|                                                                    |
//| Important                                                          |
//| - NowByOffsetHours(offsetHours) expects STANDARD offsets:          |
//|     Tokyo:  +9                                                     |
//|     London:  0                                                     |
//|     New York:-5                                                    |
//|   During DST season, London/New York are shifted by +1 hour.       |
//| - For fixed offsets (no DST), use NowByOffsetHoursFixed().         |
//+--------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_TIME_MQH
#define KUROSAWA_TIME_MQH


//+------------------------------------------------------------------+
//| Public time helpers                                              |
//+------------------------------------------------------------------+
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

// Returns true if the current time (UTC + fixed offset) is inside
// the session window [startHour, endHour).
//
// - Time base: UTC (TimeGMT), NOT broker/server time.
// - offsetHours: fixed UTC offset (no DST handling).
//   Examples:
//     Tokyo   = +9
//     London  =  0
//     NewYork = -5
//
// - The window is evaluated in whole hours.
// - Midnight crossing is supported (e.g. 22 -> 5).
//
// Notes:
// - startHour is inclusive, endHour is exclusive.
// - This function is deterministic across brokers and machines
//   because it does not depend on server or local time.
bool IsTimeWindowByOffsetHours(const int startHour, const int endHour, const int offsetHours)
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT() + offsetHours * 3600, dt);

   // Normal window (e.g. 9 -> 17)
   if(startHour <= endHour)
      return (dt.hour >= startHour && dt.hour < endHour);

   // Midnight-crossing window (e.g. 22 -> 5)
   return (dt.hour >= startHour || dt.hour < endHour);
}


// Minutes of day (00:00 -> 0, 23:59 -> 1439).
int MinutesOfDay(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.hour * 60 + dt.min;
}

// Returns how many whole minutes have passed since openTime.
// Returns -1 on invalid input.
int MinutesHeld(const datetime openTime,
                         const datetime nowTime = 0)
{
   if(openTime <= 0)
      return -1;

   const datetime now = (nowTime > 0) ? nowTime : TimeCurrent();
   if(now <= openTime)
      return 0;

   return (int)((now - openTime) / 60);
}

// Compatibility wrappers (kept to avoid mass refactors).
datetime NowJst(const int offsetHours) { return NowByOffsetHoursFixed(offsetHours); }
int      JstYmd(const datetime t)      { return DateYmd(t); }


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
