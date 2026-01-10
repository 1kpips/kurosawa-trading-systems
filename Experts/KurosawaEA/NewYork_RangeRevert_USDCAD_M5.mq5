//+------------------------------------------------------------------+
//| File: NewYork_RangeRevert_USDCAD_M5.mq5                          |
//| EA  : NewYork_RangeRevert_USDCAD_M5                              |
//| Ver : 0.1.1                                                      |
//|                                                                  |
//| Update (v0.1.1 / 2026-01-10):                                    |
//| - New York session filter (configured in JST, DST-adjustable)    |
//| - Bollinger Bands + RSI mean reversion                           |
//| - ADX filter to avoid trend-dominated conditions                 |
//| - Normalize SL/TP + validate StopsLevel before order send        |
//| - Unified order comment (EA|SIDE|VERSION)                        |
//| - Track API: POST CLOSE (and optional OPEN)                      |
//|                                                                  |
//| USDCAD New York Range Reversion EA                               |
//| - Recommended: USDCAD / M5                                       |
//| - Market regime: Range / mean-reverting conditions               |
//| - Entry: BB re-entry after touch + RSI extreme                   |
//| - Filter: ADX upper limit to block trend days                    |
//| - Session: New York window (defined in JST)                      |
//| - Safety: spread limit, daily trade cap, cooldown, loss streak   |
//| - Positioning: 1 EA = 1 position (Magic)                         |
//| - Tracking: /api/track/record                                    |
//+------------------------------------------------------------------+

#property strict

#include <Trade/Trade.mqh>
#include "KurosawaHelpers.mqh" // Ensure this is in the same folder

CTrade trade;

//==================== Identity ====================//
input string InpTrackApiKey        = "";
input int    InpMagic              = 2026011003;
input string InpEaId               = "ea-ny-rangerevert-usdcad-m5-v011";
input string InpEaName             = "NewYork_RangeRevert_USDCAD_M5";
input string InpEaVersion          = "0.1.1";

//==================== Session (JST) ====================//
input int    InpJstStartHour       = 22;
input int    InpJstEndHour         = 5;
input int    InpJstUtcOffset       = 9;

//==================== Strategy Inputs ====================//
input int    InpBBPeriod           = 20;
input double InpBBDev              = 2.0;
input int    InpRsiPeriod          = 14;
input double InpRsiBuyBelow        = 30.0;
input double InpRsiSellAbove       = 70.0;
input int    InpAdxPeriod          = 14;
input double InpMaxAdxToTrade      = 22.0;

//==================== Risk & Safety ====================//
input double InpSlPips             = 12.0;
input double InpTpPips             = 8.0;
input double InpMaxSpreadPoints    = 25.0;
input int    InpMaxTradesPerDay    = 12;
input int    InpCooldownMinutes    = 10;
input int    InpMaxConsecLosses    = 3;

//==================== Track API ====================//
input bool   InpTrackEnable        = true;
input bool   InpTrackSendOpen      = true;
input string InpTrackApiUrl        = "https://1kpips.com/api/track/record";

//==================== Runtime State ====================//
int hBB, hRSI, hADX;
datetime g_lastBarTime=0, g_lastCloseTime=0;
int g_tradesToday=0, g_lossStreak=0, g_lastJstYmd=0;
ulong g_lastOpenDealId=0, g_lastCloseDealId=0;

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(InpMagic);
   
   hBB  = iBands(_Symbol, _Period, InpBBPeriod, 0, InpBBDev, PRICE_CLOSE);
   hRSI = iRSI(_Symbol, _Period, InpRsiPeriod, PRICE_CLOSE);
   hADX = iADX(_Symbol, _Period, InpAdxPeriod);
   
   if(hBB == INVALID_HANDLE || hRSI == INVALID_HANDLE || hADX == INVALID_HANDLE) {
      Print("Error: Failed to create indicator handles.");
      return INIT_FAILED;
   }
   
   g_lastJstYmd = JstYmd(NowJst(InpJstUtcOffset));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinitialization                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   IndicatorRelease(hBB);
   IndicatorRelease(hRSI);
   IndicatorRelease(hADX);
}

