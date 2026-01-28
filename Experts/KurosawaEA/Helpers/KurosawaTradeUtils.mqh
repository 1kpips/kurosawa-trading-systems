//+--------------------------------------------------------------------+
//| File: KurosawaTradeUtils.mqh                                      |
//| Type: Include Library                                             |
//| Ver : 0.1.0                                                       |
//|                                                                    |
//| Description                                                        |
//| Broker-safe trade utilities shared across the Kurosawa EA suite.   |
//|                                                                    |
//| Scope                                                              |
//| - Spread filter helper                                             |
//| - Price distance helpers (pips <-> price)                          |
//| - Stop distance validation (StopsLevel / FreezeLevel)              |
//| - Volume normalization (min/max/step)                              |
//+--------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_TRADE_UTILS_MQH
#define KUROSAWA_TRADE_UTILS_MQH

// Spread gate (POINTS).
// - maxSpreadPoints is interpreted as "points" (not pips).
// - Uses SYMBOL_SPREAD when available.
// - Falls back to (Ask-Bid)/Point when SYMBOL_SPREAD is unavailable (0) or invalid.
// Returns true when spread is valid (<= maxSpreadPoints).
bool SpreadOK(const string symbol, const int maxSpreadPoints)
{
   if(maxSpreadPoints <= 0) return true;

   // 1) Prefer broker-provided spread (already in points)
   int sp = (int)SymbolInfoInteger(symbol, SYMBOL_SPREAD);

   // Some environments (tester / thin quotes) can return 0.
   // Treat 0 as "unknown" and compute from Bid/Ask instead.
   if(sp <= 0)
   {
      double ask=0.0, bid=0.0;
      if(!SymbolInfoDouble(symbol, SYMBOL_ASK, ask)) return false;
      if(!SymbolInfoDouble(symbol, SYMBOL_BID, bid)) return false;

      const double pt = SymbolInfoDouble(symbol, SYMBOL_POINT);
      if(pt <= 0.0) return false;

      sp = (int)MathRound((ask - bid) / pt);
   }

   // Fail-safe: if still invalid, block.
   if(sp <= 0) return false;

   return (sp <= maxSpreadPoints);
}

// Converts pips to an absolute price distance for the given symbol.
// - 5-digit (EURUSD) and 3-digit (USDJPY): 1 pip = 10 points
// - 4-digit/2-digit: 1 pip = 1 point
double PipsToPrice(const string symbol, const double pips)
{
   const int digits   = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   const double point = SymbolInfoDouble(symbol, SYMBOL_POINT);

   const double pipValue = (digits == 3 || digits == 5) ? (10.0 * point) : point;
   return pips * pipValue;
}

// Converts an absolute price distance to pips.
// - JPY pairs:    1 pip = 0.01
// - Non-JPY pairs:1 pip = 0.0001
double PriceToPips(const string symbol, const double priceDistance)
{
   if(priceDistance <= 0.0)
      return 0.0;

   const bool isJpy = (StringFind(symbol, "JPY") >= 0);
   const double pipSize = isJpy ? 0.01 : 0.0001;

   if(pipSize <= 0.0)
      return 0.0;

   return priceDistance / pipSize;
}

// Ensures SL/TP distances meet broker constraints (StopsLevel and FreezeLevel).
bool EnsureStopsLevel(const string symbol,
                      const double entryPrice,
                      double &sl,
                      double &tp,
                      const bool isBuy,
                      const bool adjustOutward)
{
   const int stopsLevel  = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const int freezeLevel = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   const double point    = SymbolInfoDouble(symbol, SYMBOL_POINT);
   const int digits      = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   const double minDist = (double)MathMax(stopsLevel, freezeLevel) * point;

   if(minDist <= 0.0)
   {
      sl = (sl > 0.0 ? NormalizeDouble(sl, digits) : 0.0);
      tp = (tp > 0.0 ? NormalizeDouble(tp, digits) : 0.0);
      return true;
   }

   bool modified = false;

   if(isBuy)
   {
      if(sl > 0.0 && (entryPrice - sl) < minDist) { sl = entryPrice - minDist; modified = true; }
      if(tp > 0.0 && (tp - entryPrice) < minDist) { tp = entryPrice + minDist; modified = true; }
   }
   else
   {
      if(sl > 0.0 && (sl - entryPrice) < minDist) { sl = entryPrice + minDist; modified = true; }
      if(tp > 0.0 && (entryPrice - tp) < minDist) { tp = entryPrice - minDist; modified = true; }
   }

   if(modified && !adjustOutward)
      return false;

   sl = (sl > 0.0 ? NormalizeDouble(sl, digits) : 0.0);
   tp = (tp > 0.0 ? NormalizeDouble(tp, digits) : 0.0);
   return true;
}

// Normalizes a requested trade volume to broker constraints.
// - Enforces [VOLUME_MIN, VOLUME_MAX]
// - Snaps to VOLUME_STEP
// Rounding mode: ceil-to-step to avoid producing a volume below minimum.
double NormalizeVolume(const string symbol, const double requested)
{
   const double vmin  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   const double vmax  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   const double vstep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   double v = requested;

   if(v < vmin) v = vmin;
   if(v > vmax) v = vmax;

   if(vstep > 0.0)
      v = MathCeil(v / vstep) * vstep;

   // Determine decimal digits needed for normalization from the step.
   int dec = 2;
   if(vstep > 0.0)
   {
      dec = 0;
      double tmp = vstep;
      while(dec < 8 && MathAbs(tmp - (int)tmp) > 0.0000001)
      {
         tmp *= 10.0;
         dec++;
      }
   }

   return NormalizeDouble(v, dec);
}

// Calculates lots from risk% and SL distance (in points).
// - symbol: trading symbol (e.g., _Symbol)
// - riskPercent: percent of equity to risk (e.g., 0.30)
// - slDistancePoints: stop distance in points (not price)
// Returns 0.0 on failure. Caller can fallback to fixed lot.
double CalcLotByRiskPoints(const string symbol,
                                   const double riskPercent,
                                   const double slDistancePoints)
{
   if(slDistancePoints <= 0.0) return 0.0;

   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0) return 0.0;

   const double riskMoney = equity * (riskPercent / 100.0);
   if(riskMoney <= 0.0) return 0.0;

   const double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   const double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   const double point     = SymbolInfoDouble(symbol, SYMBOL_POINT);

   if(tickValue <= 0.0 || tickSize <= 0.0 || point <= 0.0) return 0.0;

   // value per "point" per 1.0 lot
   const double valuePerPointPerLot = tickValue * (point / tickSize);
   if(valuePerPointPerLot <= 0.0) return 0.0;

   const double lotsRaw = riskMoney / (slDistancePoints * valuePerPointPerLot);
   return NormalizeVolume(symbol, lotsRaw);
}

double GetMinLot(const string symbol)
{
   const double vmin = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   return NormalizeVolume(symbol, vmin);
}


#endif // KUROSAWA_TRADE_UTILS_MQH
//+--------------------------------------------------------------------+
