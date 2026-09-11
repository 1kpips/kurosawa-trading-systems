//+------------------------------------------------------------------+
//| File: Strategies/TokyoFix.mqh                                    |
//| Type: Strategy module (pure, no MT5 trade calls)                 |
//| Ver : 0.2.0                                                      |
//|                                                                  |
//| Tokyo fix (09:55 JST) flow fade. 0.2.0 adds the JP holiday calendar. |
//|                                                                  |
//| What was measured (2026-09-10, OANDA M5 bars 2019-2026)          |
//| - On "gotobi" days (5th/10th/15th/20th/25th, rolled back to the  |
//|   previous business day when they fall on a weekend) and on the  |
//|   last business day of the month, USDJPY and EURJPY FALL after   |
//|   the 09:55 JST fix: about -3 pips from the 09:55 open to the    |
//|   10:20 open, t-stat 5-8, positive for the short in every full   |
//|   year 2019-2025, 549 events. Spread at that moment ~0.3 pips.   |
//| - The classic "drift up into the fix" is NOT visible in the      |
//|   bars; what is visible is the unwind after it.                  |
//| - 5th and 10th are weak (+1 to +2 pips); 15th/20th/25th/month-   |
//|   end carry the effect (+3 to +5). InpDayFilter selects.         |
//|                                                                  |
//| Clock                                                            |
//| - The fix is a Tokyo wall-clock event and Japan has no DST, so   |
//|   the engine converts SERVER time to JST properly: the broker    |
//|   server follows New York DST (UTC+3 summer / UTC+2 winter), so  |
//|   JST = server + 6h in summer, +7h in winter. The tester's bars   |
//|   carry the same server clock, so tester and live agree.         |
//+------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_TOKYOFIX_MQH
#define KUROSAWA_TOKYOFIX_MQH

enum TokyoFixDayFilter
{
   TFIX_ALL_DAYS        = 0,   // every weekday (control)
   TFIX_GOTOBI_MONTHEND = 1,   // 5/10/15/20/25 (rolled back) + last business day
   TFIX_STRONG_DAYS     = 2,   // 15/20/25 (rolled back) + last business day
   TFIX_MONTHEND_ONLY   = 3
};

// ------------------------------------------------------------------
// New York DST: from 02:00 on the second Sunday of March to 02:00 on
// the first Sunday of November (rule since 2007). `ny` is NY local time.
// ------------------------------------------------------------------
int TFix_DayOfWeek(const int y, const int m, const int d)   // 0 = Sunday
{
   MqlDateTime s; s.year = y; s.mon = m; s.day = d; s.hour = 12; s.min = 0; s.sec = 0;
   MqlDateTime r; TimeToStruct(StructToTime(s), r);
   return r.day_of_week;
}

int TFix_NthSunday(const int y, const int m, const int n)
{
   const int first = TFix_DayOfWeek(y, m, 1);            // weekday of the 1st
   const int firstSunday = 1 + ((7 - first) % 7);
   return firstSunday + 7 * (n - 1);
}

bool TFix_NyDstActive(const datetime ny)
{
   MqlDateTime t; TimeToStruct(ny, t);
   if(t.mon < 3 || t.mon > 11) return false;
   if(t.mon > 3 && t.mon < 11) return true;
   if(t.mon == 3)
   {
      const int d = TFix_NthSunday(t.year, 3, 2);
      return (t.day > d) || (t.day == d && t.hour >= 2);
   }
   const int d = TFix_NthSunday(t.year, 11, 1);          // November
   return (t.day < d) || (t.day == d && t.hour < 2);
}

// Server (NY + 7h, the OANDA convention) -> JST (UTC+9, no DST).
datetime TFix_ServerToJst(const datetime server)
{
   const datetime ny = server - 7 * 3600;
   return server + (TFix_NyDstActive(ny) ? 6 : 7) * 3600;
}

