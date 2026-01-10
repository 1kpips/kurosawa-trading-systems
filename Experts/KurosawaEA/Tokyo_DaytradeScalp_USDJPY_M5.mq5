//+------------------------------------------------------------------+
//| File: Tokyo_DaytradeScalp_USDJPY_M5.mq5                          |
//| EA  : Tokyo_DaytradeScalp_USDJPY_M5                              |
//| Ver : 0.1.2                                                      |
//|                                                                  |
//| Update (v0.1.2 / 2026-01-10):                                    |
//| - Standalone production version with KurosawaHelpers integration |
//| - Enforced M5 timeframe chart validation                         |
//| - Closed-bar EMA(9/21) crossover with EMA(200) trend filter      |
//| - Diagnostic logging for daily summaries & gate monitoring       |
//| - Tracking API integration with automated currency detection     |
//|                                                                  |
//| USDJPY Tokyo Daytrade Scalp EA                                   |
//| - Recommended: USDJPY / M5                                       |
//| - Entry: EMA(9/21) crossover in EMA(200) trend direction         |
//| - Session: Tokyo (JST) 09:00 -> 23:00                            |
//+------------------------------------------------------------------+

#property strict

#include <Trade/Trade.mqh>
#include "KurosawaHelpers.mqh" // Shared utility library

CTrade trade;

//==================== Identity ====================//
input string InpTrackApiKey        = "";
input int    InpMagic              = 2026010505;
input string InpEaId               = "ea-tokyo-daytradescalp-usdjpy-m5";
input string InpEaName             = "Tokyo_DaytradeScalp_USDJPY_M5";
input string InpEaVersion          = "0.1.2";

//==================== Strategy: EMA Configuration ====================//
input int    InpEmaFast            = 9;
input int    InpEmaSlow            = 21;
input int    InpEmaTrend           = 200;

//==================== Risk & Exit Parameters ====================//
input double InpSlPips             = 6.0;
input double InpTpPips             = 6.0;
input int    InpMaxTradesPerDay    = 6;
input int    InpCooldownMinutes    = 10;
input int    InpMaxHoldMinutes     = 60;   // Intraday hold limit
input double InpMaxSpreadPoints    = 25;

//==================== Session: Tokyo (JST) ====================//
input int    InpJstStartHour       = 9;
input int    InpJstEndHour         = 23;
input int    InpJstUtcOffset       = 9;

//==================== Track API Config ====================//
input bool   InpTrackEnable        = true;
input string InpTrackApiUrl        = "https://1kpips.com/api/track/record";

//==================== Indicators & State ====================//
int hEmaFast, hEmaSlow, hEmaTrend;
datetime g_lastBarTime=0, g_lastCloseTime=0;
int g_tradesToday=0, g_lastJstYmd=0;
ulong g_lastOpenId=0, g_lastCloseId=0;

