//+------------------------------------------------------------------+
//| File: Strategies/D1Reading.mqh                                   |
//| Type: Shared reading (pure), used as a GATE by intraday engines  |
//| Ver : 0.1.0                                                      |
//|                                                                  |
//| The D1 analyzers' readings, computed the way the analyzers do,   |
//| so an intraday engine can ask "what does the Signals page say    |
//| about this pair today?" without depending on the site.           |
//|                                                                  |
//| Why a gate and not a direction (2026-09-09 forward-return study) |
//| - The readings are CONTRARIAN: a strong LONG reading means the   |
//|   move is extended, and the next days lean down. So an intraday  |
//|   engine uses the reading to decide which SIDE of its own entry  |
//|   is allowed today: shorts when D1 reads extended-up, longs when |
//|   it reads extended-down. "Against the reading" is the gate.     |
//|                                                                  |
//| Readings                                                         |
//| - Breakout   : Fade_Reading in Strategies/Fade.mqh (20-bar prior |
//|                range, ATR expansion, strength 55 + dist*30 + atr*15)|
//| - DailyTrend : EMA20/EMA50 + ADX(14) >= 20, strength 50 + adx*25 |
//|                + spread*20 + pos*10, as in D1_Signal_Trend.mq5   |
//| All at D1 shift=1: the last CLOSED daily bar, i.e. the reading   |
//| the analyzer posted for today.                                   |
//+------------------------------------------------------------------+
#property strict

#ifndef KUROSAWA_D1READING_MQH
#define KUROSAWA_D1READING_MQH

#include "Fade.mqh"

enum D1Rule
{
   D1_RULE_BREAKOUT   = 0,
   D1_RULE_DAILYTREND = 1
};

enum D1GateMode
{
   D1_GATE_OFF          = 0,   // readings ignored (engine behaves as before)
   D1_GATE_SHORTS_ONLY  = 1,   // shorts need an extended-UP reading; longs ungated
   D1_GATE_LONGS_ONLY   = 2,   // longs need an extended-DOWN reading; shorts ungated
   D1_GATE_BOTH         = 3,   // each side needs the opposite reading
   // WITH the reading (added 2026-09-10 to test "buy the dips while D1 is up").
   // The forward-return study says the D1 drift after a LONG reading is slightly
   // negative, so the expectation is that these modes cut trades without adding
   // edge. They exist so that is measured, not argued.
   D1_GATE_WITH_LONGS   = 4,   // longs need a LONG reading; shorts ungated
   D1_GATE_WITH_SHORTS  = 5,   // shorts need a SHORT reading; longs ungated
   D1_GATE_WITH_BOTH    = 6    // each side needs its own reading
};

struct D1Handles
{
   int atr;       // Breakout rule: iATR(D1, 14)
   int emaFast;   // DailyTrend rule: iMA(D1, 20, EMA)
   int emaSlow;   // DailyTrend rule: iMA(D1, 50, EMA)
   int adx;       // DailyTrend rule: iADX(D1, 14)
};

void D1Handles_Reset(D1Handles &h)
{
   h.atr = INVALID_HANDLE; h.emaFast = INVALID_HANDLE; h.emaSlow = INVALID_HANDLE; h.adx = INVALID_HANDLE;
}

bool D1Handles_Create(const string sym, const D1Rule rule, D1Handles &h)
{
   D1Handles_Reset(h);
   if(rule == D1_RULE_BREAKOUT)
   {
      h.atr = iATR(sym, PERIOD_D1, 14);
      return (h.atr != INVALID_HANDLE);
   }
   h.emaFast = iMA(sym, PERIOD_D1, 20, 0, MODE_EMA, PRICE_CLOSE);
   h.emaSlow = iMA(sym, PERIOD_D1, 50, 0, MODE_EMA, PRICE_CLOSE);
   h.adx     = iADX(sym, PERIOD_D1, 14);
   return (h.emaFast != INVALID_HANDLE && h.emaSlow != INVALID_HANDLE && h.adx != INVALID_HANDLE);
}

void D1Handles_Release(D1Handles &h)
{
   if(h.atr     != INVALID_HANDLE) IndicatorRelease(h.atr);
   if(h.emaFast != INVALID_HANDLE) IndicatorRelease(h.emaFast);
   if(h.emaSlow != INVALID_HANDLE) IndicatorRelease(h.emaSlow);
   if(h.adx     != INVALID_HANDLE) IndicatorRelease(h.adx);
   D1Handles_Reset(h);
}

