//+------------------------------------------------------------------+
//| File: Tokyo_ScalpHigh_USDJPY_M1.mq5                              |
//| EA  : Tokyo_ScalpHigh_USDJPY_M1                                  |
//| Ver : 0.1.5-track                                                |
//|                                                                  |
//| USDJPY Tokyo High-Frequency Scalp EA (M1)                        |
//| - Entry: EMA(5/13) crossover confirmed on last closed bar        |
//| - Optional direction filter: Close(1) vs EMA(50)(1)              |
//| - Safety: session gate (JST), spread, min-move(cost), cooldown   |
//| - Risk guard: daily cap, consecutive-loss stop                   |
//| - Exit: max hold minutes (fails fast)                            |
//| - Tracking: OPEN/CLOSE + excursions via KurosawaTrack.mqh        |
//|                                                                  |
//| Template goals                                                   |
//| - One evaluation per new bar (M1)                                |
//| - Consistent daily summary logs                                  |
//| - Optional risk-based sizing with safety cap                     |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
#include "KurosawaHelpers.mqh"
#include "KurosawaTrack.mqh"

CTrade trade;

//==================== Identity ====================//
input int    InpMagic              = 2026010507;
input string InpEaId               = "ea-tokyo-scalphigh-usdjpy-m1";
input string InpEaName             = "Tokyo_ScalpHigh_USDJPY_M1";
input string InpEaVersion          = "0.1.5"; // CHANGED: template-aligned rewrite

//==================== Strategy: Scalp Logic ====================//
input int    InpEmaFast            = 5;   // Smaller => more signals, more noise
input int    InpEmaSlow            = 13;  // Larger gap => fewer signals, later entries

// Optional direction filter (helps avoid counter-trend scalps)
// true  -> fewer trades, better trend alignment, can miss reversals
// false -> more trades, higher chop exposure
input bool   InpUseDirFilter       = true;
input int    InpEmaDir             = 50;  // Smaller => looser, Larger => stricter

//==================== Stops & Targets ====================//
// For M1 scalp, TP/SL are in pips, not ATR
// Higher TP => fewer wins but bigger winners, more "almost then reverse"
// Lower TP  => more hits, smaller winners, smoother equity if costs are controlled
input double InpTpPips             = 3.0;

// Higher SL => fewer stopouts, larger loss per trade (or smaller lot with risk sizing)
// Lower SL  => more stopouts, more sensitivity to spread/noise
input double InpSlPips             = 5.0;

//==================== Position Sizing ====================//
// Choose one:
// - Fixed lot: stable sizing, easy to reason about, equity not normalized
// - Risk % sizing: normalizes risk per trade, lot becomes dynamic
input bool   InpUseRiskSizing      = false; // default false for scalps (keep behavior close to original)

// Equity risk per trade (%)
// Higher => faster growth, much larger drawdowns
// Lower  => smoother, slower
input double InpRiskPercent        = 0.20;

// If NOT using risk sizing, use fixed lot
input double InpFixedLot           = 0.01;

// Safety cap (prevents surprises if broker tick_value/tick_size behaves unexpectedly)
input double InpMaxLotCap          = 0.05; // 0 disables cap

//==================== Trade Frequency Controls ====================//
input int    InpMaxTradesPerDay    = 80;
input int    InpCooldownSeconds    = 30;  // Higher => fewer re-entries, less chop
input int    InpMaxHoldMinutes     = 20;  // Lower => faster exit, fewer long drifts

//==================== Session: Tokyo (JST) ====================//
input int    InpJstStartHour       = 9;
input int    InpJstEndHour         = 23;
input int    InpJstUtcOffset       = 9;

//==================== Execution Guards ====================//
// Spread gate (points). Lower => avoids bad fills, fewer trades
input double InpMaxSpreadPoints    = 25;

// Min-move filter: require TP distance to be "worth it" vs spread cost
// true  -> filters bad cost regimes, fewer trades, higher quality
// false -> more trades, expectancy can degrade in wide spreads
input bool   InpUseMinMoveFilter   = true;
input double InpMinMoveSpreadMult  = 2.0; // Higher => stricter, fewer trades

//==================== Risk Stops ====================//
// Stop after N consecutive losses
// Lower => safer, can stop in temporary noise
// Higher => trades through rough patches, bigger drawdown tails
input int    InpMaxConsecLosses    = 3;

// Flatten before weekend
input bool   InpCloseBeforeWeekend = true;
input int    InpFridayCloseHourJst = 22;

