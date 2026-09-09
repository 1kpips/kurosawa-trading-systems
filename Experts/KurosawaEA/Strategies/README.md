# Strategies/

Pure **signal‑evaluation modules** (`.mqh`). Each module answers one question —
*given closed‑bar data, is there a signal, and in which direction?* — and
nothing else.

> These modules are published in full, and so are the tuned values that drive
> them (`../Inputs/`, `../Presets/`, and the version pages on 1kpips.com).
>
> What is deliberately **not** here is design commentary — why a threshold sits
> where it does, what was tried and rejected. That belongs with the backtest
> record on the site, where it comes with evidence attached, rather than as a
> claim in a code comment.

## Module contract

- **Self‑contained.** No dependency on other Kurosawa helpers; uses only MQL5
  built‑ins.
- **Closed‑bar only.** Evaluates at `shift = 1` (or greater); never the forming
  bar.
- **No side effects.** No trade execution, no risk sizing, no session/spread
  gates, no live market reads — those belong to the engine. Values it needs
  (e.g. spread) are passed in, so evaluation is deterministic and reproducible.
- **Typed result.** Returns a result enum (OK / a specific block reason / data
  error) plus a filled signal struct. Non‑finite indicator reads (NaN/Inf) are
  rejected up front.
- **Two entry points per module:** a `*_EvaluateValues(...)` that takes plain
  numbers (unit‑testable), and a `*_EvaluateHandles(...)` adapter that reads
  indicator buffers and calls the values form.

## Contents

| File | Role (high level) |
|---|---|
| `Trend.mqh` | Trend‑following signal module. |
| `RangeRevert.mqh` | Mean‑reversion signal module. |
| `TrendPullback.mqh` | Trend‑with‑pullback signal module. |
| `Archived/` | Retired modules kept for reference; not part of the current product. |
