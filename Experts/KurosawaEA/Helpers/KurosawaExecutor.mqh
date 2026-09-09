//+------------------------------------------------------------------+
//| File: Helpers/KurosawaExecutor.mqh                               |
//| Type: Include Library (composes Risk + Exec + Time primitives)   |
//| Ver : 0.1.0                                                      |
//|                                                                  |
//| Purpose                                                          |
//| - ONE shared order executor + safety gate for ALL engines, so    |
//|   the PlaceTrade() and gate logic is defined once (no per-engine  |
//|   copy-paste to drift or fix in N places).                       |
//| - Exec_PlaceTrade() wraps: risk-based sizing, POINTS->price       |
//|   SL/TP, broker stop/freeze validation, a broker-SUPPORTED        |
//|   filling mode, and a bounded retry on transient send failures    |
//|   (requote / price-changed / price-off).                         |
//| - Gates_CheckFlat() runs the flat-state safety gates in one place |
//|   and returns the first failing reason; the engine maps that      |
//|   reason to its own diagnostic counter.                          |
//|                                                                  |
//| Dependencies (all self-contained, guarded against double-include)|
//| - KurosawaTime.mqh        (IsTimeWindowByOffsetHours)            |
//| - KurosawaExecUtils.mqh   (EnsureStopsLevel, SpreadOK, ...)       |
//| - KurosawaRiskManager.mqh (Risk_CalcTradeVolume, gates, state)   |
//+------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_EXECUTOR_MQH
#define KUROSAWA_EXECUTOR_MQH

#include <Trade/Trade.mqh>
#include "KurosawaTime.mqh"
#include "KurosawaExecUtils.mqh"
#include "KurosawaRiskManager.mqh"

// ------------------------------------------------------------------
// Per-engine execution configuration (built once from EA inputs).
// ------------------------------------------------------------------
struct ExecConfig
{
   ulong  magic;
   string eaName;
   string eaVersion;
   int    deviationPoints;
   bool   useRiskSizing;
   double riskPercent;
   double fixedLot;
   double maxLotCap;
   bool   requireTp;        // true: reject the entry if a valid TP cannot be placed
   int    maxSendRetries;   // extra attempts on transient send failures (e.g. 2)
};

