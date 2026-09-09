//+------------------------------------------------------------------+
//| File: Helpers/KurosawaSignalPublisher.mqh                        |
//| Type: Include Library (shared signal-publishing utilities)       |
//| Ver : 0.1.0                                                      |
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

bool Signal_Post(const SignalPubConfig &cfg, const SignalPayload &p)
{
   if(!cfg.enable)
      return true;

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
      "\"description\":\"" + JsonEscape(p.description) + "\","
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

#endif // KUROSAWA_SIGNAL_PUBLISHER_MQH
