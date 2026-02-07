//+------------------------------------------------------------------+
//| File: Helpers/KurosawaExecUtils.mqh                              |
//| Type: Include Library                                            |
//| Ver : 0.1.0                                                      |
//|                                                                  |
//| Description                                                      |
//| Execution utilities bundle for the Kurosawa EA suite.            |
//|                                                                  |
//| Why this file exists                                             |
//| - This is a self-contained helper: it does not include or rely   |
//|   on any other Kurosawa helper file.                             |
//| - It bundles the small "execution primitives" that often depend  |
//|   on each other in real EAs:                                     |
//|     * indicator buffer reads (CopyBuffer wrapper)                |
//|     * new closed bar detection                                   |
//|     * spread checks                                              |
//|     * broker stop/freeze validation for SL/TP                    |
//|     * one-position-per-(symbol, magic) selection                 |
//|     * time-stop exit (max hold minutes)                          |
//|     * ATR-step trailing stop management                          |
//|                                                                  |
//| Units                                                            |
//| - POINTS: distance in SYMBOL_POINT units                         |
//| - PRICE : actual price value                                     |
//|                                                                  |
//| Notes                                                            |
//| - Engines should treat this file as execution infrastructure.    |
//| - Strategy modules remain "pure" and should not place orders.    |
//| - All comments are public-repo friendly (no broker assumptions). |
//+------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_EXEC_UTILS_MQH
#define KUROSAWA_EXEC_UTILS_MQH

#include <Trade/Trade.mqh>

// ------------------------------------------------------------------
// Symbol helpers
// ------------------------------------------------------------------

// Resolve traded symbol: preset target pair wins, otherwise chart symbol.
string ResolveEngineSymbol(const string targetPair, const string chartSymbol)
{
   return (StringLen(targetPair) > 0 ? targetPair : chartSymbol);
}

// Safe digit lookup (fallback to _Digits)
int SymbolDigitsSafe(const string sym)
{
   const int d = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   return (d > 0 ? d : (int)_Digits);
}

// Safe point lookup (fallback to _Point)
double SymbolPointSafe(const string sym)
{
   const double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   return (pt > 0.0 ? pt : _Point);
}

// Normalize a price to the symbol digits.
double NormalizePrice(const string sym, const double price)
{
   return NormalizeDouble(price, SymbolDigitsSafe(sym));
}

// ------------------------------------------------------------------
// Spread helpers (POINTS)
// ------------------------------------------------------------------

// Returns spread in POINTS, or -1 on failure.
int SpreadPoints(const string sym)
{
   const double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   const double pt  = SymbolPointSafe(sym);

   if(ask <= 0.0 || bid <= 0.0 || pt <= 0.0)
      return -1;

   return (int)MathRound((ask - bid) / pt);
}

// True if spread <= maxSpreadPoints.
// If maxSpreadPoints <= 0, always true (spread gate disabled).
bool SpreadOK(const string sym, const int maxSpreadPoints)
{
   if(maxSpreadPoints <= 0)
      return true;

   const int sp = SpreadPoints(sym);
   if(sp < 0)
      return false;

   return (sp <= maxSpreadPoints);
}

// ------------------------------------------------------------------
// Indicator buffer helpers
// ------------------------------------------------------------------

// Reads ONE value from an indicator handle via CopyBuffer.
// - handle: indicator handle
// - buffer: indicator buffer index (usually 0)
// - shift : bar shift (1 = last closed bar)
// Returns true on success and sets outValue.
bool GetIndicatorValue(const int handle, const int buffer, const int shift, double &outValue)
{
   outValue = 0.0;

   if(handle == INVALID_HANDLE || shift < 0)
      return false;

   double tmp[];
   ArraySetAsSeries(tmp, true);

   ResetLastError();
   const int got = CopyBuffer(handle, buffer, shift, 1, tmp);
   if(got != 1)
      return false;

   if(tmp[0] == EMPTY_VALUE)
      return false;

   outValue = tmp[0];
   return true;
}

