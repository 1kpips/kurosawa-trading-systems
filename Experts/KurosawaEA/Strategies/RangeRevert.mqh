//+------------------------------------------------------------------+
//| File: Strategies/RangeRevert.mqh                                 |
//| Type: Strategy Module (independent)                              |
//|                                                                  |
//| Description                                                      |
//| RangeRevert (mean-reversion) signal logic (signal generation only)|
//| - Pure signal evaluation on CLOSED bars (shift=1 by default)     |
//| - No trade execution, no risk sizing, no session/spread gates    |
//| - No external includes (no KurosawaHelpers dependency)           |
//|                                                                  |
//| RangeRevert concept                                              |
//| - Trade "reversion to mean" in range conditions                  |
//| - Range regime gate: ADX must be below threshold                 |
//| - Volatility window gate: ATR must be within [min,max]           |
//| - Entry trigger: price touches/exceeds Bollinger band + RSI      |
//|                                                                  |
//| Notes                                                            |
//| - Uses ONLY MQL5 built-ins (CopyBuffer, ArraySetAsSeries, etc.)  |
//| - Caller passes `point` (usually _Point) so module is portable   |
//| - Caller chooses TF and shift (recommended shift=1)              |
//+------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_STRATEGY_RANGEREVERT_MQH
#define KUROSAWA_STRATEGY_RANGEREVERT_MQH

enum RangeRevertResult
{
   RANGEREVERT_OK = 0,
   RANGEREVERT_BLOCK_ATR,
   RANGEREVERT_BLOCK_ADX,
   RANGEREVERT_BLOCK_NO_SIGNAL,
   RANGEREVERT_BLOCK_AMBIG,
   RANGEREVERT_ERROR_DATA
};

struct RangeRevertInputs
{
   // Bollinger Bands (engine uses these to create handles)
   int    bb_period;
   double bb_dev;

   // RSI (engine uses this to create handles)
   int    rsi_period;
   double rsi_buy_below;
   double rsi_sell_above;

   // Regime gates
   bool   use_adx_filter;
   int    adx_period;
   double adx_max_to_trade;   // 0 disables

   // ATR window in POINTS (atr/point)
   int    atr_period;
   double atr_min_points;     // 0 disables
   double atr_max_points;     // 0 disables

   // Touch vs reclaim behavior
   bool   require_reclaim;
};

struct RangeRevertSignal
{
   bool   buy;
   bool   sell;
   bool   ambig;

   double atr_points;
   double adx;
   double rsi;

   double bb_upper;
   double bb_mid;
   double bb_lower;

   double high;
   double low;
};

bool RangeRevert_ReadBuffer1(const int handle, const int buffer, const int shift, double &outVal)
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

