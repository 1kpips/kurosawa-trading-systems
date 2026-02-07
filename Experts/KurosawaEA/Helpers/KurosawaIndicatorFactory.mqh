//+------------------------------------------------------------------+
//| File: Helpers/KurosawaIndicatorFactory.mqh                        |
//| Type: Include Library                                             |
//|                                                                   |
//| Purpose                                                           |
//| - History preload                                                 |
//| - Indicator handle lifecycle                                      |
//| - Reusable “create with retry” patterns                           |
//+------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_INDICATOR_FACTORY_MQH
#define KUROSAWA_INDICATOR_FACTORY_MQH

struct TrendIndicatorPack
{
   int hEmaFast;
   int hEmaSlow;
   int hRSI;
   int hATR;
   int hADX; // optional
};

void TrendIndicators_Reset(TrendIndicatorPack &p)
{
   p.hEmaFast = INVALID_HANDLE;
   p.hEmaSlow = INVALID_HANDLE;
   p.hRSI     = INVALID_HANDLE;
   p.hATR     = INVALID_HANDLE;
   p.hADX     = INVALID_HANDLE;
}

void TrendIndicators_Release(TrendIndicatorPack &p)
{
   if(p.hEmaFast != INVALID_HANDLE) IndicatorRelease(p.hEmaFast);
   if(p.hEmaSlow != INVALID_HANDLE) IndicatorRelease(p.hEmaSlow);
   if(p.hRSI     != INVALID_HANDLE) IndicatorRelease(p.hRSI);
   if(p.hATR     != INVALID_HANDLE) IndicatorRelease(p.hATR);
   if(p.hADX     != INVALID_HANDLE) IndicatorRelease(p.hADX);

   TrendIndicators_Reset(p);
}

bool EnsureHistory(const string symbol, const ENUM_TIMEFRAMES tf, const int needBars)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   for(int i=0; i<20; i++)
   {
      ResetLastError();
      const int got = CopyRates(symbol, tf, 0, needBars, rates);
      if(got >= needBars)
         return true;

      Print("INIT_WAIT_HISTORY: symbol=", symbol,
            " tf=", EnumToString(tf),
            " got=", got,
            " need=", needBars,
            " err=", GetLastError());

      Sleep(250);
   }
   return false;
}

// Creates Trend indicators for the traded symbol (not chart symbol).
// Returns false if handles cannot be created after retries.
bool TrendIndicators_CreateWithRetry(
   const string sym,
   const ENUM_TIMEFRAMES tf,
   const int emaFast,
   const int emaSlow,
   const int rsiPeriod,
   const int atrPeriod,
   const bool useAdx,
   const int adxPeriod,
   TrendIndicatorPack &outPack
)
{
   // Validate inputs (hard fail)
   if(emaFast < 2 || emaSlow < 2 || rsiPeriod < 2 || atrPeriod < 2)
   {
      Print("INIT_FAILED: invalid indicator inputs.",
            " EmaFast=", emaFast,
            " EmaSlow=", emaSlow,
            " RsiPeriod=", rsiPeriod,
            " AtrPeriod=", atrPeriod);
      return false;
   }
   if(useAdx && adxPeriod < 2)
   {
      Print("INIT_FAILED: invalid ADX inputs. AdxPeriod=", adxPeriod);
      return false;
   }

   ResetLastError();
   if(!SymbolSelect(sym, true))
      Print("Warning: SymbolSelect failed for ", sym, " err=", GetLastError());

   if(!EnsureHistory(sym, tf, 300))
      return false;

   for(int i=0; i<10; i++)
   {
      TrendIndicators_Release(outPack);
      ResetLastError();

      outPack.hEmaFast = iMA(sym, tf, emaFast, 0, MODE_EMA, PRICE_CLOSE);
      outPack.hEmaSlow = iMA(sym, tf, emaSlow, 0, MODE_EMA, PRICE_CLOSE);
      outPack.hRSI     = iRSI(sym, tf, rsiPeriod, PRICE_CLOSE);
      outPack.hATR     = iATR(sym, tf, atrPeriod);

      if(useAdx)
         outPack.hADX = iADX(sym, tf, adxPeriod);
      else
         outPack.hADX = INVALID_HANDLE;

      const bool baseOk =
         (outPack.hEmaFast != INVALID_HANDLE &&
          outPack.hEmaSlow != INVALID_HANDLE &&
          outPack.hRSI     != INVALID_HANDLE &&
          outPack.hATR     != INVALID_HANDLE);

      const bool adxOk  = (!useAdx || outPack.hADX != INVALID_HANDLE);

      if(baseOk && adxOk)
         return true;

      Print("INIT_RETRY(", i, "): handle create failed. err=", GetLastError(),
            " EmaFast=", outPack.hEmaFast,
            " EmaSlow=", outPack.hEmaSlow,
            " RSI=", outPack.hRSI,
            " ATR=", outPack.hATR,
            " ADX=", outPack.hADX,
            " sym=", sym,
            " tf=", EnumToString(tf));

      Sleep(200);
   }

   return false;
}

#endif // KUROSAWA_INDICATOR_FACTORY_MQH
