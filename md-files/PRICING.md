# Pricing methodology — how an Alba facility rate is built

Desk-grade conventions, implemented live in `rates/` (`/api/quote`). Simple-interest
ACT/365 throughout — the exact convention of the on-chain repayment formula
(`AlbaProgramBuilder.repaymentAmount: P × (1 + r·T/365)`).

## 1. Fixed benchmark: the Midnight curve, constructed properly

Raw Midnight order books are NOT a curve — touch prices in dust books are noise
(we observed a 63d "point" backed by a $48 book). Construction rules:

- **Executable pricing:** each maturity's price is the size-weighted average (VWAP) to
  fill a standard **$25k clip**, walking the live ask book best-first — never the top
  of book for $1.
- **Depth filter:** books that cannot fill **$5k** are excluded entirely.
- **Interpolation:** linear in **ln(discount factor)** vs time — equivalent to
  piecewise-constant forward rates, the standard short-end bootstrap. (Linear in APR
  can imply negative forwards; log-DF cannot.)
- **Extrapolation** past the last liquid point: carry the **last forward rate flat**,
  and label the output `flat-forward extrapolation from Nd` everywhere it appears —
  in the API, on the chart (dashed segment, hollow marker), and in the table.

## 2. Floating cross-check: a weighted composite, not a min–max

One Messari-standardized query across four Base lending venues via The Graph. But a
benchmark is not "min and max of whatever answered":

- **Liquidity floor:** venues under **$1M borrowed** are excluded from the headline
  (still shown, marked "below floor"). A $24k book must not move a benchmark
  anchored by ~$450M.
- **Volume-weighted MEDIAN:** the composite is the borrow-balance-weighted median of
  the included venues — the statistic SOFR actually is. Robust by construction: a small
  venue whose kinked rate model goes vertical in a utilization spike (Moonwell has
  printed >50% APR on ~$13M) cannot drag a benchmark anchored by ~$450M.
- **Stress flag:** a venue printing >3× the median is marked *stressed* — it stays in
  the table and in the median input, but is excluded from the DISPLAY band so one
  outlier doesn't set the chart scale. Benchmarks trim tails; they don't hide them.
- **Trailing average (SOFR-average style):** alongside the spot composite, a **90-day
  trailing composite** — simple mean of daily borrow-weighted medians, built from the
  same standardized schema's *daily snapshots* (time-series, still zero per-protocol
  code). The DeFi analog of the NY Fed's published 30/90/180-day SOFR averages: it
  smooths utilization spikes out of the cross-check. Tenor-matched to the 90d quote.
- Role: display context + plausibility bound for the fixed curve. Never a mechanical
  input — a fixed quote for the NEXT 90 days prices off the forward-looking curve
  (Midnight), not the past 90 days' average.

## 3. The facility rate build-up

```
rate(T) = benchmark(T)                Midnight curve at the draw tenor
        + residual risk premium       what continuous margining does NOT remove
        + liquidity/commitment premium bespoke, non-fungible, committed capacity
        + settlement fee              protocol constant
```

**Why there is no option-pricing term.** Alba runs CONTINUOUS margining: health
(`collateralValue ≥ 115% × accruedDebt`) is checkable by anyone at any time, the
Hedera sentinel checks it on schedule with no keeper, and a breach runs a
gentlest-first waterfall — full cure from the borrower's Aqua-authorized funds
(early close, **zero penalty**) → partial cure (health restored, draw lives) →
Dutch auction only for a drained borrower. The lender is therefore no longer short
a European put to maturity; the old Black–Scholes gap-risk term is gone **by
construction**, not by assumption.

**What replaces the model is a buffer, plus a parameter.** The remaining risk is
the move that can happen *between* two sentinel checks plus the auction's clearing
window, and oracle latency. That is absorbed by:
- the **margin buffer** — initial 130% vs maintenance 115% (the real risk knobs are
  this width and the check frequency, both facility-immutable), and
- a small **residual risk premium** (default 25bps, configurable) covering
  between-checks jumps and auction depth.

Current live build-up at 90d (benchmark ≈ 3.5%): benchmark + 25bps residual +
50bps liquidity ≈ **4.2% model rate**; the demo facility quotes **4.60%** — a
realistic bilateral margin over model.

## Reading the spread (benchmark 3.5% → facility 4.60%): three products, not one margin

1. **The benchmark is a shadow price, not an executable one.** The 90d point is a labeled
   flat-forward extrapolation from 35d — Midnight currently has NO executable 90d
   liquidity (books past 63d are dust). Alba's quote is the only executable 90d
   cbBTC/USDC rate in existence; a spread to a non-tradeable reference is not "width".
2. **Committed capacity ≠ spot borrowing.** A facility sells the borrower a free
   drawdown option — draw at 4.60% whenever, even after rates gap higher. TradFi prices
   that separately (commitment fee on undrawn, typically 30–50% of margin, PLUS drawn
   margin). Alba charges no commitment fee, so the option premium lives in the all-in
   drawn rate. Roadmap refinement: split into drawn margin + explicit undrawn
   commitment fee — the drawn rate then sits nearly on the model.
3. **The model's 75bps** = 25bps residual (younger liquidator network, between-check
   jumps) + 50bps lender illiquidity (bespoke, non-fungible position — no exit until
   the position NFT ships).

Calibration: IG TradFi revolvers run benchmark +100–200bps drawn plus undrawn fees.
At +109bps all-in with no undrawn fee, Alba prices TIGHT for the product class.

## Parameters (all configurable via /api/quote)

| Param | Default | Note |
|---|---|---|
| `residualRiskBps` | 25 | between-checks jump + oracle latency + auction depth |
| `liquidityPremiumBps` | 50 | non-fungible position + committed capacity |
| `settlementFeeBps` | 0 | protocol constant when enabled |
| initial / maintenance ratio | ≥137.0% / <128.2% (= Aave v3 Base cbBTC LTV 73% / LT 78%, read live via the standardized Graph query; fork tests use round 130/115) | facility-immutable; the margin buffer |
| clip / depth floor / venue floor | $25k / $5k / $1M | curve + composite construction |
