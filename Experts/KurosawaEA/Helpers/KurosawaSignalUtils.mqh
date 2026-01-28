//+------------------------------------------------------------------+
//| File: KurosawaSignalUtils.mqh                                    |
//| Type: Include Library                                            |
//| Ver : 0.1.0                                                      |
//|                                                                  |
//| Description                                                      |
//| Small signal-related helpers shared across the Kurosawa EA suite.|
//|                                                                  |
//| Scope                                                            |
//| - New CLOSED bar detection (shift=1)                             |
//| - Safe indicator buffer reads (single + pair)                    |
//| - Simple regime helpers (ADX quiet, ATR window checks)           |
//+------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_SIGNAL_UTILS_MQH
#define KUROSAWA_SIGNAL_UTILS_MQH

// Detect "new CLOSED bar" by watching shift=1 bar time.
// Why shift=1:
// - shift=0 is still forming (intra-bar noise)
// - shift=1 is the most recently CLOSED bar (stable/reproducible)
//
// Returns true once per new bar and updates lastClosedBarTime.
bool IsNewClosedBar(const string symbol, const ENUM_TIMEFRAMES tf, datetime &lastClosedBarTime)
{
   const datetime t1 = (datetime)iTime(symbol, tf, 1);
   if(t1 == 0) return false;

   if(t1 != lastClosedBarTime)
   {
      lastClosedBarTime = t1;
      return true;
   }
   return false;
}

// Copy a single indicator value from a buffer at the requested shift.
// Fail-safe behavior:
// - Returns false on any failure so callers can "refuse to trade" safely.
bool GetIndicatorValue(const int handle, const int buffer, const int shift, double &outVal)
{
   double v[];
   ArraySetAsSeries(v, true);

   if(CopyBuffer(handle, buffer, shift, 1, v) != 1)
      return false;

   outVal = v[0];
   return true;
}

// ADX "quiet market" check on the last CLOSED bar (shift=1).
// Returns false on read failure (fail-safe: do not trade).
bool IsTrendQuiet(const int adxHandle, const double maxAdxValue)
{
   if(adxHandle == INVALID_HANDLE)
      return false;

   double adx[];
   ArraySetAsSeries(adx, true);

   if(CopyBuffer(adxHandle, 0, 1, 1, adx) != 1)
      return false;

   return (adx[0] <= maxAdxValue);
}

// Simple ATR window check (ATR already converted to points by the caller).
bool IsAtrWithinPoints(const double atrPts, const double minPts, const double maxPts)
{
   return (atrPts >= minPts && atrPts <= maxPts);
}

// Simple ADX threshold check (caller provides ADX value).
bool IsAdxBelow(const double adx, const double maxAdx)
{
   return (adx <= maxAdx);
}

// ------------------------------------------------------------------
// Indicator buffer helpers
// ------------------------------------------------------------------

// Read TWO consecutive values from the main buffer (buffer 0).
// Typical use: crossover detection on CLOSED bars.
// Example: shiftStart=1 -> reads values at [1] and [2].
bool ReadBuffer2(const int handle, const int shiftStart, double &v1, double &v2)
{
   if(handle == INVALID_HANDLE)
      return false;

   double arr[];
   ArraySetAsSeries(arr, true);

   if(CopyBuffer(handle, 0, shiftStart, 2, arr) != 2)
      return false;

   v1 = arr[0]; // shiftStart
   v2 = arr[1]; // shiftStart + 1
   return true;
}

// Read ONE value from the main buffer (buffer 0) at a given shift.
bool ReadBuffer1(const int handle, const int shift, double &v)
{
   if(handle == INVALID_HANDLE)
      return false;

   double arr[];
   ArraySetAsSeries(arr, true);

   if(CopyBuffer(handle, 0, shift, 1, arr) != 1)
      return false;

   v = arr[0];
   return true;
}

#endif // KUROSAWA_SIGNAL_UTILS_MQH
//+------------------------------------------------------------------+