// ------------------------------------------------------------------
// Bar timing helper (closed-bar execution)
// ------------------------------------------------------------------

// Returns true exactly once per NEW closed bar.
// Uses iTime(sym, tf, 1) to refer to the last CLOSED bar.
// Updates lastClosedBarTime when a new closed bar is detected.
bool IsNewClosedBar(const string sym, const ENUM_TIMEFRAMES tf, datetime &lastClosedBarTime)
{
   const datetime t = (datetime)iTime(sym, tf, 1);
   if(t <= 0)
      return false;

   if(t == lastClosedBarTime)
      return false;

   lastClosedBarTime = t;
   return true;
}

// ------------------------------------------------------------------
// SL/TP validation (broker stops/freeze level)
// ------------------------------------------------------------------

// Adjusts SL/TP if needed to satisfy broker min distance constraints.
// Parameters
// - entry: reference price (typically current market price at send time)
// - sl/tp: in/out (may be adjusted)
// - isBuy: true=BUY, false=SELL
// - requireTp: if true, tp must be present and valid
//
// Returns false if constraints cannot be satisfied.
bool EnsureStopsLevel(
   const string sym,
   const double entry,
   double &sl,
   double &tp,
   const bool isBuy,
   const bool requireTp
)
{
   if(entry <= 0.0)
      return false;

   const double pt = SymbolPointSafe(sym);
   if(pt <= 0.0)
      return false;

   if(sl <= 0.0)
      return false;

   if(requireTp && tp <= 0.0)
      return false;

   // Broker constraints in points
   const int stopsPts  = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   const int freezePts = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL);

   // Use the stricter minimum distance
   int minPts = stopsPts;
   if(freezePts > minPts) minPts = freezePts;
   if(minPts < 1) minPts = 1;

   const double minDist = (double)minPts * pt;

   if(isBuy)
   {
      // Direction sanity
      if(sl >= entry)               sl = entry - minDist;
      if(tp > 0.0 && tp <= entry)   tp = entry + minDist;

      // Minimum distance
      if(entry - sl < minDist)      sl = entry - minDist;
      if(tp > 0.0 && tp - entry < minDist) tp = entry + minDist;
   }
   else
   {
      // Direction sanity
      if(sl <= entry)               sl = entry + minDist;
      if(tp > 0.0 && tp >= entry)   tp = entry - minDist;

      // Minimum distance
      if(sl - entry < minDist)      sl = entry + minDist;
      if(tp > 0.0 && entry - tp < minDist) tp = entry - minDist;
   }

   sl = NormalizePrice(sym, sl);
   if(tp > 0.0)
      tp = NormalizePrice(sym, tp);

   // Final sanity
   if(isBuy)
   {
      if(sl >= entry) return false;
      if(requireTp && tp <= entry) return false;
   }
   else
   {
      if(sl <= entry) return false;
      if(requireTp && tp >= entry) return false;
   }

   return true;
}

// ------------------------------------------------------------------
// Position selection helpers (one-position-per-symbol+magic)
// ------------------------------------------------------------------

// Selects a position by (symbol, magic). Returns true if selected.
bool PositionSelectByMagic(const string symbol, const long magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != magic) continue;

      return true;
   }
   return false;
}

// Returns true if there is a position for (symbol, magic).
bool PositionExists(const string symbol, const long magic)
{
   return PositionSelectByMagic(symbol, magic);
}

// ------------------------------------------------------------------
// Private helper: minutes held
// ------------------------------------------------------------------

// Whole minutes between openTime and nowTime.
// Returns -1 on invalid input.
int _MinutesHeld(const datetime openTime, const datetime nowTime)
{
   if(openTime <= 0)
      return -1;

   if(nowTime <= openTime)
      return 0;

   return (int)((nowTime - openTime) / 60);
}

