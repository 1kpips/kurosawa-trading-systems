# Inputs/

Input schemas (`*_Inputs.mqh`) — the `input` declarations an engine exposes in
the MT5 "Inputs" tab. Keeping them here (separate from engine code) lets the
whole suite share **one consistent column layout**, so presets and tuning
spreadsheets line up across strategies.

## Contents

| File | Used by |
|---|---|
| `Trend_Inputs.mqh` | `Engines/TrendEA.mq5` |
| `RangeRevert_Inputs.mqh` | `Engines/RangeRevertEA.mq5` |
| `TrendPullback_Inputs.mqh` | `Engines/TrendPullbackEA.mq5` |
| `Archived/` | Schemas for retired engines; kept for reference. |

## Conventions

- **Units are POINTS** for every distance‑based input (`_Point` units), never
  pips or raw price.
- **Grouped by concern:** identity/meta, target symbol+timeframe, session, core
  strategy, execution tolerance, risk sizing, safety guards, exits.
- **Unused placeholders are kept on purpose.** Some inputs are neutral
  placeholders (default `false`/`0`) that keep the column layout aligned across
  the suite even when a given engine does not use them. They are grouped and
  labelled at the bottom of each file — do not delete them, or the shared layout
  breaks.
- **Tune per symbol and per session.** Defaults are starting points, not
  universal settings.
