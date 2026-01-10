//+------------------------------------------------------------------+
//| File: Tokyo_SwingTrend_USDJPY_H1.mq5                             |
//| EA  : Tokyo_SwingTrend_USDJPY_H1                                 |
//| Ver : 0.1.1                                                      |
//|                                                                  |
//| Update (v0.1.1 / 2026-01-10):                                    |
//| - Standalone production version with KurosawaHelpers integration |
//| - True closed-bar logic (EMA/RSI/ATR/ADX pull from Index 1)      |
//| - Added g_lastClosedDealId to prevent duplicate API tracking     |
//| - ATR-based SL and R-Multiple TP calculation                     |
//| - Unified order comment (EA|SIDE|VERSION)                        |
//| - Automated JPY currency detection for Tracking API              |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
#include "KurosawaHelpers.mqh" 

CTrade trade;

//==================== Identity ====================//
input string InpTrackApiKey        = ""; 
input int    InpMagic              = 2026011008;
input string InpEaId               = "ea-tokyo-swingtrend-usdjpy-h1";
input string InpEaName             = "Tokyo_SwingTrend_USDJPY_H1";
input string InpEaVersion          = "0.1.1";

//==================== Session: Tokyo (JST) ====================//
input int    InpJstStartHour       = 9;
input int    InpJstEndHour         = 23;
input int    InpJstUtcOffset       = 9;

//==================== Strategy: Trend & Pullback ====================//
input int    InpEmaFast            = 50;
input int    InpEmaSlow            = 200;
input int    InpRsiPeriod          = 14;
input double InpRsiBuyPullback     = 45.0;
input double InpRsiSellPullback    = 55.0;

//==================== Market Quality Filters ====================//
input int    InpAtrPeriod          = 14;
input double InpAtrMinPips         = 8.0;   
input bool   InpUseAdxFilter       = true;
input double InpMinAdxToTrade      = 18.0;

//==================== Stops & Exit Management ====================//
input double InpSlAtrMult          = 2.0;   
input double InpTpRMultiple        = 2.5;   
input bool   InpUseTrailing        = true;
input double InpTrailStartR        = 1.0;   
input double InpTrailStepAtrMult   = 0.7;   
input int    InpMaxHoldHours       = 96;

//==================== Risk & Safety ====================//
input double InpMaxSpreadPoints    = 20;
input int    InpMaxTradesPerDay    = 4;
input int    InpMaxConsecLosses    = 3;
input bool   InpCloseBeforeWeekend = true;
input int    InpFridayCloseHourJst = 22;

//==================== Track API Config ====================//
input bool   InpTrackEnable        = true;
input string InpTrackApiUrl        = "https://1kpips.com/api/track/record";

//==================== Runtime State ====================//
int hEmaFast, hEmaSlow, hRsi, hAtr, hAdx;
datetime g_lastBarTime=0, g_lastCloseTime=0;
int g_tradesToday=0, g_consecLosses=0, g_lastJstYmd=0;

