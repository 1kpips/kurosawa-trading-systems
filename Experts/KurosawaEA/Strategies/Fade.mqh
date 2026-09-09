//+------------------------------------------------------------------+
//| File: Strategies/Fade.mqh                                        |
//| Type: Strategy module (pure signal judgment, NO execution)       |
//| Ver : 0.1.0                                                      |
//|                                                                  |
//| Fade the D1 Breakout analyzer's strong readings.                 |
//|                                                                  |
//| Where this comes from                                            |
//| - 2026-09-09 forward-return study: the three D1 analyzers on the |
//|   Signals page are anti-predictive over 10 years x 10 pairs, and |
//|   the stronger the reading the worse the forward return. Fading  |
//|   a Breakout reading of strength >= 80 returned ~+74 bp per event|
//|   on a 5-day hold entered at the next open, 65% hit, in both     |
//|   half-decades. See d1-signal-forward-return-study-2026-09-09.md.|
//|                                                                  |
//| Contract                                                         |
//| - The READING is computed exactly as Signals/D1_Signal_Breakout  |
//|   .mq5 computes it (20-bar prior range, ATR expansion, strength  |
//|   55 + dist*30 + atr*15). This module never changes that rule;   |
//|   the analyzer and the engine must agree on what "strength 80"   |
//|   means, or the study does not apply.                            |
//| - The SIGNAL is the opposite of the reading: LONG reading -> sell,|
//|   SHORT reading -> buy, when strength >= min_strength.           |
//| - Closed bar at `shift` (1 = the bar that just closed). No       |
//|   execution, no state. Distances in POINTS.                      |
//+------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_FADE_MQH
#define KUROSAWA_FADE_MQH

enum FadeResult
{
   FADE_OK = 0,
   FADE_ERROR_DATA,
   FADE_BLOCK_NO_READING,   // analyzer reads FLAT: no breakout to fade
   FADE_BLOCK_WEAK,         // reading below min_strength
   FADE_BLOCK_SIDE          // that side is switched off
};

struct FadeInputs
{
   int    lookback_bars;    // analyzer: prior-range window (20)
   int    atr_period;       // analyzer: ATR(14)
   int    atr_avg_bars;     // analyzer: average ATR window (20)
   double min_atr_ratio;    // analyzer: expansion threshold (1.0)
   int    min_strength;     // fade at or above this reading (80)
   bool   allow_longs;
   bool   allow_shorts;
};

struct FadeSignal
{
   bool   buy;
   bool   sell;

   // the analyzer's reading, for the record
   string reading;          // LONG | SHORT | FLAT
   int    strength;
   double atr_points;
   double range_high;
   double range_low;
   double close1;
   double dist_by_atr;
   double atr_ratio;
};

double Fade_Clamp01(const double x) { return (x < 0.0 ? 0.0 : (x > 1.0 ? 1.0 : x)); }

// ------------------------------------------------------------------
// The analyzer's reading, from values. Mirrors D1_Signal_Breakout.mq5.
// ------------------------------------------------------------------
void Fade_Reading(const double close1, const double hi, const double lo,
                  const double atr1, const double atrAvg, const double minAtrRatio,
                  string &direction, int &strength, double &distByAtr, double &atrRatio)
{
   atrRatio = (atrAvg > 0.0) ? atr1 / atrAvg : 0.0;
   direction = "FLAT";
   double dist = 0.0;
   if(close1 > hi)      { direction = "LONG";  dist = close1 - hi; }
   else if(close1 < lo) { direction = "SHORT"; dist = lo - close1; }

   distByAtr = (atr1 > 0.0) ? dist / atr1 : 0.0;
   const double distScore = Fade_Clamp01(distByAtr / 0.75);
   const double atrScore  = Fade_Clamp01((atrRatio - minAtrRatio) / 0.50);

   double raw = (direction != "FLAT") ? 55.0 + distScore * 30.0 + atrScore * 15.0
                                      : 35.0 + atrScore * 10.0;
   strength = (int)MathRound(MathMax(0.0, MathMin(100.0, raw)));
}

// ------------------------------------------------------------------
FadeResult Fade_EvaluateValues(const double close1, const double hi, const double lo,
                               const double atr1, const double atrAvg, const double pt,
                               const FadeInputs &inps, FadeSignal &out)
{
   out.buy = false; out.sell = false; out.reading = "FLAT"; out.strength = 0;
   out.close1 = close1; out.range_high = hi; out.range_low = lo;
   out.atr_points = (pt > 0.0) ? atr1 / pt : 0.0; out.dist_by_atr = 0.0; out.atr_ratio = 0.0;

   if(!MathIsValidNumber(close1) || !MathIsValidNumber(hi) || !MathIsValidNumber(lo) ||
      !MathIsValidNumber(atr1) || !MathIsValidNumber(atrAvg) || pt <= 0.0)
      return FADE_ERROR_DATA;
   if(close1 <= 0.0 || hi <= lo || atr1 <= 0.0) return FADE_ERROR_DATA;

   Fade_Reading(close1, hi, lo, atr1, atrAvg, inps.min_atr_ratio,
                out.reading, out.strength, out.dist_by_atr, out.atr_ratio);

   if(out.reading == "FLAT") return FADE_BLOCK_NO_READING;
   if(out.strength < inps.min_strength) return FADE_BLOCK_WEAK;

   // Fade: the opposite of the reading.
   if(out.reading == "LONG")
   {
      if(!inps.allow_shorts) return FADE_BLOCK_SIDE;
      out.sell = true;
   }
   else
   {
      if(!inps.allow_longs) return FADE_BLOCK_SIDE;
      out.buy = true;
   }
   return FADE_OK;
}

// ------------------------------------------------------------------
// Read the bars and the ATR buffer at `shift`, then judge.
// ------------------------------------------------------------------
FadeResult Fade_EvaluateHandles(const int atrH, const string sym, const ENUM_TIMEFRAMES tf,
                                const int shift, const double pt,
                                const FadeInputs &inps, FadeSignal &out)
{
   if(atrH == INVALID_HANDLE || inps.lookback_bars <= 0 || inps.atr_avg_bars <= 0) return FADE_ERROR_DATA;

   const double close1 = iClose(sym, tf, shift);

   // Prior range: the lookback bars BEFORE the signal bar (analyzer uses shifts 2..lookback+1).
   double highs[], lows[];
   ArraySetAsSeries(highs, true); ArraySetAsSeries(lows, true);
   if(CopyHigh(sym, tf, shift + 1, inps.lookback_bars, highs) != inps.lookback_bars) return FADE_ERROR_DATA;
   if(CopyLow (sym, tf, shift + 1, inps.lookback_bars, lows)  != inps.lookback_bars) return FADE_ERROR_DATA;
   double hi = highs[0], lo = lows[0];
   for(int i = 1; i < inps.lookback_bars; i++) { if(highs[i] > hi) hi = highs[i]; if(lows[i] < lo) lo = lows[i]; }

   // ATR at the signal bar and its average over the bars before it.
   double atr[];
   ArraySetAsSeries(atr, true);
   const int need = inps.atr_avg_bars + 1;
   if(CopyBuffer(atrH, 0, shift, need, atr) != need) return FADE_ERROR_DATA;
   const double atr1 = atr[0];
   double sum = 0.0;
   for(int i = 1; i <= inps.atr_avg_bars; i++) sum += atr[i];
   const double atrAvg = sum / inps.atr_avg_bars;

   return Fade_EvaluateValues(close1, hi, lo, atr1, atrAvg, pt, inps, out);
}

#endif // KUROSAWA_FADE_MQH