//+------------------------------------------------------------------+
//| OnTick: Main Execution Logic                                     |
//+------------------------------------------------------------------+
void OnTick() {
   // 1. Daily Reset Check
   int ymd = JstYmd(NowJst(InpJstUtcOffset));
   if(ymd != g_lastJstYmd) { g_lastJstYmd = ymd; g_tradesToday = 0; g_lossStreak = 0; }

   // 2. Safety Gates
   if(!IsEntryTimeJST(InpJstStartHour, InpJstEndHour, InpJstUtcOffset)) return;
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(((ask - bid) / _Point) > InpMaxSpreadPoints) return;

   datetime t = iTime(_Symbol, _Period, 0);
   if(t == g_lastBarTime) return;
   g_lastBarTime = t;

   if(g_tradesToday >= InpMaxTradesPerDay || g_lossStreak >= InpMaxConsecLosses) return;
   if(TimeCurrent() - g_lastCloseTime < InpCooldownMinutes * 60) return;
   if(PositionExists(_Symbol, InpMagic)) return;

   // 3. ADX Regime Filter (Blocks Range Entries during Trending Markets)
   if(!IsTrendQuiet(hADX, InpMaxAdxToTrade)) return;

   // 4. Indicator Signals (Using Closed Bars)
   double bbU[2], bbL[2], rsi1;
   ArraySetAsSeries(bbU, true); ArraySetAsSeries(bbL, true);
   
   if(CopyBuffer(hBB, 0, 1, 2, bbU) != 2 || CopyBuffer(hBB, 2, 1, 2, bbL) != 2) return;
   
   double rsiBuf[]; ArraySetAsSeries(rsiBuf, true);
   if(CopyBuffer(hRSI, 0, 1, 1, rsiBuf) != 1) return;
   rsi1 = rsiBuf[0];

   double c1 = iClose(_Symbol, _Period, 1);
   double c2 = iClose(_Symbol, _Period, 2);

   // Re-entry Logic: Bar 2 was outside the band, Bar 1 closed back inside
   bool buySig  = (c2 < bbL[1] && c1 > bbL[0] && rsi1 <= InpRsiBuyBelow);
   bool sellSig = (c2 > bbU[1] && c1 < bbU[0] && rsi1 >= InpRsiSellAbove);

   if(!buySig && !sellSig) return;

   // 5. Execution
   double slP = PipsToPrice(_Symbol, InpSlPips);
   double tpP = PipsToPrice(_Symbol, InpTpPips);
   double lot = GetMinLot(_Symbol);

   string cmt = InpEaName + "|" + InpEaVersion;

   if(buySig) {
      double sl = ask - slP; double tp = ask + tpP;
      if(EnsureStopsLevel(_Symbol, ask, sl, tp, true, true)) {
         if(trade.Buy(lot, _Symbol, ask, sl, tp, cmt + "|BUY")) g_tradesToday++;
      }
   } else if(sellSig) {
      double sl = bid + slP; double tp = bid - tpP;
      if(EnsureStopsLevel(_Symbol, bid, sl, tp, false, true)) {
         if(trade.Sell(lot, _Symbol, bid, sl, tp, cmt + "|SELL")) g_tradesToday++;
      }
   }
}

//+------------------------------------------------------------------+
//| API Tracking: Transaction Monitoring                             |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& req, const MqlTradeResult& res) {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal) || HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic) return;

   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   string side = (HistoryDealGetInteger(trans.deal, DEAL_TYPE) == DEAL_TYPE_SELL) ? "SELL" : "BUY";
   double p = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) + HistoryDealGetDouble(trans.deal, DEAL_SWAP) + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   if(entry == DEAL_ENTRY_IN && trans.deal != g_lastOpenDealId) {
      PostTrack("OPEN", side, HistoryDealGetDouble(trans.deal, DEAL_VOLUME), HistoryDealGetDouble(trans.deal, DEAL_PRICE), 0);
      g_lastOpenDealId = trans.deal;
   } else if (entry == DEAL_ENTRY_OUT && trans.deal != g_lastCloseDealId) {
      g_lossStreak = (p < 0) ? g_lossStreak + 1 : 0;
      g_lastCloseDealId = trans.deal;
      g_lastCloseTime = TimeCurrent();
      PostTrack("CLOSE", side, HistoryDealGetDouble(trans.deal, DEAL_VOLUME), HistoryDealGetDouble(trans.deal, DEAL_PRICE), p);
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
