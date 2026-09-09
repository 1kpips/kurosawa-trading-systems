//+------------------------------------------------------------------+
//| D1 Signal Publisher (DailyTrend: EMA Alignment + ADX)             |
//| MULTI-SYMBOL scanner.                                             |
//|                                                                   |
//| - Attach to ONE chart. It scans every pair listed in InpSymbols.  |
//| - Uses the last CLOSED D1 bar (shift=1), per symbol.              |
//| - Timer driven, so it does not depend on the chart symbol ticking.|
//| - Publishes once per new closed D1 bar, per symbol.               |
//|                                                                   |
//| Replaces the old one-chart-per-pair setup (10 pairs x 3           |
//| strategies = 30 charts) with one chart per strategy.              |
//+------------------------------------------------------------------+
#property strict

#include "../Helpers/KurosawaSecrets.mqh"
#include "../Helpers/KurosawaSignalPublisher.mqh"

//==================== Inputs ====================//
input int    InpMagic              = 20260111;

input ENUM_TIMEFRAMES InpTf        = PERIOD_D1;

// Comma separated. Must match the broker's symbol names exactly
// (some brokers use suffixes such as USDJPY.pro).
input string InpSymbols            = "USDJPY,EURUSD,GBPUSD,AUDUSD,USDCHF,USDCAD,NZDUSD,EURJPY,GBPJPY,EURGBP";

input int    InpEmaFastPeriod      = 20;
input int    InpEmaSlowPeriod      = 50;
input int    InpAdxPeriod          = 14;
input double InpAdxMin             = 20.0;         // trend exists above this
input double InpMaxSpreadPct       = 1.0;          // normalize EMA spread strength (pct)

// ---- Signal API
input bool   InpSignalEnable       = true;
input string InpSignalApiUrl       = "https://1kpips.com/api/signals/set";
input string InpSignalApiKey       = KUROSAWA_API_KEY;
input string InpEaId               = "ea-signal-d1-dailytrend";
input string InpEaName             = "D1_DailyTrend_Signal";
input string InpEaVersion          = "0.2.0";
input string InpStrategy           = "DailyTrend";
input int    InpHttpTimeoutMs      = 5000;

// Publish each symbol's LAST CLOSED D1 bar once on attach, instead of
// waiting for the next rollover. Sends the genuine values of that closed
// bar - use it to verify the pipeline, or to backfill after downtime.
input bool   InpSendOnInit         = false;

input int    InpTimerSeconds       = 5;    // poll interval
input int    InpMaxSendsPerCycle   = 3;    // spread the rollover burst across cycles

//============ State: parallel arrays, one slot per symbol ============//
string   g_sym[];
int      g_hEmaFast[];
int      g_hEmaSlow[];
int      g_hAdx[];

datetime g_lastBar[];        // last closed bar already published
bool     g_pendingInit[];    // on-attach publish still owed
int      g_initTries[];
int      g_barTries[];       // retries for the current unpublished bar

string   g_dir[];
int      g_strength[];
double   g_adx[];
string   g_send[];

int      g_count = 0;

//+------------------------------------------------------------------+
// Symbol list
//+------------------------------------------------------------------+
int ParseSymbols(const string csv, string &out[])
{
   string parts[];
   const int n = StringSplit(csv, ',', parts);
   ArrayResize(out, 0);

   for(int i = 0; i < n; ++i)
   {
      string s = parts[i];
      StringTrimLeft(s);
      StringTrimRight(s);
      if(StringLen(s) == 0) continue;

      const int k = ArraySize(out);
      ArrayResize(out, k + 1);
      out[k] = s;
   }
   return ArraySize(out);
}

//+------------------------------------------------------------------+
// Data access (per symbol)
//| (JsonEscape / TimeToIsoUtc / Clamp01 come from                    |
//|  ../Helpers/KurosawaSignalPublisher.mqh)                          |
//+------------------------------------------------------------------+
datetime GetBarTime(const string sym, const int shift)
{
   datetime t[];
   ArraySetAsSeries(t, true);
   if(CopyTime(sym, InpTf, shift, 1, t) != 1) return 0;
   return t[0];
}

bool GetCloseAtShift(const string sym, const int shift, double &val)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyClose(sym, InpTf, shift, 1, buf) != 1) return false;
   val = buf[0];
   return true;
}

bool GetBufAtShift(const int handle, const int bufferIndex, const int shift, double &val)
{
   if(handle == INVALID_HANDLE) return false;

   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, bufferIndex, shift, 1, buf) != 1) return false;
   val = buf[0];
   return true;
}