// Diagnostic Counters
int g_diagBars=0, g_diagSignal=0, g_diagTradeSent=0;

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit() {
   // Validate timeframe
   if(_Period != PERIOD_M5) {
      Print("CRITICAL ERROR: This EA must be attached to an M5 chart.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);
   
   hEmaFast  = iMA(_Symbol, PERIOD_M5, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow  = iMA(_Symbol, PERIOD_M5, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   hEmaTrend = iMA(_Symbol, PERIOD_M5, InpEmaTrend, 0, MODE_EMA, PRICE_CLOSE);
   
   if(hEmaFast==INVALID_HANDLE || hEmaSlow==INVALID_HANDLE || hEmaTrend==INVALID_HANDLE) return INIT_FAILED;
   
   g_lastJstYmd = JstYmd(NowJst(InpJstUtcOffset));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnTick: Main Execution                                           |
//+------------------------------------------------------------------+
void OnTick() {
   // 1. Reset counters on new day (JST)
   int ymd = JstYmd(NowJst(InpJstUtcOffset));
   if(ymd != g_lastJstYmd) {
      PrintDailySummary(); // Log summary before resetting
      g_lastJstYmd = ymd; g_tradesToday = 0; g_diagBars = 0; g_diagSignal = 0; g_diagTradeSent = 0;
   }

   // 2. Automated Exits (Time Hold)
   CheckTimeExit();

   // 3. Execution Gates
   if(!IsEntryTimeJST(InpJstStartHour, InpJstEndHour, InpJstUtcOffset)) return;
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(((ask-bid)/_Point) > InpMaxSpreadPoints) return;

   datetime t = iTime(_Symbol, PERIOD_M5, 0);
   if(t == g_lastBarTime) return; // Wait for bar completion
   g_lastBarTime = t;
   g_diagBars++;

   if(g_tradesToday >= InpMaxTradesPerDay) return;
   if(TimeCurrent() - g_lastCloseTime < InpCooldownMinutes * 60) return;
   if(PositionExists(_Symbol, InpMagic)) return;

   // 4. Indicator Logic (Bar 1 and Bar 2)
   double f[2], s[2], tr[1];
   if(CopyBuffer(hEmaFast,0,1,2,f)!=2 || CopyBuffer(hEmaSlow,0,1,2,s)!=2 || CopyBuffer(hEmaTrend,0,1,1,tr)!=1) return;

   // Crossover logic (Bar 2 was outside, Bar 1 crossed)
   bool crossUp   = (f[1] > s[1] && f[0] <= s[0]);
   bool crossDown = (f[1] < s[1] && f[0] >= s[0]);
   
   double close1 = iClose(_Symbol, PERIOD_M5, 1);
   bool trendUp   = (close1 > tr[0]);
   bool trendDown = (close1 < tr[0]);

   if(crossUp || crossDown) g_diagSignal++;

   // 5. Entry Rules
   double slPrice = PipsToPrice(_Symbol, InpSlPips);
   double tpPrice = PipsToPrice(_Symbol, InpTpPips);
   string cmt = InpEaName + "|" + InpEaVersion;

   if(crossUp && trendUp) {
      double sl = ask - slPrice; double tp = ask + tpPrice;
      if(EnsureStopsLevel(_Symbol, ask, sl, tp, true, true)) {
         if(trade.Buy(GetMinLot(_Symbol), _Symbol, ask, sl, tp, cmt + "|BUY")) {
            g_tradesToday++; g_diagTradeSent++;
         }
      }
   } else if(crossDown && trendDown) {
      double sl = bid + slPrice; double tp = bid - tpPrice;
      if(EnsureStopsLevel(_Symbol, bid, sl, tp, false, true)) {
         if(trade.Sell(GetMinLot(_Symbol), _Symbol, bid, sl, tp, cmt + "|SELL")) {
            g_tradesToday++; g_diagTradeSent++;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Management & Diagnostics                                         |
//+------------------------------------------------------------------+
void CheckTimeExit() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == InpMagic) {
         if(TimeCurrent() - PositionGetInteger(POSITION_TIME) >= InpMaxHoldMinutes * 60) {
            Print("Max hold time reached. Closing position.");
            trade.PositionClose(ticket);
            g_lastCloseTime = TimeCurrent();
         }
      }
   }
}

void PrintDailySummary() {
   PrintFormat("--- DAILY SUMMARY [%d] --- Bars: %d | Signals: %d | Trades: %d", 
               g_lastJstYmd, g_diagBars, g_diagSignal, g_diagTradeSent);
}

//+------------------------------------------------------------------+
//| API Tracking                                                     |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& req, const MqlTradeResult& res) {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal) || HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic) return;

   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   string side = (HistoryDealGetInteger(trans.deal, DEAL_TYPE) == DEAL_TYPE_SELL) ? "SELL" : "BUY";
   double p = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) + HistoryDealGetDouble(trans.deal, DEAL_SWAP) + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   if(entry == DEAL_ENTRY_IN && trans.deal != g_lastOpenId) {
      PostTrack("OPEN", side, HistoryDealGetDouble(trans.deal, DEAL_VOLUME), HistoryDealGetDouble(trans.deal, DEAL_PRICE), 0);
      g_lastOpenId = trans.deal;
   } else if (entry == DEAL_ENTRY_OUT && trans.deal != g_lastCloseId) {
      g_lastCloseTime = TimeCurrent();
      PostTrack("CLOSE", side, HistoryDealGetDouble(trans.deal, DEAL_VOLUME), HistoryDealGetDouble(trans.deal, DEAL_PRICE), p);
      g_lastCloseId = trans.deal;
   }
}

void PostTrack(string type, string side, double vol, double price, double profit) {
   if(!InpTrackEnable) return;
   string body = StringFormat("{\"eaId\":\"%s\",\"eventType\":\"%s\",\"side\":\"%s\",\"volume\":%.2f,\"price\":%.5f,\"profit\":%.2f,\"currency\":\"%s\"}",
                              InpEaId, type, side, vol, price, profit, AccountInfoString(ACCOUNT_CURRENCY));
   
   uchar data[]; StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   string headers = "Content-Type: application/json\r\nX-API-Key: " + InpTrackApiKey + "\r\n";
   char res_data[]; string res_headers;
   WebRequest("POST", InpTrackApiUrl, headers, 5000, data, res_data, res_headers);
}
