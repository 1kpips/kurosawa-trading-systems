//+------------------------------------------------------------------+
//| File: Helpers/KurosawaSignalPublisher.mqh                        |
//| Type: Include Library (shared signal-publishing utilities)       |
//| Ver : 0.2.0 (backfill after downtime)                            |
//|                                                                  |
//| Purpose                                                          |
//| - ONE place for the D1 signal EAs to build + POST a signal to    |
//|   the 1kpips signals API, instead of each EA copy-pasting the    |
//|   JSON builder, the HTTP call, and the small helpers.            |
//| - Adds a bounded retry on transient WebRequest failures.         |
//|                                                                  |
//| Self-contained: uses only MQL5 built-ins.                        |
//|                                                                  |
//| NOTE: the WebRequest URL must be allowlisted in MT5:             |
//|   Tools -> Options -> Expert Advisors -> Allow WebRequest.        |
//+------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_SIGNAL_PUBLISHER_MQH
#define KUROSAWA_SIGNAL_PUBLISHER_MQH

// Publisher config (built once per EA from its inputs).
struct SignalPubConfig
{
   bool   enable;
   string apiUrl;
   string apiKey;
   int    httpTimeoutMs;
   string eaId;
   string eaName;
   string eaVersion;
   int    maxRetries;   // extra attempts on transient WebRequest failure
};

// One signal record.
struct SignalPayload
{
   string   symbol;
   string   timeframe;
   string   strategy;
   string   direction;    // LONG / SHORT / FLAT
   int      strength;     // 0..100
   double   score;        // -1..+1
   datetime signalTimeUtc;
   string   description;
   string   externalId;
};

// ---- small shared helpers (same names as the old per-EA copies, so the
//      signal EAs can delete their locals without touching call sites) -----

string JsonEscape(const string s)
{
   string x = s;
   StringReplace(x, "\\", "\\\\");
   StringReplace(x, "\"", "\\\"");
   StringReplace(x, "\r", "\\r");
   StringReplace(x, "\n", "\\n");
   StringReplace(x, "\t", "\\t");
   return x;
}

string TimeToIsoUtc(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return StringFormat("%04d-%02d-%02dT%02d:%02d:%02dZ",
                       dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec);
}

// Bar times from iTime/CopyTime are BROKER SERVER time, not UTC. Formatting one
// with a trailing "Z" without converting publishes a timestamp that is wrong by
// the broker's offset - and since these are D1 bars, on a UTC+2/+3 broker the
// 00:00 bar open falls on the PREVIOUS UTC calendar day, so the date is wrong
// too. Always pass a bar time through here before putting it in a payload.
datetime BrokerToUtc(const datetime tBroker)
{
   return tBroker + (TimeGMT() - TimeTradeServer());
}

double Clamp01(const double x)
{
   if(x < 0.0) return 0.0;
   if(x > 1.0) return 1.0;
   return x;
}

// ---- shared signal POST (JSON build + WebRequest + bounded retry) --------

// Set by Signal_BackfillStep around its sends, so a reading published late
// says so instead of passing for one published at the rollover.
bool g_signalBackfilling = false;

bool Signal_Post(const SignalPubConfig &cfg, const SignalPayload &p)
{
   if(!cfg.enable)
      return true;

   string desc = p.description;
   if(g_signalBackfilling)
      desc += " | published late: backfilled after MT5 downtime";

   const string body =
      "{"
      "\"eaId\":\"" + JsonEscape(cfg.eaId) + "\","
      "\"eaName\":\"" + JsonEscape(cfg.eaName) + "\","
      "\"eaVersion\":\"" + JsonEscape(cfg.eaVersion) + "\","
      "\"symbol\":\"" + JsonEscape(p.symbol) + "\","
      "\"timeframe\":\"" + JsonEscape(p.timeframe) + "\","
      "\"strategy\":\"" + JsonEscape(p.strategy) + "\","
      "\"direction\":\"" + JsonEscape(p.direction) + "\","
      "\"strength\":" + (string)p.strength + ","
      "\"score\":" + DoubleToString(p.score, 6) + ","
      "\"signalTimeUtc\":\"" + TimeToIsoUtc(p.signalTimeUtc) + "\","
      "\"description\":\"" + JsonEscape(desc) + "\","
      "\"logicVersion\":\"" + JsonEscape(cfg.eaVersion) + "\","
      "\"externalId\":\"" + JsonEscape(p.externalId) + "\""
      "}";

   uchar data[];
   int len = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   if(len > 0) ArrayResize(data, len - 1);

   const string headers =
      "Content-Type: application/json\r\n" +
      "X-API-Key: " + cfg.apiKey + "\r\n";

   const int attempts = 1 + (cfg.maxRetries > 0 ? cfg.maxRetries : 0);

   for(int attempt = 0; attempt < attempts; ++attempt)
   {
      char   result[];
      string result_headers;

      ResetLastError();
      const int status = WebRequest("POST", cfg.apiUrl, headers, cfg.httpTimeoutMs,
                                    data, result, result_headers);

      if(status >= 200 && status < 300)
         return true;

      if(status == -1)
         Print("Signal POST failed. err=", GetLastError(), " url=", cfg.apiUrl,
               " attempt=", (attempt + 1), "/", attempts);
      else
      {
         const string resp = CharArrayToString(result, 0, -1, CP_UTF8);
         Print("Signal POST non-2xx. status=", status, " resp=", resp,
               " attempt=", (attempt + 1), "/", attempts);
      }

      if(attempt + 1 < attempts)
         Sleep(300); // brief backoff before retry
   }

   return false;
}

