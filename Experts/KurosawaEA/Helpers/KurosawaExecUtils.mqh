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

// Guard against attaching an EA to the wrong chart.
//
// ResolveEngineSymbol above means the EA trades InpTargetPair regardless of which
// chart it sits on. That is deliberate, but it also means a wrong attach trades a
// DIFFERENT instrument than the chart displays, and the only signal was a warning
// that scrolled past. With strict on, the mismatch fails init loudly instead.
//
// Returns false only when strict is on AND the chart does not match. Logs either way.
bool ChartMatchesTarget(const string targetPair,
                        const ENUM_TIMEFRAMES targetTf,
                        const bool strict)
{
   const string tag = (strict ? "INIT_FAILED" : "Warning");
   bool ok = true;

   if(StringLen(targetPair) > 0 && _Symbol != targetPair)
   {
      PrintFormat("%s: intended symbol=%s but chart symbol=%s", tag, targetPair, _Symbol);
      ok = false;
   }

   // PERIOD_CURRENT (0) is a legitimate value meaning "use whatever chart I am on":
   // MQL5 resolves 0 to the current timeframe in iATR/iTime/CopyBuffer, so the EA
   // works correctly with it. It is also the FIRST entry in MT5's timeframe
   // dropdown, so an input that was never set sits there. Treat it as a wildcard,
   // exactly as an empty targetPair is treated above - do not reject it.
   if(targetTf != PERIOD_CURRENT && _Period != targetTf)
   {
      PrintFormat("%s: intended TF=%s but chart TF=%s", tag,
                  EnumToString(targetTf), EnumToString((ENUM_TIMEFRAMES)_Period));
      ok = false;
   }

   if(!ok && strict)
      PrintFormat("Attach to a %s %s chart, or load the matching preset from MQL5 Presets."
                  " Set InpStrictChartMatch=false to run cross-chart on purpose.",
                  targetPair, EnumToString(targetTf));

   return (ok || !strict);
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
// Broker distance constraints
//
// STOPS_LEVEL and FREEZE_LEVEL are DIFFERENT constraints and must not be
// merged:
//   STOPS_LEVEL  - minimum distance from market at which an SL/TP may be
//                  PLACED. Applies when sending or modifying.
//   FREEZE_LEVEL - a band around the market inside which an existing
//                  position's SL/TP may NOT be modified and the position may
//                  not be closed. Says nothing about where a stop may sit.
// Taking max(stops, freeze) as a placement minimum (the previous behaviour)
// silently widens every stop on brokers with a large freeze level, which
// inflates realized risk per trade, while leaving the real freeze constraint
// unchecked on modify/close.
// ------------------------------------------------------------------

// Minimum SL/TP placement distance, in PRICE units.
double StopsDistance(const string sym)
{
   const int pts = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   return (double)(pts > 0 ? pts : 0) * SymbolPointSafe(sym);
}

// Freeze band half-width, in PRICE units. 0 on most FX symbols.
double FreezeDistance(const string sym)
{
   const int pts = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)(pts > 0 ? pts : 0) * SymbolPointSafe(sym);
}

// The price the SERVER validates a position's SL/TP against:
// Bid closes a long, Ask closes a short.
double CloseSidePrice(const string sym, const bool isBuy)
{
   return SymbolInfoDouble(sym, isBuy ? SYMBOL_BID : SYMBOL_ASK);
}

// Round a price onto the symbol's TICK grid.
// NormalizePrice only rounds to DIGITS, which is not the same thing whenever
// SYMBOL_TRADE_TICK_SIZE > SYMBOL_POINT (indices, some metals and CFDs); an
// off-grid price is rejected by the server. dir: -1 floor, +1 ceil, 0 nearest.
double RoundToTick(const string sym, const double price, const int dir)
{
   double ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0.0)
      ts = SymbolPointSafe(sym);
   if(ts <= 0.0)
      return NormalizePrice(sym, price);

   const double q = price / ts;
   double n;
   if(dir < 0)      n = MathFloor(q + 1e-8);
   else if(dir > 0) n = MathCeil(q - 1e-8);
   else             n = MathRound(q);

   return NormalizeDouble(n * ts, SymbolDigitsSafe(sym));
}

