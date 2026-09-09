//+------------------------------------------------------------------+
//| File: Strategies/Breakout.mqh                                    |
//| Type: Strategy module (pure signal judgment, NO execution)       |
//| Ver : 0.1.0                                                      |
//|                                                                  |
//| London-range breakout, traded in the New York window.            |
//|                                                                  |
//| Where this comes from                                            |
//| - 2026-09-08/09: mean reversion (RangeRevert) is proven in the   |
//|   07:00-13:00 server window and fails in 15:00-21:00, where its  |
//|   lower-band longs were stopped 35 times against 3 targets on    |
//|   EURJPY. Breaks in that window CONTINUE. Both trend entries in  |
//|   the suite fail in both windows. So: define the range where the |
//|   market ranges, and trade its break where the market breaks.    |
//|                                                                  |
//| Contract                                                         |
//| - All hours are BROKER SERVER hours (the engine clock). The      |
//|   engine passes the server-day start; the module reads the bars  |
//|   of the range window and judges ONE closed bar (shift=1).       |
//| - No execution, no state. One attempt per side per day is the    |
//|   engine's job (it owns the day state).                          |
//| - All distances are POINTS.                                      |
//+------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_BREAKOUT_MQH
#define KUROSAWA_BREAKOUT_MQH

enum BreakoutResult
{
   BREAKOUT_OK = 0,
   BREAKOUT_ERROR_DATA,
   BREAKOUT_BLOCK_NO_RANGE,     // range window not complete / no bars
   BREAKOUT_BLOCK_RANGE_WIDE,   // morning already trended
   BREAKOUT_BLOCK_ATR,
   BREAKOUT_BLOCK_ADX,
   BREAKOUT_BLOCK_NO_SIGNAL,
   BREAKOUT_BLOCK_AMBIG
};

struct BreakoutInputs
{
   int    range_start_hour;     // server hour, inclusive
   int    range_end_hour;       // server hour, exclusive

   double break_buffer_atr;     // close must clear the range by this many ATR
   double max_range_atr;        // 0 disables: skip the day if range > this many ATR

   double atr_min_points;       // 0 disables
   double atr_max_points;       // 0 disables

   bool   use_adx_filter;
   double adx_min_to_trade;     // 0 disables
   double adx_max_to_trade;     // 0 disables
   bool   require_adx_rising;   // adx(shift) > adx(shift+1)

   bool   require_fresh_break;  // previous close was still inside the buffered range
   bool   allow_longs;
   bool   allow_shorts;
};

struct BreakoutSignal
{
   bool   buy;
   bool   sell;

   double atr_points;
   double range_high;
   double range_low;
   double range_mid;
   int    range_bars;

   // debug
   double close1;
   double close2;
   double adx;
   double adx_prev;
};

// ------------------------------------------------------------------
// Range of the window [dayStart + startHour, dayStart + endHour) in
// PRICE units, from the bars of `tf`. dayStart is 00:00 of the server day.
// ------------------------------------------------------------------
bool Breakout_ComputeRange(const string sym,
                           const ENUM_TIMEFRAMES tf,
                           const datetime dayStart,
                           const int startHour,
                           const int endHour,
                           double &hi, double &lo, int &bars)
{
   hi = 0.0; lo = 0.0; bars = 0;
   if(startHour < 0 || endHour <= startHour || endHour > 24) return false;

   const datetime from = dayStart + (datetime)(startHour * 3600);
   const datetime to   = dayStart + (datetime)(endHour * 3600) - 1;   // bar OPEN times inside the window

   MqlRates r[];
   const int n = CopyRates(sym, tf, from, to, r);
   if(n <= 0) return false;

   hi = r[0].high; lo = r[0].low;
   for(int i = 1; i < n; i++)
   {
      if(r[i].high > hi) hi = r[i].high;
      if(r[i].low  < lo) lo = r[i].low;
   }
   bars = n;
   return (hi > lo);
}