//==================== Tracking ====================//
input bool   InpTrackEnable        = true;
input bool   InpTrackSendOpen      = true;

//==================== Indicator Handles & State ====================//
int hFast = INVALID_HANDLE;
int hSlow = INVALID_HANDLE;
int hDir  = INVALID_HANDLE;

datetime g_lastBarTime   = 0;
datetime g_lastCloseTime = 0;

int g_tradesToday   = 0;
int g_consecLosses  = 0; // NOTE: updated by KurosawaTrack on CLOSE; do not reset daily
int g_lastJstYmd    = 0;

ulong g_lastOpenDealId   = 0;
ulong g_lastClosedDealId = 0;

// Diagnostics (daily)
int g_diagBars      = 0;
int g_diagSignal    = 0;
int g_diagTradeSent = 0;

// Block counters (daily)
int g_blockSession   = 0;
int g_blockSpread    = 0;
int g_blockMinMove   = 0;
int g_blockCooldown  = 0;
int g_blockHasPos    = 0;
int g_blockLoss      = 0;
int g_blockMaxDay    = 0;
int g_blockNoSignal  = 0;
int g_blockStops     = 0;
int g_blockOrderFail = 0;

//+------------------------------------------------------------------+
//| Utility: clamp                                                  |
//+------------------------------------------------------------------+
double ClampDouble(const double v, const double lo, const double hi)
{
   if(v < lo) return lo;
   if(v > hi) return hi;
   return v;
}

//+------------------------------------------------------------------+
//| Lot sizing helpers                                               |
//+------------------------------------------------------------------+
// Risk-based lot sizing (same idea as swing template)
// sl_distance_price is in PRICE units (not pips)
double CalcRiskLotBySLDistance(const string symbol, const double sl_distance_price, const double risk_percent)
{
   if(sl_distance_price <= 0.0) return 0.0;

   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0) return 0.0;

   const double risk_money = equity * (risk_percent / 100.0);
   if(risk_money <= 0.0) return 0.0;

   double tick_value = 0.0;
   double tick_size  = 0.0;
   if(!SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE, tick_value)) return 0.0;
   if(!SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE,  tick_size))  return 0.0;
   if(tick_value <= 0.0 || tick_size <= 0.0) return 0.0;

   const double money_per_1lot = (sl_distance_price / tick_size) * tick_value;
   if(money_per_1lot <= 0.0) return 0.0;

   double vol = risk_money / money_per_1lot;

   double vmin = 0.0, vmax = 0.0, vstep = 0.0;
   if(!SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN,  vmin))  return 0.0;
   if(!SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX,  vmax))  return 0.0;
   if(!SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP, vstep)) return 0.0;
   if(vmin <= 0.0 || vmax <= 0.0 || vstep <= 0.0) return 0.0;

   vol = ClampDouble(vol, vmin, vmax);

   // floor to step to avoid rounding up risk
   vol = MathFloor(vol / vstep) * vstep;
   if(vol < vmin) vol = vmin;

   return NormalizeDouble(vol, 2);
}

// Returns final lot based on settings (risk sizing or fixed lot) and safety cap
double ResolveLot(const double sl_distance_price)
{
   double lot = 0.0;

   if(InpUseRiskSizing)
   {
      // If you increase InpRiskPercent => larger lot, larger drawdown
      // If you increase SL pips => lot decreases automatically, risk stays constant
      lot = CalcRiskLotBySLDistance(_Symbol, sl_distance_price, InpRiskPercent);
   }
   else
   {
      // Fixed lot => stable size, but risk varies with SL and volatility
      lot = InpFixedLot;
   }

   if(lot <= 0.0) return 0.0;

   if(InpMaxLotCap > 0.0)
      lot = MathMin(lot, InpMaxLotCap);

   return lot;
}

//+------------------------------------------------------------------+
//| Weekend window (JST)                                             |
//+------------------------------------------------------------------+
bool IsFridayCloseWindow()
{
   MqlDateTime dt;
   TimeToStruct(NowJst(InpJstUtcOffset), dt);

   // Friday after configured JST hour, plus all day Saturday
   return ((dt.day_of_week == 5 && dt.hour >= InpFridayCloseHourJst) || dt.day_of_week == 6);
}