// Handles are created lazily: a symbol not yet in Market Watch, or whose
// history has not downloaded, fails here and is simply retried next cycle.
bool EnsureHandles(const int i)
{
   if(g_hEmaFast[i] != INVALID_HANDLE &&
      g_hEmaSlow[i] != INVALID_HANDLE &&
      g_hAdx[i]     != INVALID_HANDLE)
      return true;

   const string sym = g_sym[i];

   if(!SymbolInfoInteger(sym, SYMBOL_SELECT))
      SymbolSelect(sym, true);

   if(g_hEmaFast[i] == INVALID_HANDLE)
      g_hEmaFast[i] = iMA(sym, InpTf, InpEmaFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_hEmaSlow[i] == INVALID_HANDLE)
      g_hEmaSlow[i] = iMA(sym, InpTf, InpEmaSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_hAdx[i] == INVALID_HANDLE)
      g_hAdx[i] = iADX(sym, InpTf, InpAdxPeriod);

   return (g_hEmaFast[i] != INVALID_HANDLE &&
           g_hEmaSlow[i] != INVALID_HANDLE &&
           g_hAdx[i]     != INVALID_HANDLE);
}

//+------------------------------------------------------------------+
// Compute + publish one symbol's last closed D1 bar
//| (JSON build + WebRequest + retry live in Signal_Post(),           |
//|  ../Helpers/KurosawaSignalPublisher.mqh)                          |
//+------------------------------------------------------------------+
bool ComputeAndSend(const int i)
{
   const string sym = g_sym[i];

   double close1=0.0;
   double emaFast1=0.0, emaSlow1=0.0;
   double adx1=0.0;

   if(!GetCloseAtShift(sym, 1, close1)) return false;
   if(!GetBufAtShift(g_hEmaFast[i], 0, 1, emaFast1)) return false;
   if(!GetBufAtShift(g_hEmaSlow[i], 0, 1, emaSlow1)) return false;

   // iADX buffer 0 is ADX in MQL5
   if(!GetBufAtShift(g_hAdx[i], 0, 1, adx1)) return false;

   string direction = "FLAT";

   bool trendOk = (adx1 >= InpAdxMin);
   if(trendOk)
   {
      if(emaFast1 > emaSlow1 && close1 >= emaFast1) direction = "LONG";
      else if(emaFast1 < emaSlow1 && close1 <= emaFast1) direction = "SHORT";
      else direction = "FLAT";
   }

   // Strength components
   double spreadPct = 0.0;
   if(emaSlow1 != 0.0) spreadPct = (MathAbs(emaFast1 - emaSlow1) / emaSlow1) * 100.0;

   double adxScore   = Clamp01((adx1 - InpAdxMin) / 20.0);             // 0..1 over (min..min+20)
   double spreadScore= Clamp01(spreadPct / InpMaxSpreadPct);           // 0..1
   double posScore   = 0.0;

   if(direction == "LONG" && emaFast1 != 0.0)  posScore = Clamp01((close1 - emaFast1) / emaFast1 * 100.0 / 0.5);
   if(direction == "SHORT" && emaFast1 != 0.0) posScore = Clamp01((emaFast1 - close1) / emaFast1 * 100.0 / 0.5);

   double strengthRaw = 40.0;
   if(direction != "FLAT")
      strengthRaw = 50.0 + adxScore * 25.0 + spreadScore * 20.0 + posScore * 10.0;
   else
      strengthRaw = MathMin(45.0, 40.0 + adxScore * 10.0);

   int strength = (int)MathRound(MathMax(0.0, MathMin(100.0, strengthRaw)));

   double score = 0.0;
   if(direction == "LONG")  score = +1.0 * (strength / 100.0);
   if(direction == "SHORT") score = -1.0 * (strength / 100.0);

   datetime barTime = GetBarTime(sym, 1);
   if(barTime == 0) return false;

   MqlDateTime dt;
   TimeToStruct(barTime, dt);
   string day = StringFormat("%04d-%02d-%02d", dt.year, dt.mon, dt.day);
   string externalId = sym + "|D1|" + InpStrategy + "|" + day;

   string desc = StringFormat(
      "close=%.5f emaFast(%d)=%.5f emaSlow(%d)=%.5f spreadPct=%.3f adx(%d)=%.2f adxMin=%.2f",
      close1, InpEmaFastPeriod, emaFast1, InpEmaSlowPeriod, emaSlow1, spreadPct, InpAdxPeriod, adx1, InpAdxMin
   );

   g_dir[i]      = direction;
   g_strength[i] = strength;
   g_adx[i]      = adx1;

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
   p.symbol        = sym;
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
   g_send[i] = (sent ? "OK" : "FAIL");
   return sent;
}

//+------------------------------------------------------------------+
void ShowStatus()
{
   string s = "D1 Signal EA (multi-symbol)\n";
   s += "Strategy: " + InpStrategy + "   Symbols: " + (string)g_count + "\n";
   s += "Pair      Dir     Str   Send\n";

   for(int i = 0; i < g_count; ++i)
   {
      s += StringFormat("%-9s %-7s %-5d %s\n",
                        g_sym[i], g_dir[i], g_strength[i], g_send[i]);
   }
   Comment(s);
}