// ------------------------------------------------------------------
// Time-stop exit (max holding time)
// ------------------------------------------------------------------

// Closes the position if held >= maxHoldMinutes.
// Returns true only if the position was closed successfully.
bool Position_CheckMaxHoldExit(
   CTrade &trader,
   const string sym,
   const long magic,
   const int maxHoldMinutes,
   const datetime nowTime
)
{
   if(maxHoldMinutes <= 0)
      return false;

   if(!PositionSelectByMagic(sym, magic))
      return false;

   const datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
   const int heldMin = _MinutesHeld(openTime, nowTime);

   if(heldMin < 0 || heldMin < maxHoldMinutes)
      return false;

   return trader.PositionClose(sym);
}

// ------------------------------------------------------------------
// ATR-step trailing stop management
// ------------------------------------------------------------------

// Applies an ATR-step trailing stop to the selected position.
//
// Trailing policy (stable + defensive):
// - Read ATR on last closed bar (shift=1) to avoid intrabar noise.
// - Start trailing only after profit >= trailStartR * initialRisk.
// - Step size: ATR * trailStepAtrMult.
// - Never loosen SL (only move in direction of profit).
// - Validate new SL/TP against broker constraints before modifying.
//
// Diagnostics counters are incremented when failures happen:
// - diag_block_indfail: ATR or price read failed
// - diag_block_stops  : broker stop/freeze constraints blocked the modify
// - diag_block_orderfail: PositionModify failed
bool Position_ManageAtrTrailing(
   CTrade &trader,
   const string sym,
   const long magic,
   const int hATR,
   const double trailStartR,
   const double trailStepAtrMult,
   int &diag_block_indfail,
   int &diag_block_stops,
   int &diag_block_orderfail
)
{
   if(trailStartR <= 0.0 || trailStepAtrMult <= 0.0)
      return false;

   if(!PositionSelectByMagic(sym, magic))
      return false;

   const long  type  = (long)PositionGetInteger(POSITION_TYPE);
   const bool  isBuy = (type == POSITION_TYPE_BUY);

   const double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   const double slCur = PositionGetDouble(POSITION_SL);
   const double tpCur = PositionGetDouble(POSITION_TP);

   // Trailing requires a valid entry and SL because initial risk is derived from SL
   if(entry <= 0.0 || slCur <= 0.0)
      return false;

   // 1) ATR (PRICE units) from last closed bar
   double atrPrice = 0.0;
   if(!GetIndicatorValue(hATR, 0, 1, atrPrice) || atrPrice <= 0.0)
   {
      diag_block_indfail++;
      return false;
   }

   // 2) Step size in PRICE
   const double step = atrPrice * trailStepAtrMult;
   if(step <= 0.0)
      return false;

   // 3) Initial risk reference (PRICE)
   const double riskRef = isBuy ? (entry - slCur) : (slCur - entry);
   if(riskRef <= 0.0)
      return false;

   // 4) Current market price
   const double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   const double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
   {
      diag_block_indfail++;
      return false;
   }

   const double px     = isBuy ? bid : ask;
   const double profit = isBuy ? (px - entry) : (entry - px);

   // Do not trail until we reach minimum profit in R terms
   if(profit < (trailStartR * riskRef))
      return false;

   // 5) Candidate SL: keep it step behind price; never loosen
   double slNew = slCur;

   if(isBuy)
   {
      const double cand = px - step;
      if(cand > slCur) slNew = cand;
   }
   else
   {
      const double cand = px + step;
      if(cand < slCur) slNew = cand;
   }

   slNew = NormalizePrice(sym, slNew);
   if(slNew == slCur)
      return false;

   // 6) Validate broker constraints before applying
   double slTry = slNew;
   double tpTry = tpCur;

   if(!EnsureStopsLevel(sym, entry, slTry, tpTry, isBuy, false))
   {
      diag_block_stops++;
      return false;
   }

   // 7) Apply modification
   if(!trader.PositionModify(sym, slTry, tpTry))
   {
      diag_block_orderfail++;
      return false;
   }

   return true;
}