// ------------------------------------------------------------------
// Pure judgment on values already read.
// ------------------------------------------------------------------
BreakoutResult Breakout_EvaluateValues(
   const double close1,
   const double close2,
   const double atr_points,
   const double adx,
   const double adxPrev,
   const double rangeHigh,
   const double rangeLow,
   const int    rangeBars,
   const double pt,
   const BreakoutInputs &inps,
   BreakoutSignal &out)
{
   out.buy = false; out.sell = false;
   out.atr_points = atr_points;
   out.range_high = rangeHigh; out.range_low = rangeLow; out.range_bars = rangeBars;
   out.range_mid  = (rangeHigh + rangeLow) * 0.5;
   out.close1 = close1; out.close2 = close2; out.adx = adx; out.adx_prev = adxPrev;

   if(!MathIsValidNumber(close1) || !MathIsValidNumber(close2) || !MathIsValidNumber(atr_points) ||
      !MathIsValidNumber(rangeHigh) || !MathIsValidNumber(rangeLow) || pt <= 0.0)
      return BREAKOUT_ERROR_DATA;
   if(close1 <= 0.0 || atr_points <= 0.0) return BREAKOUT_ERROR_DATA;

   if(rangeBars <= 0 || rangeHigh <= rangeLow) return BREAKOUT_BLOCK_NO_RANGE;

   // 1) ATR window
   if(inps.atr_min_points > 0.0 && atr_points < inps.atr_min_points) return BREAKOUT_BLOCK_ATR;
   if(inps.atr_max_points > 0.0 && atr_points > inps.atr_max_points) return BREAKOUT_BLOCK_ATR;

   // 2) The morning must have been a range, not a trend
   if(inps.max_range_atr > 0.0)
   {
      const double widthPts = (rangeHigh - rangeLow) / pt;
      if(widthPts > inps.max_range_atr * atr_points) return BREAKOUT_BLOCK_RANGE_WIDE;
   }

   // 3) ADX: strength and, optionally, direction of change
   if(inps.use_adx_filter)
   {
      if(!MathIsValidNumber(adx) || adx <= 0.0) return BREAKOUT_ERROR_DATA;
      if(inps.adx_min_to_trade > 0.0 && adx < inps.adx_min_to_trade) return BREAKOUT_BLOCK_ADX;
      if(inps.adx_max_to_trade > 0.0 && adx > inps.adx_max_to_trade) return BREAKOUT_BLOCK_ADX;
      if(inps.require_adx_rising)
      {
         if(!MathIsValidNumber(adxPrev)) return BREAKOUT_ERROR_DATA;
         if(adx <= adxPrev) return BREAKOUT_BLOCK_ADX;
      }
   }

   // 4) Break levels
   const double buffer   = inps.break_buffer_atr * atr_points * pt;   // PRICE
   const double upLevel  = rangeHigh + buffer;
   const double dnLevel  = rangeLow  - buffer;

   bool buy  = inps.allow_longs  && (close1 > upLevel);
   bool sell = inps.allow_shorts && (close1 < dnLevel);

   if(inps.require_fresh_break)
   {
      if(buy  && close2 > upLevel) buy  = false;   // previous bar already closed beyond: not the first close out
      if(sell && close2 < dnLevel) sell = false;
   }

   if(buy && sell) return BREAKOUT_BLOCK_AMBIG;     // impossible unless the range is degenerate
   out.buy = buy; out.sell = sell;

   return (buy || sell) ? BREAKOUT_OK : BREAKOUT_BLOCK_NO_SIGNAL;
}

// ------------------------------------------------------------------
// Read the closed bar at `shift`, the range of the day, and judge.
// ------------------------------------------------------------------
BreakoutResult Breakout_EvaluateHandles(
   const int atrH,
   const int adxH,
   const string sym,
   const ENUM_TIMEFRAMES tf,
   const int shift,
   const double pt,
   const datetime dayStart,
   const BreakoutInputs &inps,
   BreakoutSignal &out)
{
   double atr[], adx[];
   ArrayResize(atr, 1);
   ArrayResize(adx, 2);
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(adx, true);

   if(CopyBuffer(atrH, 0, shift, 1, atr) != 1) return BREAKOUT_ERROR_DATA;
   double adxNow = 0.0, adxPrev = 0.0;
   if(inps.use_adx_filter)
   {
      if(CopyBuffer(adxH, 0, shift, 2, adx) != 2) return BREAKOUT_ERROR_DATA;
      adxNow = adx[0]; adxPrev = adx[1];
   }

   const double close1 = iClose(sym, tf, shift);
   const double close2 = iClose(sym, tf, shift + 1);

   double hi, lo; int bars;
   if(!Breakout_ComputeRange(sym, tf, dayStart, inps.range_start_hour, inps.range_end_hour, hi, lo, bars))
   {
      out.buy = false; out.sell = false; out.range_bars = 0;
      return BREAKOUT_BLOCK_NO_RANGE;
   }

   return Breakout_EvaluateValues(close1, close2, atr[0] / pt, adxNow, adxPrev, hi, lo, bars, pt, inps, out);
}

#endif // KUROSAWA_BREAKOUT_MQH
