//+------------------------------------------------------------------+
//| File: Strategies/TrendPullback.mqh                               |
//| Type: Strategy Module (independent)                              |
//|                                                                  |
//| Description                                                      |
//| TrendPullback signal logic (signal generation only).             |
//| - Higher-TF bias: EMA(fast/slow) gap                             |
//| - Entry-TF reclaim: close crosses back over entry EMA            |
//| - RSI confirmation, taken on the PULLBACK bar (shift+1)          |
//| - ATR volatility window gate (POINTS)                            |
//|                                                                  |
//| Notes                                                            |
//| - Closed-bar evaluation only (caller controls shift)             |
//| - No trade execution / session / spread / risk logic             |
//| - No KurosawaHelpers dependency                                  |
//| - Caller passes `point` (usually _Point)                         |
//| - All distance-based values are in POINTS (_Point units)         |
//+------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_STRATEGY_TRENDPULLBACK_MQH
#define KUROSAWA_STRATEGY_TRENDPULLBACK_MQH

// ------------------------------------------------------------------
// Result codes
// ------------------------------------------------------------------
enum TrendPullbackResult
{
   TRENDPB_OK = 0,
   TRENDPB_BLOCK_ATR,
   TRENDPB_BLOCK_NO_BIAS,
   TRENDPB_BLOCK_NO_SIGNAL,
   TRENDPB_ERROR_DATA
};

// ------------------------------------------------------------------
// Inputs bundle (POINTS semantics)
// ------------------------------------------------------------------
struct TrendPullbackInputs
{
   // ATR window (POINTS). 0 disables each side.
   double atr_min_points;
   double atr_max_points;

   // RSI confirmation, measured on the PULLBACK bar (shift+1), not the reclaim
   // bar. See TrendPullback_EvaluateHandles for why.
   double rsi_buy_max;      // buy when the pullback bar's RSI was <= this
   double rsi_sell_min;     // sell when the pullback bar's RSI was >= this

   // Bias gap threshold (POINTS). 0 => classic fast>slow bias.
   double bias_min_gap_points;
};

// ------------------------------------------------------------------
// Output bundle
// ------------------------------------------------------------------
struct TrendPullbackSignal
{
   bool   buy;
   bool   sell;
   double atr_points;
};

// ------------------------------------------------------------------
// Internal: read one value from indicator buffer
// ------------------------------------------------------------------
bool TrendPullback_ReadBuffer1(const int handle, const int buffer, const int shift, double &outVal)
{
   outVal = 0.0;
   if(handle == INVALID_HANDLE) return false;

   double tmp[];
   ArraySetAsSeries(tmp, true);

   if(CopyBuffer(handle, buffer, shift, 1, tmp) != 1)
      return false;

   outVal = tmp[0];
   return MathIsValidNumber(outVal);
}

// ------------------------------------------------------------------
// Core logic using already-read values (closed-bar values)
// All EMA values are in PRICE; conversions to points are done via `point`.
// ------------------------------------------------------------------
TrendPullbackResult TrendPullback_EvaluateValues(
   const double biasEmaFast, const double biasEmaSlow,
   const double entryEma_1,  const double entryEma_2,
   const double close_1,     const double close_2,
   const double rsiPullback,
   const double atr_points,
   const double point,
   const TrendPullbackInputs &inps,
   TrendPullbackSignal &outSig)
{
   outSig.buy = false;
   outSig.sell = false;
   outSig.atr_points = atr_points;

   // Basic data sanity
   if(point <= 0.0) return TRENDPB_ERROR_DATA;
   if(!MathIsValidNumber(atr_points) || atr_points <= 0.0) return TRENDPB_ERROR_DATA;
   if(!MathIsValidNumber(rsiPullback) || rsiPullback < 0.0 || rsiPullback > 100.0) return TRENDPB_ERROR_DATA;

   // ATR window gate
   if((inps.atr_min_points > 0.0 && atr_points < inps.atr_min_points) ||
      (inps.atr_max_points > 0.0 && atr_points > inps.atr_max_points))
      return TRENDPB_BLOCK_ATR;

   // Higher-TF bias: EMA gap in points
   const double biasDiffPts = (biasEmaFast - biasEmaSlow) / point;
   const bool upBias   = (biasDiffPts >  inps.bias_min_gap_points);
   const bool downBias = (biasDiffPts < -inps.bias_min_gap_points);

   if(!upBias && !downBias)
      return TRENDPB_BLOCK_NO_BIAS;

   // Entry-TF reclaim pattern:
   // - Up: previous close at/below EMA, then close crosses above EMA
   // - Down: previous close at/above EMA, then close crosses below EMA
   const bool reclaimedUp   = (close_2 <= entryEma_2 && close_1 > entryEma_1);
   const bool reclaimedDown = (close_2 >= entryEma_2 && close_1 < entryEma_1);

   // rsiPullback is read on the PULLBACK bar, so "RSI was oversold, then price
   // reclaimed the EMA" - the two conditions now agree instead of fighting.
   if(upBias && reclaimedUp && rsiPullback <= inps.rsi_buy_max)
      outSig.buy = true;

   if(downBias && reclaimedDown && rsiPullback >= inps.rsi_sell_min)
      outSig.sell = true;

   // Safety: never allow both directions at once
   if(outSig.buy && outSig.sell)
   {
      outSig.buy = false;
      outSig.sell = false;
   }

   return (outSig.buy || outSig.sell) ? TRENDPB_OK : TRENDPB_BLOCK_NO_SIGNAL;
}

