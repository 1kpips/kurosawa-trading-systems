//+------------------------------------------------------------------+
//| File: NewYork_TrendPullback_EURUSD_M5.mq5                         |
//| EA  : NewYork_TrendPullback_EURUSD_M5                             |
//| Ver : 1.1.0                                                       |
//|                                                                  |
//| New York Trend Pullback (EURUSD / M5)                             |
//| - Bias: EMA(50) vs EMA(200) on M15 (closed bars)                  |
//| - Entry: Pullback on M5 via RSI + reclaim of EMA(20) (closed bar) |
//| - Optional: London range filter (avoid dead chop)                 |
//| - Volatility safety: ATR(14, M5) within [min,max] points          |
//| - Risk: ATR-based SL, R-multiple TP                               |
//| - Safety: NY session gate, spread filter, cooldown, daily loss,   |
//|           loss-streak protection, 1 position per magic            |
//| - Execution: Market orders, SL/TP validated via helpers           |
//| - Tracking: KurosawaTrack.mqh (optional, private)                 |
//|                                                                  |
//| Notes                                                             |
//| - Attach ONLY to EURUSD M5 chart                                  |
//| - All decisions use CLOSED bars                                   |
//| - Session hours are broker time; adjust inputs to match your broker|
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

#include "KurosawaHelpers.mqh"
#include "KurosawaTrack.mqh"   

// ------------------------- Identity / Tracking ---------------------
input string InpEaId          = "NY_TP_EURUSD_M5";
input string InpEaName        = "NewYork_TrendPullback_EURUSD_M5";
input string InpEaVersion     = "1.1.0";

input bool   InpTrackEnable   = false;  // default false for safety
input bool   InpTrackSendOpen = true;

// ------------------------- Inputs ---------------------------------
input long   InpMagicNumber            = 2026011703;

input double InpRiskPercent            = 0.35;     // Lower risk for M5
input double InpFixedLotFallback       = 0.05;

input int    InpSpreadMaxPoints        = 20;
input int    InpCooldownMinutes        = 45;
input int    InpMaxConsecutiveLosses   = 3;
input double InpDailyLossLimitPercent  = 2.0;

// NY session (broker/server time)
input int    InpSessionStartHour       = 13;
input int    InpSessionStartMinute     = 0;
input int    InpSessionEndHour         = 22;
input int    InpSessionEndMinute       = 0;

// Trend bias timeframe and EMAs
input ENUM_TIMEFRAMES InpBiasTF        = PERIOD_M15;
input int    InpBiasEmaFast            = 50;
input int    InpBiasEmaSlow            = 200;

// Entry timeframe (chart M5)
input int    InpEntryEma               = 20;
input int    InpRsiPeriod              = 14;
input double InpRsiBuyMax              = 45.0;
input double InpRsiSellMin             = 55.0;

// Volatility and stops
input int    InpAtrPeriod              = 14;
input int    InpAtrMinPoints           = 35;
input int    InpAtrMaxPoints           = 180;
input double InpAtrSLMult              = 2.2;
input double InpTP_R                   = 1.4;

// Optional London range filter
input bool   InpUseLondonRangeFilter   = true;
input int    InpLondonStartHour        = 8;
input int    InpLondonStartMinute      = 0;
input int    InpLondonEndHour          = 12;
input int    InpLondonEndMinute        = 0;
input int    InpLondonRangeMinPoints   = 35;

// ------------------------- Globals --------------------------------
int hBiasEmaFast = INVALID_HANDLE;
int hBiasEmaSlow = INVALID_HANDLE;

int hEntryEma    = INVALID_HANDLE;
int hRsi         = INVALID_HANDLE;
int hAtr         = INVALID_HANDLE;

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

bool LondonRangeOK()
{
   if(!InpUseLondonRangeFilter) return true;

   MqlDateTime now; TimeToStruct(TimeCurrent(), now);

   MqlDateTime st = now; st.hour = InpLondonStartHour; st.min = InpLondonStartMinute; st.sec = 0;
   MqlDateTime en = now; en.hour = InpLondonEndHour;   en.min = InpLondonEndMinute;   en.sec = 0;

   datetime tSt = StructToTime(st);
   datetime tEn = StructToTime(en);

   // If window invalid or not finished yet, do not block (conservative)
   if(tEn <= tSt) return true;
   if(TimeCurrent() < tEn) return true;

   int startShift = iBarShift(_Symbol, PERIOD_M5, tSt, false);
   int endShift   = iBarShift(_Symbol, PERIOD_M5, tEn, false);

   if(startShift < 0 || endShift < 0) return true;
   if(startShift < endShift) return true;

   double hi = -DBL_MAX;
   double lo =  DBL_MAX;

   for(int s = endShift; s <= startShift; ++s)
   {
      double h = iHigh(_Symbol, PERIOD_M5, s);
      double l = iLow(_Symbol,  PERIOD_M5, s);
      if(h > hi) hi = h;
      if(l < lo) lo = l;
   }

   if(hi <= -DBL_MAX || lo >= DBL_MAX) return true;

   double rangePts = (hi - lo) / _Point;
   if(rangePts < InpLondonRangeMinPoints)
      return false;
   
   return (rangePts >= InpLondonRangeMinPoints);
}

