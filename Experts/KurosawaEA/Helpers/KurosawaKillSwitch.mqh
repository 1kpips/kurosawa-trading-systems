//+------------------------------------------------------------------+
//| File: Helpers/KurosawaKillSwitch.mqh                             |
//| Type: Include Library                                            |
//| Ver : 0.1.0                                                      |
//|                                                                  |
//| Rolling-profit-factor kill switch.                               |
//|                                                                  |
//| Why (2026-09-10)                                                 |
//| - The presets that passed 2023-2026 failed 2019-2022 (PF 0.88-  |
//|   0.94). They are a REGIME edge. A regime edge is allowed to run |
//|   live at minimum lot, but it must notice when the regime ends.  |
//|   The daily-loss and consecutive-loss gates cannot: a regime     |
//|   fades slowly, inside those limits, over weeks.                 |
//| - This measures the edge itself: the profit factor of the last N |
//|   closed trades of this instance (magic + symbol). Below the     |
//|   threshold, new entries pause for a fixed number of days. After |
//|   the pause the instance trades a probation of K trades before   |
//|   it is judged again, so a paused window cannot re-pause itself  |
//|   on the same stale trades forever.                              |
//|                                                                  |
//| What it does NOT do                                              |
//| - It never touches an open position; the exit logic owns that.  |
//| - It is not a tuning knob. N=30, PF 0.8 come from the gate       |
//|   document, and every preset carries the same values.           |
//+------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_KILLSWITCH_MQH
#define KUROSAWA_KILLSWITCH_MQH

struct KillState
{
   ulong    lastDealSeen;      // deal id at the last recomputation
   int      closedTrades;      // closed trades found in history for this instance
   double   rollingPf;         // PF over the last N (or fewer) closed trades
   datetime pausedUntil;       // > now while paused
   int      tradesAtResume;    // closedTrades when the last pause ended
   bool     everPaused;
};

void Kill_Reset(KillState &k)
{
   k.lastDealSeen = 0; k.closedTrades = 0; k.rollingPf = 0.0;
   k.pausedUntil = 0; k.tradesAtResume = 0; k.everPaused = false;
}

// ------------------------------------------------------------------
// Profit factor of the last `n` closed deals for (symbol, magic), from the
// account history. Returns the number of closed deals found (all time).
// Profit includes swap and commission - what the account actually saw.
// ------------------------------------------------------------------
int Kill_RollingPf(const string sym, const long magic, const int n, double &pf)
{
   pf = 0.0;
   if(!HistorySelect(0, TimeCurrent() + 86400)) return 0;

   const int total = HistoryDealsTotal();
   double profits[];
   ArrayResize(profits, 0);

   for(int i = 0; i < total; i++)
   {
      const ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != magic) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != sym) continue;
      const long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT && entry != DEAL_ENTRY_OUT_BY) continue;

      const double p = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                     + HistoryDealGetDouble(ticket, DEAL_SWAP)
                     + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      const int sz = ArraySize(profits);
      ArrayResize(profits, sz + 1);
      profits[sz] = p;
   }

   const int count = ArraySize(profits);
   if(count == 0) return 0;

   double gp = 0.0, gl = 0.0;
   const int from = MathMax(0, count - n);
   for(int i = from; i < count; i++)
   {
      if(profits[i] > 0) gp += profits[i]; else gl += -profits[i];
   }
   pf = (gl > 0.0) ? gp / gl : (gp > 0.0 ? 99.0 : 0.0);
   return count;
}

// ------------------------------------------------------------------
// Call before opening a new position. Returns true when entries are allowed.
// Recomputes only when a new closed deal has appeared (lastCloseDealId moves).
// ------------------------------------------------------------------
bool Kill_EntriesAllowed(KillState &k,
                         const string sym, const long magic,
                         const int rollingTrades, const double minPf,
                         const int pauseDays, const int probationTrades,
                         const ulong lastCloseDealId, const datetime now,
                         const string eaName)
{
   if(rollingTrades <= 0) return true;               // switch off

   // Still inside a pause: no entries, no re-evaluation.
   if(k.pausedUntil > 0 && now < k.pausedUntil) return false;

   // Pause just ended: start probation.
   if(k.pausedUntil > 0 && now >= k.pausedUntil)
   {
      k.pausedUntil = 0;
      k.tradesAtResume = k.closedTrades;
      PrintFormat("KILL_RESUME %s %s magic=%I64d: pause over, probation of %d trades before the next check",
                  eaName, sym, magic, probationTrades);
   }

   // Recompute only when a trade has closed since the last look.
   if(lastCloseDealId != k.lastDealSeen)
   {
      k.lastDealSeen = lastCloseDealId;
      k.closedTrades = Kill_RollingPf(sym, magic, rollingTrades, k.rollingPf);
   }

   if(k.closedTrades < rollingTrades) return true;   // not enough history to judge
   if(k.everPaused && (k.closedTrades - k.tradesAtResume) < probationTrades) return true;   // probation

   if(k.rollingPf < minPf)
   {
      k.pausedUntil = now + (datetime)(pauseDays * 86400);
      k.everPaused  = true;
      PrintFormat("KILL_PAUSE %s %s magic=%I64d: rolling PF %.2f over last %d closed trades < %.2f - no new entries until %s",
                  eaName, sym, magic, k.rollingPf, rollingTrades, minPf, TimeToString(k.pausedUntil, TIME_DATE));
      return false;
   }
   return true;
}

#endif // KUROSAWA_KILLSWITCH_MQH
