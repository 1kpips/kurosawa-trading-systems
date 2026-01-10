# Kurosawa Trading Systems

Systematic MetaTrader 5 (MT5) Expert Advisors and shared trading utilities designed for disciplined, session-based algorithmic trading.

The KurosawaEA suite prioritizes structural robustness, execution safety, and modular code over short-term curve fitting.

---

## Philosophy

The suite is built upon five core development pillars:

- **Closed-Bar Logic First**: All entry and exit signals are derived from confirmed candle data to eliminate repainting and ensure live-to-backtest consistency.
- **One EA, One Position**: Strategies enforce a strict one-position-per-EA rule managed via unique Magic Numbers to prevent internal signal conflict.
- **Session-Aware Execution**: Bots respect Tokyo, London, and New York liquidity windows using JST-based time control with full support for midnight session crossing.
- **Execution Safety Over Frequency**: Trades are gated by safeguards including dynamic spread filters, cooldown timers, and loss-streak breakers.
- **Shared Infrastructure**: Critical mathematical and broker-compliance logic is centralized in a shared library to ensure consistency across the portfolio.

---

## Repository Structure

The repository follows a clean, professional MQL5 directory layout:

```text
/Experts/KurosawaEA/
 ├── London_ScalpHigh_EURUSD_M1.mq5    # High-frequency EMA crossover
 ├── London_SwingTrend_EURUSD_H1.mq5   # Hourly trend following (ATR-based)
 ├── Tokyo_ScalpHigh_USDJPY_M1.mq5     # Micro-scalping with cost guards
 ├── Tokyo_DaytradeScalp_USDJPY_M5.mq5 # Intraday momentum (M5)
 ├── Tokyo_RangeRevert_USDJPY_M5.mq5   # BB Mean Reversion (Mid-band exit)
 ├── NewYork_SwingTrend_GBPUSD_H1.mq5  # ATR-managed swing trend
 ├── NewYork_RangeRevert_USDCAD_M5.mq5 # Volatility-filtered reversion
 └── D1_Signal_SMA_Slope.mq5           # Institutional bias publisher
 └── KurosawaHelpers.mqh               # Shared utility framework
```

## Shared Infrastructure (KurosawaHelpers.mqh)

The centralized helper library handles all execution-critical calculations:

* **Time Management**: JST/GMT conversions and session window validation.
* **Pip Math**: Robust price normalization and automated 3-digit (JPY) or 5-digit broker detection.
* **Broker Compliance**: Dynamic validation of StopsLevel and FreezeLevel to prevent order rejections.
* **Regime Detection**: Standardized ADX-based filters for mean-reversion gating.

---

## Strategy Archetypes

### Scalping (M1/M5)
* **Focus**: High-liquidity windows such as the Tokyo or London Open.
* **Cost Guard**: Includes "MinMove" filters requiring expected targets to exceed spread multiples.
* **Cooldown**: Mandatory wait periods between trades to prevent overtrading.

### Swing Trend (H1)
* **Trend Definition**: Multi-hour trend following using EMA (50/200) definitions.
* **Volatility Stops**: ATR-based SL and R-multiple TP targets that adapt to market noise.
* **Trailing**: Optional ATR-based trailing stops to lock in profits during extended moves.

### Range & Mean Reversion (M5)
* **Focus**: Low-volatility compression phases using Bollinger Bands and RSI extremes.
* **Mid-Band Exit**: Dynamically closes positions when price reverts to the mean (BB Mid).
* **Trend Suppression**: Uses ADX filters to block entries during strong trending regimes.

---

## Tracking & Telemetry

EAs feature built-in integration with external tracking APIs for performance logging:

* **Events**: Automated reporting of OPEN and CLOSE events.
* **Metadata**: Payloads include EA ID, Magic Number, Deal ID, and trade profit/loss.
* **Currency Intelligence**: Automatically detects account currency for accurate reporting.
* **Integrity**: Implements ID guards (g_lastClosedDealId) to prevent duplicate reporting.

---

## Usage & Safety

* **Timeframe Enforcement**: EAs validate chart timeframes on startup to prevent execution errors.
* **Spread Protection**: Entry is blocked if market spreads exceed defined thresholds.
* **Risk Stops**: Daily trade caps and consecutive loss limits act as automated circuit breakers.
* **Deployment**: Always test on demo accounts first. Ensure your tracking URL is allowlisted in MT5 settings.

---

## Disclaimer

**Risk Warning**: The information and code provided here do not constitute investment advice. FX trading involves significant risk and may result in losses. Signals and performance data are provided for reference only. 

**No Liability**: By using this code, you acknowledge that all trading decisions are your own responsibility. The authors and contributors of this repository are not responsible for any financial losses or gains incurred through the use of this software. Past performance does not guarantee future results.
