//+------------------------------------------------------------------+
//| File: Tokyo_ScalpHigh_USDJPY_M1.mq5                              |
//| EA  : Tokyo_ScalpHigh_USDJPY_M1                                  |
//| Ver : 0.1.2                                                      |
//|                                                                  |
//| Update (v0.1.2 / 2026-01-10):                                    |
//| - Standalone production version with KurosawaHelpers integration |
//| - Added g_lastClosedDealId to prevent duplicate API tracking     |
//| - Enforced M1 timeframe validation                               |
//| - Cost Guard: Min move must exceed spread × Mult to enter        |
//| - True closed-bar crossover EMA(5/13) indexing                   |
//| - Daily diagnostic summary logging for weekly review             |
//| - API tracking with automated JPY currency detection             |
//|                                                                  |
//| USDJPY Tokyo High-Frequency Scalp EA                             |
//| - Recommended: USDJPY / M1                                       |
//| - Style: Micro-scalping / execution-focused                      |
//| - Entry: EMA(5/13) crossover (previous bar confirmation)         |
//+------------------------------------------------------------------+

#property strict

#include <Trade/Trade.mqh>
#include "KurosawaHelpers.mqh" 

CTrade trade;

//==================== Identity ====================//
input string InpTrackApiKey        = ""; 
input int    InpMagic              = 2026010507;
input string InpEaId               = "ea-tokyo-scalphigh-usdjpy-m1";
input string InpEaName             = "Tokyo_ScalpHigh_USDJPY_M1";
input string InpEaVersion          = "0.1.2";

//==================== Strategy: Scalp Logic ====================//
input int    InpEmaFast            = 5;
input int    InpEmaSlow            = 13;
input bool   InpUseDirFilter       = true;
input int    InpEmaDir             = 50;

//==================== Stops & Targets ====================//
input double InpTpPips             = 4.0;
input double InpSlPips             = 5.0;

//==================== Trade Frequency Controls ====================//
input int    InpMaxTradesPerDay    = 80;
input int    InpCooldownSeconds    = 30;
input int    InpMaxHoldMinutes     = 20;

//==================== Session: Tokyo (JST) ====================//
input int    InpJstStartHour       = 9;
input int    InpJstEndHour         = 23;
input int    InpJstUtcOffset       = 9;

//==================== Execution Guards ====================//
input double InpMaxSpreadPoints    = 18;
input bool   InpUseMinMoveFilter   = true;
input double InpMinMoveSpreadMult  = 2.0;

//==================== Risk Stops ====================//
input int    InpMaxConsecLosses    = 3;
input bool   InpCloseBeforeWeekend = true;
input int    InpFridayCloseHourJst = 22;

//==================== Track API ====================//
input bool   InpTrackEnable        = true;
input string InpTrackApiUrl        = "https://1kpips.com/api/track/record";

//==================== Runtime State ====================//
int hFast, hSlow, hDir;
datetime g_lastBarTime=0, g_lastCloseTime=0;
int g_tradesToday=0, g_consecLosses=0, g_lastJstYmd=0;

// API Tracking Guards
ulong g_lastOpenDealId=0;
ulong g_lastClosedDealId=0; // Prevents duplicate API posts

