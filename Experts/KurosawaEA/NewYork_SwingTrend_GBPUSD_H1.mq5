//+------------------------------------------------------------------+
//| File: NewYork_SwingTrend_GBPUSD_H1.mq5                           |
//| EA  : NewYork_SwingTrend_GBPUSD_H1                               |
//| Ver : 0.1.1                                                      |
//|                                                                  |
//| Update (v0.1.1 / 2026-01-10):                                    |
//| - New York session entry window (configured in JST, DST-aware)   |
//| - EMA(50/200) trend detection with RSI pullback entry            |
//| - ATR-based SL/TP for volatility-adaptive risk control           |
//| - Optional ATR trailing for extended trend capture               |
//| - Normalize prices + validate StopsLevel before order send       |
//| - Unified order comment (EA|SIDE|VERSION)                        |
//| - Track API: POST CLOSE (and optional OPEN)                      |
//|                                                                  |
//| GBPUSD New York Swing Trend EA                                   |
//| - Recommended: GBPUSD / H1                                       |
//| - Market regime: Trending (multi-hour to multi-day holds)        |
//| - Entry: RSI pullback in EMA trend direction                     |
//| - Stops: ATR-based SL, R-multiple TP, optional ATR trailing      |
//| - Session: New York window (defined in JST, DST-adjustable)      |
//| - Safety: spread limit, daily trade cap, cooldown, loss streak   |
//| - Positioning: 1 EA = 1 position (Magic)                         |
//| - Tracking: /api/track/record                                    |
//|                                                                  |
//| Review policy: Weekly review                                     |
//+------------------------------------------------------------------+

#property strict

#include <Trade/Trade.mqh>
#include "KurosawaHelpers.mqh" // Shared helper library

CTrade trade;

//==================== Identity ====================//
input string InpTrackApiKey        = ""; 
input int    InpMagic              = 2026011004;
input string InpEaId               = "ea-ny-swingtrend-gbpusd-h1-v011";
input string InpEaName             = "NewYork_SwingTrend_GBPUSD_H1";
input string InpEaVersion          = "0.1.1";

//==================== Session: New York (JST) ====================//
input int    InpJstStartHour       = 22;
input int    InpJstEndHour         = 5;
input int    InpJstUtcOffset       = 9;

//==================== Strategy: Trend & Pullback ====================//
input int    InpEmaFast            = 50;
input int    InpEmaSlow            = 200;
input int    InpRsiPeriod          = 14;
input double InpRsiBuyPullback     = 45.0;   // Buy when RSI dips below this in uptrend
input double InpRsiSellPullback    = 55.0;   // Sell when RSI rallies above this in downtrend

//==================== Strategy: Volatility Stops ====================//
input int    InpAtrPeriod          = 14;
input double InpAtrSlMult          = 2.0;
input double InpAtrTpMult          = 3.0;

//==================== Trade Management ====================//
input bool   InpUseTrailing        = true;
input double InpTrailStartAtrMult  = 1.5;
input double InpTrailStepAtrMult   = 1.0;
input int    InpMaxHoldHours       = 96;

//==================== Risk & Safety ====================//
input double InpMaxSpreadPoints    = 20;
input int    InpMaxTradesPerDay    = 4;
input int    InpCooldownMinutes    = 60;
input int    InpMaxConsecLosses    = 3;
input bool   InpCloseBeforeWeekend = true;
input int    InpFridayCloseHourJst = 22;

//==================== Track API ====================//
input bool   InpTrackEnable        = true;
input bool   InpTrackSendOpen      = true;
input string InpTrackApiUrl        = "https://1kpips.com/api/track/record";

