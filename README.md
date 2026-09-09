# Kurosawa Trading Systems

Systematic **MetaTrader 5 (MT5)** Expert Advisors and shared infrastructure for disciplined, session-aware algorithmic trading.

Everything in this repository is published — the strategy modules, the engines, the tuned `.set` files, and the shared execution and risk layer. The only thing kept out is the API key the engines use to report their results (see *Secrets* below). The results themselves are published too, run by run, at **https://1kpips.com/en/presets**, including every tune that failed and why.

---

## Design Philosophy

### 1. Closed-Bar Logic Only
All trading decisions are made using **confirmed (closed) candles** only.
No live-bar logic, no repainting indicators. Live behaviour matches backtest behaviour.

### 2. One EA, One Position
Each engine instance enforces a **unique magic number** and **at most one open position**.
The magic registry lives in `Helpers/KurosawaHelpers.mqh`; every chart instance gets its own slot.

### 3. Session-Aware Execution
Every preset is bound to a session window on the **broker's server clock** — the same clock
the Strategy Tester uses, so what is tested is what runs. See `Presets/README.md` for how
the hours map to UTC.

### 4. Execution Safety Over Frequency
Spread cap, cooldown, daily loss limit, consecutive-loss stop, ATR floor, broker
stops/freeze-level compliance. Missing a trade is always preferred over entering a bad one.

### 5. Values Live in `.set` Files
Engines and strategies contain logic. `Inputs/*.mqh` declares the inputs with sensible
defaults and the engine's version; `Presets/*.set` carries the values that actually ran.
Every `.set` records its own version (`InpPresetVersion`) and the engine build it was
tested on (`InpEaVersion`), and both are filed with every published result.

### 6. Tested Before Traded
A tune is promoted only through a written gate — out-of-sample window, sample size,
degradation limits, parameter stability, honest costs, build match, drawdown, and
"every window positive". The gate and each preset's status (`candidate`, `proven`,
`live`, `rejected`) are on the site, with the reasons.

---

## Repository Structure

```text
Experts/KurosawaEA/
├── Engines/                 # MT5 lifecycle + execution; strategy-agnostic
│   ├── RangeRevertEA.mq5    # proven (M15, European morning, long only) - live
│   ├── TrendEA.mq5          # rejected: entry has no edge in either session
│   ├── TrendPullbackEA.mq5  # rejected
│   ├── BreakoutEA.mq5       # rejected: London-range break in NY chops
│   ├── FadeEA.mq5           # candidate: fades the D1 Breakout reading (thin)
│   └── Archived/            # retired engines, kept for the record
├── Strategies/              # closed-bar signal judgment only, no execution
│   ├── RangeRevert.mqh
│   ├── Trend.mqh
│   ├── TrendPullback.mqh
│   ├── Breakout.mqh
│   ├── Fade.mqh             # the D1 analyzer's reading, computed the analyzer's way
│   ├── D1Reading.mqh        # D1 readings as a side gate (tested, rejected, default off)
│   └── Archived/
├── Inputs/                  # input declarations, defaults, engine version
├── Helpers/                 # shared infrastructure
│   ├── KurosawaHelpers.mqh        # umbrella include + magic registry
│   ├── KurosawaExecutor.mqh       # one order path for all engines
│   ├── KurosawaExecUtils.mqh      # stops/freeze levels, trailing, exits
│   ├── KurosawaRiskManager.mqh    # sizing, daily limits, loss streaks
│   ├── KurosawaIndicatorFactory.mqh
│   ├── KurosawaTime.mqh           # engine clock and session windows
│   ├── KurosawaTrack.mqh          # reports closed trades to 1kpips.com
│   ├── KurosawaSignalPublisher.mqh
│   └── KurosawaSecrets.example.mqh
├── Signals/                 # D1 analyzers: post direction/strength, place no trades
└── Presets/                 # the tunes, by session — see Presets/README.md
    ├── London/  NewYork/  Tokyo/  Daily/  Screening/
```

---

## Engines, Strategies, Helpers

**Engines** own `OnInit` / `OnTick` / `OnTimer` / `OnTradeTransaction`, the safety gates, sizing,
SL/TP placement and exits. They call a strategy module once per closed bar and act on its answer.

**Strategies** answer one question on one closed bar — buy, sell, or nothing — from indicator
values passed in. No broker calls, no state, no execution.

**Helpers** hold everything execution-critical once: broker stops/freeze compliance, volume
normalisation, the risk manager, the order path, the clock. No engine reimplements any of it.

---

## Building

Open `Engines/*.mq5` and `Signals/*.mq5` in MetaEditor and compile, or from a shell:

```
MetaEditor64.exe /compile:"<path>\Experts\KurosawaEA\Engines\RangeRevertEA.mq5" /log
```

Before the first compile, copy `Helpers/KurosawaSecrets.example.mqh` to
`Helpers/KurosawaSecrets.mqh`. Without a real key the engines still trade; they just fail
to report, and say so in the log.

## Running a Preset

1. Select the **engine** in the Strategy Tester or drag it onto the chart.
2. `Inputs → Load` the `.set` — the engine refuses to start on a symbol or timeframe that
   does not match the preset (`InpStrictChartMatch`).
3. Backtest first. File the result. Then, and only then, a chart.

---

## Secrets

`Helpers/KurosawaSecrets.mqh` holds the ingest API key and is git-ignored. It is the only
private file. If you fork this and run it, use your own endpoint or leave the placeholder.

---

## Disclaimer

Trading foreign exchange on margin carries a high level of risk and may not be suitable for
all investors. Losses can exceed deposits. This repository is provided for educational and
research purposes only; nothing in it is investment advice, and no guarantee of profitability
is made or implied. The authors assume no responsibility for losses incurred through its use.
Past performance does not guarantee future results.
