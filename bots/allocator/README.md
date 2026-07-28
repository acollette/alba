# Alba allocator bot — WS5, **DRY-RUN ONLY**

The off-chain brain of the v1 vault (VAULT_PLAN.md §4), running in paper-trading
mode against **live Base mainnet reads**: it fetches the real Morpho Midnight
books and the floating benchmark, scores every standing borrower offer, applies
the ladder policy, and logs exactly what it **would** do — buys, redemptions,
buffer rebalances, NAV — while evolving a simulated portfolio in `state.json`.

**No keys. No transactions. No contracts.** Live mode arrives with WS3
(`MidnightSleeve`) — until then every `buy`/`redeem`/`rebalance` line is a
decision record, not an action. The point is to validate the buying strategy on
real market data while the Solidity is still being written.

Zero dependencies (Node ≥ 18, built-in `fetch`/`node:fs` only). Reuses the
`rates/` fetchers read-only via relative imports (`fetchMidnightCurve`,
`fetchFloatingBand`, `fetchTrailingComposite`, config constants).

## Which side of the book we trade (important)

Midnight books are zero-coupon-bond order books in price space. Verified against
live offer objects (`offer.buy` flag):

| API side | `offer.buy` | Maker is a… | Takeable by | Allocator's use |
|---|---|---|---|---|
| `asks` | `false` | **borrower** selling paper (taking a fixed-rate loan) | a **lender** (us) | **the only executable side** — we lend by lifting asks: pay `price` × face now, receive par at maturity |
| `bids` | `true` | **lender** bidding to buy paper | a borrower | context only: competing lend demand; never executable by us |

Note this corrects the hackathon-era shorthand "take standing borrower bids":
borrowers' standing orders live on the **ask** side. The rates curve's
`lend-floor` points are **bid-side** marks — indicative lender demand, not
something the vault can fill. Every decision entry labels the side explicitly.

Maker offers are short-lived signed intents (`start`/`expiry` windows of hours);
the bot drops expired ones before scoring. The API returns asks in
taker-priority order (lowest price = highest yield first), which the bot
re-asserts by sorting.

## Running it

```sh
node bots/allocator/allocator.mjs             # one decision cycle (cron-safe)
node bots/allocator/allocator.mjs --loop 300  # a cycle every 300 s
node bots/allocator/allocator.mjs --reset     # wipe & re-seed the simulated book
```

Optional: `export GRAPH_API_KEY=…` (same key as `rates/`) to use the live
borrow-weighted-median floating composite + 90d trailing as the benchmark.
Without it the bot uses `fallbackFloatingAprPct` from config and says so in the
`benchmark` log line — no secrets are required for dry-run.

Cron example (every 15 min): `*/15 * * * * cd <repo> && node bots/allocator/allocator.mjs >> /tmp/alba-allocator.log 2>&1`

Safe on cron: a `state.json.lock` file makes runs single-flight (a second
concurrent invocation exits immediately; a lock older than `staleLockMinutes`
is treated as a crash leftover and stolen). Runs are idempotent — if the market
and clock haven't moved, a re-run changes nothing.

Test flags (used by the harness, handy for what-if runs without touching the
real book): `--config <path> --state <path> --log <path>`.

## The decision cycle (each run)

1. **Benchmarks** — floating composite (Graph, or config fallback) + spread
   floor ⇒ the hurdle rate; Midnight curve fetched for context via `rates/`.
