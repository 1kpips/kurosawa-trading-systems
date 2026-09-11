//+------------------------------------------------------------------+
//| File: KurosawaTrack.mqh                                          |
//| PRIVATE: contains API keys and WebRequest code. DO NOT COMMIT.   |
//|                                                                  |
//| Purpose                                                          |
//| - Centralize tracking (OPEN/CLOSE) HTTP POST to your ingest API  |
//| - Add local CSV reporting (per-trade close ledger)               |
//| - Track MFE/MAE using the EA's timeframe (caller passes tf)      |
//| - Provide unified Daily Summary counters for ALL EAs             |
//|                                                                  |
//| Integration (EA-side)                                            |
//| 1) Keep OnTradeTransaction wrapper:                              |
//|    Track_OnTradeTransaction(                                     |
//|       InpTrackEnable, trans, InpEaId, InpEaName, InpEaVersion,   |
//|       InpPresetVersion,                                          |
//|       InpMagic, InpTrackSendOpen,                                |
//|       g_lastOpenDealId, g_lastCloseDealId,                       |
//|       g_consecLosses, g_lastCloseTime,                           |
//|       (ENUM_TIMEFRAMES)_Period, _Symbol                          |
//|    );                                                            |
//| 2) OnTick new-bar (recommended):                                 |
//|    if(isNewBar) Track_OnNewBar(InpTrackEnable, InpMagic,         |
//|       _Symbol, (ENUM_TIMEFRAMES)_Period);                        |
//| 3) Daily summary counters (optional but recommended):            |
//|    - Add: KurosawaDailyDiag g_diag;                              |
//|    - Call: Kurosawa_DailyRollIfNeeded(InpEaName, _Symbol,        |
//|            (ENUM_TIMEFRAMES)_Period, g_diag, ymd);               |
//|    - Increment g_diag.block_* and g_diag.signals/trades/bars.    |
//|                                                                  |
//| Notes                                                            |
//| - WebRequest domain must be allowlisted in MT5 terminal options. |
//| - Local CSV files are written to FILE_COMMON:                    |
//|   Common\\Files\\KurosawaReports\\                               |
//+------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_TRACK_MQH
#define KUROSAWA_TRACK_MQH

// The real key lives in the git-ignored KurosawaSecrets.mqh, shared with the
// signal EAs. Do not paste a literal key here: this file used to carry the
// placeholder "1kpips-secret-key", which the ingest API rejects, so every
// OPEN/CLOSE post failed authentication and no trade was ever recorded.
#include "KurosawaSecrets.mqh"

// PositionTicketByMagic() - the hedging-safe position lookup used by
// Track_OnNewBar and the OPEN handler. Included explicitly rather than relying
// on the KurosawaHelpers.mqh umbrella pulling it in first: the engines happen to
// include ExecUtils ahead of this file, but MetaEditor's "Compile All" builds
// every header standalone, where that ordering does not exist. Both headers are
// include-guarded, so pulling it in twice is free.
#include "KurosawaExecUtils.mqh"

// ------------------------------------------------------------------
// Endpoint
// ------------------------------------------------------------------
static string TRACK_API_KEY   = KUROSAWA_API_KEY;
static string TRACK_API_URL   = "https://1kpips.com/api/track/record";
static int    HTTP_TIMEOUT_MS = 5000;

// ------------------------------------------------------------------
// Behavior toggles
// ------------------------------------------------------------------
static bool   DEBUG_LOG_PAYLOAD_ON_ERROR = true;

// Local reporting
static bool   REPORT_ENABLE       = true;
static bool   REPORT_WRITE_TRADES = true;   // per-trade close ledger
static string REPORT_DIR          = "KurosawaReports";

// History select window (avoid missing entry for older positions)
static int    HISTORY_WINDOW_SEC  = 86400 * 14;

// JST offset used only for daily boundary convenience (optional)
static int    JST_UTC_OFFSET      = 9;

