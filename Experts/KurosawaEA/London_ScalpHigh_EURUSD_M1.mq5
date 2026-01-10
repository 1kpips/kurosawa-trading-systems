//+------------------------------------------------------------------+
//| File: London_ScalpHigh_EURUSD_M1.mq5                             |
//| EA  : London_ScalpHigh_EURUSD_M1                                 |
//| Ver : 0.1.1                                                      |
//|                                                                  |
//| Update (v0.1.1 / 2026-01-10):                                    |
//| - Use closed-bar EMA crossover (reduce chop entries)             |
//| - Normalize SL/TP + validate StopsLevel/FrozenLevel              |
//| - Enforce 1-position-per-EA via Magic                            |
//| - Unified order comment: EA|SIDE|VERSION                         |
//| - Add lightweight debug logs for weekly review                   |
//|                                                                  |
//| EURUSD London High-Frequency Scalp EA                            |
//| - Recommended: EURUSD / M1                                       |
//| - Entry: EMA(5/13) crossover using previous closed bar           |
//| - Optional filter: EMA(50) trend direction                       |
//| - Safety: max spread, daily trade cap, cooldown, loss streak     |
//| - Time: London session (configured in JST: 16:00 -> 01:00 JST)   |
//| - Positioning: 1 EA = 1 position (Magic)                         |
//| - Tracking: POST CLOSE (and optional OPEN) to /api/track/record  |
//|                                                                  |
//| Notes:                                                           |
//| - If publishing to GitHub, keep API key empty and set locally.   |
//| - MT5 WebRequest must be allowlisted in Terminal settings.       |
//|                                                                  |
//| Review policy: Weekly review                                     |
//+------------------------------------------------------------------+

#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//==================== Identity ====================//
// NOTE: Clear API key before publishing to GitHub.
input string InpTrackApiKey        = "";

input int    InpMagic              = 2026011001;
input string InpEaId               = "ea-london-scalphigh-eurusd";
input string InpEaName             = "London_ScalpHigh_EURUSD_M1";
input string InpEaVersion          = "0.1.1";

//==================== Session (London, defined in JST) ====================//
// London ≒ JST 16:00 → 01:00 (crossing midnight)
input int    InpJstStartHour       = 16;
input int    InpJstEndHour         = 1;
input int    InpJstUtcOffsetHours  = 9;

//==================== Risk & Operation ====================//
input double InpSlPips             = 6.0;
input double InpTpPips             = 8.0;

input int    InpMaxTradesPerDay    = 25;
input int    InpCooldownMinutes    = 2;
input int    InpMaxConsecLosses    = 3;

//==================== Execution Guards ====================//
input double InpMaxSpreadPoints    = 20;   // 0 = disable

//==================== Strategy: EMA Logic ====================//
input int    InpEmaFast            = 5;
input int    InpEmaSlow            = 13;

input bool   InpUseTrendFilter     = true;
input int    InpEmaTrend           = 50;

//==================== Track API ====================//
input bool   InpTrackEnable        = true;
input bool   InpTrackSendOpen      = true;
input string InpTrackApiUrl        = "https://1kpips.com/api/track/record";
input int    InpHttpTimeoutMs      = 5000;

//==================== Indicator Handles ====================//
int hEmaFast   = INVALID_HANDLE;
int hEmaSlow   = INVALID_HANDLE;
int hEmaTrend  = INVALID_HANDLE;

//==================== Runtime State ====================//
datetime g_lastBarTime     = 0;
datetime g_lastCloseTime   = 0;

int      g_tradesToday     = 0;
int      g_lossStreak      = 0;
int      g_lastJstYmd      = 0;

ulong    g_lastDealOpenId  = 0;
ulong    g_lastDealCloseId = 0;

//+------------------------------------------------------------------+
//| Utilities: Time and Date Calculations                            |
//+------------------------------------------------------------------+

// Returns current time adjusted to Japan Standard Time (JST)
datetime NowJst()
{
   return TimeGMT() + InpJstUtcOffsetHours * 3600;
}

// Converts a datetime to an integer YYYYMMDD for daily reset checks
int JstYmd(datetime t)
{
   MqlDateTime d; TimeToStruct(t, d);
   return d.year*10000 + d.mon*100 + d.day;
}

// Checks if the current JST time falls within the allowed session window
bool IsTradingTimeJST()
{
   MqlDateTime d; TimeToStruct(NowJst(), d);

   if(InpJstStartHour <= InpJstEndHour)
      return (d.hour >= InpJstStartHour && d.hour < InpJstEndHour);

   return (d.hour >= InpJstStartHour || d.hour < InpJstEndHour);
}