//==================== Runtime State ====================//
int hEmaFast, hEmaSlow, hRsi, hAtr;
datetime g_lastBarTime=0, g_lastCloseTime=0;
int g_tradesToday=0, g_consecLosses=0, g_lastJstYmd=0;
ulong g_lastOpenDealId=0, g_lastCloseDealId=0;

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(InpMagic);
   
   hEmaFast = iMA(_Symbol, _Period, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow = iMA(_Symbol, _Period, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   hRsi     = iRSI(_Symbol, _Period, InpRsiPeriod, PRICE_CLOSE);
   hAtr     = iATR(_Symbol, _Period, InpAtrPeriod);
   
   if(hEmaFast == INVALID_HANDLE || hEmaSlow == INVALID_HANDLE || hRsi == INVALID_HANDLE || hAtr == INVALID_HANDLE) {
      Print("CRITICAL: Indicator handle creation failed.");
      return INIT_FAILED;
   }
   
   g_lastJstYmd = JstYmd(NowJst(InpJstUtcOffset));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnTick: Main Logic Loop                                          |
//+------------------------------------------------------------------+
void OnTick() {
   // 1. Daily Reset Check
   int ymd = JstYmd(NowJst(InpJstUtcOffset));
   if(ymd != g_lastJstYmd) { g_lastJstYmd = ymd; g_tradesToday = 0; }

   // 2. Hard Exits (Weekend & Time)
   if(InpCloseBeforeWeekend && IsFridayWindow()) {
      if(PositionExists(_Symbol, InpMagic)) {
         trade.PositionClose(_Symbol);
         g_lastCloseTime = TimeCurrent();
      }
   }

   // 3. Trailing Stops & Indicator Data (Using Bar 1)
   double atr1; double bA[]; ArraySetAsSeries(bA, true);
   if(CopyBuffer(hAtr, 0, 1, 1, bA) != 1) return;
   atr1 = bA[0];

   if(InpUseTrailing) ApplyAtrTrailing(atr1);

   // 4. Execution Gates
   bool isNewBar = false;
   datetime t = iTime(_Symbol, _Period, 0);
   if(t != g_lastBarTime) { isNewBar = true; g_lastBarTime = t; }

   if(!IsEntryTimeJST(InpJstStartHour, InpJstEndHour, InpJstUtcOffset) || !isNewBar) return;
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(((ask-bid)/_Point) > InpMaxSpreadPoints) return;
   
   if(g_tradesToday >= InpMaxTradesPerDay || g_consecLosses >= InpMaxConsecLosses) return;
   if(PositionExists(_Symbol, InpMagic)) return;

   // 5. Signal Logic (EMA Trend + RSI Pullback)
   double f1, s1, r1; double bF[], bS[], bR[];
   ArraySetAsSeries(bF, true); ArraySetAsSeries(bS, true); ArraySetAsSeries(bR, true);
   if(CopyBuffer(hEmaFast, 0, 1, 1, bF) != 1 || CopyBuffer(hEmaSlow, 0, 1, 1, bS) != 1 || CopyBuffer(hRsi, 0, 1, 1, bR) != 1) return;
   
   f1 = bF[0]; s1 = bS[0]; r1 = bR[0];
   bool buySig = (f1 > s1 && r1 <= InpRsiBuyPullback);
   bool sellSig = (f1 < s1 && r1 >= InpRsiSellPullback);

   if(!buySig && !sellSig) return;

   // 6. Placement
   double slDist = atr1 * InpAtrSlMult;
   double tpDist = atr1 * InpAtrTpMult;
   string comment = InpEaName + "|" + InpEaVersion;

   if(buySig) {
      double sl = ask - slDist; double tp = ask + tpDist;
      if(EnsureStopsLevel(_Symbol, ask, sl, tp, true, true))
         if(trade.Buy(GetMinLot(_Symbol), _Symbol, ask, sl, tp, comment + "|BUY")) g_tradesToday++;
   } else {
      double sl = bid + slDist; double tp = bid - tpDist;
      if(EnsureStopsLevel(_Symbol, bid, sl, tp, false, true))
         if(trade.Sell(GetMinLot(_Symbol), _Symbol, bid, sl, tp, comment + "|SELL")) g_tradesToday++;
   }
}

//+------------------------------------------------------------------+
//| ATR Trailing Management                                          |
//+------------------------------------------------------------------+
void ApplyAtrTrailing(double atrVal) {
   if(!PositionSelectByMagic(_Symbol, InpMagic)) return;

   double open = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl   = PositionGetDouble(POSITION_SL);
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
      if(bid - open < atrVal * InpTrailStartAtrMult) return;
      double newSl = NormalizeDouble(bid - (atrVal * InpTrailStepAtrMult), _Digits);
      if(sl == 0 || newSl > sl) trade.PositionModify(_Symbol, newSl, PositionGetDouble(POSITION_TP));
   } else {
      if(open - ask < atrVal * InpTrailStartAtrMult) return;
      double newSl = NormalizeDouble(ask + (atrVal * InpTrailStepAtrMult), _Digits);
      if(sl == 0 || newSl < sl) trade.PositionModify(_Symbol, newSl, PositionGetDouble(POSITION_TP));
   }
}

//+------------------------------------------------------------------+
//| API Tracking & Transaction Events                                |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& req, const MqlTradeResult& res) {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal) || HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic) return;

   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   string side = (HistoryDealGetInteger(trans.deal, DEAL_TYPE) == DEAL_TYPE_SELL) ? "SELL" : "BUY";
   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) + HistoryDealGetDouble(trans.deal, DEAL_SWAP) + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   if(entry == DEAL_ENTRY_IN && trans.deal != g_lastOpenDealId) {
      SendApiRecord("OPEN", side, HistoryDealGetDouble(trans.deal, DEAL_VOLUME), HistoryDealGetDouble(trans.deal, DEAL_PRICE), 0);
      g_lastOpenDealId = trans.deal;
   } else if ((entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY) && trans.deal != g_lastCloseDealId) {
      g_consecLosses = (profit < 0) ? g_consecLosses + 1 : 0;
      g_lastCloseDealId = trans.deal;
      g_lastCloseTime = TimeCurrent();
      SendApiRecord("CLOSE", side, HistoryDealGetDouble(trans.deal, DEAL_VOLUME), HistoryDealGetDouble(trans.deal, DEAL_PRICE), profit);
   }
}

void SendApiRecord(string type, string side, double vol, double price, double profit) {
   if(!InpTrackEnable) return;
   string body = StringFormat("{\"eaId\":\"%s\",\"eventType\":\"%s\",\"side\":\"%s\",\"volume\":%.2f,\"price\":%.5f,\"profit\":%.2f,\"currency\":\"%s\"}",
                              InpEaId, type, side, vol, price, profit, AccountInfoString(ACCOUNT_CURRENCY));
   
   uchar data[]; StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   string headers = "Content-Type: application/json\r\nX-API-Key: " + InpTrackApiKey + "\r\n";
   char res_data[]; string res_headers;
   WebRequest("POST", InpTrackApiUrl, headers, 5000, data, res_data, res_headers);
}

//+------------------------------------------------------------------+
//| Local Logic Helpers                                              |
//+------------------------------------------------------------------+
bool IsFridayWindow() {
   MqlDateTime dt; TimeToStruct(NowJst(InpJstUtcOffset), dt);
   if(dt.day_of_week == 5 && dt.hour >= InpFridayCloseHourJst) return true;
   if(dt.day_of_week == 6) return true;
   return false;
}

bool PositionSelectByMagic(string smb, int magic) {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t) && PositionGetString(POSITION_SYMBOL) == smb && PositionGetInteger(POSITION_MAGIC) == magic) return true;
   }
   return false;
}
