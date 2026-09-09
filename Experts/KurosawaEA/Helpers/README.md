# Helpers/

Shared libraries used across the suite. Engines include the **single umbrella
header** (`KurosawaHelpers.mqh`); the rest are modular pieces grouped by
responsibility.

## Design rule

Each helper file must **compile on its own** and must not rely on symbols from
another helper. When two concerns genuinely must cooperate, they live in the
*same* file rather than cross‑including. The umbrella header controls include
order.

## Contents

| File | Purpose |
|---|---|
| `KurosawaHelpers.mqh` | Umbrella include — the one entry point engines pull in; also the on‑chart EA label. |
| `KurosawaTime.mqh` | UTC (`TimeGMT`) clock, session‑window checks (fixed offset, no DST auto), and the unified trading‑day helpers (`TradingDayNow` / `TradingDayYmd`). |
| `KurosawaExecUtils.mqh` | Execution primitives: buffer reads, new‑closed‑bar detection, spread check, broker stops/freeze validation, and position management (time‑stop, ATR trailing) addressed by ticket + magic. |
| `KurosawaExecutor.mqh` | The one shared order path (`Exec_PlaceTrade`: sizing → SL/TP → broker stops → filling mode → bounded send‑retry) and the flat‑state safety gate (`Gates_CheckFlat`). |
| `KurosawaRiskManager.mqh` | Daily equity baseline & loss limit, cooldown, loss‑streak, and risk‑based volume sizing that **stands down** rather than oversizing on bad data. |
| `KurosawaIndicatorFactory.mqh` | Creates and packs indicator handles for the engines. |
| `KurosawaTrack.mqh` | **Git‑ignored / local‑only** — not in the public repo. Reporting/tracking client that posts real win/loss results to the 1kpips API (bounded retry) with a local CSV mirror. |
| `KurosawaSignalPublisher.mqh` | Shared JSON + WebRequest publisher for the signal analyzers, with bounded retry. |
| `KurosawaSecrets.example.mqh` | **Committable template** for API keys. Copy to `KurosawaSecrets.mqh` and fill in. |
| `KurosawaSecrets.mqh` | **Git‑ignored** real secrets. Never commit this file. |

## Secrets

API keys are provided via `KurosawaSecrets.mqh` (git‑ignored). The committed
`KurosawaSecrets.example.mqh` is a placeholder template. Modules that need a key
(`KurosawaTrack`, the signal publisher) read it from there rather than
hard‑coding it, so no key ever reaches the repository.