// True if `price` sits inside the broker's freeze band around the market, i.e.
// the server will refuse a modify/close that involves it.
bool InFreezeBand(const string sym, const bool isBuy, const double price)
{
   if(price <= 0.0)
      return false;

   const double fz = FreezeDistance(sym);
   if(fz <= 0.0)
      return false;   // no freeze band on this symbol

   const double ref = CloseSidePrice(sym, isBuy);
   if(ref <= 0.0)
      return false;

   return (MathAbs(ref - price) < fz);
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

// Adjusts SL/TP if needed to satisfy the broker's minimum placement distance.
// Parameters
// - entry   : the fill/reference price the caller derived sl/tp from. Used for
//             DIRECTION sanity only (a long's stop must sit below its entry).
// - refClose: the price the SERVER measures SL/TP distance against - Bid for a
//             long, Ask for a short. Measuring from `entry` instead overstates
//             the distance by exactly the spread, so an order can pass local
//             validation and still be rejected with 10016 Invalid stops. That
//             recurs precisely at news and rollover, when the spread is widest.
// - sl/tp   : in/out (may be widened, never tightened)
// - isBuy   : true=BUY, false=SELL
// - requireTp: if true, tp must be present and valid
//
// Returns false if constraints cannot be satisfied.
bool EnsureStopsLevelRef(
   const string sym,
   const double entry,
   const double refClose,
   double &sl,
   double &tp,
   const bool isBuy,
   const bool requireTp
)
{
   if(entry <= 0.0 || refClose <= 0.0)
      return false;

   const double pt = SymbolPointSafe(sym);
   if(pt <= 0.0)
      return false;

   if(sl <= 0.0)
      return false;

   if(requireTp && tp <= 0.0)
      return false;

   // Placement minimum is STOPS_LEVEL only. FREEZE_LEVEL is a modify/close
   // constraint and is checked separately at those call sites.
   double minDist = StopsDistance(sym);
   if(minDist < pt)
      minDist = pt;   // never allow a zero-width stop

   if(isBuy)
   {
      // Direction sanity is measured against the entry price...
      if(sl >= entry)               sl = entry - minDist;
      if(tp > 0.0 && tp <= entry)   tp = entry + minDist;

      // ...but the minimum distance is measured against the price the server
      // validates - Bid for a long.
      if(refClose - sl < minDist)             sl = refClose - minDist;
      if(tp > 0.0 && tp - refClose < minDist) tp = refClose + minDist;

      // Snap onto the tick grid AWAY from the market, so rounding can never
      // pull a level back inside the minimum distance.
      sl = RoundToTick(sym, sl, -1);
      if(tp > 0.0)
         tp = RoundToTick(sym, tp, +1);
   }
   else
   {
      if(sl <= entry)               sl = entry + minDist;
      if(tp > 0.0 && tp >= entry)   tp = entry - minDist;

      if(sl - refClose < minDist)             sl = refClose + minDist;
      if(tp > 0.0 && refClose - tp < minDist) tp = refClose - minDist;

      sl = RoundToTick(sym, sl, +1);
      if(tp > 0.0)
         tp = RoundToTick(sym, tp, -1);
   }

   // Final sanity: direction must still hold after every adjustment. If a
   // required TP was pushed to the wrong side of entry (possible when the
   // spread exceeds the requested TP distance), stand down rather than send a
   // target that cannot be profitable.
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

// Back-compat wrapper: derives the server-side reference price from the current
// market. Prefer EnsureStopsLevelRef and hand it the bid/ask you already read,
// so validation and the order itself use one consistent snapshot.
bool EnsureStopsLevel(
   const string sym,
   const double entry,
   double &sl,
   double &tp,
   const bool isBuy,
   const bool requireTp
)
{
   const double refClose = CloseSidePrice(sym, isBuy);
   if(refClose <= 0.0)
      return false;

   return EnsureStopsLevelRef(sym, entry, refClose, sl, tp, isBuy, requireTp);
}

// ------------------------------------------------------------------
// Position selection helpers (one-position-per-symbol+magic)
// ------------------------------------------------------------------

// Returns the ticket of the FIRST position matching (symbol, magic), or 0 if none.
// On a match, that position is left SELECTED (PositionGet* then refer to it).
// Prefer this for close/modify so CTrade acts on the RIGHT position by ticket,
// not by symbol (critical on hedging accounts running multiple EAs per symbol).
ulong PositionTicketByMagic(const string symbol, const long magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != magic) continue;

      return ticket;
   }
   return 0;
}

