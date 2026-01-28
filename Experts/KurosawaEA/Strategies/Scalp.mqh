//+------------------------------------------------------------------+
//| File: Strategies/Scalp.mqh                                       |
//| Type: Strategy Module (independent)                              |
//| Ver : 0.2.3                                                      |
//|                                                                  |
//| Description                                                      |
//| Scalp strategy logic (signal generation only).                   |
//| - Pure signal evaluation on CLOSED bars (shift=1 by default)     |
//| - No trade execution, no risk sizing, no session/spread gates    |
//| - No KurosawaHelpers dependency                                  |
//|                                                                  |
//| Concept                                                          |
//| - Mean-reversion scalp using Bollinger Bands + RSI extremes      |
//| - Optional reclaim mode: prior bar pierces outside, current      |
//|   bar closes back inside                                         |
//| - Optional RSI cross confirmation                                |
//| - Optional wick/edge quality filter                              |
//|   * MinBandBreakPoints: requires pierce depth beyond band        |
//|   * MinEdgeOverSpread: requires edge_points >= spread_points*k   |
//| - Optional ADX calm filter (trade only within [min,max])         |
//| - ATR window gate uses POINTS (atr / point)                      |
//+------------------------------------------------------------------+
#property strict
#ifndef KUROSAWA_STRATEGY_SCALP_MQH
#define KUROSAWA_STRATEGY_SCALP_MQH

// ------------------------------------------------------------------
// Result codes (engine maps to diagnostics)
// ------------------------------------------------------------------
enum ScalpResult
{
   SCALP_OK = 0,

   SCALP_BLOCK_NO_SIGNAL,
   SCALP_ERROR_DATA,

   SCALP_BLOCK_ATR,
   SCALP_BLOCK_ADX,
   SCALP_BLOCK_AMBIG,
   SCALP_BLOCK_WICK
};

// ------------------------------------------------------------------
// Inputs bundle (matches your schema naming intent)
// ------------------------------------------------------------------
struct ScalpInputs
{
   // RSI thresholds
   int    rsi_period;
   double rsi_buy_below;
   double rsi_sell_above;

   // Optional RSI cross confirmation (uses rsi_prev -> rsi_curr)
   bool   use_rsi_cross_confirm;
   double rsi_buy_cross_level;
   double rsi_sell_cross_level;

   // ATR window (POINTS). 0 disables bound.
   int    atr_period;
   double atr_min_points;
   double atr_max_points;

   // ADX window. If enabled, trade only within [min,max] (0 disables a bound).
   bool   use_adx_filter;
   int    adx_period;
   double adx_min_to_trade;
   double adx_max_to_trade;

   // Wick/edge quality filter (schema)
   bool   use_wick_signal;
   double min_band_break_points;   // depth beyond band in POINTS (0 disables)
   double min_edge_over_spread;    // edge_points >= spread_points * k (0 disables)

   // false: touch/pierce on current closed bar
   // true : reclaim (prior pierce outside, current closes back inside)
   bool   require_reclaim;
};

// ------------------------------------------------------------------
// Output bundle (debug-friendly)
// ------------------------------------------------------------------
struct ScalpSignal
{
   bool   buy;
   bool   sell;

   double atr_points;     // ATR converted to POINTS (atr / point)
   double adx;
   double rsi;

   double bb_upper_1;
   double bb_lower_1;

   // Edge diagnostics (pierce depth beyond band, in POINTS)
   double edge_points;
   double spread_points;
};

// ------------------------------------------------------------------
// Internal: read 1 value from an indicator buffer at shift
// ------------------------------------------------------------------
bool Scalp_ReadBuffer1(const int handle, const int buffer, const int shift, double &outVal)
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
// Internal: RSI confirmation (threshold or cross)
// ------------------------------------------------------------------
bool Scalp_PassRsiConfirm(const bool isBuy, const double rsi_curr, const double rsi_prev, const ScalpInputs &inps)
{
   if(inps.use_rsi_cross_confirm)
   {
      if(isBuy)
      {
         if(inps.rsi_buy_cross_level <= 0.0) return false;
         return (rsi_prev < inps.rsi_buy_cross_level && rsi_curr >= inps.rsi_buy_cross_level);
      }
      else
      {
         if(inps.rsi_sell_cross_level <= 0.0) return false;
         return (rsi_prev > inps.rsi_sell_cross_level && rsi_curr <= inps.rsi_sell_cross_level);
      }
   }

   if(isBuy)  return (rsi_curr <= inps.rsi_buy_below);
   else       return (rsi_curr >= inps.rsi_sell_above);
}