//+------------------------------------------------------------------+
//| Utilities: Trade Execution Helpers                               |
//+------------------------------------------------------------------+

// Detects the start of a new candle to prevent multiple trades per bar
bool IsNewBar()
{
   datetime t = iTime(_Symbol, _Period, 0);
   if(t == g_lastBarTime) return false;
   g_lastBarTime = t;
   return true;
}

// Robust pip-to-price conversion for 5-digit brokers
double PipsToPrice(double pips)
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pipVal = (digits == 3 || digits == 5) ? 10 * _Point : _Point;
   return pips * pipVal;
}

// Filters entries based on current market spread
bool SpreadOK()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return false;
   return ((ask - bid) / _Point <= InpMaxSpreadPoints);
}

// Prevents rapid-fire trading by enforcing a wait period after a close
bool CooldownOK()
{
   if(InpCooldownMinutes <= 0) return true;
   if(g_lastCloseTime <= 0) return true;

   datetime now = TimeCurrent();
   return (now - g_lastCloseTime) >= (InpCooldownMinutes * 60);
}

// Validates SL/TP against broker's minimum StopLevels and FreezeLevels
bool EnsureStopsLevel(double entry, double &sl, double &tp, bool isBuy)
{
   int level = (int)MathMax(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL), 
                           SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL));
   double minDist = level * _Point;

   if(isBuy)
   {
      if(sl > 0 && (entry - sl) < minDist) sl = entry - minDist;
      if(tp > 0 && (tp - entry) < minDist) tp = entry + minDist;
   }
   else
   {
      if(sl > 0 && (sl - entry) < minDist) sl = entry + minDist;
      if(tp > 0 && (entry - tp) < minDist) tp = entry - minDist;
   }
   
   sl = (sl > 0 ? NormalizeDouble(sl, _Digits) : 0);
   tp = (tp > 0 ? NormalizeDouble(tp, _Digits) : 0);
   return true;
}

// Checks if the EA already has a position open (1 position per Magic)
bool HasOpenPosition()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Track API: JSON Formatting and WebRequest                        |
//+------------------------------------------------------------------+

string JsonEscape(const string s)
{
   string x=s;
   StringReplace(x,"\\","\\\\");
   StringReplace(x,"\"","\\\"");
   return x;
}

bool PostTrack(const string eventType, const string side, const double volume, 
               const double price, const double profit, const string payload)
{
   if(!InpTrackEnable) return true;

   string body = StringFormat(
      "{\"eaId\":\"%s\",\"eaName\":\"%s\",\"eaVersion\":\"%s\",\"eventType\":\"%s\","
      "\"symbol\":\"%s\",\"side\":\"%s\",\"volume\":%.2f,\"price\":%.5f,"
      "\"profit\":%.2f,\"currency\":\"%s\",\"payloadJson\":\"%s\"}",
      InpEaId, InpEaName, InpEaVersion, eventType, _Symbol, side, volume, price, 
      profit, AccountInfoString(ACCOUNT_CURRENCY), JsonEscape(payload)
   );

   uchar data[];
   int len=StringToCharArray(body,data,0,WHOLE_ARRAY,CP_UTF8);
   if(len>0) ArrayResize(data,len-1);

   string headers="Content-Type: application/json\r\nX-API-Key: "+InpTrackApiKey+"\r\n";
   char result[]; string rh;

   int status=WebRequest("POST",InpTrackApiUrl,headers,InpHttpTimeoutMs,data,result,rh);
   if(status<200 || status>=300) Print("Track API Error: Status ",status);

   return true;
}

//+------------------------------------------------------------------+
//| Trade Transaction: Real-time deal monitoring                     |
//+------------------------------------------------------------------+

