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
// The API key is NOT an input: MT5 writes every input value into chart
// profiles, .set files and the tester journal in plain text. It is read
// straight from KUROSAWA_API_KEY (git-ignored KurosawaSecrets.mqh).
input string InpEaId               = "ea-signal-d1-sma-slope";
input string InpEaName             = "D1_SMA_Slope_Signal";
input string InpEaVersion          = "0.1.0";
input string InpStrategy           = "DailySmaSlope";
input int    InpHttpTimeoutMs      = 5000;

// Publish the LAST CLOSED D1 bar once on attach, instead of waiting for the
// next daily rollover. Sends the genuine values of that closed bar - use it
// to verify the pipeline, or to recover a signal missed while MT5 was down.
input bool   InpSendOnInit         = false;

// On attach, publish the closed bars MT5 missed while it was down: every bar in
// the window the site has no reading for. Never one it already holds.
input bool   InpBackfillOnInit     = true;
input int    InpBackfillMaxBars    = 10;      // two trading weeks

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
int      g_barTries          = 0;   // publish attempts for the pending bar
datetime g_nextBarTry        = 0;   // earliest local time for the next attempt
SignalBackfill g_backfill;

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

void FillConfig(SignalPubConfig &cfg)
{
   cfg.enable        = InpSignalEnable;
   cfg.apiUrl        = InpSignalApiUrl;
   cfg.apiKey        = KUROSAWA_API_KEY;
   cfg.httpTimeoutMs = InpHttpTimeoutMs;
   cfg.eaId          = InpEaId;
   cfg.eaName        = InpEaName;
   cfg.eaVersion     = InpEaVersion;
   cfg.maxRetries    = 2;
}

//+------------------------------------------------------------------+
// Compute + send one closed D1 bar: shift 1 on a rollover, older
// shifts when backfilling after downtime.
//| (JSON build + WebRequest + retry live in Signal_Post(),           |
//|  ../Helpers/KurosawaSignalPublisher.mqh)                          |
//+------------------------------------------------------------------+
bool ComputeAndSend(const int shift)
{
   double close1=0.0, sma1=0.0, smaRef=0.0;

   if(!GetCloseAtShift(shift, close1)) return false;
   if(!GetSmaAtShift(shift, sma1)) return false;

   int slopeShift = shift + MathMax(InpSlopeLookbackBars, 1);
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

   datetime barTime = GetBarTime(shift);
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
   FillConfig(cfg);

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

// SignalSendAtShift adapter: one symbol per chart, so the slot is unused.
bool SendAtShift(const int slot, const int shift) { return ComputeAndSend(shift); }

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
   Signal_BackfillInit(g_backfill, InpBackfillOnInit);

   EventSetTimer(5);   // poll every 5s, independent of tick flow

   Print("Init OK. symbol=", _Symbol, " strategy=", InpStrategy,
         " sendOnInit=", (InpSendOnInit ? "true" : "false"),
         " backfill=", (InpBackfillOnInit ? "true" : "false"),
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
   if(g_backfill.pending)
   {
      SignalPubConfig cfg;
      FillConfig(cfg);
      Signal_BackfillStep(g_backfill, cfg, _Symbol, InpTf, "D1", InpStrategy,
                          InpBackfillMaxBars, SendAtShift, 0);
   }

   if(g_pendingInitSend)
   {
      g_initSendTries++;
      const bool okInit = ComputeAndSend(1);
      if(okInit || g_initSendTries >= 10)
      {
         g_pendingInitSend = false;
         Print("On-attach publish finished. ok=", okInit,
               " tries=", g_initSendTries, " symbol=", _Symbol);
      }
   }

   // Advance the bar ONLY on success, so a failed publish is retried instead of
   // being lost for the day (2026-10-07: a reconnect blip at the D1 rollover cost
   // 20 readings, while D1_Signal_Trend, which already did this, recovered).
   // Poll also runs on every tick, so retries are spaced by time, not by call.
   if(t1 != g_lastClosedBarTime && TimeLocal() >= g_nextBarTry)
   {
      g_barTries++;
      const bool ok = ComputeAndSend(1);
      Print("Signal computed and sent. ok=", ok, " symbol=", _Symbol, " try=", g_barTries);
      if(ok || g_barTries >= 12)
      {
         if(!ok) Print("Publish FAILED after retries, skipping bar. symbol=", _Symbol);
         g_lastClosedBarTime = t1;
         g_barTries          = 0;
         g_nextBarTry        = 0;
      }
      else
         g_nextBarTry = TimeLocal() + 60;
   }
   
   ShowStatus();
}

void OnTick()  { Poll(); }
void OnTimer() { Poll(); }