//+------------------------------------------------------------------+
// One scan pass over every symbol. Called from OnInit, OnTimer, OnTick.
//+------------------------------------------------------------------+
void Poll()
{
   int sentThisCycle = 0;

   for(int i = 0; i < g_count; ++i)
   {
      if(!EnsureHandles(i))
      {
         g_send[i] = "no handle";
         continue;
      }

      const datetime t1 = GetBarTime(g_sym[i], 1);
      if(t1 == 0)
      {
         g_send[i] = "no history";
         continue;
      }

      // First successful read of this symbol: adopt the current bar as
      // already-seen, so startup is not mistaken for a fresh close.
      if(g_lastBar[i] == 0)
      {
         g_lastBar[i] = t1;
         if(g_send[i] == "no handle" || g_send[i] == "no history")
            g_send[i] = "not sent yet";
      }

      const bool isNewBar = (t1 != g_lastBar[i]);
      const bool wantInit = g_pendingInit[i];

      if(!isNewBar && !wantInit) continue;

      // Spread the rollover burst so one timer callback never blocks long.
      if(sentThisCycle >= InpMaxSendsPerCycle) continue;

      const bool ok = ComputeAndSend(i);
      sentThisCycle++;

      if(isNewBar)
      {
         g_barTries[i]++;
         if(ok)
         {
            // Advance ONLY on success, so a failed publish is retried
            // instead of being silently lost for the day.
            g_lastBar[i]  = t1;
            g_barTries[i] = 0;
            Print("Published new D1 bar. sym=", g_sym[i], " dir=", g_dir[i],
                  " str=", g_strength[i]);
         }
         else if(g_barTries[i] >= 12)
         {
            g_lastBar[i]  = t1;   // give up on this bar rather than hammer the API
            g_barTries[i] = 0;
            Print("Publish FAILED after retries, skipping bar. sym=", g_sym[i]);
         }
      }

      if(wantInit)
      {
         g_initTries[i]++;
         if(ok || g_initTries[i] >= 10)
         {
            g_pendingInit[i] = false;
            Print("On-attach publish finished. sym=", g_sym[i], " ok=", ok,
                  " tries=", g_initTries[i]);
         }
      }
   }

   ShowStatus();
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_count = ParseSymbols(InpSymbols, g_sym);
   if(g_count <= 0)
   {
      Print("No symbols parsed from InpSymbols.");
      return INIT_FAILED;
   }

   ArrayResize(g_hEmaFast,    g_count);
   ArrayResize(g_hEmaSlow,    g_count);
   ArrayResize(g_hAdx,        g_count);
   ArrayResize(g_lastBar,     g_count);
   ArrayResize(g_pendingInit, g_count);
   ArrayResize(g_initTries,   g_count);
   ArrayResize(g_barTries,    g_count);
   ArrayResize(g_dir,         g_count);
   ArrayResize(g_strength,    g_count);
   ArrayResize(g_adx,         g_count);
   ArrayResize(g_send,        g_count);

   for(int i = 0; i < g_count; ++i)
   {
      g_hEmaFast[i]    = INVALID_HANDLE;
      g_hEmaSlow[i]    = INVALID_HANDLE;
      g_hAdx[i]        = INVALID_HANDLE;
      g_lastBar[i]     = 0;
      g_pendingInit[i] = InpSendOnInit;
      g_initTries[i]   = 0;
      g_barTries[i]    = 0;
      g_dir[i]         = "N/A";
      g_strength[i]    = 0;
      g_adx[i]         = 0.0;
      g_send[i]        = "not sent yet";

      // Pull the symbol into Market Watch so history starts downloading.
      SymbolSelect(g_sym[i], true);
   }

   EventSetTimer(MathMax(1, InpTimerSeconds));

   Print("Init OK. strategy=", InpStrategy, " symbols=", g_count,
         " sendOnInit=", (InpSendOnInit ? "true" : "false"),
         " url=", InpSignalApiUrl);

   Poll();   // act immediately, do not wait for a tick or the first timer
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();

   for(int i = 0; i < g_count; ++i)
   {
      if(g_hEmaFast[i] != INVALID_HANDLE) IndicatorRelease(g_hEmaFast[i]);
      if(g_hEmaSlow[i] != INVALID_HANDLE) IndicatorRelease(g_hEmaSlow[i]);
      if(g_hAdx[i]     != INVALID_HANDLE) IndicatorRelease(g_hAdx[i]);
   }
   Comment("");
}

void OnTick()  { Poll(); }
void OnTimer() { Poll(); }