ulong g_lastOpenDealId=0;
ulong g_lastClosedDealId=0;

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(InpMagic);
   
   hEmaFast = iMA(_Symbol, _Period, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow = iMA(_Symbol, _Period, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   hRsi     = iRSI(_Symbol, _Period, InpRsiPeriod, PRICE_CLOSE);
   hAtr     = iATR(_Symbol, _Period, InpAtrPeriod);
   hAdx     = iADX(_Symbol, _Period, 14);
   
   if(hEmaFast==INVALID_HANDLE || hEmaSlow==INVALID_HANDLE || hRsi==INVALID_HANDLE || hAtr==INVALID_HANDLE || hAdx==INVALID_HANDLE) 
      return INIT_FAILED;
   
   g_lastJstYmd = JstYmd(NowJst(InpJstUtcOffset));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnTick: Core Execution                                           |
//+------------------------------------------------------------------+
void OnTick() {
   int ymd = JstYmd(NowJst(InpJstUtcOffset));
   if(ymd != g_lastJstYmd) { g_lastJstYmd = ymd; g_tradesToday = 0; }

   if(InpCloseBeforeWeekend && IsWeekendWindow()) {
      if(PositionExists(_Symbol, InpMagic)) trade.PositionClose(_Symbol);
      return;
   }
   CheckHoldTimeExit();

   double f1, s1, r1, a1, adx1;
   double bufF[], bufS[], bufR[], bufA[], bufADX[];
   ArraySetAsSeries(bufF, true); ArraySetAsSeries(bufS, true); 
   ArraySetAsSeries(bufR, true); ArraySetAsSeries(bufA, true); ArraySetAsSeries(bufADX, true);

   if(CopyBuffer(hEmaFast,0,1,1,bufF)!=1 || CopyBuffer(hEmaSlow,0,1,1,bufS)!=1 || 
      CopyBuffer(hRsi,0,1,1,bufR)!=1 || CopyBuffer(hAtr,0,1,1,bufA)!=1 || CopyBuffer(hAdx,0,1,1,bufADX)!=1) return;

   f1=bufF[0]; s1=bufS[0]; r1=bufR[0]; a1=bufA[0]; adx1=bufADX[0];

   if(InpUseTrailing) ApplySwingTrailing(a1);

   if(!IsEntryTimeJST(InpJstStartHour, InpJstEndHour, InpJstUtcOffset)) return;
   
   datetime t = iTime(_Symbol, _Period, 0);
   if(t == g_lastBarTime) return; 
   g_lastBarTime = t;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(((ask-bid)/_Point) > InpMaxSpreadPoints) return;
   
   if(g_tradesToday >= InpMaxTradesPerDay || g_consecLosses >= InpMaxConsecLosses) return;
   if(PositionExists(_Symbol, InpMagic)) return;

   bool uptrend   = (f1 > s1);
   bool downtrend = (f1 < s1);
   bool atrOk     = (a1 >= PipsToPrice(_Symbol, InpAtrMinPips));
   bool adxOk     = (!InpUseAdxFilter || adx1 >= InpMinAdxToTrade);

   bool buySig    = (uptrend && r1 <= InpRsiBuyPullback && atrOk && adxOk);
   bool sellSig   = (downtrend && r1 >= InpRsiSellPullback && atrOk && adxOk);

   if(!buySig && !sellSig) return;

   double slDist = a1 * InpSlAtrMult;
   double lot = GetMinLot(_Symbol);
   string cmt = InpEaName + "|" + InpEaVersion;

   if(buySig) {
      double sl = ask - slDist;
      double tp = ask + (slDist * InpTpRMultiple);
      if(EnsureStopsLevel(_Symbol, ask, sl, tp, true, true)) {
         if(trade.Buy(lot, _Symbol, ask, sl, tp, cmt + "|BUY")) g_tradesToday++;
      }
   } else if(sellSig) {
      double sl = bid + slDist;
      double tp = bid - (slDist * InpTpRMultiple);
      if(EnsureStopsLevel(_Symbol, bid, sl, tp, false, true)) {
         if(trade.Sell(lot, _Symbol, bid, sl, tp, cmt + "|SELL")) g_tradesToday++;
      }
   }
}

//+------------------------------------------------------------------+
//| Management & Tracking Logic                                      |
//+------------------------------------------------------------------+
void ApplySwingTrailing(double atrVal) {
   if(!PositionSelectByMagic(_Symbol, InpMagic)) return;

   double open = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl   = PositionGetDouble(POSITION_SL);
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   double initialSlDist = MathAbs(open - sl);
   if(initialSlDist <= 0) return;

   if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
      if(bid - open < initialSlDist * InpTrailStartR) return;
      double newSl = NormalizeDouble(bid - (atrVal * InpTrailStepAtrMult), _Digits);
      if(newSl > sl) trade.PositionModify(_Symbol, newSl, PositionGetDouble(POSITION_TP));
   } else {
      if(open - ask < initialSlDist * InpTrailStartR) return;
      double newSl = NormalizeDouble(ask + (atrVal * InpTrailStepAtrMult), _Digits);
      if(sl == 0 || newSl < sl) trade.PositionModify(_Symbol, newSl, PositionGetDouble(POSITION_TP));
   }
}

void CheckHoldTimeExit() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == InpMagic) {
         if(TimeCurrent() - PositionGetInteger(POSITION_TIME) >= InpMaxHoldHours * 3600) {
            trade.PositionClose(ticket); g_lastCloseTime = TimeCurrent();
         }
      }
   }
}

bool IsWeekendWindow() {
   MqlDateTime dt; TimeToStruct(NowJst(InpJstUtcOffset), dt);
   return (dt.day_of_week == 5 && dt.hour >= InpFridayCloseHourJst) || dt.day_of_week == 6;
}

void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& req, const MqlTradeResult& res) {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal) || HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic) return;

   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   string side = (HistoryDealGetInteger(trans.deal, DEAL_TYPE) == DEAL_TYPE_SELL) ? "SELL" : "BUY";
   double p = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) + HistoryDealGetDouble(trans.deal, DEAL_SWAP) + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   if(entry == DEAL_ENTRY_IN && trans.deal != g_lastOpenDealId) {
      PostTrack("OPEN", side, HistoryDealGetDouble(trans.deal, DEAL_VOLUME), HistoryDealGetDouble(trans.deal, DEAL_PRICE), 0);
      g_lastOpenDealId = trans.deal;
   } else if (entry == DEAL_ENTRY_OUT && trans.deal != g_lastClosedDealId) {
      g_consecLosses = (p < 0) ? g_consecLosses + 1 : 0;
      g_lastCloseTime = TimeCurrent();
      PostTrack("CLOSE", side, HistoryDealGetDouble(trans.deal, DEAL_VOLUME), HistoryDealGetDouble(trans.deal, DEAL_PRICE), p);
      g_lastClosedDealId = trans.deal;
   }
}

void PostTrack(string type, string side, double vol, double price, double profit) {
   if(!InpTrackEnable) return;
   string body = StringFormat("{\"eaId\":\"%s\",\"eventType\":\"%s\",\"side\":\"%s\",\"volume\":%.2f,\"price\":%.5f,\"profit\":%.2f,\"currency\":\"%s\"}",
                              InpEaId, type, side, vol, price, profit, AccountInfoString(ACCOUNT_CURRENCY));
   
   uchar data[]; StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   string headers = "Content-Type: application/json\r\nX-API-Key: " + InpTrackApiKey + "\r\n";
   char res_d[]; string res_h;
   WebRequest("POST", InpTrackApiUrl, headers, 5000, data, res_d, res_h);
}

bool PositionSelectByMagic(string smb, int magic) {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t) && PositionGetString(POSITION_SYMBOL) == smb && PositionGetInteger(POSITION_MAGIC) == magic) return true;
   }
   return false;
}