// ------------------------------------------------------------------
// Day classification on the JST date. Business day = Mon-Fri, minus
// Japanese holidays when InpSkipJpHolidays is on (0.2.0; the original
// study used none).
// ------------------------------------------------------------------
int TFix_DaysInMonth(const int y, const int m)
{
   static const int dm[12] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
   if(m == 2 && ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0)) return 29;
   return dm[m - 1];
}

bool TFix_IsWeekday(const int y, const int m, const int d)
{
   const int w = TFix_DayOfWeek(y, m, d);
   return (w >= 1 && w <= 5);
}

bool TFix_IsBusinessDay(const int y, const int m, const int d, const bool skipJpHolidays);   // defined below

// The business day on which a calendar-date flow settles: the date itself,
// or the previous business day when it falls on a weekend (or, with
// skipJpHolidays, a Japanese holiday - the 5th's flow settles on the 2nd
// when the 5th is Children's Day).
int TFix_RolledBack(const int y, const int m, int d, const bool skipJpHolidays)
{
   while(d > 1 && !TFix_IsBusinessDay(y, m, d, skipJpHolidays)) d--;
   return d;
}

bool TFix_IsMonthEnd(const int y, const int m, const int d, const bool skipJpHolidays)
{
   return TFix_IsBusinessDay(y, m, d, skipJpHolidays) && d == TFix_RolledBack(y, m, TFix_DaysInMonth(y, m), skipJpHolidays);
}

bool TFix_IsGotobi(const int y, const int m, const int d, const bool strongOnly, const bool skipJpHolidays)
{
   if(!TFix_IsBusinessDay(y, m, d, skipJpHolidays)) return false;
   const int first = strongOnly ? 15 : 5;
   for(int g = first; g <= 25; g += 5)
      if(d == TFix_RolledBack(y, m, g, skipJpHolidays)) return true;
   return false;
}

// True when today (JST) is a day the filter admits. `why` names the class.
bool TFix_DayAllowed(const datetime jstNow, const TokyoFixDayFilter filter, const bool skipJpHolidays, string &why)
{
   MqlDateTime t; TimeToStruct(jstNow, t);
   why = "";
   if(!TFix_IsWeekday(t.year, t.mon, t.day)) { why = "weekend"; return false; }
   if(skipJpHolidays && TFix_IsJpHoliday(t.year, t.mon, t.day)) { why = "JP holiday - no fix"; return false; }
   const bool me = TFix_IsMonthEnd(t.year, t.mon, t.day, skipJpHolidays);
   if(me) why = "monthend";
   switch(filter)
   {
      case TFIX_ALL_DAYS:        if(why == "") why = "weekday"; return true;
      case TFIX_MONTHEND_ONLY:   if(!me) why = "not monthend"; return me;
      case TFIX_STRONG_DAYS:
      {
         const bool g = TFix_IsGotobi(t.year, t.mon, t.day, true, skipJpHolidays);
         if(g && !me) why = StringFormat("gotobi(%d)", t.day);
         if(!g && !me) why = "not a strong day";
         return g || me;
      }
      default:
      {
         const bool g = TFix_IsGotobi(t.year, t.mon, t.day, false, skipJpHolidays);
         if(g && !me) why = StringFormat("gotobi(%d)", t.day);
         if(!g && !me) why = "not gotobi";
         return g || me;
      }
   }
}

// Minutes since 00:00 JST for the given JST time.
int TFix_MinutesOfDay(const datetime jst)
{
   MqlDateTime t; TimeToStruct(jst, t);
   return t.hour * 60 + t.min;
}

int TFix_Ymd(const datetime jst)
{
   MqlDateTime t; TimeToStruct(jst, t);
   return t.year * 10000 + t.mon * 100 + t.day;
}


