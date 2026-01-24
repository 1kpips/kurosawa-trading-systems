//+------------------------------------------------------------------+
//| File: London_SwingTrend_EURJPY_H1.mq5                            |
//| EA  : London_SwingTrend_EURJPY_H1                                |
//| Ver : 1.1.0                                                      |
//|                                                                  |
//| London Swing Trend (EURJPY / H1)                                 |
//| - Trend: EMA(50) vs EMA(200) on closed bars                      |
//| - Entry: RSI pullback in trend direction (closed bar)            |
//| - Volatility safety: ATR(14) must be within [min,max] in points  |
//| - Optional quality: ADX(14) >= threshold                         |
//| - Risk: ATR-based SL, R-multiple TP                              |
//| - Safety: London session gate, spread filter, cooldown,          |
//|           daily loss limit, loss-streak protection,              |
//|           1 position per magic                                   |
//| - Tracking: KurosawaTrack.mqh (optional, private)                |
//|                                                                  |
//| Notes                                                            |
//| - Attach ONLY to EURJPY H1 chart                                 |
//| - All decisions use CLOSED bars                                  |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

#include "KurosawaHelpers.mqh"
#include "KurosawaTrack.mqh" 

// ------------------------- Identity / Tracking ---------------------
input string InpEaId          = "LDN_ST_EURJPY_H1";
input string InpEaName        = "London_SwingTrend_EURJPY_H1";
input string InpEaVersion     = "1.1.0";

input bool   InpTrackEnable   = false;  // default false for safety
input bool   InpTrackSendOpen = true;

// ------------------------- Inputs ---------------------------------
input long   InpMagicNumber            = 2026011701;

input double InpRiskPercent            = 0.50;     // Risk per trade (% of equity)
input double InpFixedLotFallback       = 0.05;     // Used if risk sizing fails

input int    InpSpreadMaxPoints        = 25;
input int    InpCooldownMinutes        = 120;
input int    InpMaxConsecutiveLosses   = 3;
input double InpDailyLossLimitPercent  = 2.0;

// Session: London (broker/server time)
input int    InpSessionStartHour       = 8;
input int    InpSessionStartMinute     = 0;
input int    InpSessionEndHour         = 17;
input int    InpSessionEndMinute       = 0;

// Indicators
input int    InpEmaFast                = 50;
input int    InpEmaSlow                = 200;
input int    InpRsiPeriod              = 14;

input double InpRsiBuyMax              = 45.0;
input double InpRsiSellMin             = 55.0;

input int    InpAtrPeriod              = 14;
input double InpAtrSLMult              = 2.5;
input double InpTP_R                   = 1.5;

// Volatility safety window (points)
input int    InpAtrMinPoints           = 80;
input int    InpAtrMaxPoints           = 450;

// Optional ADX filter
input bool   InpUseAdxFilter           = true;
input int    InpAdxPeriod              = 14;
input double InpAdxMin                 = 18.0;

// ------------------------- Globals --------------------------------
int hEmaFast = INVALID_HANDLE;
int hEmaSlow = INVALID_HANDLE;
int hRsi     = INVALID_HANDLE;
int hAtr     = INVALID_HANDLE;
int hAdx     = INVALID_HANDLE;

datetime g_lastBarTime   = 0;
datetime g_lastTradeTime = 0;

int    g_consecLosses   = 0;
double g_dayStartEquity = 0.0;
int    g_dayOfYear      = -1;

// Track state (required by KurosawaTrack.mqh integration contract)
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
   datetime t = (datetime)iTime(_Symbol, PERIOD_H1, 0);
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

   for(long i = HistoryDealsTotal()-1; i >= 0; --i)
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

