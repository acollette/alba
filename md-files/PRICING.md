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
- **Volume weighting:** the composite is the borrow-balance-weighted mean of the
  included venues — the same discipline that makes SOFR a volume-weighted statistic
  rather than a survey.
- Role: display context + plausibility bound for the fixed curve. Never a mechanical input.

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

## Parameters (all configurable via /api/quote)

| Param | Default | Note |
|---|---|---|
| `residualRiskBps` | 25 | between-checks jump + oracle latency + auction depth |
| `liquidityPremiumBps` | 50 | non-fungible position + committed capacity |
| `settlementFeeBps` | 0 | protocol constant when enabled |
| initial / maintenance ratio | 130% / 115% | facility-immutable; the margin buffer |
| clip / depth floor / venue floor | $25k / $5k / $1M | curve + composite construction |