// ------------------------------------------------------------------
// Internal: compute "edge beyond band" in POINTS
// - buy:  bandLower - low  (if low is below band)
// - sell: high - bandUpper (if high is above band)
// ------------------------------------------------------------------
double Scalp_EdgePointsBuy(const double low, const double bandLower, const double point)
{
   if(point <= 0.0) return 0.0;
   if(low >= bandLower) return 0.0;
   return (bandLower - low) / point;
}
double Scalp_EdgePointsSell(const double high, const double bandUpper, const double point)
{
   if(point <= 0.0) return 0.0;
   if(high <= bandUpper) return 0.0;
   return (high - bandUpper) / point;
}

// ------------------------------------------------------------------
// Internal: wick/edge quality filter on the "pierce bar"
// - If reclaim: pierce bar is bar2 (prior), bands are bb2
// - Else: pierce bar is bar1 (current closed), bands are bb1
// ------------------------------------------------------------------
bool Scalp_PassWickEdgeConfirm(
   const bool isBuy,
   const double pierce_low,
   const double pierce_high,
   const double bbUpperPierce,
   const double bbLowerPierce,
   const double point,
   const double spread_points,
   const ScalpInputs &inps,
   ScalpSignal &outSig)
{
   outSig.edge_points   = 0.0;
   outSig.spread_points = spread_points;

   if(!inps.use_wick_signal)
      return true;

   if(point <= 0.0)
      return false;

   double edgePts = 0.0;
   if(isBuy)  edgePts = Scalp_EdgePointsBuy(pierce_low,  bbLowerPierce, point);
   else       edgePts = Scalp_EdgePointsSell(pierce_high, bbUpperPierce, point);

   outSig.edge_points = edgePts;

   // 1) Require a minimum pierce depth beyond band (POINTS)
   if(inps.min_band_break_points > 0.0)
   {
      if(edgePts < inps.min_band_break_points)
         return false;
   }

   // 2) Require edge relative to current spread (POINTS)
   //    edgePts >= spreadPts * k
   if(inps.min_edge_over_spread > 0.0)
   {
      if(spread_points <= 0.0)
         return false;

      if(edgePts < (spread_points * inps.min_edge_over_spread))
         return false;
   }

   return true;
}