// ============================================================================
// RangeRevert execution helpers (engine-side)
// - History/indicator readiness
// - Position management helpers (mid-band exit, time-stop)
// - Trade failure logging
// ============================================================================

// Required bars heuristic for RangeRevert indicators.
int RR_RequiredBarsForInit(
   const int bbPeriod,
   const int atrPeriod,
   const int rsiPeriod,
   const bool useAdxFilter,
   const double adxMaxToTrade,
   const int adxPeriod
)
{
   int req = 200;
   req = (int)MathMax(req, bbPeriod  + 10);
   req = (int)MathMax(req, atrPeriod + 10);
   req = (int)MathMax(req, rsiPeriod + 10);

   if(useAdxFilter && adxMaxToTrade > 0.0)
      req = (int)MathMax(req, adxPeriod + 10);

   return req;
}

// Force-load and confirm history is accessible.
bool RR_EnsureHistoryReady(const string symbol, const ENUM_TIMEFRAMES tf, const int requiredBars)
{
   if(requiredBars <= 0) return true;
   if(Bars(symbol, tf) < requiredBars) return false;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   const int want = MathMin(requiredBars, 300);
   const int got  = CopyRates(symbol, tf, 0, want, rates);

   return (got >= want);
}

// BarsCalculated sanity check to reduce early CopyBuffer failures.
bool RR_EnsureIndicatorsCalculated(
   const int hAtrHandle,
   const int hRsiHandle,
   const int hBbHandle,
   const int hAdxHandle
)
{
   if(hAtrHandle == INVALID_HANDLE || BarsCalculated(hAtrHandle) < 3) return false;
   if(hRsiHandle == INVALID_HANDLE || BarsCalculated(hRsiHandle) < 3) return false;
   if(hBbHandle  == INVALID_HANDLE || BarsCalculated(hBbHandle)  < 3) return false;

   if(hAdxHandle != INVALID_HANDLE && BarsCalculated(hAdxHandle) < 3) return false;
   return true;
}

// Grep-friendly order failure logging.
// Pass CTrade by reference so we can read ResultRetcode/Description.
void RR_LogTradeFail(CTrade &execTrade, const string tag)
{
   const int err = GetLastError();
   Print("TRADE_FAILED ", tag,
         " retcode=", execTrade.ResultRetcode(),
         " desc=", execTrade.ResultRetcodeDescription(),
         " err=", err);
}

// Mid-band exit for an existing position.
// Requires:
// - BB handle (iBands)
// - GetIndicatorValue() existing in the same exec utils file
bool RR_CheckMidBandExitAndClose(
   CTrade &execTrade,
   const string sym,
   const int hBbHandle,
   const bool useMidBandExit,
   const bool isBuy
)
{
   if(!useMidBandExit)
      return false;

   // BB: buffer 1 is middle band
   double bbMid = 0.0;
   if(!GetIndicatorValue(hBbHandle, 1, 1, bbMid))
      return false;

   const double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   const double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return false;

   if(isBuy  && bid >= bbMid) return execTrade.PositionClose(sym);
   if(!isBuy && ask <= bbMid) return execTrade.PositionClose(sym);

   return false;
}


// Time-stop close wrapper.
// If you want to keep engine as “events + PlaceTrade only”, call into exec utils.
bool RR_CheckMaxHoldAndClose(
   CTrade &execTrade,
   const string sym,
   const long magic,
   const int maxHoldMinutes,
   const datetime nowTime
)
{
   if(maxHoldMinutes <= 0) return false;
   return Position_CheckMaxHoldExit(execTrade, sym, magic, maxHoldMinutes, nowTime);
}

#endif // KUROSAWA_EXEC_UTILS_MQH
//+------------------------------------------------------------------+