// ---- backfill after downtime ---------------------------------------------
//
// The analyzers publish on the bar ROLLOVER, and on attach they adopt the
// newest closed bar as already seen. So a D1 close that happens while MT5 is
// shut is never published - and a Friday bar only becomes shift 1 when
// Monday's bar opens, so a terminal that is off over the weekend loses Friday
// too. 2026-10-10 the terminal stopped and came back on 10-13: the Friday and
// Monday readings of all 30 series were lost for good.
//
// On attach, read the site's recent history for the series and publish every
// closed bar in the window it has no reading for, oldest first. Never resend a
// bar the site already holds: that would stamp today's logic version over a
// reading an older version made.

// Bar times compare to what the API stores, which is BrokerToUtc of the bar
// open. Half a day of slack absorbs a DST change in the broker offset since
// the bar was published, without matching the neighbouring bar.
#define SIGNAL_BACKFILL_SLACK_SEC (12 * 3600)

// The history endpoint sits next to /set.
string Signal_HistoryUrl(const string apiUrl)
{
   string base = apiUrl;
   const int pos = StringFind(base, "/set");
   if(pos > 0) base = StringSubstr(base, 0, pos);
   return base + "/history";
}

// "2026-10-12T21:00:00+00:00" -> UTC datetime, or 0 if it is not a UTC stamp.
datetime Signal_ParseUtcStamp(const string stamp)
{
   const string offset = StringSubstr(stamp, 19);
   if(StringFind(offset, "+00:00") != 0 && StringFind(offset, "Z") != 0)
      return 0;

   string mql = StringSubstr(stamp, 0, 19);
   StringReplace(mql, "-", ".");
   StringReplace(mql, "T", " ");
   return StringToTime(mql);
}

// The UTC times of the newest `take` readings the site holds for one series;
// empty when it holds none. false means the answer cannot be trusted - network
// or parse failure - and the caller must not backfill on it.
bool Signal_FetchPublishedUtc(const SignalPubConfig &cfg, const string symbol,
                              const string timeframe, const string strategy,
                              const int take, datetime &out[])
{
   ArrayResize(out, 0);
   const string url = Signal_HistoryUrl(cfg.apiUrl) +
                      "?symbol=" + symbol + "&timeframe=" + timeframe +
                      "&strategy=" + strategy + "&take=" + (string)take;

   char   data[];
   char   result[];
   string resultHeaders;

   ResetLastError();
   const int status = WebRequest("GET", url, "", cfg.httpTimeoutMs, data, result, resultHeaders);
   if(status < 200 || status >= 300)
   {
      Print("Signal history lookup failed. status=", status, " err=", GetLastError(), " url=", url);
      return false;
   }

   // {"ok":true,"count":2,"items":[{..."signalTimeUtc":"2026-10-12T21:00:00+00:00",...},...]}
   const string resp = CharArrayToString(result, 0, -1, CP_UTF8);
   if(StringFind(resp, "\"ok\":true") < 0)
   {
      Print("Signal history lookup: unexpected response. url=", url);
      return false;
   }

   const string key = "\"signalTimeUtc\":\"";
   int at = StringFind(resp, key);
   while(at >= 0)
   {
      const string stamp = StringSubstr(resp, at + StringLen(key), 25);
      const datetime t = Signal_ParseUtcStamp(stamp);
      if(t == 0)
      {
         Print("Signal history lookup: unparseable time. stamp=", stamp, " url=", url);
         return false;
      }
      const int n = ArraySize(out);
      ArrayResize(out, n + 1);
      out[n] = t;
      at = StringFind(resp, key, at + StringLen(key));
   }
   return true;
}

bool Signal_IsPublished(const datetime barUtc, const datetime &published[])
{
   for(int k = 0; k < ArraySize(published); ++k)
      if(MathAbs((long)(barUtc - published[k])) < SIGNAL_BACKFILL_SLACK_SEC)
         return true;
   return false;
}