// Diagnostic Counters
int g_diagBars=0, g_diagSignal=0, g_diagTradeSent=0;

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit() {
   if(_Period != PERIOD_M1) {
      Print("CRITICAL: This EA is designed for M1. Please switch chart.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);
   
   hFast = iMA(_Symbol, PERIOD_M1, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, PERIOD_M1, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   hDir  = iMA(_Symbol, PERIOD_M1, InpEmaDir,  0, MODE_EMA, PRICE_CLOSE);
   
   if(hFast==INVALID_HANDLE || hSlow==INVALID_HANDLE || hDir==INVALID_HANDLE) return INIT_FAILED;
   
   g_lastJstYmd = JstYmd(NowJst(InpJstUtcOffset));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnTick: Execution Loop                                           |
//+------------------------------------------------------------------+
void OnTick() {
   // 1. Reset counters & Log Daily Summary
   int ymd = JstYmd(NowJst(InpJstUtcOffset));
   if(ymd != g_lastJstYmd) {
      PrintFormat("Tokyo Scalp Daily Summary: Bars:%d Signals:%d Trades:%d", g_diagBars, g_diagSignal, g_diagTradeSent);
      g_lastJstYmd = ymd; g_tradesToday = 0; g_diagBars = 0; g_diagSignal = 0; g_diagTradeSent = 0;
   }

   // 2. Safety Exits
   if(InpCloseBeforeWeekend && IsFridayCloseWindow()) {
      if(PositionExists(_Symbol, InpMagic)) trade.PositionClose(_Symbol);
      return;
   }
   CheckHoldTimeExit();

   // 3. Trading Window & Spread Gates
   if(!IsEntryTimeJST(InpJstStartHour, InpJstEndHour, InpJstUtcOffset)) return;
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sprPoints = (ask - bid) / _Point;
   if(sprPoints > InpMaxSpreadPoints) return;

   // 4. Cost Guard (Profit potential vs Spread cost)
   if(InpUseMinMoveFilter) {
      if((InpTpPips * 10) < (sprPoints * InpMinMoveSpreadMult)) return; 
   }

   // 5. New Bar Gate (M1 logic)
   datetime t = iTime(_Symbol, PERIOD_M1, 0);
   if(t == g_lastBarTime) return; 
   g_lastBarTime = t;
   g_diagBars++;

   // 6. Frequency & Risk Gates
   if(g_tradesToday >= InpMaxTradesPerDay || g_consecLosses >= InpMaxConsecLosses) return;
   if(TimeCurrent() - g_lastCloseTime < InpCooldownSeconds) return;
   if(PositionExists(_Symbol, InpMagic)) return;

   // 7. Indicators (Index 1 and 2 for confirmation)
   double f[2], s[2], d[1];
   if(CopyBuffer(hFast,0,1,2,f)!=2 || CopyBuffer(hSlow,0,1,2,s)!=2 || CopyBuffer(hDir,0,1,1,d)!=1) return;

   // crossover: f[0] (bar 2) vs f[1] (bar 1)
   bool crossUp   = (f[1] > s[1] && f[0] <= s[0]);
   bool crossDown = (f[1] < s[1] && f[0] >= s[0]);
   
   double close1 = iClose(_Symbol, PERIOD_M1, 1);
   bool dirUp = (close1 > d[0]);
   bool dirDown = (close1 < d[0]);

   if(crossUp || crossDown) g_diagSignal++;

   // 8. Final Decision
   double slP = PipsToPrice(_Symbol, InpSlPips);
   double tpP = PipsToPrice(_Symbol, InpTpPips);
   string cmt = InpEaName + "|" + InpEaVersion;

   if(crossUp && (!InpUseDirFilter || dirUp)) {
      double sl = ask - slP; double tp = ask + tpP;
      if(EnsureStopsLevel(_Symbol, ask, sl, tp, true, true)) {
         if(trade.Buy(GetMinLot(_Symbol), _Symbol, ask, sl, tp, cmt + "|BUY")) {
            g_tradesToday++; g_diagTradeSent++;
         }
      }
   } else if(crossDown && (!InpUseDirFilter || dirDown)) {
      double sl = bid + slP; double tp = bid - tpP;
      if(EnsureStopsLevel(_Symbol, bid, sl, tp, false, true)) {
         if(trade.Sell(GetMinLot(_Symbol), _Symbol, bid, sl, tp, cmt + "|SELL")) {
            g_tradesToday++; g_diagTradeSent++;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Transaction Monitoring & Tracking                                |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& req, const MqlTradeResult& res) {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal) || HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic) return;

   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   string side = (HistoryDealGetInteger(trans.deal, DEAL_TYPE) == DEAL_TYPE_SELL) ? "SELL" : "BUY";
   double p = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) + HistoryDealGetDouble(trans.deal, DEAL_SWAP) + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   // Record OPEN event
   if(entry == DEAL_ENTRY_IN && trans.deal != g_lastOpenDealId) {
      PostTrack("OPEN", side, HistoryDealGetDouble(trans.deal, DEAL_VOLUME), HistoryDealGetDouble(trans.deal, DEAL_PRICE), 0);
      g_lastOpenDealId = trans.deal;
   } 
   // Record CLOSE event with duplicate guard
   else if (entry == DEAL_ENTRY_OUT && trans.deal != g_lastClosedDealId) {
      g_consecLosses = (p < 0) ? g_consecLosses + 1 : 0;
      g_lastCloseTime = TimeCurrent();
      PostTrack("CLOSE", side, HistoryDealGetDouble(trans.deal, DEAL_VOLUME), HistoryDealGetDouble(trans.deal, DEAL_PRICE), p);
      g_lastClosedDealId = trans.deal; // ID Locked
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

//+------------------------------------------------------------------+
//| Management Logic                                                 |
//+------------------------------------------------------------------+
void CheckHoldTimeExit() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == InpMagic) {
         if(TimeCurrent() - PositionGetInteger(POSITION_TIME) >= InpMaxHoldMinutes * 60) {
            trade.PositionClose(ticket); g_lastCloseTime = TimeCurrent();
         }
      }
   }
}

bool IsFridayCloseWindow() {
   MqlDateTime dt; TimeToStruct(NowJst(InpJstUtcOffset), dt);
   return (dt.day_of_week == 5 && dt.hour >= InpFridayCloseHourJst) || dt.day_of_week == 6;
}
