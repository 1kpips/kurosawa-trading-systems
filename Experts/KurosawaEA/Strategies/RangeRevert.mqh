//+------------------------------------------------------------------+
//| File: Strategies/RangeRevert.mqh                                 |
//| Type: Strategy Module (independent)                              |
//|                                                                  |
//| Description                                                      |
//| RangeRevert (mean-reversion) signal logic (signal generation only)|
//| - Closed-bar evaluation (caller chooses shift; recommended shift=1)|
//| - No trade execution, no risk sizing, no session/spread gates    |
//| - No external includes (no KurosawaHelpers dependency)           |
//|                                                                  |
//| RangeRevert concept                                              |
//| - Range regime gate: ADX must be below threshold (optional)      |
//| - Volatility window gate: ATR must be within [min,max] (optional)|
//| - Entry: BB edge interaction + RSI confirmation                  |
//| - Optional "edge quality": require minimum BB break in POINTS    |
//| - Optional "edge quality": require break beyond spread multiple  |
//|                                                                  |
//| Notes                                                            |
//| - Uses ONLY MQL5 built-ins (CopyBuffer, ArraySetAsSeries, etc.)  |
//| - Caller passes `point` (usually _Point) so module is portable   |
//| - All distance-based filters are in POINTS (_Point units)        |
//+------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_STRATEGY_RANGEREVERT_MQH
#define KUROSAWA_STRATEGY_RANGEREVERT_MQH

// ------------------------------------------------------------------
// Result codes
// ------------------------------------------------------------------
enum RangeRevertResult
{
   RANGEREVERT_OK = 0,
   RANGEREVERT_BLOCK_ATR,
   RANGEREVERT_BLOCK_ADX,
   RANGEREVERT_BLOCK_EDGE,        // edge quality not met
   RANGEREVERT_BLOCK_NO_SIGNAL,
   RANGEREVERT_BLOCK_AMBIG,
   RANGEREVERT_ERROR_DATA
};

// ------------------------------------------------------------------
// Inputs bundle
// ------------------------------------------------------------------
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
   double adx_max_to_trade;      // 0 disables

   // ATR window in POINTS (atr/point)
   int    atr_period;
   double atr_min_points;        // 0 disables
   double atr_max_points;        // 0 disables

   // Band interaction behavior
   bool   require_reclaim;       // previous close outside, current close back inside

   // Optional edge quality (POINTS)
   // These are neutral when set to 0 (disabled).
   // - min_band_break_points: require band penetration of at least this many points
   // - min_edge_over_spread: require penetration >= spread_points * this multiple
   double min_band_break_points; // 0 disables
   double min_edge_over_spread;  // 0 disables
};

// ------------------------------------------------------------------
// Output bundle (for diagnostics / tracking)
// ------------------------------------------------------------------
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

   double close1;
   double high1;
   double low1;
   double close2;

   // computed edge break in POINTS (>=0)
   double lower_break_points;
   double upper_break_points;
};

// ------------------------------------------------------------------
// Internal: read one value from indicator buffer
// ------------------------------------------------------------------
bool RangeRevert_ReadBuffer1(const int handle, const int buffer, const int shift, double &outVal)
{
   outVal = 0.0;
   if(handle == INVALID_HANDLE) return false;

   double v[];
   ArraySetAsSeries(v, true);

   if(CopyBuffer(handle, buffer, shift, 1, v) != 1)
      return false;

   outVal = v[0];
   return MathIsValidNumber(outVal);
}

// ------------------------------------------------------------------
// Internal: safe clamp
// ------------------------------------------------------------------
double RangeRevert_Max0(const double x) { return (x > 0.0 ? x : 0.0); }

