//+------------------------------------------------------------------+
//| File: Strategies/TokyoFix.mqh                                    |
//| Type: Strategy module (pure, no MT5 trade calls)                 |
//| Ver : 0.1.0                                                      |
//|                                                                  |
//| Tokyo fix (09:55 JST) flow fade.                                 |
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
// Day classification on the JST date. Business day = Mon-Fri; no
// holiday calendar (the study that justifies the engine used none).
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

// The business day on which a calendar-date flow settles: the date itself,
// or the previous weekday when it falls on a weekend.
int TFix_RolledBack(const int y, const int m, int d)
{
   while(d > 1 && !TFix_IsWeekday(y, m, d)) d--;
   return d;
}

bool TFix_IsMonthEnd(const int y, const int m, const int d)
{
   return TFix_IsWeekday(y, m, d) && d == TFix_RolledBack(y, m, TFix_DaysInMonth(y, m));
}

bool TFix_IsGotobi(const int y, const int m, const int d, const bool strongOnly)
{
   if(!TFix_IsWeekday(y, m, d)) return false;
   const int first = strongOnly ? 15 : 5;
   for(int g = first; g <= 25; g += 5)
      if(d == TFix_RolledBack(y, m, g)) return true;
   return false;
}

// True when today (JST) is a day the filter admits. `why` names the class.
bool TFix_DayAllowed(const datetime jstNow, const TokyoFixDayFilter filter, string &why)
{
   MqlDateTime t; TimeToStruct(jstNow, t);
   why = "";
   if(!TFix_IsWeekday(t.year, t.mon, t.day)) { why = "weekend"; return false; }
   const bool me = TFix_IsMonthEnd(t.year, t.mon, t.day);
   if(me) why = "monthend";
   switch(filter)
   {
      case TFIX_ALL_DAYS:        if(why == "") why = "weekday"; return true;
      case TFIX_MONTHEND_ONLY:   if(!me) why = "not monthend"; return me;
      case TFIX_STRONG_DAYS:
      {
         const bool g = TFix_IsGotobi(t.year, t.mon, t.day, true);
         if(g && !me) why = StringFormat("gotobi(%d)", t.day);
         if(!g && !me) why = "not a strong day";
         return g || me;
      }
      default:
      {
         const bool g = TFix_IsGotobi(t.year, t.mon, t.day, false);
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

#endif // KUROSAWA_TOKYOFIX_MQH
