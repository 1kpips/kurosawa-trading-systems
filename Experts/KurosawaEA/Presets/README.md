# Presets/

Ready‑to‑attach **preset EAs**, grouped by trading session. A preset is a thin
wrapper that binds one strategy/engine to a specific **symbol, timeframe, and
session**, with inputs already tuned for that context — so you can attach it to
a chart without hand‑configuring every input.

## Naming convention

```
{Session}_{Strategy}_{Pair}_{Timeframe}
```

e.g. `London_SwingTrend_GBPJPY_H1`. Each preset is a pair of files:

- `*.mq5` — the compiled preset EA.
- `*.mqh` — that preset's input values.

## Folders

| Folder | Session | Example presets |
|---|---|---|
| `Tokyo/` | Tokyo | `Tokyo_SwingTrend_USDJPY_H1`, `Tokyo_RangeRevert_USDJPY_M5`, `Tokyo_ScalpHigh_USDJPY_M1`, `Tokyo_DaytradeScalp_USDJPY_M5` |
| `London/` | London | `London_SwingTrend_{EURUSD,EURJPY,GBPJPY}_H1`, `London_RangeRevert_EURGBP_M5`, `London_ScalpHigh_EURUSD_M1` |
| `New York/` | New York | `NewYork_SwingTrend_{AUDUSD,GBPUSD}_H1`, `NewYork_RangeRevert_USDCAD_M5`, `NewYork_TrendPullback_EURUSD_M5` |

## Notes

- Session timing uses a fixed UTC offset (no DST auto‑adjust — see
  `../Helpers/KurosawaTime.mqh`). Adjust the offset seasonally if you need to
  track a wall‑clock session precisely.
- Preset input values are **starting points**, not guarantees; re‑tune per
  broker, spread, and market conditions.
- Some presets target strategies kept under the `Archived/` folders; treat those
  as reference rather than the current product line.