void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& req, const MqlTradeResult& res)
{
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=InpMagic) return;

   long entry = HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
   long type  = HistoryDealGetInteger(trans.deal,DEAL_TYPE);
   string side=(type==DEAL_TYPE_SELL?"SELL":"BUY");

   double vol=HistoryDealGetDouble(trans.deal,DEAL_VOLUME);
   double price=HistoryDealGetDouble(trans.deal,DEAL_PRICE);

   // Handle Opening Deals
   if(entry==DEAL_ENTRY_IN && InpTrackSendOpen && trans.deal!=g_lastDealOpenId)
   {
      PostTrack("OPEN",side,vol,price,0,"{}");
      g_lastDealOpenId=trans.deal;
   }

   // Handle Closing Deals
   if(entry==DEAL_ENTRY_OUT && trans.deal!=g_lastDealCloseId)
   {
      double p=HistoryDealGetDouble(trans.deal,DEAL_PROFIT)+
               HistoryDealGetDouble(trans.deal,DEAL_SWAP)+
               HistoryDealGetDouble(trans.deal,DEAL_COMMISSION);

      g_lossStreak = (p < 0 ? g_lossStreak + 1 : 0);
      g_lastDealCloseId=trans.deal;
      g_lastCloseTime=TimeCurrent();

      PostTrack("CLOSE",side,vol,price,p,"{}");
   }
}

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);

   // Initialize Indicator Handles
   hEmaFast  = iMA(_Symbol,_Period,InpEmaFast,0,MODE_EMA,PRICE_CLOSE);
   hEmaSlow  = iMA(_Symbol,_Period,InpEmaSlow,0,MODE_EMA,PRICE_CLOSE);
   hEmaTrend = iMA(_Symbol,_Period,InpEmaTrend,0,MODE_EMA,PRICE_CLOSE);

   if(hEmaFast==INVALID_HANDLE || hEmaSlow==INVALID_HANDLE || hEmaTrend==INVALID_HANDLE)
   {
      Print("CRITICAL: Failed to create indicator handles.");
      return INIT_FAILED;
   }

   g_lastJstYmd = JstYmd(NowJst());
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnTick: Main Execution Logic                                     |
//+------------------------------------------------------------------+

void OnTick()
{
   // 1. Daily Reset Check
   int ymd=JstYmd(NowJst());
   if(ymd!=g_lastJstYmd)
   {
      g_lastJstYmd=ymd;
      g_tradesToday=0;
      g_lossStreak=0;
   }

   // 2. Execution Gates (Safety Checks)
   if(!IsTradingTimeJST()) return;
   if(!SpreadOK()) return;
   if(!IsNewBar()) return; // Entry logic only runs once per candle close
   if(g_tradesToday >= InpMaxTradesPerDay) return;
   if(!CooldownOK()) return;
   if(g_lossStreak >= InpMaxConsecLosses) return;
   if(HasOpenPosition()) return;

   // 3. Signal Calculation (Using closed bars: index 1 and 2)
   double ef[2], es[2], et[1];
   if(CopyBuffer(hEmaFast,0,1,2,ef)!=2) return;
   if(CopyBuffer(hEmaSlow,0,1,2,es)!=2) return;
   if(CopyBuffer(hEmaTrend,0,1,1,et)!=1) return;

   // Crossover logic: Bar 2 was outside, Bar 1 (newest closed) crossed over
   bool crossUp   = (ef[1] > es[1] && ef[0] < es[0]); 
   bool crossDown = (ef[1] < es[1] && ef[0] > es[0]);

   // Trend Filter: Price vs EMA Trend on last closed bar
   bool trendUp   = (iClose(_Symbol,_Period,1) > et[0]);
   bool trendDown = (iClose(_Symbol,_Period,1) < et[0]);

   // 4. Execution Prices and Volumes
   double lot=SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN); 
   double slD=PipsToPrice(InpSlPips);
   double tpD=PipsToPrice(InpTpPips);

   string cmtBase = InpEaName + "|" + InpEaVersion;

   // 5. Final Entry Logic
   if(crossUp && (!InpUseTrendFilter || trendUp))
   {
      double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double sl = ask - slD; double tp = ask + tpD;
      
      if(EnsureStopsLevel(ask, sl, tp, true))
      {
         if(trade.Buy(lot, _Symbol, ask, sl, tp, cmtBase + "|BUY"))
         {
            g_tradesToday++;
            PrintFormat("Scalp BUY Sent: SL %.5f TP %.5f", sl, tp);
         }
      }
   }
   else if(crossDown && (!InpUseTrendFilter || trendDown))
   {
      double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double sl = bid + slD; double tp = bid - tpD;

      if(EnsureStopsLevel(bid, sl, tp, false))
      {
         if(trade.Sell(lot, _Symbol, bid, sl, tp, cmtBase + "|SELL"))
         {
            g_tradesToday++;
            PrintFormat("Scalp SELL Sent: SL %.5f TP %.5f", sl, tp);
         }
      }
   }
}
