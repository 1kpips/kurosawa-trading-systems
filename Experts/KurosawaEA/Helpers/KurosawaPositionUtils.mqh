//+--------------------------------------------------------------------+
//| File: KurosawaPositionUtils.mqh                                    |
//| Type: Include Library                                              |
//| Ver : 0.1.0                                                        |
//|                                                                    |
//| Description                                                        |
//| Position scanning helpers shared across the Kurosawa EA suite.     |
//|                                                                    |
//| Scope                                                              |
//| - 1-position-per-symbol+magic checks                               |
//| - Select position by magic                                         |
//+--------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_POSITION_UTILS_MQH
#define KUROSAWA_POSITION_UTILS_MQH

// Returns true if there is an open position for the given symbol and magic number.
bool PositionExists(const string symbol, const int magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;

      return true;
   }
   return false;
}

// Selects a position by symbol + magic. Returns true if selected.
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

#endif // KUROSAWA_POSITION_UTILS_MQH
//+--------------------------------------------------------------------+
