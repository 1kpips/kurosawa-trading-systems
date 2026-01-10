//+------------------------------------------------------------------+
//| File: KurosawaHelpers.mqh                                        |
//| Type: Include Library                                            |
//| Ver : 0.1.3                                                      |
//|                                                                  |
//| Description: Global utility functions for the KurosawaEA suite.  |
//| - Handles JST time conversions for session-based trading.        |
//| - Standardizes pip-to-price math for 3/5 digit brokers.          |
//| - Validates broker constraints (StopsLevel/FreezeLevel).         |
//| - Provides cross-EA position and trend regime detection.         |
//+------------------------------------------------------------------+
#property strict

//--- Returns current time adjusted to Japan Standard Time (JST)
datetime NowJst(int offsetHours) { 
   return TimeGMT() + (offsetHours * 3600); 
}

//--- Converts datetime to integer YYYYMMDD for daily reset logic
int JstYmd(datetime t) { 
   MqlDateTime dt; TimeToStruct(t, dt); 
   return dt.year*10000 + dt.mon*100 + dt.day; 
}

//--- Checks if current JST time is within the allowed window (supports midnight crossing)
bool IsEntryTimeJST(int startHour, int endHour, int offsetHours) {
   MqlDateTime dt; TimeToStruct(NowJst(offsetHours), dt);
   if(startHour <= endHour) return (dt.hour >= startHour && dt.hour < endHour);
   return (dt.hour >= startHour || dt.hour < endHour);
}

//--- Robust pip-to-price conversion (Auto-detects 3/5 digit brokers)
double PipsToPrice(string symbol, double pips) {
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   // For JPY (3-digit) and standard FX (5-digit), 1 pip = 10 points
   double pipVal = (digits == 3 || digits == 5) ? 10 * SymbolInfoDouble(symbol, SYMBOL_POINT) : SymbolInfoDouble(symbol, SYMBOL_POINT);
   return pips * pipVal;
}

//--- Ensures SL/TP distances respect broker's minimum StopsLevel and FreezeLevel
bool EnsureStopsLevel(string symbol, double entryPrice, double &sl, double &tp, bool isBuy, bool adjustOutward) {
   int stopsLevel  = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freezeLevel = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist  = MathMax(stopsLevel, freezeLevel) * SymbolInfoDouble(symbol, SYMBOL_POINT);
   
   if(minDist <= 0) return true;

   bool modified = false;
   if(isBuy) {
      if(sl > 0 && (entryPrice - sl) < minDist) { sl = entryPrice - minDist; modified = true; }
      if(tp > 0 && (tp - entryPrice) < minDist) { tp = entryPrice + minDist; modified = true; }
   } else {
      if(sl > 0 && (sl - entryPrice) < minDist) { sl = entryPrice + minDist; modified = true; }
      if(tp > 0 && (entryPrice - tp) < minDist) { tp = entryPrice - minDist; modified = true; }
   }

   // If adjustment is disabled but levels are violated, return false to block order
   if(modified && !adjustOutward) return false;

   // Final price normalization
   sl = (sl > 0 ? NormalizeDouble(sl, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)) : 0);
   tp = (tp > 0 ? NormalizeDouble(tp, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)) : 0);
   return true;
}

//--- Validates minimum volume requirements
double GetMinLot(string symbol) {
   double vmin = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double vstep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   return (vstep > 0) ? MathFloor(vmin / vstep) * vstep : 0.01;
}

//--- Checks if an EA position already exists for a specific Magic Number
bool PositionExists(string symbol, int magic) {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t) && 
         PositionGetString(POSITION_SYMBOL) == symbol && 
         PositionGetInteger(POSITION_MAGIC) == magic) return true;
   }
   return false;
}

//--- Filters out trending markets for Mean Reversion strategies
bool IsTrendQuiet(int adxHandle, double maxAdxValue) {
   double adxBuf[];
   ArraySetAsSeries(adxBuf, true);
   if(CopyBuffer(adxHandle, 0, 1, 1, adxBuf) != 1) return false;
   return (adxBuf[0] <= maxAdxValue);
}