// ------------------------------------------------------------------
// Shared order executor.
// Converts a signal (BUY/SELL + SL/TP in POINTS) into a market order:
//   size -> price SL/TP -> broker-stops validation -> filling mode -> send (+retry).
// Increments the matching diagnostic counter on failure, diag_trades on success.
// Returns true only if the order was placed.
// ------------------------------------------------------------------
bool Exec_PlaceTrade(
   CTrade      &trader,
   const string sym,
   const bool   isBuy,
   const double slPts,
   const double tpPts,
   const ExecConfig &cfg,
   DailyRiskState &risk,
   int &diag_trades,
   int &diag_block_orderfail,
   int &diag_block_indfail,
   int &diag_block_stops
)
{
   // Defensive: strategy/math must never send non-positive distances.
   if(slPts <= 0.0 || tpPts <= 0.0)
      return false;

   // 1) Position sizing (fail-safe: 0.0 => skip the trade).
   const double vol = Risk_CalcTradeVolume(
      sym, slPts, cfg.useRiskSizing, cfg.riskPercent, cfg.fixedLot, cfg.maxLotCap
   );
   if(vol <= 0.0)
   {
      // Risk-based sizing refuses rather than oversizing to min lot (see
      // Risk_NormalizeVolumeStrict). On a small account that means the EA
      // simply never trades, so say so instead of standing down in silence.
      PrintFormat("EXEC_NO_VOLUME sym=%s slPts=%.1f riskPct=%.2f fixedLot=%.2f"
                  " - cannot size a lot within the risk budget, skipping signal",
                  sym, slPts, cfg.riskPercent, cfg.fixedLot);
      diag_block_orderfail++;
      return false;
   }

   const double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(pt <= 0.0)
   {
      diag_block_indfail++;
      return false;
   }

   // 2) Configure the executor once for this send.
   trader.SetExpertMagicNumber(cfg.magic);
   trader.SetDeviationInPoints(cfg.deviationPoints);
   trader.SetTypeFillingBySymbol(sym); // pick a filling mode the broker/symbol supports

   const string base = cfg.eaName + "|" + cfg.eaVersion + (isBuy ? "|BUY" : "|SELL");
   const int    attempts = 1 + (cfg.maxSendRetries > 0 ? cfg.maxSendRetries : 0);

   for(int attempt = 0; attempt < attempts; ++attempt)
   {
      // Re-read prices each attempt (they move on requote / price-changed).
      const double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      const double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      if(ask <= 0.0 || bid <= 0.0)
      {
         diag_block_indfail++;
         return false;
      }

      const double entry = isBuy ? ask : bid;

      // The server measures SL/TP distance against the CLOSING side: Bid for a
      // long, Ask for a short. Pass the same snapshot we are about to trade on,
      // so validation and the order agree.
      const double refClose = isBuy ? bid : ask;

      double sl = isBuy ? (entry - slPts * pt) : (entry + slPts * pt);
      double tp = isBuy ? (entry + tpPts * pt) : (entry - tpPts * pt);

      // Validate/adjust SL/TP against the broker's minimum placement distance.
      if(!EnsureStopsLevelRef(sym, entry, refClose, sl, tp, isBuy, cfg.requireTp))
      {
         diag_block_stops++;
         return false;
      }

      // EnsureStopsLevel can only push the stop FURTHER from entry, never
      // closer. Volume was sized for the requested slPts, so sending a widened
      // stop on that volume risks proportionally more than riskPercent -- e.g.
      // a 40-point stop clamped to 100 on a broker with STOPS_LEVEL=100 risks
      // 2.5x. Re-size from the distance actually being sent, and stand down if
      // it cannot be sized inside the risk budget.
      double sendVol = vol;
      const double effSlPts = MathAbs(entry - sl) / pt;

      if(effSlPts > slPts * 1.0001)
      {
         sendVol = Risk_CalcTradeVolume(
            sym, effSlPts, cfg.useRiskSizing, cfg.riskPercent, cfg.fixedLot, cfg.maxLotCap
         );

         if(sendVol <= 0.0)
         {
            PrintFormat("EXEC_STOP_WIDENED sym=%s reqSL=%.1f effSL=%.1f pts"
                        " - cannot size within risk, standing down",
                        sym, slPts, effSlPts);
            diag_block_stops++;
            return false;
         }

         PrintFormat("EXEC_RESIZED sym=%s reqSL=%.1f effSL=%.1f pts vol %.2f -> %.2f",
                     sym, slPts, effSlPts, vol, sendVol);
      }

      const bool ok = isBuy ? trader.Buy(sendVol, sym, 0.0, sl, tp, base)
                            : trader.Sell(sendVol, sym, 0.0, sl, tp, base);
      if(ok)
      {
         // CTrade returns true for TRADE_RETCODE_DONE_PARTIAL as well as DONE,
         // so a thin book can fill far less than requested and still look like
         // a clean send. Surface it: the position, its R-multiple and the
         // reported track record are all wrong for that trade otherwise.
         const double filled = trader.ResultVolume();
         if(filled > 0.0 && filled + 1e-8 < sendVol)
            PrintFormat("EXEC_PARTIAL_FILL sym=%s requested=%.2f filled=%.2f retcode=%u",
                        sym, sendVol, filled, trader.ResultRetcode());

         Risk_OnTradePlaced(risk, TimeCurrent());
         diag_trades++;
         return true;
      }

      // Retry only on transient conditions; break on a permanent rejection.
      const uint rc = trader.ResultRetcode();
      const bool transient = (rc == TRADE_RETCODE_REQUOTE
                           || rc == TRADE_RETCODE_PRICE_CHANGED
                           || rc == TRADE_RETCODE_PRICE_OFF);
      if(!transient)
         break;
   }

   Print("EXEC_TRADE_FAILED ", (isBuy ? "BUY" : "SELL"),
         " sym=", sym,
         " retcode=", trader.ResultRetcode(),
         " desc=", trader.ResultRetcodeDescription());
   diag_block_orderfail++;
   return false;
}

// ------------------------------------------------------------------
// Shared flat-state safety gate.
// Returns the FIRST failing reason (or GATE_OK). The engine maps the
// reason to its own diagnostic counter, keeping the gate logic in one place.
// ------------------------------------------------------------------
enum GateResult
{
   GATE_OK = 0,
   GATE_BLOCK_SESSION,
   GATE_BLOCK_SPREAD,
   GATE_BLOCK_COOLDOWN,
   GATE_BLOCK_MAXDAY,
   GATE_BLOCK_LOSS,
   GATE_BLOCK_MAXTRADES
};

GateResult Gates_CheckFlat(
   const string sym,
   const DailyRiskState &risk,
   const int    consecLosses,
   const int    startHour,
   const int    endHour,
   const int    utcOffset,
   const int    maxSpreadPoints,
   const int    cooldownMinutes,
   const double dailyLossLimitPercent,
   const int    maxConsecLosses,
   const int    maxTradesPerDay,
   const datetime nowTime
)
{
   if(!IsTimeWindowByOffsetHours(startHour, endHour, utcOffset)) return GATE_BLOCK_SESSION;
   if(!SpreadOK(sym, maxSpreadPoints))                           return GATE_BLOCK_SPREAD;
   if(!CooldownOK(risk, cooldownMinutes, nowTime))               return GATE_BLOCK_COOLDOWN;
   if(!DailyLossLimitOK(risk, dailyLossLimitPercent))            return GATE_BLOCK_MAXDAY;
   if(!LossStreakOK(consecLosses, maxConsecLosses))              return GATE_BLOCK_LOSS;
   if(maxTradesPerDay > 0 && risk.trades_today >= maxTradesPerDay) return GATE_BLOCK_MAXTRADES;
   return GATE_OK;
}

#endif // KUROSAWA_EXECUTOR_MQH