// ------------------------------------------------------------------
// Core evaluator (values already provided)
// - All series are CLOSED bars
// - "1" means current closed bar at shift
// - "2" means prior closed bar at shift+1
// - spread_points is provided by caller (current spread in POINTS)
// ------------------------------------------------------------------
ScalpResult Scalp_EvaluateValues(
   const double close1,
   const double low1,
   const double high1,

   const double close2,
   const double low2,
   const double high2,

   const double bbUpper1,
   const double bbLower1,
   const double bbUpper2,
   const double bbLower2,

   const double rsi1,
   const double rsi2,
   const double atr_points,
   const double adx,

   const double point,
   const double spread_points,
   const ScalpInputs &inps,
   ScalpSignal &outSig)
{
   outSig.buy          = false;
   outSig.sell         = false;
   outSig.atr_points   = atr_points;
   outSig.adx          = adx;
   outSig.rsi          = rsi1;
   outSig.bb_upper_1   = bbUpper1;
   outSig.bb_lower_1   = bbLower1;
   outSig.edge_points  = 0.0;
   outSig.spread_points= spread_points;

   // ----------------------------
   // Sanity
   // ----------------------------
   if(point <= 0.0) return SCALP_ERROR_DATA;
   if(atr_points <= 0.0) return SCALP_ERROR_DATA;

   if(close1 <= 0.0 || low1 <= 0.0 || high1 <= 0.0) return SCALP_ERROR_DATA;
   if(bbUpper1 <= 0.0 || bbLower1 <= 0.0) return SCALP_ERROR_DATA;

   if(inps.require_reclaim)
   {
      if(close2 <= 0.0 || low2 <= 0.0 || high2 <= 0.0) return SCALP_ERROR_DATA;
      if(bbUpper2 <= 0.0 || bbLower2 <= 0.0) return SCALP_ERROR_DATA;
   }

   // ----------------------------
   // 1) ATR window gate (POINTS)
   // ----------------------------
   if(inps.atr_min_points > 0.0 && atr_points < inps.atr_min_points)
      return SCALP_BLOCK_ATR;

   if(inps.atr_max_points > 0.0 && atr_points > inps.atr_max_points)
      return SCALP_BLOCK_ATR;

   // ----------------------------
   // 2) Optional ADX gate (window)
   // ----------------------------
   if(inps.use_adx_filter)
   {
      // ADX must be a valid positive value if filter is enabled
      if(adx <= 0.0)
         return SCALP_ERROR_DATA;
   
      // Minimum ADX (avoid dead-flat markets)
      if(inps.adx_min_to_trade > 0.0 && adx < inps.adx_min_to_trade)
         return SCALP_BLOCK_ADX;
   
      // Maximum ADX (avoid strong trends)
      if(inps.adx_max_to_trade > 0.0 && adx > inps.adx_max_to_trade)
         return SCALP_BLOCK_ADX;
   }

   // ----------------------------
   // 3) Band interaction
   // ----------------------------
   bool bandBuy  = false;
   bool bandSell = false;

   if(inps.require_reclaim)
   {
      // Reclaim:
      // - prior bar (2) pierced outside
      // - current bar (1) closed back inside
      bandBuy  = (low2  <= bbLower2 && close1 > bbLower1);
      bandSell = (high2 >= bbUpper2 && close1 < bbUpper1);
   }
   else
   {
      // Touch/pierce on current closed bar
      bandBuy  = (low1  <= bbLower1);
      bandSell = (high1 >= bbUpper1);
   }

   // ----------------------------
   // 4) RSI confirmation
   // ----------------------------
   const bool rsiBuyOk  = (bandBuy  ? Scalp_PassRsiConfirm(true,  rsi1, rsi2, inps) : false);
   const bool rsiSellOk = (bandSell ? Scalp_PassRsiConfirm(false, rsi1, rsi2, inps) : false);

   // ----------------------------
   // 5) Wick/edge quality confirm (on pierce bar)
   // ----------------------------
   bool wickBuyOk  = true;
   bool wickSellOk = true;

   if(inps.use_wick_signal)
   {
      if(inps.require_reclaim)
      {
         if(bandBuy && rsiBuyOk)
            wickBuyOk = Scalp_PassWickEdgeConfirm(true,  low2, high2, bbUpper2, bbLower2, point, spread_points, inps, outSig);

         if(bandSell && rsiSellOk)
            wickSellOk = Scalp_PassWickEdgeConfirm(false, low2, high2, bbUpper2, bbLower2, point, spread_points, inps, outSig);
      }
      else
      {
         if(bandBuy && rsiBuyOk)
            wickBuyOk = Scalp_PassWickEdgeConfirm(true,  low1, high1, bbUpper1, bbLower1, point, spread_points, inps, outSig);

         if(bandSell && rsiSellOk)
            wickSellOk = Scalp_PassWickEdgeConfirm(false, low1, high1, bbUpper1, bbLower1, point, spread_points, inps, outSig);
      }
   }

   // Final decision
   if(bandBuy && rsiBuyOk && wickBuyOk)    outSig.buy  = true;
   if(bandSell && rsiSellOk && wickSellOk) outSig.sell = true;

   // Ambiguity guard
   if(outSig.buy && outSig.sell)
   {
      outSig.buy  = false;
      outSig.sell = false;
      return SCALP_BLOCK_AMBIG;
   }

   if(!outSig.buy && !outSig.sell)
   {
      // If wick filter was enabled and rejected, surface a separate block reason.
      if(inps.use_wick_signal && ((bandBuy && rsiBuyOk && !wickBuyOk) || (bandSell && rsiSellOk && !wickSellOk)))
         return SCALP_BLOCK_WICK;

      return SCALP_BLOCK_NO_SIGNAL;
   }

   return SCALP_OK;
}