// ------------------------------------------------------------------
// Handle-based evaluation (closed-bar)
// Expected handles (buffer 0):
// - bias EMA fast/slow
// - entry EMA
// - RSI
// - ATR
//
// `shift` should refer to a CLOSED bar index (usually 1).
// ------------------------------------------------------------------
TrendPullbackResult TrendPullback_EvaluateHandles(
   const int hBiasFast,
   const int hBiasSlow,
   const int hEntryEmaLocal,
   const int hRsiLocal,      // renamed: avoid hiding globals
   const int hAtrLocal,      // renamed: avoid hiding globals
   const string symbol,
   const ENUM_TIMEFRAMES entryTf,
   const int shift,
   const double point,
   const TrendPullbackInputs &inps,
   TrendPullbackSignal &outSig)
{
   if(point <= 0.0) return TRENDPB_ERROR_DATA;
   if(shift < 1)    return TRENDPB_ERROR_DATA; // require closed bar index

   // Bias EMAs (use CLOSED bar on bias TF => shift=1)
   double bFast = 0.0, bSlow = 0.0;
   if(!TrendPullback_ReadBuffer1(hBiasFast, 0, 1, bFast)) return TRENDPB_ERROR_DATA;
   if(!TrendPullback_ReadBuffer1(hBiasSlow, 0, 1, bSlow)) return TRENDPB_ERROR_DATA;

   // Entry EMA on requested closed bar and its previous
   double e1 = 0.0, e2 = 0.0;
   if(!TrendPullback_ReadBuffer1(hEntryEmaLocal, 0, shift,   e1)) return TRENDPB_ERROR_DATA;
   if(!TrendPullback_ReadBuffer1(hEntryEmaLocal, 0, shift+1, e2)) return TRENDPB_ERROR_DATA;

   // RSI is read on the PULLBACK bar (shift+1), NOT the reclaim bar.
   //
   // The reclaim trigger below requires close_1 to cross back ABOVE the entry
   // EMA. On that bar RSI is by definition recovering through ~50, so demanding
   // rsi <= 45 on the SAME bar fights the trigger: the two conditions can only
   // both hold on the weakest possible reclaims, which is why this EA produced
   // almost no trades. Reading the previous bar restores the intended meaning -
   // "RSI was oversold on the pullback, and then price reclaimed the EMA" - and
   // leaves InpRsiBuyBelow / InpRsiSellAbove meaning exactly what they say.
   double rsiPullback = 0.0, atrPrice = 0.0;
   if(!TrendPullback_ReadBuffer1(hRsiLocal, 0, shift + 1, rsiPullback)) return TRENDPB_ERROR_DATA;
   if(!TrendPullback_ReadBuffer1(hAtrLocal, 0, shift,     atrPrice))    return TRENDPB_ERROR_DATA;
   if(!MathIsValidNumber(atrPrice) || atrPrice <= 0.0)           return TRENDPB_ERROR_DATA;

   // Close prices (entry TF, closed bars)
   const double c1 = iClose(symbol, entryTf, shift);
   const double c2 = iClose(symbol, entryTf, shift + 1);
   if(!MathIsValidNumber(c1) || !MathIsValidNumber(c2) || c1 <= 0.0 || c2 <= 0.0)
      return TRENDPB_ERROR_DATA;

   // Convert ATR from PRICE to POINTS
   const double atr_points = atrPrice / point;

   return TrendPullback_EvaluateValues(
      bFast, bSlow,
      e1, e2,
      c1, c2,
      rsiPullback,
      atr_points,
      point,
      inps,
      outSig
   );
}
#endif // KUROSAWA_STRATEGY_TRENDPULLBACK_MQH
