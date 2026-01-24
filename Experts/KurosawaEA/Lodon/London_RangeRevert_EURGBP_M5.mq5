//+------------------------------------------------------------------+
//| File: London_RangeRevert_EURGBP_M5.mq5                            |
//| EA  : London_RangeRevert_EURGBP_M5                                |
//| Ver : 1.1.0                                                       |
//|                                                                  |
//| London Range Revert (EURGBP / M5)                                 |
//| - Session: London (broker/server time)                            |
//| - Regime: Range/quiet only (ADX low, ATR in window)               |
//| - Entry: Bollinger Band outer touch + RSI extreme (closed bar)    |
//| - Exit : Mean reversion to mid-band OR time-based exit            |
//| - Risk : ATR-based SL, fixed R-multiple TP (optional mid exit)    |
//| - Safety: spread, cooldown, daily loss, loss streak, 1 pos/magic  |
//| - Tracking: KurosawaTrack.mqh (optional, private)                 |
//|                                                                  |
//| Notes                                                             |
//| - Attach ONLY to EURGBP M5 chart                                  |
//| - All decisions use CLOSED bars                                   |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

#include "KurosawaHelpers.mqh"
#include "KurosawaTrack.mqh"   // PRIVATE: keep out of git. Provide a public stub for GitHub.

// ------------------------- Identity / Tracking ---------------------
input string InpEaId          = "LDN_RR_EURGBP_M5";
input string InpEaName        = "London_RangeRevert_EURGBP_M5";
input string InpEaVersion     = "1.1.0";

input bool   InpTrackEnable   = false;  // default false for safety
input bool   InpTrackSendOpen = true;

// ------------------------- Inputs ---------------------------------
input long   InpMagicNumber            = 2026011704;

input double InpRiskPercent            = 0.30;     // Range systems: keep risk small
input double InpFixedLotFallback       = 0.05;

input int    InpSpreadMaxPoints        = 18;       // EURGBP often tight, but still filter
input int    InpCooldownMinutes        = 45;
input int    InpMaxConsecutiveLosses   = 3;
input double InpDailyLossLimitPercent  = 2.0;

// Session: London (broker/server time)
input int    InpSessionStartHour       = 8;
input int    InpSessionStartMinute     = 0;
input int    InpSessionEndHour         = 17;
input int    InpSessionEndMinute       = 0;

// Range regime filters
input int    InpAdxPeriod              = 14;
input double InpAdxMax                 = 18.0;    // must be <= (quiet market)

input int    InpAtrPeriod              = 14;
input int    InpAtrMinPoints           = 18;      // too dead -> skip
input int    InpAtrMaxPoints           = 90;      // too volatile/trendy -> skip

// Entry: Bollinger + RSI extremes
input int    InpBbPeriod               = 20;
input double InpBbDeviations           = 2.0;

input int    InpRsiPeriod              = 14;
input double InpRsiBuyMax              = 30.0;    // buy when oversold at lower band
input double InpRsiSellMin             = 70.0;    // sell when overbought at upper band

// Exits
input bool   InpUseMidBandExit         = true;    // close at mid band (mean)
input int    InpMaxHoldMinutes         = 240;     // safety time exit (4h)

// Risk model
input double InpAtrSLMult              = 2.2;     // SL = ATR * mult
input double InpTP_R                   = 1.0;     // TP = SL_distance * R (backup TP)

// ------------------------- Globals --------------------------------
int hAdx = INVALID_HANDLE;
int hAtr = INVALID_HANDLE;
int hRsi = INVALID_HANDLE;
int hBb  = INVALID_HANDLE; // Bollinger

datetime g_lastBarTime   = 0;
datetime g_lastTradeTime = 0;

int    g_consecLosses   = 0;
double g_dayStartEquity = 0.0;
int    g_dayOfYear      = -1;

// Track state
ulong    g_lastOpenDealId  = 0;
ulong    g_lastCloseDealId = 0;
datetime g_lastCloseTime   = 0;

KurosawaDailyDiag g_diag;

// ------------------------- Utilities ------------------------------
int MinutesOfDay(datetime t)
{
   MqlDateTime dt; TimeToStruct(t, dt);
   return dt.hour * 60 + dt.min;
}

bool IsWithinSession()
{
   int cur = MinutesOfDay(TimeCurrent());
   int st  = InpSessionStartHour * 60 + InpSessionStartMinute;
   int en  = InpSessionEndHour   * 60 + InpSessionEndMinute;

   if(st <= en) return (cur >= st && cur < en);
   return (cur >= st || cur < en);
}

bool SpreadOK()
{
   int sp = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (sp > 0 && sp <= InpSpreadMaxPoints);
}

bool CooldownOK()
{
   if(g_lastTradeTime == 0) return true;
   return ((TimeCurrent() - g_lastTradeTime) >= (InpCooldownMinutes * 60));
}

void RefreshDailyEquityBaseline()
{
   MqlDateTime now; TimeToStruct(TimeCurrent(), now);
   if(now.day_of_year != g_dayOfYear)
   {
      g_dayOfYear      = now.day_of_year;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_consecLosses   = 0;
   }
}

