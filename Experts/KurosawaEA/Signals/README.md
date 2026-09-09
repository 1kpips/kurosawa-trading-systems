# Signals/

Signal‑only **analyzers** (`.mq5`). These attach to a chart, evaluate the last
closed **D1** bar, and publish a direction + strength to the 1kpips **Signals**
page. They **place no trades** — they only analyze and report.

> These analyzers run on the owner's local MT5 and place no trades. The scoring
> rules are in the source alongside this file — direction, strength and the
> gates behind them are all readable. The API key they post with is not: it
> lives in the git-ignored `../Helpers/KurosawaSecrets.mqh`.

## Contents

| File | Publishes |
|---|---|
| `D1_Signal_Trend.mq5` | A daily trend read (direction + strength). |
| `D1_Signal_Breakout.mq5` | A daily breakout read. |
| `D1_Signal_SMA_Slope.mq5` | A daily SMA‑slope read. |

## How they work (shape only)

- **Closed‑bar, once per day.** Each EA fires when a new closed D1 bar appears,
  computes a direction (`LONG` / `SHORT` / `FLAT`) and a `0–100` strength, and
  posts once for that bar.
- **Shared publisher.** JSON building, the HTTP `POST`, and the bounded retry
  live in `../Helpers/KurosawaSignalPublisher.mqh`; each analyzer just fills a
  payload and calls it. This keeps the three EAs free of duplicated networking
  code.
- **Secrets + WebRequest.** The API key comes from the git‑ignored
  `../Helpers/KurosawaSecrets.mqh`, and the reporting host must be allowlisted in
  *Tools → Options → Expert Advisors → Allow WebRequest*.

## Signals vs. Track Record

The Signals page reflects **market response** as read by these analyzers — it is
*not* a prediction and *not* a trade log. Executed trades and their real results
are reported separately by the trading engines to the EA Track Record page.
