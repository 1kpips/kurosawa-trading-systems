//+------------------------------------------------------------------+
//| D1 Signal Publisher (SMA + Slope + Distance Penalty)              |
//| - Attaches to each symbol's D1 chart                              |
//| - Uses last closed D1 bar (shift=1)                               |
//| - Computes signal: Close vs SMA, SMA slope, distance penalty      |
//| - Sends once per new closed D1 bar to /api/signals/set            |
//+------------------------------------------------------------------+
#property strict

#include "../Helpers/KurosawaSecrets.mqh"
#include "../Helpers/KurosawaSignalPublisher.mqh"

//==================== Inputs ====================//
input int    InpMagic              = 20260108;

input ENUM_TIMEFRAMES InpTf        = PERIOD_D1;   // Use D1 chart
input int    InpSmaPeriod          = 50;
input int    InpSlopeLookbackBars  = 5;           // slope = SMA[1] - SMA[1+lookback]
input double InpMaxDistPct         = 1.2;         // penalty saturates beyond this % distance

// ---- Signal API
input bool   InpSignalEnable       = true;
input string InpSignalApiUrl       = "https://1kpips.com/api/signals/set";
input string InpSignalApiKey       = KUROSAWA_API_KEY;
input string InpEaId               = "ea-signal-d1-sma-slope";
input string InpEaName             = "D1_SMA_Slope_Signal";
input string InpEaVersion          = "0.1.0";
input string InpStrategy           = "DailySmaSlope";
input int    InpHttpTimeoutMs      = 5000;

// Publish the LAST CLOSED D1 bar once on attach, instead of waiting for the
// next daily rollover. Sends the genuine values of that closed bar - use it
// to verify the pipeline, or to recover a signal missed while MT5 was down.
input bool   InpSendOnInit         = false;

string  g_lastDirection = "N/A";
int     g_lastStrength  = 0;
double  g_lastDistPct   = 0.0;
double  g_lastSlope     = 0.0;
string  g_lastSendText  = "not sent yet";   // "not sent yet" | "OK" | "FAIL"
bool    g_pendingInitSend = false;          // publish-on-attach still owed
int     g_initSendTries   = 0;

//==================== Indicator handles ====================//
int hSma = INVALID_HANDLE;

//==================== State ====================//
datetime g_lastClosedBarTime = 0;

//+------------------------------------------------------------------+
// Data access
//| (JsonEscape / TimeToIsoUtc / Clamp01 come from                    |
//|  ../Helpers/KurosawaSignalPublisher.mqh)                          |
//+------------------------------------------------------------------+
datetime GetBarTime(const int shift)
{
   datetime t[];
   ArraySetAsSeries(t, true);
   if(CopyTime(_Symbol, InpTf, shift, 1, t) != 1) return 0;
   return t[0];
}

bool GetCloseAtShift(const int shift, double &val)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyClose(_Symbol, InpTf, shift, 1, buf) != 1) return false;
   val = buf[0];
   return true;
}

bool GetSmaAtShift(const int shift, double &val)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(hSma, 0, shift, 1, buf) != 1) return false;
   val = buf[0];
   return true;
}