bool D1_Buf1(const int handle, const int shift, double &v)
{
   double b[];
   ArraySetAsSeries(b, true);
   if(handle == INVALID_HANDLE || CopyBuffer(handle, 0, shift, 1, b) != 1) return false;
   v = b[0];
   return MathIsValidNumber(v);
}

// ------------------------------------------------------------------
// The reading at D1 shift (1 = last closed daily bar). Returns false on
// data problems; direction is "LONG" | "SHORT" | "FLAT".
// ------------------------------------------------------------------
bool D1_Read(const string sym, const D1Rule rule, const D1Handles &h, const int shift,
             string &direction, int &strength)
{
   direction = "FLAT"; strength = 0;
   const double close1 = iClose(sym, PERIOD_D1, shift);
   if(close1 <= 0.0) return false;

   if(rule == D1_RULE_BREAKOUT)
   {
      const int lookback = 20, avgBars = 20;
      double highs[], lows[], atr[];
      ArraySetAsSeries(highs, true); ArraySetAsSeries(lows, true); ArraySetAsSeries(atr, true);
      if(CopyHigh(sym, PERIOD_D1, shift + 1, lookback, highs) != lookback) return false;
      if(CopyLow (sym, PERIOD_D1, shift + 1, lookback, lows)  != lookback) return false;
      if(h.atr == INVALID_HANDLE || CopyBuffer(h.atr, 0, shift, avgBars + 1, atr) != avgBars + 1) return false;
      double hi = highs[0], lo = lows[0];
      for(int i = 1; i < lookback; i++) { if(highs[i] > hi) hi = highs[i]; if(lows[i] < lo) lo = lows[i]; }
      double sum = 0.0; for(int i = 1; i <= avgBars; i++) sum += atr[i];
      double distByAtr, atrRatio;
      Fade_Reading(close1, hi, lo, atr[0], sum / avgBars, 1.0, direction, strength, distByAtr, atrRatio);
      return true;
   }

   // DailyTrend
   double ef, es, adx;
   if(!D1_Buf1(h.emaFast, shift, ef) || !D1_Buf1(h.emaSlow, shift, es) || !D1_Buf1(h.adx, shift, adx)) return false;
   if(es == 0.0 || ef == 0.0) return false;

   if(adx >= 20.0)
   {
      if(ef > es && close1 >= ef)      direction = "LONG";
      else if(ef < es && close1 <= ef) direction = "SHORT";
   }
   const double spreadPct = MathAbs(ef - es) / es * 100.0;
   const double adxScore  = Fade_Clamp01((adx - 20.0) / 20.0);
   const double spScore   = Fade_Clamp01(spreadPct / 1.0);
   double posScore = 0.0;
   if(direction == "LONG")  posScore = Fade_Clamp01((close1 - ef) / ef * 100.0 / 0.5);
   if(direction == "SHORT") posScore = Fade_Clamp01((ef - close1) / ef * 100.0 / 0.5);
   double raw = (direction != "FLAT") ? 50.0 + adxScore * 25.0 + spScore * 20.0 + posScore * 10.0
                                      : MathMin(45.0, 40.0 + adxScore * 10.0);
   strength = (int)MathRound(MathMax(0.0, MathMin(100.0, raw)));
   return true;
}

// ------------------------------------------------------------------
// Gate an intraday signal side against today's reading.
// Returns true when the side is allowed. `why` explains a refusal.
// ------------------------------------------------------------------
bool D1_SideAllowed(const bool isBuy, const D1GateMode mode, const int minStrength,
                    const string direction, const int strength, string &why)
{
   why = "";
   if(mode == D1_GATE_OFF) return true;

   const bool withMode = (mode >= D1_GATE_WITH_LONGS);
   const bool gateThisSide = withMode
      ? ((mode == D1_GATE_WITH_BOTH) || (isBuy && mode == D1_GATE_WITH_LONGS) || (!isBuy && mode == D1_GATE_WITH_SHORTS))
      : ((mode == D1_GATE_BOTH)      || (isBuy && mode == D1_GATE_LONGS_ONLY) || (!isBuy && mode == D1_GATE_SHORTS_ONLY));
   if(!gateThisSide) return true;

   // Against the reading (modes 1-3): a short needs extended-UP, a long needs extended-DOWN.
   // With the reading (modes 4-6): a long needs LONG, a short needs SHORT.
   const string need = withMode ? (isBuy ? "LONG" : "SHORT") : (isBuy ? "SHORT" : "LONG");
   if(direction != need || strength < minStrength)
   {
      why = StringFormat("D1 reads %s/%d, %s needs %s>=%d", direction, strength, (isBuy ? "long" : "short"), need, minStrength);
      return false;
   }
   return true;
}

#endif // KUROSAWA_D1READING_MQH
