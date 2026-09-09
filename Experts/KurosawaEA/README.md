# 1KPIPS — Kurosawa EA Suite (MQL5)

Automated FX trading logic for **MetaTrader 5**, built by **Shouki Inc.** and
published as part of the [1kpips.com](https://1kpips.com) project — a place to
**learn and *prove* automated FX trading with real code and real results**,
rather than sell black‑box signals.

The suite is organized so that each moving part has one clear job: read closed
bars, evaluate a rule‑based signal, size a trade under strict risk limits, place
it through one shared order path, and report real outcomes.

---

## What this repository is — and is not

**It is:** the real, running scaffolding of the EAs — the execution path, risk
guards, indicator plumbing, session/time handling, tracking, and per‑session
presets. This is genuine code that compiles and runs on live MT5.

**What is published:** everything except the API key. The strategy modules, the
input schemas, the shared execution and risk layer, and the tuned `.set` presets
are all here, and the per-tune parameter values and their backtest results are
published on [1kpips.com/en/presets](https://1kpips.com/en/presets).

That is deliberate. A tune decays — the parameters that looked best in February
were worthless within seven months — so the specific numbers were never the
thing worth protecting. What is worth showing is the method: how a tune is
tested, what was rejected and why, and how the live results compare with the
backtest that justified them.

**The one secret** is the ingest API key, which lives in a git-ignored
`Helpers/KurosawaSecrets.mqh`. Copy `KurosawaSecrets.example.mqh` and paste your
own; never commit the real file.

**No secrets in the repo.** API keys live only in a local, git‑ignored
`Helpers/KurosawaSecrets.mqh` (see setup). A committable
`KurosawaSecrets.example.mqh` template ships in its place.

**Not investment advice.** These programs are educational and experimental.
Trading FX carries substantial risk. Nothing here is a recommendation.

---

## Architecture at a glance

```
MT5 (local) ──> Signal analyzers  ──> 1kpips API ──> Signals page
            └─> Trading engines    ──> 1kpips API ──> EA Track Record page
```

- **Signal analyzers** analyze closed bars and publish a direction/strength — they place **no trades**.
- **Trading engines** evaluate a strategy, size under risk limits, execute, and report **real** results.

## Repository layout

| Folder | Role |
|---|---|
| [`Engines/`](Engines/) | Trading EAs (`.mq5`). Thin orchestrators: gates → strategy → shared executor. |
| [`Strategies/`](Strategies/) | Pure, self‑contained signal‑evaluation modules (`.mqh`). |
| [`Inputs/`](Inputs/) | Per‑strategy input schemas (`*_Inputs.mqh`), aligned to one column layout across the suite. |
| [`Helpers/`](Helpers/) | Shared libraries: time, execution, risk, tracking, indicator factory, signal publisher. |
| [`Presets/`](Presets/) | Ready‑to‑attach preset EAs per session (Tokyo / London / New York), symbol, and timeframe. |
| [`Signals/`](Signals/) | Signal‑only analyzers (run locally; **not** part of the published trading logic). |

Each folder has its own `README.md` describing purpose and contents.

---

## Getting started

1. **Install** MetaTrader 5 and open **MetaEditor**.
2. **Place** the `KurosawaEA` folder under `MQL5/Experts/`.
3. **Configure secrets:** copy `Helpers/KurosawaSecrets.example.mqh` to
   `Helpers/KurosawaSecrets.mqh` and fill in your own API key. This real file is
   git‑ignored and must never be committed.
4. **Allowlist WebRequest:** in MT5, *Tools → Options → Expert Advisors →
   Allow WebRequest for listed URL*, and add the reporting endpoint's host.
5. **Compile** an engine from `Engines/` (or a preset from `Presets/`). A clean
   build has 0 errors / 0 warnings.
6. **Attach** the compiled EA to the intended symbol/timeframe chart (or use a
   preset that already targets one). Enable AutoTrading.

> Tip: keep files **closed in MetaEditor** while they are being edited outside
> the editor, so a stale editor buffer cannot overwrite changes on save.

## Suite conventions

- **Closed‑bar evaluation.** Signals are read from the last *closed* bar
  (`shift = 1`); the forming bar is never used for a decision.
- **POINTS everywhere.** All distance‑based inputs are in *points*
  (`_Point` units for the symbol), not pips or price.
- **Unified UTC trading day.** Daily risk limits and daily reporting roll over on
  one shared UTC clock (see `Helpers/KurosawaTime.mqh`) — broker‑timezone and DST
  independent.
- **Risk‑first sizing.** Position size is derived from risk; if the broker data
  or stop distance is unusable, the EA stands down rather than oversizing.

---

© Shouki Inc. — 1KPIPS. Educational/experimental software; **not investment advice.**