//+------------------------------------------------------------------+
// Compute + send once per new closed D1 bar
//| (JSON build + WebRequest + retry live in Signal_Post(),           |
//|  ../Helpers/KurosawaSignalPublisher.mqh)                          |
//+------------------------------------------------------------------+
bool ComputeAndSend()
{
   double close1=0.0, sma1=0.0, smaRef=0.0;

   if(!GetCloseAtShift(1, close1)) return false;
   if(!GetSmaAtShift(1, sma1)) return false;

   int slopeShift = 1 + MathMax(InpSlopeLookbackBars, 1);
   if(!GetSmaAtShift(slopeShift, smaRef)) return false;

   double slope = sma1 - smaRef; // positive => SMA rising
   double distPct = 0.0;
   if(sma1 != 0.0) distPct = ((close1 - sma1) / sma1) * 100.0;

   string direction = "FLAT";
   if(close1 > sma1 && slope > 0.0) direction = "LONG";
   else if(close1 < sma1 && slope < 0.0) direction = "SHORT";

   double slopeNormPct = 0.0;
   if(sma1 != 0.0) slopeNormPct = (slope / sma1) * 100.0;

   double slopeScore = Clamp01(MathAbs(slopeNormPct) / 0.5);
   double distPenalty = Clamp01(MathAbs(distPct) / InpMaxDistPct);

   double strengthRaw = 50.0 + (direction == "FLAT" ? 0.0 : (slopeScore * 40.0)) - (distPenalty * 25.0);
   if(direction == "FLAT") strengthRaw = MathMin(strengthRaw, 40.0);

   int strength = (int)MathRound(MathMax(0.0, MathMin(100.0, strengthRaw)));

   double score = 0.0;
   if(direction == "LONG")  score = +1.0 * (strength / 100.0);
   if(direction == "SHORT") score = -1.0 * (strength / 100.0);

   datetime barTime = GetBarTime(1);
   if(barTime == 0) return false;

   MqlDateTime dt;
   TimeToStruct(barTime, dt);
   string day = StringFormat("%04d-%02d-%02d", dt.year, dt.mon, dt.day);
   string externalId = _Symbol + "|D1|" + InpStrategy + "|" + day;

   string desc = StringFormat(
      "close=%.5f sma(%d)=%.5f slopeBars=%d slope=%.5f distPct=%.3f slopePct=%.3f penalty=%.2f",
      close1, InpSmaPeriod, sma1, InpSlopeLookbackBars, slope, distPct, slopeNormPct, distPenalty
   );
   
   g_lastDirection = direction;
   g_lastStrength  = strength;
   g_lastDistPct   = distPct;
   g_lastSlope     = slope;

   SignalPubConfig cfg;
   cfg.enable        = InpSignalEnable;
   cfg.apiUrl        = InpSignalApiUrl;
   cfg.apiKey        = InpSignalApiKey;
   cfg.httpTimeoutMs = InpHttpTimeoutMs;
   cfg.eaId          = InpEaId;
   cfg.eaName        = InpEaName;
   cfg.eaVersion     = InpEaVersion;
   cfg.maxRetries    = 2;

   SignalPayload p;
   p.symbol        = _Symbol;
   p.timeframe     = "D1";
   p.strategy      = InpStrategy;
   p.direction     = direction;
   p.strength      = strength;
   p.score         = score;
   // externalId above stays keyed to the BROKER trading day on purpose, so the
   // row identity does not shift and already-published bars keep deduping.
   p.signalTimeUtc = BrokerToUtc(barTime);
   p.description   = desc;
   p.externalId    = externalId;

   const bool sent = Signal_Post(cfg, p);
   g_lastSendText = (sent ? "OK" : "FAIL");
   return sent;
}

void ShowStatus()
{
   string slopeDir = (g_lastSlope > 0 ? "UP" : (g_lastSlope < 0 ? "DOWN" : "FLAT"));

   Comment(
      "D1 Signal EA\n",
      "Symbol: ", _Symbol, "\n",
      "Strategy: ", InpStrategy, "\n",
      "SMA(", InpSmaPeriod, ")\n",
      "Direction: ", g_lastDirection, "\n",
      "Strength: ", g_lastStrength, "\n",
      "Slope: ", DoubleToString(g_lastSlope, 6), " (", slopeDir, ")\n",
      "Distance: ", DoubleToString(g_lastDistPct, 3), "%\n",
      "Last Send: ", g_lastSendText
   );
}

//+------------------------------------------------------------------+
int OnInit()
{
   hSma = iMA(_Symbol, InpTf, InpSmaPeriod, 0, MODE_SMA, PRICE_CLOSE);
   if(hSma == INVALID_HANDLE)
   {
      Print("Failed to create SMA handle.");
      return INIT_FAILED;
   }

   g_lastClosedBarTime = GetBarTime(1);
   g_pendingInitSend   = InpSendOnInit;
   g_initSendTries     = 0;

   EventSetTimer(5);   // poll every 5s, independent of tick flow

   Print("Init OK. symbol=", _Symbol, " strategy=", InpStrategy,
         " sendOnInit=", (InpSendOnInit ? "true" : "false"),
         " lastClosedBar=", TimeToString(g_lastClosedBarTime),
         " url=", InpSignalApiUrl);

   Poll();   // act immediately, do not wait for a tick
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(hSma != INVALID_HANDLE) IndicatorRelease(hSma);
}

// Shared poll body. Driven by ticks AND a timer, so the EA still works on a
// quiet feed (a D1 signal must not depend on tick flow to notice a bar close).
void Poll()
{
   datetime t1 = GetBarTime(1);
   if(t1 == 0)
   {
      Comment("D1 Signal EA | ", _Symbol,
              " | WAITING FOR HISTORY (no D1 bars yet)");
      return;
   }

   // On-attach publish: retry until indicator data is ready, then stop.
   if(g_pendingInitSend)
   {
      g_initSendTries++;
      const bool okInit = ComputeAndSend();
      if(okInit || g_initSendTries >= 10)
      {
         g_pendingInitSend = false;
         Print("On-attach publish finished. ok=", okInit,
               " tries=", g_initSendTries, " symbol=", _Symbol);
      }
   }

   if(t1 != g_lastClosedBarTime)
   {
      g_lastClosedBarTime = t1;
      bool ok = ComputeAndSend();
      Print("Signal computed and sent. ok=", ok, " symbol=", _Symbol);
   }
   
   ShowStatus();
}

void OnTick()  { Poll(); }
void OnTimer() { Poll(); }
