# Kurosawa Trading Systems

Systematic **MetaTrader 5 (MT5)** Expert Advisors and shared infrastructure for disciplined, session-aware algorithmic trading.

The **KurosawaEA** suite is designed as a *portfolio of independent systems*, prioritizing **capital protection, execution safety, and long-term robustness** over short-term backtest optimization.

---

## Design Philosophy

All systems in this repository are built under the following core principles:

### 1. Closed-Bar Logic Only
All trading decisions are made using **confirmed (closed) candles**.  
No indicators rely on live-bar values or repainting logic, ensuring **live behavior matches backtests**.

### 2. One EA, One Position
Each EA enforces:
- a **unique Magic Number**
- **maximum one open position per EA**

This prevents signal interference and simplifies risk attribution at the portfolio level.

### 3. Session-Aware Execution
Every EA is explicitly bound to a **market session**:
- Tokyo
- London
- New York

Trades are only allowed during defined liquidity windows, with **safe handling of midnight-crossing sessions**.

### 4. Execution Safety Over Frequency
Trade frequency is intentionally constrained using:
- spread filters
- cooldown timers
- daily loss limits
- consecutive loss protection
- volatility (ATR) safety windows

Missing a trade is always preferred over entering a low-quality one.

### 5. Shared, Centralized Infrastructure
All critical logic is centralized into shared libraries to guarantee **behavioral consistency** across EAs:
- broker constraint handling
- pip / point math
- session logic
- tracking and telemetry

---

## Repository Structure

```text
/Experts/KurosawaEA/
 ├── D1_Signal_Breakout.mq5
 ├── D1_Signal_SMA_Slope.mq5
 ├── D1_Signal_Trend.mq5

 ├── London_ScalpHigh_EURUSD_M1.mq5
 ├── London_RangeRevert_EURGBP_M5.mq5
 ├── London_SwingTrend_EURUSD_H1.mq5
 ├── London_SwingTrend_EURJPY_H1.mq5
 ├── London_SwingTrend_GBPJPY_H1.mq5

 ├── Tokyo_ScalpHigh_USDJPY_M1.mq5
 ├── Tokyo_DaytradeScalp_USDJPY_M5.mq5
 ├── Tokyo_RangeRevert_USDJPY_M5.mq5
 ├── Tokyo_SwingTrend_USDJPY_H1.mq5

 ├── NewYork_RangeRevert_USDCAD_M5.mq5
 ├── NewYork_TrendPullback_EURUSD_M5.mq5
 ├── NewYork_SwingTrend_GBPUSD_H1.mq5
 ├── NewYork_SwingTrend_AUDUSD_H1.mq5

 ├── KurosawaHelpers.mqh
 └── KurosawaTrack.mqh
```

## Shared Infrastructure (KurosawaHelpers.mqh)

The centralized helper library handles all execution-critical calculations:

* **Time Management**: JST/GMT conversions and session window validation.
* **Pip Math**: Robust price normalization and automated 3-digit (JPY) or 5-digit broker detection.
* **Broker Compliance**: Dynamic validation of StopsLevel and FreezeLevel to prevent order rejections.
* **Regime Detection**: Standardized ADX-based filters for mean-reversion gating.

---

Each EA is self-contained, symbol- and timeframe-specific, and designed to be run independently as part of a diversified portfolio.

## Shared Infrastructure

### KurosawaHelpers.mqh

Provides execution-critical utilities shared by all EAs.  
No EA reimplements this logic locally.

**Session Handling**
- Broker-time session windows
- Safe handling of midnight-crossing sessions

**Price & Volume Normalization**
- Automatic handling of JPY vs non-JPY pairs
- Broker min / max / step volume compliance

**Broker Safety**
- StopsLevel and FreezeLevel validation
- Order parameter normalization to prevent rejections

**Volatility Filters**
- ATR-based safety gates
- ADX-based regime suppression

---

### KurosawaTrack.mqh

Unified trade tracking and telemetry layer used across the entire portfolio.

- Centralized `OnTradeTransaction` handling
- OPEN / CLOSE event reporting
- Loss-streak tracking
- Duplicate-deal guards
- Symbol- and timeframe-aware metadata

All EAs call the **same 13-parameter tracking interface**, ensuring consistent and reliable reporting behavior.

---

## Strategy Archetypes

### Scalping (M1 / M5)
- Designed for high-liquidity windows
- Strong cost controls (spread and volatility filters)
- Mandatory cooldown between trades
- Intended for precision, not volume

### Swing Trend (H1)
- EMA(50/200) structural trend definition
- ATR-based stop sizing and R-multiple targets
- Session-gated to avoid low-liquidity chop
- Designed for multi-hour directional moves

### Range & Mean Reversion (M5)
- Bollinger Band and RSI extreme-based entries
- Mean (mid-band) based exits
- ADX filters to suppress trades during strong trends
- Focused on volatility compression regimes

### Daily Bias Signals (D1)
- Non-trading signal generators
- Publish higher-timeframe market structure
- Intended for directional context and filtering

---

## Risk & Safety Controls

Every EA enforces the following controls:

- Risk-based position sizing (or safe fixed-lot fallback)
- Daily loss limits
- Maximum consecutive loss protection
- Spread filters
- Cooldown timers
- Maximum positions per Magic Number

These controls are **mandatory**, not optional.

---

## Usage Notes

- Always attach EAs to their intended symbol and timeframe
- Verify broker server time and session inputs before deployment
- Demo-test all EAs before live trading
- If using tracking, ensure required WebRequest domains are allowlisted in MT5

---

## Disclaimer

### Risk Warning
Trading foreign exchange on margin carries a high level of risk and may not be suitable for all investors. Losses can exceed initial deposits.

### No Investment Advice
This repository is provided for educational and research purposes only. No guarantees of profitability are made or implied.

### No Liability
The authors and contributors assume no responsibility for any trading losses incurred through the use of this software. Past performance does not guarantee future results.