// Selects a position by (symbol, magic). Returns true if selected.
bool PositionSelectByMagic(const string symbol, const long magic)
{
   return (PositionTicketByMagic(symbol, magic) != 0);
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

   const ulong ticket = PositionTicketByMagic(sym, magic);
   if(ticket == 0)
      return false;
   // ticket is now the selected position (see PositionTicketByMagic)

   const datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
   const int heldMin = _MinutesHeld(openTime, nowTime);

   if(heldMin < 0 || heldMin < maxHoldMinutes)
      return false;

   // Freeze band: the server refuses to close a position whose SL/TP sits too
   // close to the market. Skip this tick and retry on the next one rather than
   // burning a rejected close request.
   const bool   isBuyPos = ((long)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
   const double slCur    = PositionGetDouble(POSITION_SL);
   const double tpCur    = PositionGetDouble(POSITION_TP);

   if((slCur > 0.0 && InFreezeBand(sym, isBuyPos, slCur)) ||
      (tpCur > 0.0 && InFreezeBand(sym, isBuyPos, tpCur)))
      return false;

   return trader.PositionClose(ticket); // close by TICKET, not symbol (hedging-safe)
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

   const ulong ticket = PositionTicketByMagic(sym, magic);
   if(ticket == 0)
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

   // 3) Current market price
   const double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   const double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
   {
      diag_block_indfail++;
      return false;
   }

   const double px = isBuy ? bid : ask;

   // 4) Start-trailing gate based on the CURRENT risk distance to SL.
   //    While SL is still on the risk side of entry (riskRef > 0), require profit to
   //    reach trailStartR * risk before trailing. Once SL has locked breakeven+
   //    (riskRef <= 0) we are already trailing in profit, so keep trailing. This
   //    fixes the previous freeze: SL past entry made riskRef negative and the
   //    function bailed out, so the stop stopped advancing when most in profit.
   const double riskRef = isBuy ? (entry - slCur) : (slCur - entry);
   if(riskRef > 0.0)
   {
      const double profit = isBuy ? (px - entry) : (entry - px);
      if(profit < (trailStartR * riskRef))
         return false;
   }

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

   if(slNew == slCur)
      return false;

   // 6) Broker constraints.
   //
   // Do NOT route this through EnsureStopsLevel: that validates against the
   // position's ENTRY price, and its buy branch rewrites any stop at or above
   // entry back to (entry - minDist). A trailing stop sits above entry by
   // definition once in profit, so every trail was being discarded and the
   // position pinned at breakeven. Worse, the discarded value equalled the
   // current SL, so a no-op PositionModify went to the server on every tick -
   // CTrade reports TRADE_RETCODE_NO_CHANGES as failure, so it also counted a
   // block_orderfail per tick.
   //
   // Validate against the CURRENT market on the closing side, and REJECT when
   // the candidate is too close rather than relocating it.
   const double minDist = StopsDistance(sym);

   if(isBuy)
   {
      if(px - slNew < minDist) { diag_block_stops++; return false; }
   }
   else
   {
      if(slNew - px < minDist) { diag_block_stops++; return false; }
   }

   // Freeze band: inside it the server refuses to modify the position at all.
   // Not an error - skip this tick and retry once price has moved out.
   if(InFreezeBand(sym, isBuy, slCur) || InFreezeBand(sym, isBuy, slNew))
      return false;

   if(tpCur > 0.0 && InFreezeBand(sym, isBuy, tpCur))
      return false;

   // Snap to the tick grid, away from the market so rounding cannot breach
   // minDist. Comparing to the current stop AFTER rounding is what stops a
   // sub-tick "change" from becoming a pointless modify request.
   slNew = RoundToTick(sym, slNew, isBuy ? -1 : +1);

   const double pt = SymbolPointSafe(sym);
   if(MathAbs(slNew - slCur) < pt * 0.5)
      return false;

   // Never loosen, even after rounding.
   if(isBuy  && slNew <= slCur) return false;
   if(!isBuy && slNew >= slCur) return false;

   // 7) Apply modification (TP is left untouched)
   if(!trader.PositionModify(ticket, slNew, tpCur))
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
   const long magic,
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

   const bool hit = (isBuy && bid >= bbMid) || (!isBuy && ask <= bbMid);
   if(!hit)
      return false;

   // Close by TICKET (hedging-safe), not by symbol.
   const ulong ticket = PositionTicketByMagic(sym, magic);
   if(ticket == 0)
      return false;

   // Freeze band: the server refuses to close while SL/TP is too close to the
   // market. Skip this tick; the mid-band condition will still hold next tick.
   const double slCur = PositionGetDouble(POSITION_SL);
   const double tpCur = PositionGetDouble(POSITION_TP);

   if((slCur > 0.0 && InFreezeBand(sym, isBuy, slCur)) ||
      (tpCur > 0.0 && InFreezeBand(sym, isBuy, tpCur)))
      return false;

   return execTrade.PositionClose(ticket);
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