// ------------------------------------------------------------------
// Evaluate by reading indicator handles directly.
// Expected buffers:
// - BB:  iBands (0=upper, 1=middle, 2=lower)
// - RSI: iRSI   (0)
// - ATR: iATR   (0)
// - ADX: iADX   (0) when enabled
//
// Shift is typically 1 (latest closed bar).
// `point` is usually _Point.
// `spread_points` is computed at evaluation time from current bid/ask.
// ------------------------------------------------------------------
ScalpResult Scalp_EvaluateHandles(
   const int bbHandle,
   const int rsiHandle,
   const int atrHandle,
   const int adxHandle,       // may be INVALID_HANDLE if not used
   const int shift,
   const double point,
   const ScalpInputs &inps,
   ScalpSignal &outSig,
   const string symbol,
   const ENUM_TIMEFRAMES tf)
{
   if(point <= 0.0) return SCALP_ERROR_DATA;

   // Closed-bar OHLC (bar 1 and bar 2)
   const double close1 = iClose(symbol, tf, shift);
   const double low1   = iLow(symbol,   tf, shift);
   const double high1  = iHigh(symbol,  tf, shift);

   const int sh2 = shift + 1;
   const double close2 = (inps.require_reclaim ? iClose(symbol, tf, sh2) : 0.0);
   const double low2   = (inps.require_reclaim ? iLow(symbol,   tf, sh2) : 0.0);
   const double high2  = (inps.require_reclaim ? iHigh(symbol,  tf, sh2) : 0.0);

   // Indicators
   double bbU1=0.0, bbL1=0.0, rsi1=0.0, atr=0.0;
   if(!Scalp_ReadBuffer1(bbHandle,  0, shift, bbU1)) return SCALP_ERROR_DATA;
   if(!Scalp_ReadBuffer1(bbHandle,  2, shift, bbL1)) return SCALP_ERROR_DATA;
   if(!Scalp_ReadBuffer1(rsiHandle, 0, shift, rsi1)) return SCALP_ERROR_DATA;
   if(!Scalp_ReadBuffer1(atrHandle, 0, shift, atr))  return SCALP_ERROR_DATA;

   // Prior bar values for reclaim and/or RSI cross
   double bbU2=0.0, bbL2=0.0, rsi2=0.0;
   if(!Scalp_ReadBuffer1(rsiHandle, 0, sh2, rsi2)) return SCALP_ERROR_DATA;

   if(inps.require_reclaim)
   {
      if(!Scalp_ReadBuffer1(bbHandle, 0, sh2, bbU2)) return SCALP_ERROR_DATA;
      if(!Scalp_ReadBuffer1(bbHandle, 2, sh2, bbL2)) return SCALP_ERROR_DATA;
   }

   // ADX read if enabled and any bound active
   double adx = 0.0;
   if(inps.use_adx_filter)
   {
      if(adxHandle == INVALID_HANDLE)
         return SCALP_ERROR_DATA;
   
      if(!Scalp_ReadBuffer1(adxHandle, 0, shift, adx))
         return SCALP_ERROR_DATA;
   }

   // Convert ATR to points
   const double atrPts = atr / point;

   // Spread in points (current tick)
   double bid = 0.0, ask = 0.0;
   if(!SymbolInfoDouble(symbol, SYMBOL_BID, bid)) return SCALP_ERROR_DATA;
   if(!SymbolInfoDouble(symbol, SYMBOL_ASK, ask)) return SCALP_ERROR_DATA;
   const double spreadPts = (ask - bid) / point;

   return Scalp_EvaluateValues(
      close1, low1, high1,
      close2, low2, high2,
      bbU1, bbL1,
      bbU2, bbL2,
      rsi1, rsi2,
      atrPts,
      adx,
      point,
      spreadPts,
      inps,
      outSig
   );
}

#endif // KUROSAWA_STRATEGY_SCALP_MQH