// ------------------------------------------------------------------
// Japanese public + bank holidays, rule-based (2010-2099). No banks, no
// fix: the engine treats these like weekends, both for skipping the day
// and for rolling a gotobi flow back to the previous business day.
// Mirrors scratchpad/study/jp_holidays.py, checked against 2019-2026.
// ------------------------------------------------------------------
int TFix_NthMonday(const int y, const int m, const int n)
{
   const int w = TFix_DayOfWeek(y, m, 1);            // 0 = Sunday
   const int firstMonday = 1 + ((8 - w) % 7);
   return firstMonday + 7 * (n - 1);
}

int TFix_Equinox(const int y, const bool vernal)
{
   const double base = vernal ? 20.8431 : 23.2488;
   return (int)MathFloor(base + 0.242194 * (y - 1980) - MathFloor((y - 1980) / 4.0));
}

// The statutory holidays before substitute / citizens' days are applied.
bool TFix_IsBaseHoliday(const int y, const int m, const int d)
{
   if(m == 1  && d == 1)  return true;
   if(m == 2  && d == 11) return true;
   if(m == 4  && d == 29) return true;
   if(m == 5  && (d == 3 || d == 4 || d == 5)) return true;
   if(m == 11 && (d == 3 || d == 23)) return true;
   if(m == 1  && d == TFix_NthMonday(y, 1, 2)) return true;      // Coming of Age
   if(m == 9  && d == TFix_NthMonday(y, 9, 3)) return true;      // Respect for the Aged
   if(m == 3  && d == TFix_Equinox(y, true))  return true;
   if(m == 9  && d == TFix_Equinox(y, false)) return true;
   if(y >= 2020 && m == 2 && d == 23) return true;               // Emperor's Birthday (Naruhito)
   if(y <= 2018 && m == 12 && d == 23) return true;              // Emperor's Birthday (Akihito)
   if(y == 2020)                                                 // Olympic shifts
   {
      if(m == 7 && (d == 23 || d == 24)) return true;
      if(m == 8 && d == 10) return true;
   }
   else if(y == 2021)
   {
      if(m == 7 && (d == 22 || d == 23)) return true;
      if(m == 8 && d == 8) return true;
   }
   else
   {
      if(y >= 2016 && m == 8 && d == 11) return true;            // Mountain Day
      if(m == 7  && d == TFix_NthMonday(y, 7, 3)) return true;   // Marine Day
      if(m == 10 && d == TFix_NthMonday(y, 10, 2)) return true;  // Sports Day
   }
   if(y == 2019 && ((m == 5 && d == 1) || (m == 10 && d == 22))) return true;   // enthronement
   return false;
}

bool TFix_IsJpHoliday(const int y, const int m, const int d)
{
   if(TFix_IsBaseHoliday(y, m, d)) return true;
   if(m == 12 && d == 31) return true;                            // bank holidays
   if(m == 1 && (d == 2 || d == 3)) return true;
   // citizens' holiday: a Mon-Sat day between two base holidays
   if(TFix_DayOfWeek(y, m, d) != 0 && d > 1 && d < TFix_DaysInMonth(y, m) &&
      TFix_IsBaseHoliday(y, m, d - 1) && TFix_IsBaseHoliday(y, m, d + 1)) return true;
   // substitute holiday: walk back over consecutive holidays; if the run started on a Sunday base holiday, today is the substitute
   if(TFix_DayOfWeek(y, m, d) != 0)
   {
      int k = d - 1;
      while(k >= 1 && TFix_IsBaseHoliday(y, m, k))
      {
         if(TFix_DayOfWeek(y, m, k) == 0) return true;
         k--;
      }
   }
   return false;
}

// A business day for the fix: Mon-Fri and (when asked) not a Japanese holiday.
bool TFix_IsBusinessDay(const int y, const int m, const int d, const bool skipJpHolidays)
{
   if(!TFix_IsWeekday(y, m, d)) return false;
   return !(skipJpHolidays && TFix_IsJpHoliday(y, m, d));
}

#endif // KUROSAWA_TOKYOFIX_MQH
