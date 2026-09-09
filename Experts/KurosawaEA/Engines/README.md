# Engines/

Trading Expert Advisors (`.mq5`). An engine is a **thin orchestrator** — it
wires together the reusable pieces and owns no strategy logic of its own:

1. **Gates** — session window, spread, cooldown, daily loss limit, loss‑streak,
   max‑trades/day, existing‑position check (`Gates_CheckFlat`).
2. **Signal** — delegates to a pure module in [`Strategies/`](../Strategies/),
   evaluated on the last closed bar.
3. **Execution** — hands the trade to the one shared order path,
   `Exec_PlaceTrade` (sizing, SL/TP, broker stops, filling mode, send‑retry).

Each engine also keeps a per‑day diagnostic tally and rolls it on the unified
UTC trading day.

## Contents

| File | Purpose |
|---|---|
| `TrendEA.mq5` | Trend‑following engine. Requires a take‑profit. |
| `TrendPullbackEA.mq5` | Trend‑with‑pullback engine. Requires a take‑profit. |
| `RangeRevertEA.mq5` | Mean‑reversion engine. Supports a mid‑band exit (TP optional). |
| `Archived/` | Retired engines kept for reference; not part of the current product. |

## Notes

- Engines include the single umbrella header `../Helpers/KurosawaHelpers.mqh`.
- Cooldown / max‑hold timing uses broker time (`TimeCurrent`) to match recorded
  trade timestamps; only the **day boundary** uses the unified UTC clock.
- Inputs come from the matching schema in [`Inputs/`](../Inputs/).
