//+------------------------------------------------------------------+
//| File: Helpers/KurosawaPortfolio.mqh                              |
//| Type: Include Library                                            |
//| Ver : 0.1.0                                                      |
//|                                                                  |
//| Account-level (portfolio) risk cap.                              |
//|                                                                  |
//| Why (2026-09-11)                                                 |
//| - Seven charts run on one account, each with its own daily-loss  |
//|   and streak gates. Nothing looked at the account as a whole: at |
//|   09:55 JST three fix charts sell yen at once, and a London      |
//|   morning can stack four longs. At 0.01 lot that is trivia; it   |
//|   is the thing that has to exist BEFORE size goes up.            |
//| - Every instance reads the same account, so no channel between   |
//|   EAs is needed: each one evaluates the same four numbers before |
//|   it sends an order, and whoever is first fills the last slot.   |
//|                                                                  |
//| What it does NOT do                                              |
//| - It never touches an open position. It only refuses new ones.  |
//| - It counts EVERY position on the account (a manual trade uses   |
//|   the same margin and the same luck), not only Kurosawa magics.  |
//| - 0 on a limit = that limit is off. The tester runs one instance |
//|   so the caps never bind there; a filed backtest is unchanged.   |
//+------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_PORTFOLIO_MQH
#define KUROSAWA_PORTFOLIO_MQH

struct PortfolioLimits
{
   int    maxPositions;       // open positions on the account, all symbols
   double maxRiskPercent;     // sum of distance-to-stop money of open positions + this trade, % of balance
   double dailyLossPercent;   // realized today + floating, all magics, % of day-start balance
   int    maxPerCurrency;     // open positions whose symbol contains the new trade's base or quote currency
};

// Money at risk if a position of `lot` on `sym` is stopped `slPts` points away.
double Portfolio_RiskMoney(const string sym, const double lot, const double slPts)
{
   const double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   const double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   const double point     = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(tickValue <= 0.0 || tickSize <= 0.0 || point <= 0.0 || lot <= 0.0 || slPts <= 0.0) return 0.0;
   return slPts * point / tickSize * tickValue * lot;
}

// Money at risk of one open position (0 when it has no stop).
double Portfolio_PositionRisk(const ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return 0.0;
   const string sym = PositionGetString(POSITION_SYMBOL);
   const double sl  = PositionGetDouble(POSITION_SL);
   if(sl <= 0.0) return 0.0;
   const double price = PositionGetDouble(POSITION_PRICE_OPEN);
   const double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(point <= 0.0) return 0.0;
   return Portfolio_RiskMoney(sym, PositionGetDouble(POSITION_VOLUME), MathAbs(price - sl) / point);
}

// Today's closed P/L over the whole account (server day), profit + swap + commission.
double Portfolio_RealizedToday()
{
   const datetime now = TimeCurrent();
   const datetime dayStart = now - (now % 86400);
   if(!HistorySelect(dayStart, now + 60)) return 0.0;
   double sum = 0.0;
   const int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
   {
      const ulong t = HistoryDealGetTicket(i);
      if(t == 0) continue;
      const long entry = HistoryDealGetInteger(t, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT && entry != DEAL_ENTRY_OUT_BY) continue;
      sum += HistoryDealGetDouble(t, DEAL_PROFIT) + HistoryDealGetDouble(t, DEAL_SWAP) + HistoryDealGetDouble(t, DEAL_COMMISSION);
   }
   return sum;
}

bool Portfolio_HasCurrency(const string sym, const string ccy)
{
   return (ccy != "" && StringFind(sym, ccy) >= 0);
}

// ------------------------------------------------------------------
// Call before sending a new order. Returns true when the account has room.
// `newRiskMoney` is what THIS trade would lose at its stop (Portfolio_RiskMoney).
// ------------------------------------------------------------------
bool Portfolio_HasRoom(const string sym, const double newRiskMoney, const PortfolioLimits &lim, string &why)
{
   why = "";
   const int total = PositionsTotal();

   if(lim.maxPositions > 0 && total >= lim.maxPositions)
   {
      why = StringFormat("portfolio: %d open positions >= cap %d", total, lim.maxPositions);
      return false;
   }

   const double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(lim.dailyLossPercent > 0.0 && balance > 0.0)
   {
      const double realized = Portfolio_RealizedToday();
      const double floating = AccountInfoDouble(ACCOUNT_EQUITY) - balance;
      const double dayStart = balance - realized;
      const double pnlPct   = (dayStart > 0.0) ? (realized + floating) / dayStart * 100.0 : 0.0;
      if(pnlPct <= -lim.dailyLossPercent)
      {
         why = StringFormat("portfolio: account P/L today %.2f%% (realized %.2f + floating %.2f) beyond -%.2f%%", pnlPct, realized, floating, lim.dailyLossPercent);
         return false;
      }
   }

   if(lim.maxRiskPercent > 0.0 && balance > 0.0)
   {
      double open = 0.0;
      for(int i = 0; i < total; i++) open += Portfolio_PositionRisk(PositionGetTicket(i));
      const double pct = (open + newRiskMoney) / balance * 100.0;
      if(pct > lim.maxRiskPercent)
      {
         why = StringFormat("portfolio: open risk %.2f + this trade %.2f = %.2f%% of balance > cap %.2f%%", open, newRiskMoney, pct, lim.maxRiskPercent);
         return false;
      }
   }

   if(lim.maxPerCurrency > 0)
   {
      const string base  = SymbolInfoString(sym, SYMBOL_CURRENCY_BASE);
      const string quote = SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT);
      int nb = 0, nq = 0;
      for(int i = 0; i < total; i++)
      {
         const ulong t = PositionGetTicket(i);
         if(t == 0 || !PositionSelectByTicket(t)) continue;
         const string s = PositionGetString(POSITION_SYMBOL);
         if(Portfolio_HasCurrency(s, base))  nb++;
         if(Portfolio_HasCurrency(s, quote)) nq++;
      }
      if(nb >= lim.maxPerCurrency || nq >= lim.maxPerCurrency)
      {
         why = StringFormat("portfolio: %s already in %d / %s in %d open positions, cap %d per currency", base, nb, quote, nq, lim.maxPerCurrency);
         return false;
      }
   }
   return true;
}

#endif // KUROSAWA_PORTFOLIO_MQH
