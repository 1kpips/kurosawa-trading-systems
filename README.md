# Kurosawa Trading Systems

Systematic **MetaTrader 5 (MT5)** Expert Advisors and shared infrastructure for disciplined, session-aware algorithmic trading.

The **KurosawaEA** suite is designed as a *portfolio of independent systems*, prioritizing **capital protection, execution safety, and long-term robustness** over short-term backtest optimization.

---

## Design Philosophy

All systems in this repository follow these non-negotiable principles:

### 1. Closed-Bar Logic Only
All trading decisions are made using **confirmed (closed) candles** only.  
No live-bar logic, no repainting indicators.

This guarantees that **live behavior matches backtest behavior**.

---

### 2. One EA, One Position
Each EA enforces:
- a **unique Magic Number**
- **maximum one open position per EA**

This prevents signal interference and simplifies portfolio-level risk attribution.

---

### 3. Session-Aware Execution
Every EA is explicitly bound to a **market session**:
- Tokyo  
- London  
- New York  

Trades are allowed only during defined liquidity windows, with **safe handling of midnight-crossing sessions**.

---

### 4. Execution Safety Over Frequency
Trade frequency is intentionally constrained using:
- spread filters  
- cooldown timers  
- daily loss limits  
- consecutive loss protection  
- volatility (ATR) safety windows  

Missing a trade is always preferred over entering a low-quality one.

---

### 5. Preset-Driven Configuration (No Hard-Coded Inputs)
**All actual trading parameters live in `.set` files**, not in code.

- EAs and strategies contain **logic only**
- Parameters are injected via **Preset `.set` files**
- Inputs `.mqh` files exist only as placeholders for MT5 input binding

This enables:
- rapid strategy iteration
- clean symbol / timeframe switching
- zero code changes when tuning parameters

---

## Repository Structure

```text
/Experts/KurosawaEA/
├── Engines/                  # Execution-only MQ5 engines
│   ├── RangeRevertEA.mq5
│   ├── ScalpEA.mq5
│   ├── SwingTrendEA.mq5
│   └── TrendPullbackEA.mq5
│
├── Strategies/               # Signal judgment only (NO execution)
│   ├── RangeRevert.mqh
│   ├── Scalp.mqh
│   ├── SwingTrend.mqh
│   └── TrendPullback.mqh
│
├── Helpers/                  # Shared infrastructure (umbrella)
│   ├── KurosawaHelpers.mqh        # Umbrella include
│   ├── KurosawaPositionUtils.mqh
│   ├── KurosawaRiskManager.mqh
│   ├── KurosawaSignalUtils.mqh
│   ├── KurosawaTime.mqh
│   └── KurosawaTradeUtils.mqh
│
├── Inputs/                   # Placeholder only (NOT used at runtime)
│   ├── RangeRevert_Inputs.mqh
│   ├── Scalp_Inputs.mqh
│   ├── SwingTrend_Inputs.mqh
│   └── TrendPullback_Inputs.mqh
│
├── Presets/                  # Actual trading parameters
│   ├── Tokyo/
│   │   ├── Tokyo_Scalp_USDJPY_M5.set
│   │   ├── Tokyo_RangeRevert_USDJPY_M5.set
│   │   └── Tokyo_SwingTrend_USDJPY_H1.set
│   ├── London/
│   │   ├── London_RangeRevert_EURGBP_M5.set
│   │   ├── London_Scalp_EURUSD_M5.set
│   │   └── London_SwingTrend_GBPJPY_H1.set
│   └── NewYork/
│       ├── NewYork_TrendPullback_NZDUSD_M15.set
│       └── NewYork_SwingTrend_USDCAD_H1.set
---
```

## Architecture Overview

### Execution Engines (`Engines/*.mq5`)

Execution engines are responsible for **all MT5 lifecycle and execution logic**.

They perform the following tasks:

- Handle MT5 lifecycle events  
  (`OnInit`, `OnTick`, `OnTradeTransaction`)
- Apply global safety gates  
  (session window, spread filter, cooldown, daily limits)
- Execute trades  
  (SL / TP placement, position sizing, exit handling)
- Call strategy modules for **closed-bar signal judgment only**

Each engine is **strategy-agnostic** and contains **no market logic** beyond execution control.

---

### Strategy Modules (`Strategies/*.mqh`)

Strategy modules are responsible for **signal judgment only**.

Characteristics:

- Pure signal evaluation
- Closed-bar logic only
- No execution logic
- No broker interaction
- No position or risk management

Strategies answer **one question only**:

> Should we BUY, SELL, or do NOTHING on this closed bar?

---

### Shared Infrastructure (`Helpers/*.mqh`)

#### KurosawaHelpers.mqh (Umbrella)

`KurosawaHelpers.mqh` is the **single include point** for all shared utilities.

- No EA reimplements this logic locally
- All execution-critical calculations are centralized

**Provided functionality:**

- Session & time management (JST / broker time)
- Pip & price normalization (JPY / non-JPY)
- Broker `StopsLevel` / `FreezeLevel` compliance
- Volume normalization
- ATR & ADX regime filters
- Trade safety helpers

All EAs behave consistently because **all critical math lives here**.

---

### Inputs Folder (Placeholder Only)

```text
/Inputs/*.mqh
```

- Exists only to satisfy MT5 input binding
- Values are **not used**
- All real parameters come from `.set` files

This design allows you to:

- Create your own `.set` files
- Choose any symbol and timeframe
- Reuse the same EA binary safely

---

### Presets (`Presets/{Session}/`)

Preset naming convention:

```text
Presets/{MarketSession}/{MarketSession}_{Strategy}_{Pair}_{TF}.set
```

Example:

```text
Tokyo_SwingTrend_USDJPY_H1.set
```

Presets define:

- Session window
- Indicators
- Risk model
- Filters
- SL / TP behavior
- Tracking options

**This is the only place you should tune parameters.**

---

## Risk & Safety Controls

Every EA enforces:

- Risk-based position sizing (or safe fixed-lot fallback)
- Daily loss limits
- Maximum consecutive loss protection
- Spread filters
- Cooldown timers
- Maximum one position per Magic Number

These controls are **mandatory**, not optional.

---

## Usage Notes

- Always attach EAs to their intended symbol and timeframe
- Load the corresponding `.set` file before enabling AutoTrading
- Demo-test all configurations before live deployment
- Never mix presets across sessions or symbols

---

## Disclaimer

### Risk Warning

Trading foreign exchange on margin carries a high level of risk and may not be suitable for all investors.  
Losses can exceed initial deposits.

### No Investment Advice

This repository is provided for educational and research purposes only.  
No guarantees of profitability are made or implied.

### No Liability

The authors and contributors assume no responsibility for any trading losses incurred through the use of this software.  
Past performance does not guarantee future results.
