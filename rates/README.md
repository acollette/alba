# alba-rates

Rates layer for **Alba** (on-chain revolving credit, settled by schedule). Two live data
sources, one tiny zero-dependency Node service:

1. **Floating-rate band — The Graph.** One Messari-standardized lending query — the *same
   query text* — against four protocols on Base through the decentralized gateway.
   **Same query, four protocols, one chain, zero per-protocol code.** That's the point of
   standardized schemas: adding a fifth protocol is one line of config, not an integration.
2. **Fixed-rate benchmark — Morpho Midnight.** The live cbBTC/USDC fixed-rate curve, read
   from Midnight's public API over indexed on-chain order books (core contract on Base:
   `0xadedd8ab6de832766fedf0fac4992e5c4d3ea18a`), ticks converted to zero-coupon prices and
   implied APRs. Alba facilities are priced as a spread over this curve.

## Subgraphs consumed (Messari standardized lending schema, Base, decentralized network)

| Protocol | Query ID |
|---|---|
| Aave v3 | `D7mapexM5ZsQckLJai2FawTKXJ7CqYGKM8PErnS3cJi9` |
| Compound v3 | `AwoxEZbiWLvv6e3QdvdMZw4WDURdGbvPfHmZRc8Dpfz9` |
| Moonwell | `33ex1ExmYQtwGVwri1AP3oMFPGSce6YbocBP7fWbsBrg` |
| Seamless | `2u4mWUV4xS19ef1MbnxZHWLLMwdPxtVifH46JbonXwXP` |

Endpoint shape: `https://gateway.thegraph.com/api/<API_KEY>/subgraphs/id/<QUERY_ID>`

The one query (see `src/config.mjs`):

```graphql
{
  markets(where: {inputToken_: {symbol_in: ["USDC", "USDbC"]}},
          orderBy: totalBorrowBalanceUSD, orderDirection: desc, first: 5) {
    name
    inputToken { symbol }
    rates { rate side type }
    totalBorrowBalanceUSD
  }
}
```

## Run

```bash
cp .env.example .env   # add your Graph gateway API key
GRAPH_API_KEY=... node src/server.mjs
```

- `GET /api/rates` — everything (used by the Alba frontend)
- `GET /api/floating-band` — per-protocol APRs + the borrow-weighted composite
  (venues ≥ $1M borrow; SOFR-style discipline)
- `GET /api/midnight-curve` — depth-filtered, $25k-clip executable curve + labeled
  log-DF interpolation / flat-forward extrapolation for arbitrary tenors
- `GET /api/quote?tenor=90&ratioBps=15000` — the desk build-up: benchmark + gap-risk
  put (Black–Scholes on the collateral, maturity-only margining) + liquidity premium.
  Full methodology: `../md-files/PRICING.md`
- `GET /` — dashboard

All responses are computed from **live endpoints at request time** (90s cache); nothing is
mocked or checkpointed.

Part of the Alba project (ETHGlobal Lisbon 2026) — lives at `rates/` in the
[acollette/alba](https://github.com/acollette/alba) monorepo during the event; split to a
standalone repo at submission (`git subtree split --prefix=rates`). MIT.