RangeRevertResult RangeRevert_EvaluateValues(
   const double close1, const double high1, const double low1,
   const double close2,
   const double rsi,
   const double atr_points,
   const double adx,
   const double bb_upper, const double bb_mid, const double bb_lower,
   const RangeRevertInputs &inps,
   RangeRevertSignal &outSig)
{
   outSig.buy = false;
   outSig.sell = false;
   outSig.ambig = false;

   outSig.atr_points = atr_points;
   outSig.adx = adx;
   outSig.rsi = rsi;

   outSig.bb_upper = bb_upper;
   outSig.bb_mid   = bb_mid;
   outSig.bb_lower = bb_lower;

   outSig.high = high1;
   outSig.low  = low1;

   // Basic sanity
   if(close1 <= 0.0 || high1 <= 0.0 || low1 <= 0.0) return RANGEREVERT_ERROR_DATA;
   if(low1 > high1) return RANGEREVERT_ERROR_DATA;
   if(atr_points <= 0.0) return RANGEREVERT_ERROR_DATA;
   if(bb_upper <= 0.0 || bb_lower <= 0.0) return RANGEREVERT_ERROR_DATA;
   if(bb_lower > bb_upper) return RANGEREVERT_ERROR_DATA;

   // 1) ATR window gate
   if(inps.atr_min_points > 0.0 && atr_points < inps.atr_min_points) return RANGEREVERT_BLOCK_ATR;
   if(inps.atr_max_points > 0.0 && atr_points > inps.atr_max_points) return RANGEREVERT_BLOCK_ATR;

   // 2) ADX gate (range-only)
   if(inps.use_adx_filter && inps.adx_max_to_trade > 0.0)
   {
      if(adx <= 0.0) return RANGEREVERT_ERROR_DATA;
      if(adx > inps.adx_max_to_trade) return RANGEREVERT_BLOCK_ADX;
   }

   // 3) Band interaction (touch vs reclaim)
   bool buyEdge = false, sellEdge = false;

   if(inps.require_reclaim)
   {
      // cheap reclaim variant: previous close outside, current close back inside
      buyEdge  = (close2 <= bb_lower && close1 > bb_lower);
      sellEdge = (close2 >= bb_upper && close1 < bb_upper);
   }
   else
   {
      buyEdge  = (low1  <= bb_lower);
      sellEdge = (high1 >= bb_upper);
   }

   // 4) RSI confirmation (optionally sanity-check RSI range)
   if(rsi < 0.0 || rsi > 100.0) return RANGEREVERT_ERROR_DATA;

   outSig.buy  = (buyEdge  && rsi <= inps.rsi_buy_below);
   outSig.sell = (sellEdge && rsi >= inps.rsi_sell_above);

   if(outSig.buy && outSig.sell)
   {
      outSig.buy = false;
      outSig.sell = false;
      outSig.ambig = true;
      return RANGEREVERT_BLOCK_AMBIG;
   }

   return (outSig.buy || outSig.sell) ? RANGEREVERT_OK : RANGEREVERT_BLOCK_NO_SIGNAL;
}

RangeRevertResult RangeRevert_EvaluateHandles(
   const int atrHandle,
   const int rsiHandle,
   const int bbHandle,
   const int adxHandle,
   const string symbol,
   const ENUM_TIMEFRAMES tf,
   const int shift,
   const double point,
   const RangeRevertInputs &inps,
   RangeRevertSignal &outSig)
{
   if(point <= 0.0) return RANGEREVERT_ERROR_DATA;

   const double c1 = iClose(symbol, tf, shift);
   const double c2 = iClose(symbol, tf, shift + 1);
   const double h1 = iHigh(symbol, tf, shift);
   const double l1 = iLow(symbol, tf, shift);

   double atr=0.0, rsi=0.0, adx=0.0, bbU=0.0, bbM=0.0, bbL=0.0;

   if(!RangeRevert_ReadBuffer1(atrHandle, 0, shift, atr)) return RANGEREVERT_ERROR_DATA;
   if(!RangeRevert_ReadBuffer1(rsiHandle, 0, shift, rsi)) return RANGEREVERT_ERROR_DATA;

   if(!RangeRevert_ReadBuffer1(bbHandle, 0, shift, bbU)) return RANGEREVERT_ERROR_DATA;
   if(!RangeRevert_ReadBuffer1(bbHandle, 1, shift, bbM)) return RANGEREVERT_ERROR_DATA;
   if(!RangeRevert_ReadBuffer1(bbHandle, 2, shift, bbL)) return RANGEREVERT_ERROR_DATA;

   if(inps.use_adx_filter && inps.adx_max_to_trade > 0.0)
   {
      if(adxHandle == INVALID_HANDLE) return RANGEREVERT_ERROR_DATA;
      if(!RangeRevert_ReadBuffer1(adxHandle, 0, shift, adx)) return RANGEREVERT_ERROR_DATA;
   }

   return RangeRevert_EvaluateValues(
      c1, h1, l1, c2,
      rsi,
      (atr / point),
      adx,
      bbU, bbM, bbL,
      inps,
      outSig
   );
}

#endif // KUROSAWA_STRATEGY_RANGEREVERT_MQH
