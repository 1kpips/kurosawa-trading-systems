//+------------------------------------------------------------------+
//| File: Strategies/LondonFix.mqh                                   |
//| Type: Strategy module (pure, no MT5 trade calls)                 |
//| Ver : 0.1.0                                                      |
//|                                                                  |
//| London 16:00 fix, month-end: FADE the move into the fix.         |
//|                                                                  |
//| What was measured (2026-09-10/11, OANDA M5 bars 2019-2026)       |
//| - On the last business day of the month, GBPUSD drifts into the  |
//|   16:00 London fix (median |15:00->16:00 move| 20 pips) and      |
//|   gives part of it back: trading AGAINST that move from the      |
//|   16:00 open to the 16:30 open made +5.2 pips a trade, 67 % hit, |
//|   t 3.8, 91 events, every year 2019-2026 positive. EURGBP +1.7   |
//|   pips (t 2.2). EURUSD nothing. Ordinary days: at the spread.    |
//| - The cause: month-end portfolio rebalancing is executed at the  |
//|   WM/Reuters 4pm fix; the flow is pre-positioned into it and     |
//|   unwound after. Same shape as the Tokyo fix, different clock,   |
//|   and the side is not fixed - it is whatever the pre-fix move    |
//|   was, reversed.                                                  |
//|                                                                  |
//| Clock                                                            |
//| - The fix is a London wall-clock event. The broker server runs   |
//|   New York + 7 h; London = UTC + 1 during UK summer time (last    |
//|   Sunday of March 01:00 UTC to last Sunday of October 01:00 UTC).|
//|   The two DST calendars differ by a couple of weeks in spring    |
//|   and autumn, so both are computed exactly.                      |
//+------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_LONDONFIX_MQH
#define KUROSAWA_LONDONFIX_MQH

#include "TokyoFix.mqh"   // calendar helpers: day-of-week, NY DST, business days, month-end

enum FixSideMode
{
   FIX_SIDE_FIXED    = 0,   // always InpSide (the Tokyo way)
   FIX_SIDE_FADE_PRE = 1    // opposite to the move over the pre-window (the London month-end way)
};

// Last Sunday of a month.
int LFix_LastSunday(const int y, const int m)
{
   int d = TFix_DaysInMonth(y, m);
   while(TFix_DayOfWeek(y, m, d) != 0) d--;
   return d;
}

// UK summer time, judged on UTC time.
bool LFix_UkDstActive(const datetime utc)
{
   MqlDateTime t; TimeToStruct(utc, t);
   if(t.mon < 3 || t.mon > 10) return false;
   if(t.mon > 3 && t.mon < 10) return true;
   if(t.mon == 3)
   {
      const int d = LFix_LastSunday(t.year, 3);
      return (t.day > d) || (t.day == d && t.hour >= 1);
   }
   const int d = LFix_LastSunday(t.year, 10);   // October
   return (t.day < d) || (t.day == d && t.hour < 1);
}

// Server (NY + 7h) -> UTC -> London.
datetime LFix_ServerToUtc(const datetime server)
{
   const datetime ny = server - 7 * 3600;
   return server - (TFix_NyDstActive(ny) ? 3 : 2) * 3600;
}

datetime LFix_ServerToLondon(const datetime server)
{
   const datetime utc = LFix_ServerToUtc(server);
   return utc + (LFix_UkDstActive(utc) ? 1 : 0) * 3600;
}

// The side to trade: -1 short, +1 long, 0 = no trade (pre-move too small / no data).
// `preMovePips` is the move over the pre-window in pips (signed).
int LFix_Side(const FixSideMode mode, const int fixedSide, const double preMovePips, const double minPreMovePips)
{
   if(mode == FIX_SIDE_FIXED) return fixedSide;
   if(MathAbs(preMovePips) < MathMax(minPreMovePips, 0.0001)) return 0;
   return (preMovePips > 0.0) ? -1 : +1;
}

#endif // KUROSAWA_LONDONFIX_MQH