//+------------------------------------------------------------------+
//| Daily summary                                                    |
//+------------------------------------------------------------------+
void PrintDailySummary()
{
   PrintFormat(
      "%s Daily Summary: Bars=%d Signals=%d Trades=%d TradesToday=%d ConsecLoss=%d",
      InpEaName, g_diagBars, g_diagSignal, g_diagTradeSent, g_tradesToday, g_consecLosses
   );

   PrintFormat(
      "Daily Blocks | session=%d spread=%d minmove=%d cooldown=%d haspos=%d loss=%d maxday=%d nosignal=%d stops=%d orderfail=%d",
      g_blockSession, g_blockSpread, g_blockMinMove, g_blockCooldown,
      g_blockHasPos, g_blockLoss, g_blockMaxDay, g_blockNoSignal,
      g_blockStops, g_blockOrderFail
   );
}

//+------------------------------------------------------------------+
//| Max-hold exit                                                    |
//+------------------------------------------------------------------+
void CheckHoldTimeExit()
{
   if(InpMaxHoldMinutes <= 0) return;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      const datetime openT = (datetime)PositionGetInteger(POSITION_TIME);
      if((TimeCurrent() - openT) >= (InpMaxHoldMinutes * 60))
      {
         trade.PositionClose(ticket);
         // NOTE: g_lastCloseTime is updated by KurosawaTrack on CLOSE
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| Initialization / Deinit                                          |
//+------------------------------------------------------------------+
int OnInit()
{
   if(_Period != PERIOD_M1)
   {
      Print("CRITICAL: Attach this EA to M1.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);

   hFast = iMA(_Symbol, PERIOD_M1, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, PERIOD_M1, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);

   if(InpUseDirFilter)
      hDir = iMA(_Symbol, PERIOD_M1, InpEmaDir, 0, MODE_EMA, PRICE_CLOSE);

   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE || (InpUseDirFilter && hDir == INVALID_HANDLE))
   {
      Print("CRITICAL: Indicator handle creation failed.");
      return INIT_FAILED;
   }

   g_lastJstYmd = JstYmd(NowJst(InpJstUtcOffset));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hFast != INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow != INVALID_HANDLE) IndicatorRelease(hSlow);
   if(hDir  != INVALID_HANDLE) IndicatorRelease(hDir);
}

//+------------------------------------------------------------------+
//| Main Tick Loop                                                   |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1) Daily rollover (JST)
   const int ymd = JstYmd(NowJst(InpJstUtcOffset));
   if(ymd != g_lastJstYmd)
   {
      PrintDailySummary();

      g_lastJstYmd = ymd;

      // Reset daily counters
      g_tradesToday   = 0;

      g_diagBars      = 0;
      g_diagSignal    = 0;
      g_diagTradeSent = 0;

      g_blockSession  = 0;
      g_blockSpread   = 0;
      g_blockMinMove  = 0;
      g_blockCooldown = 0;
      g_blockHasPos   = 0;
      g_blockLoss     = 0;
      g_blockMaxDay   = 0;
      g_blockNoSignal = 0;
      g_blockStops    = 0;
      g_blockOrderFail= 0;

      // NOTE: do NOT reset g_consecLosses
   }

   // 2) Pre-weekend flatten (risk control)
   if(InpCloseBeforeWeekend && IsFridayCloseWindow())
   {
      if(PositionExists(_Symbol, InpMagic))
         trade.PositionClose(_Symbol);
      return;
   }

   // 3) Max-hold exit
   CheckHoldTimeExit();

   // 4) New bar gate (evaluate once per M1 bar)
   const datetime t0 = iTime(_Symbol, PERIOD_M1, 0);
   if(t0 == g_lastBarTime) return;
   g_lastBarTime = t0;
   g_diagBars++;

   // 4.1) Tracking excursion update (Option A)
   // Using PERIOD_M1 keeps review numbers aligned with the scalp timeframe.
   KurosawaTrack_OnNewBar(InpTrackEnable, InpMagic, _Symbol, PERIOD_M1);

   // 5) Session gate (counted per bar)
   if(!IsEntryTimeJST(InpJstStartHour, InpJstEndHour, InpJstUtcOffset))
   {
      g_blockSession++;
      return;
   }

   // 6) Quotes
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return;

   // 7) Spread gate (counted per bar)
   const double sprPoints = (ask - bid) / _Point;
   if(InpMaxSpreadPoints > 0.0 && sprPoints > InpMaxSpreadPoints)
   {
      g_blockSpread++;
      return;
   }

   // 8) Min-move(cost) gate (counted per bar)
   if(InpUseMinMoveFilter)
   {
      const double tpMovePrice = PipsToPrice(_Symbol, InpTpPips);
      const double spreadPrice = (ask - bid);

      // If you increase InpMinMoveSpreadMult => stricter (fewer trades, better cost regimes)
      if(tpMovePrice <= spreadPrice * InpMinMoveSpreadMult)
      {
         g_blockMinMove++;
         return;
      }
   }

   // 9) Frequency & risk gates
   if(g_tradesToday >= InpMaxTradesPerDay) { g_blockMaxDay++; return; }
   if(g_consecLosses >= InpMaxConsecLosses) { g_blockLoss++; return; }

   if(InpCooldownSeconds > 0 && g_lastCloseTime > 0 && (TimeCurrent() - g_lastCloseTime) < InpCooldownSeconds)
   {
      g_blockCooldown++;
      return;
   }

   if(PositionExists(_Symbol, InpMagic)) { g_blockHasPos++; return; }

   // 10) Indicator reads (closed bars: shift=1 and shift=2 for crossover)
   double f[2], s[2];
   if(CopyBuffer(hFast, 0, 1, 2, f) != 2) return;
   if(CopyBuffer(hSlow, 0, 1, 2, s) != 2) return;

   double dirVal[1];
   if(InpUseDirFilter)
   {
      if(CopyBuffer(hDir, 0, 1, 1, dirVal) != 1) return;
   }

   // 11) Closed-bar crossover
   const bool crossUp   = (f[1] <= s[1] && f[0] > s[0]);
   const bool crossDown = (f[1] >= s[1] && f[0] < s[0]);

   // Direction filter uses Close(1) vs EMAdir(1)
   const double close1 = iClose(_Symbol, PERIOD_M1, 1);
   const bool dirUp    = (!InpUseDirFilter) ? true : (close1 > dirVal[0]);
   const bool dirDown  = (!InpUseDirFilter) ? true : (close1 < dirVal[0]);

   if(crossUp || crossDown) g_diagSignal++;

   const bool goBuy  = (crossUp   && dirUp);
   const bool goSell = (crossDown && dirDown);

   if(!goBuy && !goSell)
   {
      g_blockNoSignal++;
      return;
   }

   // 12) Build SL/TP and execute
   const double slDist = PipsToPrice(_Symbol, InpSlPips);
   const double tpDist = PipsToPrice(_Symbol, InpTpPips);
   if(slDist <= 0.0 || tpDist <= 0.0) return;

   double lot = ResolveLot(slDist);
   if(lot <= 0.0) return;

   const string cmtBase = InpEaName + "|" + InpEaVersion;

   if(goBuy)
   {
      double sl = NormalizeDouble(ask - slDist, _Digits);
      double tp = NormalizeDouble(ask + tpDist, _Digits);

      if(!EnsureStopsLevel(_Symbol, ask, sl, tp, true, true))
      {
         g_blockStops++;
         return;
      }

      if(!trade.Buy(lot, _Symbol, 0, sl, tp, cmtBase + "|BUY"))
      {
         g_blockOrderFail++;
         PrintFormat("ORDER_FAIL BUY: retcode=%d", trade.ResultRetcode());
         return;
      }

      g_tradesToday++;
      g_diagTradeSent++;
   }
   else // goSell
   {
      double sl = NormalizeDouble(bid + slDist, _Digits);
      double tp = NormalizeDouble(bid - tpDist, _Digits);

      if(!EnsureStopsLevel(_Symbol, bid, sl, tp, false, true))
      {
         g_blockStops++;
         return;
      }

      if(!trade.Sell(lot, _Symbol, 0, sl, tp, cmtBase + "|SELL"))
      {
         g_blockOrderFail++;
         PrintFormat("ORDER_FAIL SELL: retcode=%d", trade.ResultRetcode());
         return;
      }

      g_tradesToday++;
      g_diagTradeSent++;
   }
}

//+------------------------------------------------------------------+
//| Transaction Monitoring & Tracking (via KurosawaTrack.mqh)         |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& req,
                        const MqlTradeResult& res)
{
   // Passing PERIOD_M1 keeps reporting consistent for scalp review
   KurosawaTrack_OnTradeTransaction(
      InpTrackEnable,
      trans,
      InpEaId,
      InpEaName,
      InpEaVersion,
      InpMagic,
      InpTrackSendOpen,
      g_lastOpenDealId,
      g_lastClosedDealId,
      g_consecLosses,
      g_lastCloseTime,
      (ENUM_TIMEFRAMES)_Period,_Symbol
   );
}