// ------------------------------------------------------------------
// Unified daily diagnostics (shared across all EAs)
// ------------------------------------------------------------------
struct DailyDiag
  {
   int               ymd;

   int               bars;
   int               signals;
   int               trades;

   int               block_session;
   int               block_spread;
   int               block_adx;
   int               block_atr;
   int               block_cooldown;
   int               block_haspos;
   int               block_loss;
   int               block_maxday;
   int               block_maxtrades;
   int               block_nosignal;   // no entry signal on this bar
   int               block_ambig;      // both buy and sell true (conflict)
   int               block_indfail;    // indicators/data not available (CopyBuffer, handles, SymbolInfo)
   int               block_wick;       // wick/edge quality filter rejected

   int               block_stops;
   int               block_orderfail;
   int               block_nobias;    // EMA fast == slow (no trend)
   int               block_portfolio; // account-level cap refused the entry (KurosawaPortfolio.mqh)


   void              Reset(const int newYmd)
     {
      ymd = newYmd;

      bars = 0;
      signals = 0;
      trades = 0;

      block_session = 0;
      block_spread = 0;
      block_adx = 0;
      block_atr = 0;
      block_cooldown = 0;
      block_haspos = 0;
      block_loss = 0;
      block_maxday = 0;
      block_maxtrades = 0;
      block_nosignal = 0;
      block_ambig = 0;
      block_indfail = 0;
      block_portfolio = 0;
      block_wick = 0;

      block_stops = 0;
      block_orderfail = 0;
      block_nobias = 0;
     }
  };

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
// True JST calendar day, broker-independent.
// NOTE: live engines now roll the day via KurosawaTime's TradingDayYmd()
// (unified UTC clock). This is kept for legacy/archived callers; it uses
// TimeGMT() (real UTC) + JST offset, NOT TimeCurrent(), so it no longer
// depends on the broker's server timezone.
int NowYmdJst()
  {
   datetime t = TimeGMT() + JST_UTC_OFFSET * 3600;
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.year * 10000 + dt.mon * 100 + dt.day;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string TrackTfToString(const ENUM_TIMEFRAMES tf)
  {
   if(tf == PERIOD_M1)
      return "M1";
   if(tf == PERIOD_M2)
      return "M2";
   if(tf == PERIOD_M3)
      return "M3";
   if(tf == PERIOD_M4)
      return "M4";
   if(tf == PERIOD_M5)
      return "M5";
   if(tf == PERIOD_M6)
      return "M6";
   if(tf == PERIOD_M10)
      return "M10";
   if(tf == PERIOD_M12)
      return "M12";
   if(tf == PERIOD_M15)
      return "M15";
   if(tf == PERIOD_M20)
      return "M20";
   if(tf == PERIOD_M30)
      return "M30";
   if(tf == PERIOD_H1)
      return "H1";
   if(tf == PERIOD_H2)
      return "H2";
   if(tf == PERIOD_H3)
      return "H3";
   if(tf == PERIOD_H4)
      return "H4";
   if(tf == PERIOD_H6)
      return "H6";
   if(tf == PERIOD_H8)
      return "H8";
   if(tf == PERIOD_H12)
      return "H12";
   if(tf == PERIOD_D1)
      return "D1";
   if(tf == PERIOD_W1)
      return "W1";
   if(tf == PERIOD_MN1)
      return "MN1";
   return "TF";
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void PrintDailySummary(
   const string eaName,
   const string symbol,
   const ENUM_TIMEFRAMES tf,
   const DailyDiag& d
)
  {
   PrintFormat(
      "%s (%s,%s) Daily Summary: ymd=%d | Bars=%d Signals=%d Trades=%d | Blocks session=%d spread=%d adx=%d atr=%d cooldown=%d haspos=%d loss=%d maxday=%d maxtrades=%d nosignal=%d ambig=%d indfail=%d wick=%d stops=%d orderfail=%d nobias=%d portfolio=%d",
      eaName, symbol, TrackTfToString(tf),
      d.ymd,
      d.bars, d.signals, d.trades,
      d.block_session,
      d.block_spread,
      d.block_adx,
      d.block_atr,
      d.block_cooldown,
      d.block_haspos,
      d.block_loss,
      d.block_maxday,
      d.block_maxtrades,
      d.block_nosignal,
      d.block_ambig,
      d.block_indfail,
      d.block_wick,
      d.block_stops,
      d.block_orderfail,
      d.block_nobias,
      d.block_portfolio
   );
  }

// Call each tick. When ymd changes it prints yesterday and resets.
void DailyRollIfNeeded(
   const string eaName,
   const string symbol,
   const ENUM_TIMEFRAMES tf,
   DailyDiag& d,
   const int currentYmd
)
  {
   if(d.ymd == 0)
     {
      d.Reset(currentYmd);
      return;
     }

   if(currentYmd == d.ymd)
      return;

   PrintDailySummary(eaName, symbol, tf, d);
   d.Reset(currentYmd);
  }

// ------------------------------------------------------------------
// Utils (event id, digits, pip conversion)
// ------------------------------------------------------------------
string TrackBuildEventId(const ulong dealId, const long dealEntry)
  {
   string suffix = "UNK";
   if(dealEntry == DEAL_ENTRY_IN)
      suffix = "IN";
   else
      if(dealEntry == DEAL_ENTRY_OUT)
         suffix = "OUT";
      else
         if(dealEntry == DEAL_ENTRY_OUT_BY)
            suffix = "OUT_BY";
         else
            if(dealEntry == DEAL_ENTRY_INOUT)
               suffix = "INOUT";
   return (string)dealId + "-" + suffix;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int TrackDigits(const string symbol)
  {
   return (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double TrackPoint(const string symbol)
  {
   const double pt = SymbolInfoDouble(symbol, SYMBOL_POINT);
   return (pt > 0.0) ? pt : _Point;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double TrackPips(const string symbol, const double priceDiff)
  {
// Convert price diff -> points (for that symbol) -> pips convention
   const int digits = TrackDigits(symbol);
   const double pt = TrackPoint(symbol);
   const double points = priceDiff / pt;

// Common convention:
// - 5-digit (EURUSD 1.23456): 10 points = 1 pip
// - 3-digit (USDJPY 158.123): 10 points = 1 pip
   if(digits == 5 || digits == 3)
      return points / 10.0;
   return points;
  }

// ------------------------------------------------------------------
// Local CSV (FILE_COMMON)
// ------------------------------------------------------------------
string TrackTradesCsvPath(const string eaName, const string symbol)
  {
   return REPORT_DIR + "\\trades_" + eaName + "_" + symbol + ".csv";
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool EnsureCsvHeader(const string path, const string headerLine)
  {
   const bool exists = FileIsExist(path, FILE_COMMON);

   int fh = FileOpen(path, FILE_WRITE|FILE_READ|FILE_TXT|FILE_COMMON);
   if(fh == INVALID_HANDLE)
     {
      Print("TRACK_REPORT: FileOpen failed. err=", GetLastError(), " path=", path);
      return false;
     }

   if(!exists)
     {
      FileSeek(fh, 0, SEEK_SET);
      FileWriteString(fh, headerLine + "\r\n");
     }

   FileClose(fh);
   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool AppendCsvLine(const string path, const string line)
  {
   int fh = FileOpen(path, FILE_WRITE|FILE_READ|FILE_TXT|FILE_COMMON);
   if(fh == INVALID_HANDLE)
     {
      Print("TRACK_REPORT: FileOpen failed. err=", GetLastError(), " path=", path);
      return false;
     }

   FileSeek(fh, 0, SEEK_END);
   FileWriteString(fh, line + "\r\n");
   FileClose(fh);
   return true;
  }

// ------------------------------------------------------------------
// Open-trade snapshot + excursion tracking (per position_id)
// - Updated by Track_OnNewBar() using caller-supplied tf
// ------------------------------------------------------------------
struct TrackOpenState
  {
   long              pos_id;
   int               magic;
   string            symbol;
   ENUM_TIMEFRAMES   tf;

   datetime          time_open;
   double            entry_price;
   double            lot;
   string            side;              // "BUY"/"SELL" (POSITION direction, NOT deal type)

   double            sl;
   double            tp;

   // excursion tracking
   double            max_high;
   double            min_low;

   // bar tracking
   datetime          last_bar_time;
   int               bars_held;

   bool              active;
  };

static TrackOpenState g_state[300];
static int            g_state_n = 0;

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int TrackFindStateIdx(const long pos_id)
  {
   for(int i=0;i<g_state_n;i++)
      if(g_state[i].pos_id == pos_id)
         return i;
   return -1;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void TrackUpsertState(const TrackOpenState &s)
  {
   const int idx = TrackFindStateIdx(s.pos_id);
   if(idx >= 0)
     {
      g_state[idx] = s;
      return;
     }

   if(g_state_n < 300)
      g_state[g_state_n++] = s;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool TrackPopState(const long pos_id, TrackOpenState &out)
  {
   const int idx = TrackFindStateIdx(pos_id);
   if(idx < 0)
      return false;

   out = g_state[idx];
   g_state[idx] = g_state[g_state_n-1];
   g_state_n--;
   return true;
  }

// ------------------------------------------------------------------
// API sending
// ------------------------------------------------------------------
bool TrackSendRecord(
   const bool   enable,

   const string apiUrl,
   const int    timeoutMs,
   const string apiKey,

   const string eaId,
   const string eaName,
   const string eaVersion,
   const string presetVersion,

   const string eventType,    // "OPEN" / "CLOSE"
   const string eventId,      // stable/idempotent

   const string symbol,
   const string side,         // "BUY" / "SELL" (position direction)
   const double volume,
   const double price,
   const double profit,

   const string currency,
   const int    digits,

   const string debugTag = ""
)
  {
   if(!enable)
      return false;

   if(StringLen(apiUrl) == 0)
     {
      Print("TrackSendRecord: apiUrl is empty.");
      return false;
     }
   if(StringLen(apiKey) == 0)
     {
      Print("TrackSendRecord: apiKey is empty.");
      return false;
     }
   if(StringLen(eaId) == 0)
     {
      Print("TrackSendRecord: eaId is empty.");
      return false;
     }
   if(StringLen(eventId) == 0)
     {
      Print("TrackSendRecord: eventId is empty.");
      return false;
     }
   if(StringLen(eventType) == 0)
     {
      Print("TrackSendRecord: eventType is empty.");
      return false;
     }

   int safeDigits = digits;
   if(safeDigits < 0)
      safeDigits = 0;
   if(safeDigits > 10)
      safeDigits = 10;

   const string body = StringFormat(
                          "{\"eaId\":\"%s\",\"eaName\":\"%s\",\"eaVersion\":\"%s\","
                          "\"presetVersion\":\"%s\","
                          "\"eventId\":\"%s\",\"eventType\":\"%s\","
                          "\"symbol\":\"%s\",\"side\":\"%s\","
                          "\"volume\":%s,\"price\":%s,\"profit\":%s,\"currency\":\"%s\"}",
                          eaId, eaName, eaVersion,
                          presetVersion,
                          eventId, eventType,
                          symbol, side,
                          DoubleToString(volume, 3),
                          DoubleToString(price, safeDigits),
                          DoubleToString(profit, 2),
                          currency
                       );

   uchar data[];
   int len = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   if(len > 0)
      ArrayResize(data, len - 1); // drop null terminator

   const string headers =
      "Content-Type: application/json\r\n"
      "X-API-Key: " + apiKey + "\r\n";

   char   res_data[];
   string res_headers;

   // Bounded retry. Records carry an eventId, so the server can dedupe a
   // resend -> safe to retry TRANSIENT failures (WebRequest -1 / HTTP 5xx,
   // which almost certainly never processed). A 4xx is a permanent client
   // rejection: do not retry it.
   const int maxAttempts = 3;   // 1 initial try + up to 2 retries

   for(int attempt = 1; attempt <= maxAttempts; ++attempt)
     {
      ArrayFree(res_data);
      ResetLastError();
      const int status = WebRequest("POST", apiUrl, headers, timeoutMs, data, res_data, res_headers);
      const int err = GetLastError();

      if(status >= 200 && status < 300)
         return true; // success

      const bool transient = (status == -1 || status >= 500);

      if(status == -1)
         Print("TrackSendRecord: WebRequest failed. err=", err, " url=", apiUrl,
               " tag=", debugTag, " attempt=", attempt, "/", maxAttempts);
      else
        {
         const string resp = (ArraySize(res_data) > 0) ? CharArrayToString(res_data) : "";

         // 401/403 means the key is wrong or revoked. That is a silent,
         // permanent outage of the whole track-record pipeline, so name it
         // loudly rather than letting it read as one more failed POST.
         if(status == 401 || status == 403)
            Print("TRACK AUTH FAILED (", status, ") - the ingest API rejected the API key. ",
                  "No trades are being recorded. Check KurosawaSecrets.mqh. tag=", debugTag);
         else
            Print("Track API Error. Status=", status, " tag=", debugTag, " resp=", resp,
                  " attempt=", attempt, "/", maxAttempts);
        }

      if(DEBUG_LOG_PAYLOAD_ON_ERROR)
        {
         string bodyShort = body;
         if(StringLen(bodyShort) > 900)
            bodyShort = StringSubstr(bodyShort, 0, 900) + "...";
         Print("Track API Payload: ", bodyShort);
        }

      if(!transient || attempt == maxAttempts)
         return false; // permanent failure, or out of retries

      Sleep(400); // brief backoff before retry
     }

   return false;
  }

// ------------------------------------------------------------------
// Ownership
// ------------------------------------------------------------------
bool TrackAcceptDealOwnership(const long dealMagic,
                              const string dealComment,
                              const int expectedMagic,
                              const string eaName)
  {
   if((int)dealMagic == expectedMagic)
      return true;

// Compatibility fallback only (close deals may not have comment)
   if(StringLen(eaName) > 0 && StringFind(dealComment, eaName) >= 0)
      return true;

   return false;
  }

// ------------------------------------------------------------------
// NEW BAR hook (Option A)
// Call from EA when a new bar is detected on the EA timeframe.
// Updates MFE/MAE tracking for the current open position (if any).
// ------------------------------------------------------------------
void Track_OnNewBar(
   const bool enable,
   const int expectedMagic,
   const string symbol,
   const ENUM_TIMEFRAMES tf
)
  {
   if(!enable)
      return;

// One position per EA instance. Select by MAGIC, not by symbol: this account is
// hedging, where PositionSelect(symbol) picks an arbitrary position for that
// symbol. With two EAs on one pair it would select the other EA's position, the
// magic check would reject it, and this EA's own position would never be
// sampled. PositionTicketByMagic leaves the matched position selected.
// (It comes from KurosawaExecUtils.mqh, included ahead of this file by the
// KurosawaHelpers.mqh umbrella.)
   if(PositionTicketByMagic(symbol, (long)expectedMagic) == 0)
      return;

   const long posId = (long)PositionGetInteger(POSITION_IDENTIFIER);
   const long type  = (long)PositionGetInteger(POSITION_TYPE);

   TrackOpenState s;
   const int idx = TrackFindStateIdx(posId);

   if(idx >= 0)
     {
      s = g_state[idx];
     }
   else
     {
      // Create state if missing (e.g., terminal restarted)
      s.pos_id = posId;
      s.magic = expectedMagic;
      s.symbol = symbol;
      s.tf = tf;

      s.time_open = (datetime)PositionGetInteger(POSITION_TIME);
      s.entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
      s.lot = PositionGetDouble(POSITION_VOLUME);

      // POSITION direction
      s.side = (type == POSITION_TYPE_SELL) ? "SELL" : "BUY";

      s.sl = PositionGetDouble(POSITION_SL);
      s.tp = PositionGetDouble(POSITION_TP);

      s.max_high = s.entry_price;
      s.min_low  = s.entry_price;

      s.last_bar_time = 0;
      s.bars_held = 0;
      s.active = true;
     }

// Update extremes using last CLOSED bar (shift=1) on caller timeframe
   const datetime bar0 = iTime(symbol, tf, 0);
   if(bar0 == 0)
      return;
   if(bar0 == s.last_bar_time)
      return; // not a new bar for this tf

   s.last_bar_time = bar0;
   s.bars_held++;

   const double hi1 = iHigh(symbol, tf, 1);
   const double lo1 = iLow(symbol, tf, 1);

   if(hi1 > 0.0 && hi1 > s.max_high)
      s.max_high = hi1;
   if(lo1 > 0.0 && (s.min_low == 0.0 || lo1 < s.min_low))
      s.min_low = lo1;

// Refresh SL/TP in case of modifications
   s.sl = PositionGetDouble(POSITION_SL);
   s.tp = PositionGetDouble(POSITION_TP);

   TrackUpsertState(s);
  }

// ------------------------------------------------------------------
// Per-trade close ledger (CSV)
// ------------------------------------------------------------------
void ReportTradeClose(
   const string eaId,
   const string eaName,
   const string eaVersion,
   const int    magic,
   const string symbol,
   const ENUM_TIMEFRAMES tf,
   const string side,          // POSITION direction ("BUY"/"SELL")
   const long   dealEntry,
   const ulong  dealId,
   const long   posId,
   const datetime tOpen,
   const datetime tClose,
   const double entryPrice,
   const double exitPrice,
   const double lot,
   const double sl,
   const double tp,
   const double maxHigh,
   const double minLow,
   const int    barsHeld,
   const double profitMoney
)
  {
   if(!REPORT_ENABLE || !REPORT_WRITE_TRADES)
      return;

   const string path = TrackTradesCsvPath(eaName, symbol);

   EnsureCsvHeader(path,
                   "ymd_open,time_open,ymd_close,time_close,"
                   "ea_id,ea_name,version,magic,symbol,tf,side,"
                   "pos_id,deal_id,deal_entry,lot,entry,exit,sl,tp,"
                   "max_high,min_low,mfe_pips,mae_pips,best_to_tp_pips,bars_held,hold_min,profit"
                  );

   const int digits = TrackDigits(symbol);
   const double holdMin = (double)(tClose - tOpen) / 60.0;

// MFE/MAE from extremes (based on POSITION direction)
   double mfePips = 0.0;
   double maePips = 0.0;
   double bestToTpPips = 0.0;

   if(side == "BUY")
     {
      mfePips = TrackPips(symbol, maxHigh - entryPrice);
      maePips = TrackPips(symbol, entryPrice - minLow);
      bestToTpPips = (tp > 0.0) ? TrackPips(symbol, tp - maxHigh) : 0.0;
     }
   else // SELL
     {
      mfePips = TrackPips(symbol, entryPrice - minLow);
      maePips = TrackPips(symbol, maxHigh - entryPrice);
      bestToTpPips = (tp > 0.0) ? TrackPips(symbol, minLow - tp) : 0.0;
     }

   const string line = StringFormat(
                          "%s,%s,%s,%s,%s,%s,%s,%d,%s,%s,%s,"
                          "%I64d,%I64u,%d,%s,%s,%s,%s,%s,"
                          "%s,%s,%.2f,%.2f,%.2f,%d,%.1f,%.2f",
                          TimeToString(tOpen, TIME_DATE),
                          TimeToString(tOpen, TIME_SECONDS),
                          TimeToString(tClose, TIME_DATE),
                          TimeToString(tClose, TIME_SECONDS),
                          eaId, eaName, eaVersion, magic, symbol, TrackTfToString(tf), side,
                          posId, dealId, (int)dealEntry,
                          DoubleToString(lot, 2),
                          DoubleToString(entryPrice, digits),
                          DoubleToString(exitPrice, digits),
                          DoubleToString(sl, digits),
                          DoubleToString(tp, digits),
                          DoubleToString(maxHigh, digits),
                          DoubleToString(minLow, digits),
                          mfePips, maePips, bestToTpPips,
                          barsHeld,
                          holdMin,
                          profitMoney
                       );

   AppendCsvLine(path, line);
  }

// Avoid sending request while testing.
bool Track_IsEnabled(bool enable)
  {
   if(MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION))
      return false;
   return enable;
  }

// ------------------------------------------------------------------
// Main transaction hook
// - Caller supplies tf + expectedSymbol for correctness
// - Correct "side" on CLOSE using stored open-state direction
// ------------------------------------------------------------------
void Track_OnTradeTransaction(
   const bool                 enable,
   const MqlTradeTransaction& trans,

   const string               eaId,
   const string               eaName,
   const string               eaVersion,
   const string               presetVersion,

   const int                  expectedMagic,
   const bool                 sendOpen,

   ulong&                     lastOpenDealId,
   ulong&                     lastCloseDealId,
   int&                       consecLosses,
   datetime&                  lastCloseTime,

   const ENUM_TIMEFRAMES      tf,
   const string               expectedSymbol
)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   // Reporting (HTTP POST + CSV ledger) is suppressed in the tester/optimizer
   // and by the caller's toggle. The loss-streak bookkeeping further down is
   // NOT gated on it: consecLosses feeds the risk guard, so it has to behave
   // identically in a backtest and live. Gating it here is what made every
   // optimization run trade through losing streaks that live would have halted.
   const bool reportingOn = Track_IsEnabled(enable);

   const datetime now = TimeCurrent();
   HistorySelect(now - HISTORY_WINDOW_SEC, now + 60);

   if(!HistoryDealSelect(trans.deal))
     {
      PrintFormat("TRACK: HistoryDealSelect failed. deal=%I64u err=%d", trans.deal, GetLastError());
      return;
     }

   const long   entry     = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   const long   dtype     = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   const long   dealMagic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   const string comment   = HistoryDealGetString(trans.deal, DEAL_COMMENT);
   const string symbol    = HistoryDealGetString(trans.deal, DEAL_SYMBOL);

// Ownership: prefer magic. Comment is fallback only.
   if(!TrackAcceptDealOwnership(dealMagic, comment, expectedMagic, eaName))
      return;

// Symbol gate: use caller-supplied expectedSymbol (safe for includes)
   if(StringLen(expectedSymbol) > 0 && symbol != expectedSymbol)
      return;

// Deal direction (NOTE: for CLOSE deals this may be opposite of position direction)
   const string dealSide = (dtype == DEAL_TYPE_SELL) ? "SELL" : "BUY";

   const double vol      = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
   const double price    = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   const datetime dtime  = (datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME);

   const double profit =
      HistoryDealGetDouble(trans.deal, DEAL_PROFIT) +
      HistoryDealGetDouble(trans.deal, DEAL_SWAP) +
      HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   const string eventId  = "deal-" + TrackBuildEventId(trans.deal, entry);
   const string currency = AccountInfoString(ACCOUNT_CURRENCY);
   const int    digits   = TrackDigits(symbol);

// Join open->close
   const long posId = (long)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);

// ---------------------------------------------------------------
// OPEN
// ---------------------------------------------------------------
   if(entry == DEAL_ENTRY_IN)
     {
      if(!reportingOn || !sendOpen)
         return;
      if(trans.deal == lastOpenDealId)
         return;
      lastOpenDealId = trans.deal;

      // Seed open state (best effort)
      TrackOpenState s;
      s.pos_id = posId;
      s.magic = expectedMagic;
      s.symbol = symbol;
      s.tf = tf;

      s.time_open = dtime;
      s.entry_price = price;
      s.lot = vol;

      // For OPEN, dealSide matches position direction
      s.side = dealSide;

      s.sl = 0.0;
      s.tp = 0.0;

      s.max_high = price;
      s.min_low  = price;

      s.last_bar_time = 0;
      s.bars_held = 0;
      s.active = true;

      // Try to pull SL/TP from the current position (usually available right
      // after entry). Select by MAGIC, not by symbol - on a hedging account
      // PositionSelect(symbol) can return another EA's position on the same
      // pair, the magic check then rejects it, and this trade's SL/TP would be
      // recorded as 0 in the ledger.
      if(PositionTicketByMagic(symbol, (long)expectedMagic) != 0)
        {
         s.sl = PositionGetDouble(POSITION_SL);
         s.tp = PositionGetDouble(POSITION_TP);
        }

      TrackUpsertState(s);

      const bool ok = TrackSendRecord(
                         true,
                         TRACK_API_URL,
                         HTTP_TIMEOUT_MS,
                         TRACK_API_KEY,
                         eaId, eaName, eaVersion, presetVersion,
                         "OPEN",
                         eventId,
                         symbol,
                         s.side,      // position direction
                         vol,
                         price,
                         0.0,
                         currency,
                         digits,
                         StringFormat("OPEN deal=%I64u pos=%I64d", trans.deal, posId)
                      );

      if(!ok)
         PrintFormat("TRACK: send OPEN failed. deal=%I64u pos=%I64d", trans.deal, posId);
      return;
     }

// ---------------------------------------------------------------
// CLOSE (include INOUT for safety)
// IMPORTANT: dealSide may be opposite to the original position.
// Use stored open-state side if available.
// ---------------------------------------------------------------
   if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY || entry == DEAL_ENTRY_INOUT)
     {
      if(trans.deal == lastCloseDealId)
         return;
      lastCloseDealId = trans.deal;

      // Risk bookkeeping — runs in the tester and with tracking off, because
      // the loss-streak gate depends on it. Everything below this point is
      // reporting only.
      consecLosses  = (profit < 0.0) ? (consecLosses + 1) : 0;
      lastCloseTime = TimeCurrent();

      if(!reportingOn)
         return;

      string posSide = dealSide; // fallback only

      TrackOpenState o;
      const bool hasState = TrackPopState(posId, o);

      if(hasState)
        {
         posSide = o.side; // correct position direction from OPEN

         ReportTradeClose(
            eaId, eaName, eaVersion,
            expectedMagic,
            symbol,
            o.tf,
            posSide,
            entry,
            trans.deal,
            posId,
            o.time_open,
            dtime,
            o.entry_price,
            price,
            o.lot,
            o.sl,
            o.tp,
            o.max_high,
            o.min_low,
            o.bars_held,
            profit
         );
        }
      else
        {
         // If state missing (restart etc.), log minimal row (MFE/MAE=0)
         ReportTradeClose(
            eaId, eaName, eaVersion,
            expectedMagic,
            symbol,
            tf,
            posSide,
            entry,
            trans.deal,
            posId,
            dtime,
            dtime,
            price,
            price,
            vol,
            0.0,
            0.0,
            price,
            price,
            0,
            profit
         );
        }

      const bool ok = TrackSendRecord(
                         enable,
                         TRACK_API_URL,
                         HTTP_TIMEOUT_MS,
                         TRACK_API_KEY,
                         eaId, eaName, eaVersion, presetVersion,
                         "CLOSE",
                         eventId,
                         symbol,
                         posSide,     // position direction (not deal direction)
                         vol,
                         price,
                         profit,
                         currency,
                         digits,
                         StringFormat("CLOSE deal=%I64u pos=%I64d entry=%d", trans.deal, posId, (int)entry)
                      );

      if(!ok)
         PrintFormat("TRACK: send CLOSE failed. deal=%I64u pos=%I64d profit=%.2f", trans.deal, posId, profit);
      return;
     }
  }

#endif // KUROSAWA_TRACK_MQH
//+------------------------------------------------------------------+