2. **Buffer accrual** — simulated MetaMorpho interest since the last run.
3. **Maturities** — lots past maturity: face → par → idle (`redeem` entries;
   live mode will submit the sleeve's `redeem()`).
4. **Market scan** — every USDC/cbBTC Midnight market (cursor-paginated),
   ask-side book per market; filters: tenor window, $5k dust floor on depth.
5. **Score & size** — per market: ask levels that clear the hurdle, then clip =
   min(max single buy, bucket room, per-maturity AUM cap, % of visible depth,
   spendable cash, eligible depth). Clips under the $5k dust floor are skipped
   with the binding constraint named. Survivors become `buy` entries with the
   exact fills (tick, price, maker) the bot would lift.
6. **Buffer rebalance** — idle ↔ buffer toward `bufferTargetPct` of NAV
   (tolerance band avoids churn).
7. **NAV** — amortized-cost accounting: each lot at purchase price + linear
   accretion to par (deterministic, oracle-free — the vault's own method);
   share price, ladder weights, delta since last run.

## Config reference (`config.json`)

`_`-prefixed keys are inline documentation; the bot ignores them.

| Knob | Default | Meaning |
|---|---|---|
| `simulatedAumUSDC` | 100000 | paper-trading AUM seeded on first run / `--reset` |
| `buckets[]` | 0–14d 20% · 15–45d 35% · 46–90d 25% | ladder targets as % of NAV; a lot migrates buckets as it ages |
| `bufferTargetPct` | 20 | MetaMorpho buffer target, % of NAV (weights + buffer = 100) |
| `bufferTolerancePct` | 3 | no rebalance while buffer is within this % of NAV of target |
| `minSpreadBps` | 75 | required spread of bond YTM **over the floating benchmark** before an ask is worth lifting |
| `perMaturityMaxPctOfAum` | 10 | concentration cap per maturity date |
| `perMaturityMaxPctOfBookDepth` | 25 | never take more than this share of a book's visible ask depth per run |
| `maxSingleBuyUSDC` | 10000 | max cash per buy decision |
| `minClipUSDC` | 5000 | dust floor: sized clips below this are skipped |
| `minBookDepthUSDC` | 5000 | ask-side depth needed for a market to be considered |
| `minDaysToMaturity` / `maxDaysToMaturity` | 2 / 90 | tenor window |
| `fallbackFloatingAprPct` | 4.0 | benchmark when `GRAPH_API_KEY` is unset |
| `fallbackBufferSupplyAprPct` | 3.6 | simulated buffer APR when `GRAPH_API_KEY` is unset |
| `staleLockMinutes` | 10 | crashed-run lock recovery |
| `maxMarketPages` | 5 | pagination cap on `/markets` |

Yield convention: simple interest, ACT/365 — same as the rates curve and the
on-chain repayment formula.

## Reading the logs

Console output is the human view; `decisions.jsonl` is the record — one JSON
object per decision, append-only across runs:

- common fields: `ts`, `run`, `seq`, `type`, `summary` (the console line);
- `type`: `benchmark` · `accrual` · `redeem` · `skip` · `buy` · `rebalance` ·
  `no-op` · `nav` · `note`;
- `skip` carries `reason` (`tenor`, `no-executable-asks`, `below-hurdle`,
  `clip-below-dust-floor`, `no-bucket`) plus the full ask ladder
  (`askLevels[]`: tick, price, yield, size, maker, expiry) and the bid-side
  context (`competingLendBids`) so you can audit *why* nothing was bought;
- `buy` carries the sizing `constraints` object with the `binding` one named,
  the exact `fills[]`, and the resulting `lot`;
- `nav` carries the whole book: lots, ladder weights, share price, deltas.

Expect the most common line to be a `skip`: today's market has thin borrower
offers below the floating benchmark — "nothing worth buying, and here's why"
**is** the strategy working.

`state.json` is the simulated portfolio (idle, buffer, lots with
face/cost/maturity, running totals). Delete it or `--reset` to start over.
Generated files (`state.json`, `decisions.jsonl`, `*.lock`) are gitignored.

## Dry-run → live (WS3 dependency)

Live mode replaces the simulated actions with transactions through the vault's
`MidnightSleeve`/`MetaMorphoSleeve` within on-chain guards (curator floor
spread, per-maturity caps, max buy — the bot proposes, the contracts bound).
See the live-mode TODO in VAULT_PLAN.md §0/§4; the decision engine, policy
config, and logs here carry over unchanged.
