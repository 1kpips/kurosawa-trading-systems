//+------------------------------------------------------------------+
//| File: Tokyo_RangeRevert_USDJPY_M5.mq5                            |
//| EA  : Tokyo_RangeRevert_USDJPY_M5                                |
//| Ver : 0.1.2                                                      |
//|                                                                  |
//| Update (v0.1.2 / 2026-01-10):                                    |
//| - Standalone production version with KurosawaHelpers integration |
//| - Added missing InpTrackEnable flag for API control              |
//| - Mid-Band exit logic (reversion target confirmation)            |
//| - MaxHoldMinutes time stop (fails fast on broken ranges)         |
//| - Entry quality filter: MinBandBreakPips + Edge-over-Spread      |
//| - Tracking API with automated JPY currency detection             |
//|                                                                  |
//| USDJPY Tokyo Range Mean Reversion EA                             |
//| - Recommended: USDJPY / M5                                       |
//| - Entry: Price close outside BB + RSI extreme                    |
//| - Exit: Mid-Band touch or MaxHoldMinutes                         |
//+------------------------------------------------------------------+

#property strict

#include <Trade/Trade.mqh>
#include "KurosawaHelpers.mqh" 

CTrade trade;

//==================== Identity ====================//
input string InpTrackApiKey        = "";
input int    InpMagic              = 2026010606;
input string InpEaId               = "ea-tokyo-range-usdjpy-m5";
input string InpEaName             = "Tokyo_RangeRevert_USDJPY_M5";
input string InpEaVersion          = "0.1.2";

//==================== Session (JST) ====================//
input int    InpJstStartHour       = 9;
input int    InpJstEndHour         = 23;
input int    InpJstUtcOffset       = 9;

//==================== Strategy: Range Reversion ====================//
input int    InpBBPeriod           = 20;
input double InpBBDev              = 2.0;
input double InpRsiBuyBelow        = 30.0;
input double InpRsiSellAbove       = 70.0;
input double InpMaxAdxToTrade      = 22.0;
input bool   InpUseMidBandExit     = true;

//==================== Quality Filters ====================//
input double InpMinBandBreakPips   = 1.5;   
input double InpMinEdgeOverSpread  = 2.0;   

//==================== Risk & Operation ====================//
input double InpSlPips             = 10.0;
input double InpTpPips             = 6.0;   
input int    InpMaxTradesPerDay    = 20;
input int    InpCooldownMinutes    = 5;
input int    InpMaxHoldMinutes     = 120;   
input double InpMaxSpreadPoints    = 25;

//==================== Track API ====================//
input bool   InpTrackEnable        = true; // Fixed: Added missing input
input bool   InpTrackSendOpen      = true;
input string InpTrackApiUrl        = "https://1kpips.com/api/track/record";

