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
- Role: display context + plausibility bound for the fixed curve (fixed(T) should sit
  near expected average floating over T ± term premium). Never a mechanical input.

## 3. The facility rate build-up

```
rate(T) = benchmark(T)                      Midnight curve at the draw tenor
        + gap-risk spread(T, ratio, σ, ρ)   the price of maturity-only margining
        + liquidity/commitment premium      bespoke, non-fungible, committed capacity
        + settlement fee                    protocol constant
```

**Gap risk is an option price, not a fudge factor.** With maturity-only margining the
lender is short a European put on the collateral: for principal P, collateral ratio c,
repayment K = P(1+rT), auction recovery ρ (fraction of oracle the auction realizes),
the lender loses iff `ρ·S_T·c/S_0 < K/P`. Expected loss = `ρ · BSput(S0=c, K'=K/ρ, σ, T)`
per unit principal, annualized into bps. Defaults: **σ = 40%** (cbBTC annualized,
configurable), **ρ = 0.90** (auction clears between the 105% start and 85% floor).

**Sensitivity (90d, σ=40%, ρ=0.90, benchmark ≈ 3.5%):**

| Collateral ratio | Gap risk | Suggested rate |
|---|---|---|
| 130% | ~1,440 bps | ~18.4% |
| 140% | ~650 bps | ~10.4% |
| **150%** | **~290 bps** | **~6.9%** |
| 160% | ~130 bps | ~5.3% |
| 180% | ~26 bps | ~4.2% |

Two consequences we adopt:

1. **Facilities are sized at 150%** (not the earlier 130%): the model prices 130% as
   uneconomic for the lender at realistic vol. The demo facility quotes **8.20% at
   150%** — ~130bps over model, which is where real bilateral quotes sit (balance-sheet
   cost + margin).
2. The table IS the quantitative case for the roadmap: **continuous margining
   collapses the gap-risk column** — that's precisely what the Hedera-scheduled
   sentinel upgrade buys, in bps.

## Parameters (all configurable via /api/quote)

| Param | Default | Note |
|---|---|---|
| `volAnnual` | 0.40 | cbBTC annualized vol; swap in a live implied-vol feed in production |
| `recovery` | 0.90 | auction realization vs oracle (start 105%, floor 85%) |
| `liquidityPremiumBps` | 50 | non-fungible position + committed capacity |
| `settlementFeeBps` | 0 | protocol constant when enabled |
| clip / depth floor / venue floor | $25k / $5k / $1M | curve + composite construction |
