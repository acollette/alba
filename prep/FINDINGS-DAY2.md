# Day 2 Phase 0 spike findings

## Midnight spike ✅ GREEN (~35 min)

The Morpho Midnight benchmark curve is fully readable, live:

- **Core contract on Base mainnet:** `0xadedd8ab6de832766fedf0fac4992e5c4d3ea18a`
  (code verified on-chain; also returned by their API in every offer).
- **REST API** (no key needed): `https://api.morpho.org/v0/midnight/`
  - `GET /markets?chainId=8453` — 98 live markets; ~70 USDC-loan, cbBTC-collateral
    (LLTV 86%), maturities weekly/monthly out to 2027-07.
  - `GET /books/{marketId}/{asks|bids}/takeable-offers` — live order book with ticks.
- **Tick → price (zero-coupon):** logistic curve, NOT simple exponential:
  `price = 1 / (1 + exp(LN_ONE_PLUS_DELTA × (MAX_TICK/2 − tick)))`
  with `LN_ONE_PLUS_DELTA = 4987541511039073e-18`, `MAX_TICK = 6744`
  (from `@morpho-org/midnight-sdk` v1.3.0 `TickLib`). APR = (1/price − 1) × 365d/T.
- **Live curve at spike time (best-ask implied APR):**
  7d ≈ 2.76% · 35d ≈ 3.36% · 63d ≈ 3.89% — real upward-sloping term structure,
  meaningful depth at the ~1-month point (~300k units).
- Plan: rates service reads the API (60–120s cache) and quotes "Midnight Xd: y% —
  this offer: +z bps" in the facility card. On-chain read possible via the core
  contract if we want the flex; API is the pragmatic Day 2 path.

## Graph spike ✅ GREEN (key fixed)

Live results, one identical query, four protocols, all Base, all via gateway:
aave-v3 USDC borrow 4.35% ($152M borrowed) · compound-v3 3.90% ($298M) ·
moonwell 14.58% ($13M) · seamless 1.05% (small). Floating band (majors): ~3.9–4.35%.
Note: some markets return `name: null` — service must null-guard. Original notes:

- **Morpho Blue has NO Messari-standardized subgraph** (Base or queryable mainnet).
  Swap: **Moonwell** (and optionally Seamless) — BOTH on Base. Upgraded story:
  "same query, four protocols, one chain."
- Messari decentralized-network query IDs (Base), from
  `messari/subgraphs/deployment/deployment.json`:
  - aave-v3-base:      `D7mapexM5ZsQckLJai2FawTKXJ7CqYGKM8PErnS3cJi9`
  - compound-v3-base:  `AwoxEZbiWLvv6e3QdvdMZw4WDURdGbvPfHmZRc8Dpfz9`
  - moonwell-base:     `33ex1ExmYQtwGVwri1AP3oMFPGSce6YbocBP7fWbsBrg`
  - seamless-base:     `2u4mWUV4xS19ef1MbnxZHWLLMwdPxtVifH46JbonXwXP`
- THE query (identical for all four): `markets(where:{inputToken_:{symbol_in:["USDC","USDbC"]}})
  { name inputToken{symbol} rates{rate side type} totalBorrowBalanceUSD }`
- Gateway URL shape: `https://gateway.thegraph.com/api/<KEY>/subgraphs/id/<QUERY_ID>`
- Current blocker: gateway returns "auth error: API key not found" — likely a
  Studio DEPLOY key was created instead of an API key (API Keys tab in sidebar).
