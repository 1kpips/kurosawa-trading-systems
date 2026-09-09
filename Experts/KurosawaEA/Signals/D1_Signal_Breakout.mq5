//+------------------------------------------------------------------+
//| D1 Signal Publisher (Breakout: Donchian + ATR Expansion)          |
//| - Attaches to each symbol's D1 chart                              |
//| - Uses last closed D1 bar (shift=1)                               |
//| - Donchian breakout based on close over previous range            |
//| - Strength uses breakout distance normalized by ATR + ATR ratio   |
//| - Sends once per new closed D1 bar to /api/signals/set            |
//+------------------------------------------------------------------+
#property strict

#include "../Helpers/KurosawaSecrets.mqh"
#include "../Helpers/KurosawaSignalPublisher.mqh"

//==================== Inputs ====================//
input int    InpMagic              = 20260111;

input ENUM_TIMEFRAMES InpTf        = PERIOD_D1;
input int    InpLookbackBars       = 20;           // breakout range window
input int    InpAtrPeriod          = 14;
input int    InpAtrAvgBars         = 20;           // average ATR window for expansion check
input double InpMinAtrRatio        = 1.00;         // ATR(shift=1) / avgATR >= this suggests expansion

// ---- Signal API
input bool   InpSignalEnable       = true;
input string InpSignalApiUrl       = "https://1kpips.com/api/signals/set";
input string InpSignalApiKey       = KUROSAWA_API_KEY;
input string InpEaId               = "ea-signal-d1-breakout";
input string InpEaName             = "D1_Breakout_Signal";
input string InpEaVersion          = "0.1.0";
input string InpStrategy           = "Breakout";
input int    InpHttpTimeoutMs      = 5000;

// Publish the LAST CLOSED D1 bar once on attach, instead of waiting for the
// next daily rollover. Sends the genuine values of that closed bar - use it
// to verify the pipeline, or to recover a signal missed while MT5 was down.
input bool   InpSendOnInit         = false;

//==================== State ====================//
datetime g_lastClosedBarTime = 0;

string  g_lastDirection = "N/A";
int     g_lastStrength  = 0;
double  g_lastAtr       = 0.0;
double  g_lastAtrRatio  = 0.0;
string  g_lastSendText  = "not sent yet";   // "not sent yet" | "OK" | "FAIL"
bool    g_pendingInitSend = false;          // publish-on-attach still owed
int     g_initSendTries   = 0;

//==================== Indicator handles ====================//
int hAtr = INVALID_HANDLE;

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

bool GetHighLowRangePrev(const int lookbackBars, double &hi, double &lo)
{
   // We exclude shift=1 bar from the range calculation.
   // Use shifts 2..(lookbackBars+1)
   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);

   int need = lookbackBars;
   if(CopyHigh(_Symbol, InpTf, 2, need, highs) != need) return false;
   if(CopyLow (_Symbol, InpTf, 2, need, lows)  != need) return false;

   hi = highs[0];
   lo = lows[0];
   for(int i=1; i<need; i++)
   {
      if(highs[i] > hi) hi = highs[i];
      if(lows[i]  < lo) lo = lows[i];
   }
   return true;
}

bool GetAtrAtShift(const int shift, double &val)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(hAtr, 0, shift, 1, buf) != 1) return false;
   val = buf[0];
   return true;
}

bool GetAtrAverage(const int startShift, const int bars, double &avg)
{
   // Average ATR over [startShift .. startShift+bars-1]
   double buf[];
   ArraySetAsSeries(buf, true);

   if(CopyBuffer(hAtr, 0, startShift, bars, buf) != bars) return false;

   double sum = 0.0;
   for(int i=0; i<bars; i++) sum += buf[i];
   avg = (bars > 0 ? sum / bars : 0.0);
   return true;
}

//+------------------------------------------------------------------+
// Compute + send once per new closed D1 bar
//| (JSON build + WebRequest + retry live in Signal_Post(),           |
//|  ../Helpers/KurosawaSignalPublisher.mqh)                          |
//+------------------------------------------------------------------+
bool ComputeAndSend()
{
   double close1=0.0;
   if(!GetCloseAtShift(1, close1)) return false;

   double hi=0.0, lo=0.0;
   if(!GetHighLowRangePrev(InpLookbackBars, hi, lo)) return false;

   double atr1=0.0, atrAvg=0.0;
   if(!GetAtrAtShift(1, atr1)) return false;

   // Average ATR excluding shift=1 to avoid leaking current bar impact.
   // Use shifts 2..(2+InpAtrAvgBars-1)
   if(!GetAtrAverage(2, InpAtrAvgBars, atrAvg)) return false;

   double atrRatio = 0.0;
   if(atrAvg > 0.0) atrRatio = atr1 / atrAvg;

   string direction = "FLAT";
   double breakoutDist = 0.0;

   if(close1 > hi)
   {
      direction = "LONG";
      breakoutDist = close1 - hi;
   }
   else if(close1 < lo)
   {
      direction = "SHORT";
      breakoutDist = lo - close1;
   }

   // Strength
   double distByAtr = 0.0;
   if(atr1 > 0.0) distByAtr = breakoutDist / atr1;

   double distScore = Clamp01(distByAtr / 0.75);                    // 0..1 when dist is 0..0.75 ATR
   double atrScore  = Clamp01((atrRatio - InpMinAtrRatio) / 0.50);  // 0..1 when ratio exceeds threshold by 0.5

   double strengthRaw = 35.0;
   if(direction != "FLAT")
      strengthRaw = 55.0 + distScore * 30.0 + atrScore * 15.0;
   else
      strengthRaw = 35.0 + atrScore * 10.0;

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
      "close=%.5f lookback=%d prevHigh=%.5f prevLow=%.5f breakoutDist=%.5f atr(%d)=%.5f atrAvg(%d)=%.5f atrRatio=%.3f distByAtr=%.3f",
      close1, InpLookbackBars, hi, lo, breakoutDist, InpAtrPeriod, atr1, InpAtrAvgBars, atrAvg, atrRatio, distByAtr
   );

   g_lastDirection = direction;
   g_lastStrength  = strength;
   g_lastAtr       = atr1;
   g_lastAtrRatio  = atrRatio;

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
   Comment(
      "D1 Signal EA\n",
      "Symbol: ", _Symbol, "\n",
      "Strategy: ", InpStrategy, "\n",
      "Direction: ", g_lastDirection, "\n",
      "Strength: ", g_lastStrength, "\n",
      "ATR: ", DoubleToString(g_lastAtr, 6), "\n",
      "ATR Ratio: ", DoubleToString(g_lastAtrRatio, 3), "\n",
      "Last Send: ", g_lastSendText
   );
}

//+------------------------------------------------------------------+
int OnInit()
{
   hAtr = iATR(_Symbol, InpTf, InpAtrPeriod);
   if(hAtr == INVALID_HANDLE)
   {
      Print("Failed to create ATR handle.");
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
   if(hAtr != INVALID_HANDLE) IndicatorRelease(hAtr);
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