//==================== Indicator Handles & State ====================//
int hBB, hRSI, hADX;
datetime g_lastBarTime=0, g_lastCloseTime=0;
int g_tradesToday=0, g_lossStreak=0, g_lastJstYmd=0;
ulong g_lastOpenId=0, g_lastCloseId=0;

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit() {
   if(_Period != PERIOD_M5) {
      Print("CRITICAL: Attach to M5 chart only.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);
   hBB  = iBands(_Symbol, _Period, InpBBPeriod, 0, InpBBDev, PRICE_CLOSE);
   hRSI = iRSI(_Symbol, _Period, 14, PRICE_CLOSE);
   hADX = iADX(_Symbol, _Period, 14);
   
   if(hBB == INVALID_HANDLE || hRSI == INVALID_HANDLE || hADX == INVALID_HANDLE) return INIT_FAILED;
   
   g_lastJstYmd = JstYmd(NowJst(InpJstUtcOffset));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnTick: Main Execution                                           |
//+------------------------------------------------------------------+
void OnTick() {
   // 1. Reset daily counters
   int ymd = JstYmd(NowJst(InpJstUtcOffset));
   if(ymd != g_lastJstYmd) { g_lastJstYmd = ymd; g_tradesToday = 0; g_lossStreak = 0; }

   // 2. Indicator Data (Closed Bar 1)
   double bbU[1], bbM[1], bbL[1], rsi[1];
   if(CopyBuffer(hBB, 0, 1, 1, bbU) != 1 || CopyBuffer(hBB, 1, 1, 1, bbM) != 1 || 
      CopyBuffer(hBB, 2, 1, 1, bbL) != 1 || CopyBuffer(hRSI, 0, 1, 1, rsi) != 1) return;

   // 3. Dynamic Exits (Mid-Band & Time)
   CheckMeanReversionExits(bbM[0]);

   // 4. Entry Gates
   if(!IsEntryTimeJST(InpJstStartHour, InpJstEndHour, InpJstUtcOffset)) return;
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spreadPts = (ask - bid) / _Point;
   if(spreadPts > InpMaxSpreadPoints) return;

   datetime t = iTime(_Symbol, _Period, 0);
   if(t == g_lastBarTime) return;
   g_lastBarTime = t;

   if(g_tradesToday >= InpMaxTradesPerDay || g_lossStreak >= 3) return;
   if(TimeCurrent() - g_lastCloseTime < InpCooldownMinutes * 60) return;
   if(PositionExists(_Symbol, InpMagic)) return;

   // 5. Signal Logic
   if(!IsTrendQuiet(hADX, InpMaxAdxToTrade)) return;

   double c1 = iClose(_Symbol, _Period, 1);
   double minBreak = PipsToPrice(_Symbol, InpMinBandBreakPips);
   double minEdge = (spreadPts * _Point) * InpMinEdgeOverSpread;

   bool buySig  = (c1 < (bbL[0] - minBreak) && rsi[0] <= InpRsiBuyBelow && (bbM[0] - c1) > minEdge);
   bool sellSig = (c1 > (bbU[0] + minBreak) && rsi[0] >= InpRsiSellAbove && (c1 - bbM[0]) > minEdge);

   // 6. Execution
   double slP = PipsToPrice(_Symbol, InpSlPips);
   double tpP = PipsToPrice(_Symbol, InpTpPips);
   string cmt = InpEaName + "|" + InpEaVersion;

   if(buySig) {
      double sl = ask - slP; double tp = InpUseMidBandExit ? 0 : ask + tpP;
      if(EnsureStopsLevel(_Symbol, ask, sl, tp, true, true)) {
         if(trade.Buy(GetMinLot(_Symbol), _Symbol, ask, sl, tp, cmt + "|BUY")) g_tradesToday++;
      }
   } else if(sellSig) {
      double sl = bid + slP; double tp = InpUseMidBandExit ? 0 : bid - tpP;
      if(EnsureStopsLevel(_Symbol, bid, sl, tp, false, true)) {
         if(trade.Sell(GetMinLot(_Symbol), _Symbol, bid, sl, tp, cmt + "|SELL")) g_tradesToday++;
      }
   }
}

//+------------------------------------------------------------------+
//| Exits & API Tracking                                             |
//+------------------------------------------------------------------+
void CheckMeanReversionExits(double midPrice) {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == InpMagic) {
         long type = PositionGetInteger(POSITION_TYPE);
         datetime openT = (datetime)PositionGetInteger(POSITION_TIME);

         if(TimeCurrent() - openT >= InpMaxHoldMinutes * 60) {
            trade.PositionClose(ticket); g_lastCloseTime = TimeCurrent(); return;
         }
         if(InpUseMidBandExit) {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            if((type == POSITION_TYPE_BUY && bid >= midPrice) || (type == POSITION_TYPE_SELL && ask <= midPrice)) {
               trade.PositionClose(ticket); g_lastCloseTime = TimeCurrent();
            }
         }
      }
   }
}

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
      g_lossStreak = (p < 0) ? g_lossStreak + 1 : 0;
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
   char res_d[]; string res_h;
   WebRequest("POST", InpTrackApiUrl, headers, 5000, data, res_d, res_h);
}