// ------------------------- Trading Logic --------------------------
bool GetSignals(bool &buySignal, bool &sellSignal, double &atrPointsOut)
{
   buySignal = false;
   sellSignal = false;
   atrPointsOut = 0.0;

   double emaFast1, emaSlow1, rsi1, atr1, adx1 = 0.0;

   if(!GetIndicatorDouble(hEmaFast, 0, 1, emaFast1)) return false;
   if(!GetIndicatorDouble(hEmaSlow, 0, 1, emaSlow1)) return false;
   if(!GetIndicatorDouble(hRsi,     0, 1, rsi1))     return false;
   if(!GetIndicatorDouble(hAtr,     0, 1, atr1))     return false;

   // Volatility window first (fail-safe gate)
   double atrPts = atr1 / _Point;
   atrPointsOut = atrPts;

   if(atrPts < InpAtrMinPoints) { g_diag.block_atr++; return true; }
   if(atrPts > InpAtrMaxPoints) { g_diag.block_atr++; return true; }

   // Optional ADX quality gate
   if(InpUseAdxFilter)
   {
      if(!GetIndicatorDouble(hAdx, 0, 1, adx1)) return false;
      if(adx1 < InpAdxMin) { g_diag.block_adx++; return true; }
   }

   bool upTrend   = (emaFast1 > emaSlow1);
   bool downTrend = (emaFast1 < emaSlow1);

   if(upTrend && rsi1 <= InpRsiBuyMax) buySignal = true;
   if(downTrend && rsi1 >= InpRsiSellMin) sellSignal = true;

   if(!buySignal && !sellSignal) g_diag.block_nosignal++;

   return true;
}

bool PlaceTrade(const bool isBuy, const double slDistancePoints, const double tpDistancePoints)
{
   double vol = CalcLotByRisk(slDistancePoints);
   if(vol <= 0.0) vol = NormalizeVolume(_Symbol, InpFixedLotFallback);
   if(vol <= 0.0) vol = GetMinLot(_Symbol);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return false;

   double entry = isBuy ? ask : bid;

   double sl = isBuy ? (entry - slDistancePoints * _Point) : (entry + slDistancePoints * _Point);
   double tp = isBuy ? (entry + tpDistancePoints * _Point) : (entry - tpDistancePoints * _Point);

   // Unified broker constraint enforcement (block rather than silently adjust)
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
   if(_Symbol != "EURJPY")
      Print("Warning: This EA is intended for EURJPY. Current symbol=", _Symbol);

   if(_Period != PERIOD_H1)
      Print("Warning: This EA is intended for H1. Current period=", _Period);

   hEmaFast = iMA(_Symbol, PERIOD_H1, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow = iMA(_Symbol, PERIOD_H1, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   hRsi     = iRSI(_Symbol, PERIOD_H1, InpRsiPeriod, PRICE_CLOSE);
   hAtr     = iATR(_Symbol, PERIOD_H1, InpAtrPeriod);
   if(InpUseAdxFilter) hAdx = iADX(_Symbol, PERIOD_H1, InpAdxPeriod);

   if(hEmaFast == INVALID_HANDLE || hEmaSlow == INVALID_HANDLE ||
      hRsi     == INVALID_HANDLE || hAtr     == INVALID_HANDLE ||
      (InpUseAdxFilter && hAdx == INVALID_HANDLE))
   {
      Print("Failed to create indicator handles");
      return INIT_FAILED;
   }

   RefreshDailyEquityBaseline();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hEmaFast != INVALID_HANDLE) IndicatorRelease(hEmaFast);
   if(hEmaSlow != INVALID_HANDLE) IndicatorRelease(hEmaSlow);
   if(hRsi     != INVALID_HANDLE) IndicatorRelease(hRsi);
   if(hAtr     != INVALID_HANDLE) IndicatorRelease(hAtr);
   if(hAdx     != INVALID_HANDLE) IndicatorRelease(hAdx);
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

   // Daily diagnostics (JST boundary handled in Track file)
   Kurosawa_DailyRollIfNeeded(InpEaName, _Symbol, (ENUM_TIMEFRAMES)_Period, g_diag, NowYmdJst());

   // Hard safety gates
   if(!IsWithinSession()) { g_diag.block_session++; return; }
   if(!SpreadOK())        { g_diag.block_spread++;  return; }
   if(!CooldownOK())      { g_diag.block_cooldown++;return; }
   if(!DailyLossLimitOK()){ g_diag.block_maxday++;  return; }

   // Enforce 1 position per magic using shared helper
   if(PositionExists(_Symbol, (int)InpMagicNumber)) { g_diag.block_haspos++; return; }

   bool isNewBar = IsNewClosedBar();
   if(!isNewBar) return;

   g_diag.bars++;

   // Optional per-bar tracking for MFE/MAE and bar-held
   KurosawaTrack_OnNewBar(InpTrackEnable, (int)InpMagicNumber, _Symbol, (ENUM_TIMEFRAMES)_Period);

   // Loss streak update on new bar
   UpdateLossStreakFromHistory();
   if(g_consecLosses >= InpMaxConsecutiveLosses) { g_diag.block_loss++; return; }

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
