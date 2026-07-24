# chronos-rates

Rates layer for **Chronos** (on-chain revolving credit, settled by schedule). Two live data
sources, one tiny zero-dependency Node service:

1. **Floating-rate band — The Graph.** One Messari-standardized lending query — the *same
   query text* — against four protocols on Base through the decentralized gateway.
   **Same query, four protocols, one chain, zero per-protocol code.** That's the point of
   standardized schemas: adding a fifth protocol is one line of config, not an integration.
2. **Fixed-rate benchmark — Morpho Midnight.** The live cbBTC/USDC fixed-rate curve, read
   from Midnight's public API over indexed on-chain order books (core contract on Base:
   `0xadedd8ab6de832766fedf0fac4992e5c4d3ea18a`), ticks converted to zero-coupon prices and
   implied APRs. Chronos facilities are priced as a spread over this curve.

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

- `GET /api/rates` — everything (used by the Chronos frontend)
- `GET /api/floating-band` — per-protocol variable USDC borrow/supply APRs + min/max band
- `GET /api/midnight-curve` — maturity, days, implied APR, zero-coupon price per point,
  plus a 90d interpolation (the default Chronos draw tenor)
- `GET /` — dashboard

All responses are computed from **live endpoints at request time** (90s cache); nothing is
mocked or checkpointed.

Part of the Chronos project (ETHGlobal Lisbon 2026) — contracts repo:
[acollette/alba](https://github.com/acollette/alba). MIT.