bool DailyLossLimitOK()
{
   if(g_dayStartEquity <= 0.0) return true;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd = (g_dayStartEquity - eq) / g_dayStartEquity * 100.0;
   return (dd < InpDailyLossLimitPercent);
}

bool IsNewClosedBar()
{
   datetime t = (datetime)iTime(_Symbol, PERIOD_M5, 0);
   if(t == 0) return false;
   if(t != g_lastBarTime)
   {
      g_lastBarTime = t;
      return true;
   }
   return false;
}

bool GetIndicatorDouble(int handle, int buffer, int shift, double &outVal)
{
   double v[];
   ArraySetAsSeries(v, true);
   if(CopyBuffer(handle, buffer, shift, 1, v) != 1) return false;
   outVal = v[0];
   return true;
}

double CalcLotByRisk(const double slDistancePoints)
{
   if(slDistancePoints <= 0.0) return 0.0;

   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * (InpRiskPercent / 100.0);
   if(riskMoney <= 0.0) return 0.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0) return 0.0;

   double valuePerPointPerLot = tickValue * (_Point / tickSize);
   if(valuePerPointPerLot <= 0.0) return 0.0;

   double lots = riskMoney / (slDistancePoints * valuePerPointPerLot);
   return NormalizeVolume(_Symbol, lots);
}

void UpdateLossStreakFromHistory()
{
   datetime from = TimeCurrent() - 14 * 24 * 3600;
   datetime to   = TimeCurrent();
   if(!HistorySelect(from, to)) return;

   for(long i = HistoryDealsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = HistoryDealGetTicket((int)i);
      if(ticket == 0) continue;

      string sym = (string)HistoryDealGetString(ticket, DEAL_SYMBOL);
      if(sym != _Symbol) continue;

      long mg = (long)HistoryDealGetInteger(ticket, DEAL_MAGIC);
      if(mg != InpMagicNumber) continue;

      long entry = (long)HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT) continue;

      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                    + HistoryDealGetDouble(ticket, DEAL_SWAP)
                    + HistoryDealGetDouble(ticket, DEAL_COMMISSION);

      if(profit < 0) g_consecLosses++;
      else           g_consecLosses = 0;

      break;
   }
}

// ------------------------- Range Logic ----------------------------
bool IsRangeRegime(double &atrPtsOut, double &midBandOut)
{
   atrPtsOut = 0.0;
   midBandOut = 0.0;

   double adx1, atr1;
   if(!GetIndicatorDouble(hAdx, 0, 1, adx1)) return false;
   if(!GetIndicatorDouble(hAtr, 0, 1, atr1)) return false;

   double atrPts = atr1 / _Point;
   atrPtsOut = atrPts;

   if(atrPts < InpAtrMinPoints) { g_diag.block_atr++; return true; }
   if(atrPts > InpAtrMaxPoints) { g_diag.block_atr++; return true; }

   if(adx1 > InpAdxMax) { g_diag.block_adx++; return true; }

   // BB mid band is buffer 1 in iBands (0=upper,1=middle,2=lower)
   double bbMid;
   if(!GetIndicatorDouble(hBb, 1, 1, bbMid)) return false;
   midBandOut = bbMid;

   return true;
}

bool GetSignals(bool &buySig, bool &sellSig, double &atrPtsOut, double &bbMidOut)
{
   buySig = false;
   sellSig = false;
   atrPtsOut = 0.0;
   bbMidOut = 0.0;

   if(!IsRangeRegime(atrPtsOut, bbMidOut)) return false;

   double rsi1, bbUpper, bbLower;
   if(!GetIndicatorDouble(hRsi, 0, 1, rsi1)) return false;
   if(!GetIndicatorDouble(hBb,  0, 1, bbUpper)) return false;
   if(!GetIndicatorDouble(hBb,  2, 1, bbLower)) return false;

   double close1 = iClose(_Symbol, PERIOD_M5, 1);

   // Mean reversion triggers: touch/close beyond band + RSI extreme
   if(close1 <= bbLower && rsi1 <= InpRsiBuyMax)  buySig  = true;
   if(close1 >= bbUpper && rsi1 >= InpRsiSellMin) sellSig = true;

   if(!buySig && !sellSig) g_diag.block_nosignal++;

   return true;
}

// ------------------------- Exits ----------------------------------
bool CloseIfMidBandHit(const double bbMid, const bool isBuy)
{
   if(!InpUseMidBandExit) return false;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0) return false;

   // For buy, exit when Bid >= mid. For sell, exit when Ask <= mid.
   if(isBuy && bid >= bbMid) return trade.PositionClose(_Symbol);
   if(!isBuy && ask <= bbMid) return trade.PositionClose(_Symbol);

   return false;
}

bool CloseIfTimedOut()
{
   if(InpMaxHoldMinutes <= 0) return false;

   if(!PositionSelect(_Symbol)) return false;
   long mg = (long)PositionGetInteger(POSITION_MAGIC);
   if(mg != InpMagicNumber) return false;

   datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
   if(openTime <= 0) return false;

   int heldMin = (int)((TimeCurrent() - openTime) / 60);
   if(heldMin >= InpMaxHoldMinutes)
      return trade.PositionClose(_Symbol);

   return false;
}