// Closed bars (shift 1..maxBars) the site has no reading for, oldest first,
// as broker open times. Only bars inside the span the history covers count: a
// bar older than the oldest reading returned may be published and simply not
// listed, and a series the site has never held is not backfilled at all - a
// new analyzer starts at its next close, not with a retroactive history.
int Signal_MissedBars(const string sym, const ENUM_TIMEFRAMES tf, const datetime &published[],
                      const int maxBars, datetime &missed[])
{
   ArrayResize(missed, 0);
   const int n = ArraySize(published);
   if(n == 0) return 0;

   datetime oldestListed = published[0];
   for(int k = 1; k < n; ++k)
      if(published[k] < oldestListed) oldestListed = published[k];

   for(int shift = maxBars; shift >= 1; --shift)
   {
      datetime t[];
      if(CopyTime(sym, tf, shift, 1, t) != 1) continue;

      const datetime barUtc = BrokerToUtc(t[0]);
      if(barUtc < oldestListed - SIGNAL_BACKFILL_SLACK_SEC) continue;
      if(Signal_IsPublished(barUtc, published)) continue;

      const int m = ArraySize(missed);
      ArrayResize(missed, m + 1);
      missed[m] = t[0];
   }
   return ArraySize(missed);
}

// Publishes one closed bar of one series. slot is the EA's own index for a
// multi-symbol scanner; single-symbol analyzers ignore it.
typedef bool (*SignalSendAtShift)(const int slot, const int shift);

struct SignalBackfill
{
   bool     pending;    // still owed on this attach
   bool     planned;    // the site's history has been read
   datetime missed[];   // broker open times still to publish, oldest first
   int      next;       // index into missed
   int      sent;
   int      tries;      // consecutive failures of the current step
   datetime retryAt;    // local time before which a failed step is not retried
};

void Signal_BackfillInit(SignalBackfill &b, const bool enabled)
{
   b.pending = enabled;
   b.planned = false;
   ArrayResize(b.missed, 0);
   b.next    = 0;
   b.sent    = 0;
   b.tries   = 0;
   b.retryAt = 0;
}

void Signal_BackfillFinish(SignalBackfill &b, const string sym, const string strategy,
                           const string why)
{
   b.pending = false;
   Print("Backfill finished. sym=", sym, " strategy=", strategy,
         " sent=", b.sent, "/", ArraySize(b.missed), " (", why, ")");
}

// Advances the backfill by at most one HTTP call. Returns true when it made
// one, so a scanner can count it against its per-cycle budget. Bars are kept
// as open times, not shifts, so a rollover mid-backfill cannot make it
// publish the wrong bar.
bool Signal_BackfillStep(SignalBackfill &b, const SignalPubConfig &cfg,
                         const string sym, const ENUM_TIMEFRAMES tf, const string tfName,
                         const string strategy, const int maxBars,
                         SignalSendAtShift send, const int slot)
{
   if(!b.pending) return false;
   if(!cfg.enable) { b.pending = false; return false; }

   // Poll runs on every tick as well as the timer: space retries by time,
   // or ten of them can burn out inside one second while indicators load.
   if(TimeLocal() < b.retryAt) return false;

   if(!b.planned)
   {
      // Twice the window: enough readings to span it even when it has holes.
      datetime published[];
      if(!Signal_FetchPublishedUtc(cfg, sym, tfName, strategy, 2 * maxBars + 5, published))
      {
         if(++b.tries >= 3) Signal_BackfillFinish(b, sym, strategy, "history lookup failed");
         b.retryAt = TimeLocal() + 5;
         return true;
      }

      b.planned = true;
      b.tries   = 0;
      if(Signal_MissedBars(sym, tf, published, maxBars, b.missed) == 0)
      {
         b.pending = false;   // up to date: the common case, not worth a log line
         return true;
      }

      Print("Backfill planned. sym=", sym, " strategy=", strategy,
            " missed=", ArraySize(b.missed), " from=", TimeToString(b.missed[0]));
      return true;
   }

   const int shift = iBarShift(sym, tf, b.missed[b.next], true);
   if(shift < 1)
   {
      Print("Backfill: bar not in history, skipping. sym=", sym, " strategy=", strategy,
            " bar=", TimeToString(b.missed[b.next]));
   }
   else
   {
      g_signalBackfilling = true;
      const bool ok = send(slot, shift);
      g_signalBackfilling = false;

      if(ok)
         b.sent++;
      else if(++b.tries < 10)
      {
         b.retryAt = TimeLocal() + 5;
         return true;   // indicator data may not be ready yet: retry shortly
      }
      else
         Print("Backfill FAILED for bar, skipping. sym=", sym, " strategy=", strategy,
               " bar=", TimeToString(b.missed[b.next]));
   }

   b.tries = 0;
   if(++b.next >= ArraySize(b.missed))
      Signal_BackfillFinish(b, sym, strategy, "done");
   return true;
}

#endif // KUROSAWA_SIGNAL_PUBLISHER_MQH