// ------------------------- Trading Logic --------------------------
bool GetSignals(bool &buySig, bool &sellSig, double &atrPtsOut)
{
   buySig = false;
   sellSig = false;
   atrPtsOut = 0.0;

   // Bias TF (closed bar shift=1)
   double emaFastBias, emaSlowBias;
   if(!GetIndicatorDouble(hBiasEmaFast, 0, 1, emaFastBias)) return false;
   if(!GetIndicatorDouble(hBiasEmaSlow, 0, 1, emaSlowBias)) return false;

   bool upBias   = (emaFastBias > emaSlowBias);
   bool downBias = (emaFastBias < emaSlowBias);
   if(!upBias && !downBias) { g_diag.block_nobias++; return true; }

   // Entry TF (M5) closed bars
   double ema20_1, ema20_2, rsi1, atr1;
   if(!GetIndicatorDouble(hEntryEma, 0, 1, ema20_1)) return false;
   if(!GetIndicatorDouble(hEntryEma, 0, 2, ema20_2)) return false;
   if(!GetIndicatorDouble(hRsi,      0, 1, rsi1))     return false;
   if(!GetIndicatorDouble(hAtr,      0, 1, atr1))     return false;

   double close1 = iClose(_Symbol, PERIOD_M5, 1);

   double atrPts = atr1 / _Point;
   atrPtsOut = atrPts;

   if(atrPts < InpAtrMinPoints) { g_diag.block_atr++; return true; }
   if(atrPts > InpAtrMaxPoints) { g_diag.block_atr++; return true; }

   bool reclaimedUp   = (iClose(_Symbol, PERIOD_M5, 2) < ema20_2 && close1 > ema20_1);
   bool reclaimedDown = (iClose(_Symbol, PERIOD_M5, 2) > ema20_2 && close1 < ema20_1);

   if(upBias && rsi1 <= InpRsiBuyMax && reclaimedUp)   buySig  = true;
   if(downBias && rsi1 >= InpRsiSellMin && reclaimedDown) sellSig = true;

   if(!buySig && !sellSig) g_diag.block_nosignal++;

   return true;
}

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
   if(_Symbol != "EURUSD")
      Print("Warning: This EA is intended for EURUSD. Current symbol=", _Symbol);

   if(_Period != PERIOD_M5)
      Print("Warning: This EA is intended for M5. Current period=", _Period);

   hBiasEmaFast = iMA(_Symbol, InpBiasTF, InpBiasEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   hBiasEmaSlow = iMA(_Symbol, InpBiasTF, InpBiasEmaSlow, 0, MODE_EMA, PRICE_CLOSE);

   hEntryEma = iMA(_Symbol, PERIOD_M5, InpEntryEma, 0, MODE_EMA, PRICE_CLOSE);
   hRsi      = iRSI(_Symbol, PERIOD_M5, InpRsiPeriod, PRICE_CLOSE);
   hAtr      = iATR(_Symbol, PERIOD_M5, InpAtrPeriod);

   if(hBiasEmaFast == INVALID_HANDLE || hBiasEmaSlow == INVALID_HANDLE ||
      hEntryEma    == INVALID_HANDLE || hRsi        == INVALID_HANDLE ||
      hAtr         == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles");
      return INIT_FAILED;
   }

   RefreshDailyEquityBaseline();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hBiasEmaFast != INVALID_HANDLE) IndicatorRelease(hBiasEmaFast);
   if(hBiasEmaSlow != INVALID_HANDLE) IndicatorRelease(hBiasEmaSlow);

   if(hEntryEma != INVALID_HANDLE) IndicatorRelease(hEntryEma);
   if(hRsi      != INVALID_HANDLE) IndicatorRelease(hRsi);
   if(hAtr      != INVALID_HANDLE) IndicatorRelease(hAtr);
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

   if(!IsWithinSession())  { g_diag.block_session++; return; }
   if(!SpreadOK())         { g_diag.block_spread++;  return; }
   if(!CooldownOK())       { g_diag.block_cooldown++;return; }
   if(!DailyLossLimitOK()) { g_diag.block_maxday++;  return; }

   if(PositionExists(_Symbol, (int)InpMagicNumber)) { g_diag.block_haspos++; return; }

   bool isNewBar = IsNewClosedBar();
   if(!isNewBar) return;

   g_diag.bars++;

   KurosawaTrack_OnNewBar(InpTrackEnable, (int)InpMagicNumber, _Symbol, (ENUM_TIMEFRAMES)_Period);

   UpdateLossStreakFromHistory();
   if(g_consecLosses >= InpMaxConsecutiveLosses) { g_diag.block_loss++; return; }

   if(!LondonRangeOK()) return;

   bool buySig=false, sellSig=false;
   double atrPts=0.0;
   if(!GetSignals(buySig, sellSig, atrPts)) return;

   if(buySig && sellSig) return;
   if(!buySig && !sellSig) return;

   g_diag.signals++;

   double slPts = atrPts * InpAtrSLMult;
   double tpPts = slPts * InpTP_R;

   if(buySig)  PlaceTrade(true,  slPts, tpPts);
   if(sellSig) PlaceTrade(false, slPts, tpPts);
}
