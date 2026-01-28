//+------------------------------------------------------------------+
//| File: Strategies/SwingTrend.mqh                                  |
//| Type: Strategy Module (independent)                              |
//|                                                                  |
//| Description                                                      |
//| SwingTrend strategy logic (signal generation only).              |
//| - Pure signal evaluation on CLOSED bars (shift=1 by default)     |
//| - No trade execution, no risk sizing, no session/spread gates    |
//| - No external includes (no KurosawaHelpers dependency)           |
//|                                                                  |
//| Notes                                                            |
//| - Uses ONLY MQL5 built-ins (CopyBuffer, ArraySetAsSeries, etc.)  |
//| - Caller passes `point` (usually _Point) so module is portable   |
//+------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_STRATEGY_SWINGTREND_MQH
#define KUROSAWA_STRATEGY_SWINGTREND_MQH

enum SwingTrendResult
{
   SWINGTREND_OK = 0,
   SWINGTREND_BLOCK_ATR,
   SWINGTREND_BLOCK_ADX,
   SWINGTREND_BLOCK_NO_BIAS,
   SWINGTREND_BLOCK_NO_SIGNAL,
   SWINGTREND_ERROR_DATA
};

struct SwingTrendInputs
{
   double rsi_buy_below;
   double rsi_sell_above;

   double atr_min_points;     // 0 disables
   double atr_max_points;     // 0 disables

   bool   use_adx_filter;
   double adx_min_to_trade;   // 0 disables
   double adx_max_to_trade;   // 0 disables

   bool   require_ema_slope;  // if true: require slow EMA rising/falling
};

struct SwingTrendSignal
{
   bool   buy;
   bool   sell;
   double atr_points;

   // Optional debug
   double ema_fast;
   double ema_slow;
   double rsi;
   double adx;
};

// Read 1 value from indicator buffer at `shift`
bool SwingTrend_ReadBuffer1(const int handle, const int buffer, const int shift, double &outVal)
{
   outVal = 0.0;
   if(handle == INVALID_HANDLE) return false;
   if(shift < 0) return false;

   double v[1];
   ArraySetAsSeries(v, true);

   if(CopyBuffer(handle, buffer, shift, 1, v) != 1)
      return false;

   outVal = v[0];
   return true;
}

SwingTrendResult SwingTrend_EvaluateValues(
   const double emaFast,
   const double emaSlow,
   const double emaSlowPrev,
   const double rsi,
   const double atr_points,
   const double adx,
   const SwingTrendInputs &inps,
   SwingTrendSignal &outSig)
{
   outSig.buy        = false;
   outSig.sell       = false;
   outSig.atr_points = atr_points;
   outSig.ema_fast   = emaFast;
   outSig.ema_slow   = emaSlow;
   outSig.rsi        = rsi;
   outSig.adx        = adx;

   if(atr_points <= 0.0) return SWINGTREND_ERROR_DATA;
   if(rsi < 0.0 || rsi > 100.0) return SWINGTREND_ERROR_DATA;

   // ATR window gate
   if(inps.atr_min_points > 0.0 && atr_points < inps.atr_min_points) return SWINGTREND_BLOCK_ATR;
   if(inps.atr_max_points > 0.0 && atr_points > inps.atr_max_points) return SWINGTREND_BLOCK_ATR;

   // Optional ADX gate (only meaningful if at least one bound is set)
   if(inps.use_adx_filter && (inps.adx_min_to_trade > 0.0 || inps.adx_max_to_trade > 0.0))
   {
      if(adx <= 0.0) return SWINGTREND_ERROR_DATA;

      if(inps.adx_min_to_trade > 0.0 && adx < inps.adx_min_to_trade) return SWINGTREND_BLOCK_ADX;
      if(inps.adx_max_to_trade > 0.0 && adx > inps.adx_max_to_trade) return SWINGTREND_BLOCK_ADX;
   }

   bool upTrend   = (emaFast > emaSlow);
   bool downTrend = (emaFast < emaSlow);

   if(inps.require_ema_slope)
   {
      upTrend   = upTrend   && (emaSlow > emaSlowPrev);
      downTrend = downTrend && (emaSlow < emaSlowPrev);
   }

   if(!upTrend && !downTrend) return SWINGTREND_BLOCK_NO_BIAS;

   if(upTrend   && rsi <= inps.rsi_buy_below)  outSig.buy  = true;
   if(downTrend && rsi >= inps.rsi_sell_above) outSig.sell = true;

   if(!outSig.buy && !outSig.sell) return SWINGTREND_BLOCK_NO_SIGNAL;
   return SWINGTREND_OK;
}

SwingTrendResult SwingTrend_EvaluateHandles(
   const int emaFastH,
   const int emaSlowH,
   const int rsiH,
   const int atrH,
   const int adxH,
   const int shift,
   const double point,
   const SwingTrendInputs &inps,
   SwingTrendSignal &outSig)
{
   // Enforce closed-bar usage
   if(shift < 1) return SWINGTREND_ERROR_DATA;
   if(point <= 0.0) return SWINGTREND_ERROR_DATA;

   double fast=0.0, slow=0.0, slowPrev=0.0, rsi=0.0, atr=0.0, adx=0.0;

   if(!SwingTrend_ReadBuffer1(emaFastH, 0, shift,   fast))     return SWINGTREND_ERROR_DATA;
   if(!SwingTrend_ReadBuffer1(emaSlowH, 0, shift,   slow))     return SWINGTREND_ERROR_DATA;
   if(!SwingTrend_ReadBuffer1(emaSlowH, 0, shift+1, slowPrev)) return SWINGTREND_ERROR_DATA;

   if(!SwingTrend_ReadBuffer1(rsiH, 0, shift, rsi)) return SWINGTREND_ERROR_DATA;
   if(!SwingTrend_ReadBuffer1(atrH, 0, shift, atr)) return SWINGTREND_ERROR_DATA;

   if(inps.use_adx_filter && (inps.adx_min_to_trade > 0.0 || inps.adx_max_to_trade > 0.0))
   {
      if(adxH == INVALID_HANDLE) return SWINGTREND_ERROR_DATA;
      if(!SwingTrend_ReadBuffer1(adxH, 0, shift, adx)) return SWINGTREND_ERROR_DATA;
   }

   return SwingTrend_EvaluateValues(
      fast, slow, slowPrev,
      rsi,
      (atr / point),
      adx,
      inps,
      outSig
   );
}

#endif // KUROSAWA_STRATEGY_SWINGTREND_MQH
