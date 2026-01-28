//+------------------------------------------------------------------+
//| File: Strategies/TrendPullback.mqh                               |
//| Type: Strategy Module (independent)                              |
//|                                                                  |
//| Description                                                      |
//| TrendPullback strategy logic (signal generation only).           |
//| - Higher-TF trend bias (EMA fast/slow)                           |
//| - Entry-TF pullback + reclaim pattern                            |
//| - RSI confirmation                                               |
//| - ATR volatility window (POINTS)                                 |
//|                                                                  |
//| Notes                                                            |
//| - Pure signal evaluation on CLOSED bars                           |
//| - No trade execution / no session / no spread / no risk logic    |
//| - No KurosawaHelpers dependency                                   |
//| - Caller passes `point` (usually _Point)                          |
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
// Inputs bundle (Excel-aligned semantics)
// ------------------------------------------------------------------
struct TrendPullbackInputs
{
   // ATR window (POINTS)
   double atr_min_points;   // 0 disables
   double atr_max_points;   // 0 disables

   // RSI
   double rsi_buy_max;      // buy when RSI <= this
   double rsi_sell_min;     // sell when RSI >= this
   
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
// Internal: read 1 value from indicator buffer
// ------------------------------------------------------------------
bool TrendPullback_ReadBuffer1(const int handle, const int buffer, const int shift, double &outVal)
{
   outVal = 0.0;
   if(handle == INVALID_HANDLE) return false;

   double v[];
   ArraySetAsSeries(v, true);

   if(CopyBuffer(handle, buffer, shift, 1, v) != 1)
      return false;

   outVal = v[0];
   return true;
}

// ------------------------------------------------------------------
// Core logic using already-read values
// ------------------------------------------------------------------
TrendPullbackResult TrendPullback_EvaluateValues(
   const double biasEmaFast, const double biasEmaSlow,
   const double entryEma_1, const double entryEma_2,
   const double close_1, const double close_2,
   const double rsi, const double atr_points, const double point,
   const TrendPullbackInputs &inps, TrendPullbackSignal &outSig)
{
   outSig.buy = false;
   outSig.sell = false;
   outSig.atr_points = atr_points;

   if(point <= 0.0) return TRENDPB_ERROR_DATA;
   if(!MathIsValidNumber(atr_points) || atr_points <= 0.0) return TRENDPB_ERROR_DATA;
   if(!MathIsValidNumber(rsi) || rsi < 0.0 || rsi > 100.0) return TRENDPB_ERROR_DATA;

   // ATR window
   if((inps.atr_min_points > 0.0 && atr_points < inps.atr_min_points) ||
      (inps.atr_max_points > 0.0 && atr_points > inps.atr_max_points))
      return TRENDPB_BLOCK_ATR;

   // Bias gap in points
   const double biasDiffPts = (biasEmaFast - biasEmaSlow) / point;
   const bool upBias   = (biasDiffPts >  inps.bias_min_gap_points);
   const bool downBias = (biasDiffPts < -inps.bias_min_gap_points);
   if(!upBias && !downBias) return TRENDPB_BLOCK_NO_BIAS;

   // Reclaim pattern
   const bool reclaimedUp   = (close_2 <= entryEma_2 && close_1 > entryEma_1);
   const bool reclaimedDown = (close_2 >= entryEma_2 && close_1 < entryEma_1);

   if(upBias   && reclaimedUp   && rsi <= inps.rsi_buy_max)  outSig.buy  = true;
   if(downBias && reclaimedDown && rsi >= inps.rsi_sell_min) outSig.sell = true;

   if(outSig.buy && outSig.sell) { outSig.buy = false; outSig.sell = false; }

   return (outSig.buy || outSig.sell) ? TRENDPB_OK : TRENDPB_BLOCK_NO_SIGNAL;
}

// ------------------------------------------------------------------
// Handle-based evaluation
//
// Expected handles:
// - bias EMA fast/slow : buffer 0
// - entry EMA          : buffer 0
// - RSI                : buffer 0
// - ATR                : buffer 0
// ------------------------------------------------------------------
TrendPullbackResult TrendPullback_EvaluateHandles(
   const int hBiasFast, const int hBiasSlow, const int hEntryEma,
   const int hRsi, const int hAtr,
   const string symbol, const ENUM_TIMEFRAMES entryTf,
   const int shift, const double point,
   const TrendPullbackInputs &inps, TrendPullbackSignal &outSig)
{
   if(point <= 0.0) return TRENDPB_ERROR_DATA;

   double bFast, bSlow, e1, e2, rsi, atr;

   // Always use shift 1 for Bias to ensure we use a closed HTF candle
   if(!TrendPullback_ReadBuffer1(hBiasFast, 0, 1, bFast)) return TRENDPB_ERROR_DATA;
   if(!TrendPullback_ReadBuffer1(hBiasSlow, 0, 1, bSlow)) return TRENDPB_ERROR_DATA;

   if(!TrendPullback_ReadBuffer1(hEntryEma, 0, shift,   e1)) return TRENDPB_ERROR_DATA;
   if(!TrendPullback_ReadBuffer1(hEntryEma, 0, shift+1, e2)) return TRENDPB_ERROR_DATA;

   if(!TrendPullback_ReadBuffer1(hRsi, 0, shift, rsi)) return TRENDPB_ERROR_DATA;
   if(!TrendPullback_ReadBuffer1(hAtr, 0, shift, atr)) return TRENDPB_ERROR_DATA;

   double c1 = iClose(symbol, entryTf, shift);
   double c2 = iClose(symbol, entryTf, shift + 1);

   return TrendPullback_EvaluateValues(bFast, bSlow, e1, e2, c1, c2, rsi, (atr/point), point, inps, outSig);
}

#endif // KUROSAWA_STRATEGY_TRENDPULLBACK_MQH