// ------------------------- Orders ---------------------------------
bool PlaceTrade(const bool isBuy, const double slPts, const double tpPts)
{
   double vol = CalcLotByRisk(slPts);
   if(vol <= 0.0) vol = NormalizeVolume(_Symbol, InpFixedLotFallback);
   if(vol <= 0.0) vol = GetMinLot(_Symbol);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return false;

   double entry = isBuy ? ask : bid;

   double sl = isBuy ? (entry - slPts * _Point) : (entry + slPts * _Point);
   double tp = isBuy ? (entry + tpPts * _Point) : (entry - tpPts * _Point);

   if(!EnsureStopsLevel(_Symbol, entry, sl, tp, isBuy, false))
   {
      g_diag.block_stops++;
      return false;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(10);

   bool ok = false;
   if(isBuy) ok = trade.Buy(vol, _Symbol, 0.0, sl, tp, InpEaName);
   else      ok = trade.Sell(vol, _Symbol, 0.0, sl, tp, InpEaName);

   if(ok)
   {
      g_lastTradeTime = TimeCurrent();
      g_diag.trades++;
   }
   else
   {
      g_diag.block_orderfail++;
   }

   return ok;
}

// ------------------------- MQL5 Events ----------------------------
int OnInit()
{
   if(_Symbol != "EURGBP")
      Print("Warning: This EA is intended for EURGBP. Current symbol=", _Symbol);

   if(_Period != PERIOD_M5)
      Print("Warning: This EA is intended for M5. Current period=", _Period);

   hAdx = iADX(_Symbol, PERIOD_M5, InpAdxPeriod);
   hAtr = iATR(_Symbol, PERIOD_M5, InpAtrPeriod);
   hRsi = iRSI(_Symbol, PERIOD_M5, InpRsiPeriod, PRICE_CLOSE);
   hBb  = iBands(_Symbol, PERIOD_M5, InpBbPeriod, 0, InpBbDeviations, PRICE_CLOSE);

   if(hAdx == INVALID_HANDLE || hAtr == INVALID_HANDLE || hRsi == INVALID_HANDLE || hBb == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles");
      return INIT_FAILED;
   }

   RefreshDailyEquityBaseline();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hAdx != INVALID_HANDLE) IndicatorRelease(hAdx);
   if(hAtr != INVALID_HANDLE) IndicatorRelease(hAtr);
   if(hRsi != INVALID_HANDLE) IndicatorRelease(hRsi);
   if(hBb  != INVALID_HANDLE) IndicatorRelease(hBb);
}

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   KurosawaTrack_OnTradeTransaction(
      InpTrackEnable,
      trans,
      InpEaId, InpEaName, InpEaVersion,
      (int)InpMagicNumber,
      InpTrackSendOpen,
      g_lastOpenDealId, g_lastCloseDealId,
      g_consecLosses, g_lastCloseTime,
      (ENUM_TIMEFRAMES)_Period, _Symbol
   );
}

void OnTick()
{
   RefreshDailyEquityBaseline();

   Kurosawa_DailyRollIfNeeded(InpEaName, _Symbol, (ENUM_TIMEFRAMES)_Period, g_diag, NowYmdJst());

   // If we have a position, manage exits first (mid-band / time exit)
   if(PositionSelect(_Symbol) && (long)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
   {
      bool isBuy = ((long)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);

      double bbMid = 0.0;
      double dummyAtr = 0.0;
      // refresh mid band on demand
      if(IsRangeRegime(dummyAtr, bbMid))
      {
         CloseIfMidBandHit(bbMid, isBuy);
      }
      CloseIfTimedOut();
      return;
   }

   if(!IsWithinSession())  { g_diag.block_session++; return; }
   if(!SpreadOK())         { g_diag.block_spread++;  return; }
   if(!CooldownOK())       { g_diag.block_cooldown++;return; }
   if(!DailyLossLimitOK()) { g_diag.block_maxday++;  return; }

   bool isNewBar = IsNewClosedBar();
   if(!isNewBar) return;

   g_diag.bars++;

   KurosawaTrack_OnNewBar(InpTrackEnable, (int)InpMagicNumber, _Symbol, (ENUM_TIMEFRAMES)_Period);

   UpdateLossStreakFromHistory();
   if(g_consecLosses >= InpMaxConsecutiveLosses) { g_diag.block_loss++; return; }

   bool buySig=false, sellSig=false;
   double atrPts=0.0, bbMid=0.0;
   if(!GetSignals(buySig, sellSig, atrPts, bbMid)) return;

   if(buySig && sellSig) return;
   if(!buySig && !sellSig) return;

   g_diag.signals++;

   double slPts = atrPts * InpAtrSLMult;
   double tpPts = slPts * InpTP_R;

   if(buySig)  PlaceTrade(true,  slPts, tpPts);
   if(sellSig) PlaceTrade(false, slPts, tpPts);
}