// ------------------------------------------------------------------
// Core logic using already-read values (closed-bar values)
// All "break" distances are evaluated in POINTS.
// ------------------------------------------------------------------
RangeRevertResult RangeRevert_EvaluateValues(
   const double close1, const double high1, const double low1,
   const double close2,
   const double rsi,
   const double atr_points,
   const double adx,
   const double bb_upper, const double bb_mid, const double bb_lower,
   const double spread_points,        // spread in POINTS (caller can pass 0 if unknown)
   const RangeRevertInputs &inps,
   RangeRevertSignal &outSig)
{
   // init outputs
   outSig.buy = false;
   outSig.sell = false;
   outSig.ambig = false;

   outSig.atr_points = atr_points;
   outSig.adx = adx;
   outSig.rsi = rsi;

   outSig.bb_upper = bb_upper;
   outSig.bb_mid   = bb_mid;
   outSig.bb_lower = bb_lower;

   outSig.close1 = close1;
   outSig.high1  = high1;
   outSig.low1   = low1;
   outSig.close2 = close2;

   outSig.lower_break_points = 0.0;
   outSig.upper_break_points = 0.0;

   // Basic sanity
   if(!MathIsValidNumber(close1) || !MathIsValidNumber(high1) || !MathIsValidNumber(low1) || !MathIsValidNumber(close2))
      return RANGEREVERT_ERROR_DATA;

   if(close1 <= 0.0 || high1 <= 0.0 || low1 <= 0.0)
      return RANGEREVERT_ERROR_DATA;

   if(low1 > high1)
      return RANGEREVERT_ERROR_DATA;

   if(!MathIsValidNumber(atr_points) || atr_points <= 0.0)
      return RANGEREVERT_ERROR_DATA;

   if(!MathIsValidNumber(bb_upper) || !MathIsValidNumber(bb_lower) || bb_upper <= 0.0 || bb_lower <= 0.0)
      return RANGEREVERT_ERROR_DATA;

   if(bb_lower > bb_upper)
      return RANGEREVERT_ERROR_DATA;

   // RSI sanity
   if(!MathIsValidNumber(rsi) || rsi < 0.0 || rsi > 100.0)
      return RANGEREVERT_ERROR_DATA;

   // 1) ATR window gate
   if(inps.atr_min_points > 0.0 && atr_points < inps.atr_min_points)
      return RANGEREVERT_BLOCK_ATR;

   if(inps.atr_max_points > 0.0 && atr_points > inps.atr_max_points)
      return RANGEREVERT_BLOCK_ATR;

   // 2) ADX gate (range-only)
   if(inps.use_adx_filter && inps.adx_max_to_trade > 0.0)
   {
      if(!MathIsValidNumber(adx) || adx <= 0.0)
         return RANGEREVERT_ERROR_DATA;

      if(adx > inps.adx_max_to_trade)
         return RANGEREVERT_BLOCK_ADX;
   }

   // 3) Band interaction (touch vs reclaim)
   bool buyEdge = false;
   bool sellEdge = false;

   // Compute penetration in PRICE then convert to POINTS later (caller controls point via EvaluateHandles)
   // Here we assume bb_* and highs/lows are same PRICE units; conversion done before calling EvaluateValues
   // For EvaluateValues, we already get spread_points and later compare using "break_points" (already points)
   // So we compute "break_points" outside of reclaim logic.

   if(inps.require_reclaim)
   {
      // previous close outside, current close back inside
      buyEdge  = (close2 <= bb_lower && close1 > bb_lower);
      sellEdge = (close2 >= bb_upper && close1 < bb_upper);
   }
   else
   {
      buyEdge  = (low1  <= bb_lower);
      sellEdge = (high1 >= bb_upper);
   }

   // 4) Edge break quality (optional)
   // lower break: how far low went below lower band (points)
   // upper break: how far high went above upper band (points)
   // Note: when require_reclaim=true, break is measured on bar1's low/high as well (still meaningful).
   outSig.lower_break_points = RangeRevert_Max0(bb_lower - low1);   // PRICE distance
   outSig.upper_break_points = RangeRevert_Max0(high1 - bb_upper);  // PRICE distance
   // These are still PRICE units; the caller should pass them already converted to points if desired.
   // To keep EvaluateValues purely points-based, we will treat them as POINTS here.
   // Therefore: EvaluateHandles must convert them to points before passing.

   // Minimum band break in points
   if(inps.min_band_break_points > 0.0)
   {
      if(buyEdge && outSig.lower_break_points < inps.min_band_break_points) buyEdge = false;
      if(sellEdge && outSig.upper_break_points < inps.min_band_break_points) sellEdge = false;
   }

   // Break beyond spread multiple
   if(inps.min_edge_over_spread > 0.0 && spread_points > 0.0)
   {
      const double need = spread_points * inps.min_edge_over_spread;
      if(buyEdge && outSig.lower_break_points < need) buyEdge = false;
      if(sellEdge && outSig.upper_break_points < need) sellEdge = false;
   }

   if(!buyEdge && !sellEdge)
      return RANGEREVERT_BLOCK_EDGE;

   // 5) RSI confirmation
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

// ------------------------------------------------------------------
// Handle-based evaluation
//
// Expected handles:
// - ATR : buffer 0 (PRICE units)
// - RSI : buffer 0
// - BB  : buffer 0=upper,1=mid,2=lower (PRICE units)
// - ADX : buffer 0 (optional)
// ------------------------------------------------------------------
RangeRevertResult RangeRevert_EvaluateHandles(
   const int atrHandle,
   const int rsiHandle,
   const int bbHandle,
   const int adxHandle,
   const string symbol,
   const ENUM_TIMEFRAMES tf,
   const int shift,
   const double point,
   const double spread_points,   // spread in POINTS, supplied by caller (0 disables the edge-over-spread filter)
   const RangeRevertInputs &inps,
   RangeRevertSignal &outSig)
{
   if(point <= 0.0) return RANGEREVERT_ERROR_DATA;
   if(shift < 1)    return RANGEREVERT_ERROR_DATA; // enforce closed-bar contract

   // Prices
   const double c1 = iClose(symbol, tf, shift);
   const double c2 = iClose(symbol, tf, shift + 1);
   const double h1 = iHigh(symbol,  tf, shift);
   const double l1 = iLow(symbol,   tf, shift);

   // Indicator values
   double atrPrice = 0.0, rsi = 0.0, adx = 0.0, bbU = 0.0, bbM = 0.0, bbL = 0.0;

   if(!RangeRevert_ReadBuffer1(atrHandle, 0, shift, atrPrice)) return RANGEREVERT_ERROR_DATA;
   if(!RangeRevert_ReadBuffer1(rsiHandle, 0, shift, rsi))      return RANGEREVERT_ERROR_DATA;

   if(!RangeRevert_ReadBuffer1(bbHandle, 0, shift, bbU)) return RANGEREVERT_ERROR_DATA;
   if(!RangeRevert_ReadBuffer1(bbHandle, 1, shift, bbM)) return RANGEREVERT_ERROR_DATA;
   if(!RangeRevert_ReadBuffer1(bbHandle, 2, shift, bbL)) return RANGEREVERT_ERROR_DATA;

   if(inps.use_adx_filter && inps.adx_max_to_trade > 0.0)
   {
      if(adxHandle == INVALID_HANDLE) return RANGEREVERT_ERROR_DATA;
      if(!RangeRevert_ReadBuffer1(adxHandle, 0, shift, adx)) return RANGEREVERT_ERROR_DATA;
   }

   // Convert ATR from PRICE to POINTS
   const double atr_points = atrPrice / point;

   // Spread is caller-supplied (see signature). Keeping this module free of
   // live market reads makes the signal a pure function of closed-bar inputs
   // and avoids the Strategy-Tester fail-open where SYMBOL_ASK/BID can read 0
   // (which would silently skip the edge-over-spread quality filter).

   // Convert penetration distances to POINTS before calling EvaluateValues
   // We pass the original PRICE highs/lows and BB values, but EvaluateValues expects
   // outSig.lower_break_points/outSig.upper_break_points to be in POINTS.
   // To achieve that, we scale bb/price distance logic by converting here:
   // - We will pass low/high/bb in PRICE units, but we will pre-adjust the "break points"
   //   by temporarily converting PRICE -> POINTS inside EvaluateValues based on the same values.
   //
   // To keep EvaluateValues strictly points-only, we instead pass bb/price values in POINTS units.
   // This is safer and consistent.
   const double c1p = c1 / point;
   const double h1p = h1 / point;
   const double l1p = l1 / point;
   const double c2p = c2 / point;
   const double bbUp = bbU / point;
   const double bbMp = bbM / point;
   const double bbLp = bbL / point;

   return RangeRevert_EvaluateValues(
      c1p, h1p, l1p,
      c2p,
      rsi,
      atr_points,
      adx,
      bbUp, bbMp, bbLp,
      spread_points,
      inps,
      outSig
   );
}

#endif // KUROSAWA_STRATEGY_RANGEREVERT_MQH
