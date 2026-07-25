# Alba — committed credit, settled by schedule

**Revolving credit facilities and bespoke term loans as SwapVM programs: Aqua settlement
with zero signatures, Hedera-scheduled maturities via Axelar GMP, continuous margining
with cure-first liquidation — no bots, no keepers, no servers.**

> Midnight built the bond market; Alba is the revolver desk beside it — committed credit
> that draws on demand and settles itself, priced off Midnight's live curve.

Built solo at ETHGlobal Lisbon 2026. Everything below is backed by a green test or a
public transaction hash.

## Proven live (public testnets, fully autonomous after setup)

| # | What happened | Evidence |
|---|---|---|
| 1–3 | Hedera schedule executed BY THE NETWORK at its exact expiry second → Axelar GMP → executor pulls the repayment via **Aqua (no signature exists)** straight to the lender, releases collateral | e.g. schedule `0.0.9734648` @ `1784925648.266` → Base Sepolia tx `0x842b2e6e…4ca2` |
| 4 | **Sentinel cure**: oracle crashed −20% → the recurring self-rescheduling Hedera CHECK notices → pulls the debt from the borrower's pre-authorized cure leg → collateral home, **zero penalty, zero humans** — one transaction end-to-end | Base Sepolia tx `0xb6e9d53d…d284` (block 44,584,639) |
| 5 | Two-wallet run (distinct lender/borrower keys) of the full loop | current stack, see `STATUS.md` |

Full evidence tables with every hash: [`STATUS.md`](STATUS.md).

## The product in three layers

1. **Benchmark** — the live Morpho Midnight cbBTC/USDC fixed curve (order books →
   executable clip pricing) + a borrow-weighted floating composite from four Base lending
   protocols via one Messari-standardized Graph query. Methodology: [`md-files/PRICING.md`](md-files/PRICING.md).
2. **Instrument** — a committed USDC facility against cbBTC: zero collateral until drawn;
   each draw is one atomic tx (oracle-sized collateral in, cash out) against a standing
   Aqua order capped by the custom `_stopWhenCovered` opcode; per-draw zero-coupon
   maturities; Dutch-auction liquidation with partial fills that halt the moment the
   lender is whole. A term loan is a facility drawn once.
3. **Automation** — Hedera Schedule Service (HIP-1215) fires the maturity and the
   recurring health sentinel; Axelar GMP carries `(facilityId, drawId, epoch, action)` to
   Base; the executor settles or runs the liquidation waterfall. Aqua-mode authorization
   is a balance lookup — **machines can't sign; machines can read a ledger.** That is the
   load-bearing fact of the whole design.

### Continuous margining, cure-first

Health (`collateralValue ≥ 115% × accruedDebt`) is checkable by **anyone at any time**
(oracle-verified on-chain) and by the network itself on schedule. A breach runs the
gentlest path first:

1. **Full cure** — pull the accrued debt from the borrower's pre-authorized Aqua cure
   leg: early settlement, collateral home, zero penalty;
2. **Partial cure** — pull what's available; health restored → the draw lives on;
3. **Auction** — only for a drained borrower: signature-mode SwapVM Dutch auction
   (escrow signs via ERC-1271 — code signing for code), partial fills, stops at target,
   exact waterfall: lender → immutable 0.5% fee → surplus back to the borrower.

## Repo map (monorepo for the event)

```
contracts/   Foundry. TermRouter (SwapVM redeployment vs the OFFICIAL Aqua), 3 custom
             opcodes (_notBefore, _onlyTaker, _stopWhenCovered), AlbaOrderBuilder
             (single source of truth: ship() bytes ARE abi.encode(order)),
             CollateralEscrow (custody + margining + auction maker),
             AxelarSettlementExecutor, Hedera trigger/sentinel. 38 fork tests.
rates/       Zero-dependency Node service (MIT, self-contained — split out at
             submission via `git subtree split --prefix=rates`). Live Midnight curve
             (clip VWAP, log-DF interpolation) + one Messari query across four Base
             subgraphs + desk quote endpoint + validated dashboard.
frontend/    Next.js + wagmi/viem desk terminal. Lender/Borrower role tabs
             (auto-detected from the wallet), atomic draw, health meters, timeline
             merging Base events with Hedera mirror-node schedule IDs.
md-files/    Planning pack: ARCHITECTURE, OPCODES, PRICING, DEMO, PLAN.
STATUS.md    Gate-by-gate build log with every live-run evidence table.
prep/        Spike findings (swap-vm internals, Midnight tick math, day-2 spikes).
```

## Run it

```bash
git clone --recurse-submodules https://github.com/acollette/alba
cd alba/contracts/lib/swap-vm && yarn          # swap-vm resolves deps via node_modules
cd ../.. && forge test                          # 38 tests on a pinned Base mainnet fork
                                                # (uses public RPC; or set BASE_MAINNET_RPC)

# rates layer (needs a free Graph gateway API key)
GRAPH_API_KEY=... node ../rates/src/server.mjs  # :8787 — API + dashboard

# frontend
cd ../frontend && npm i && npm run dev          # desk terminal, defaults to the live stack
```

## Prize-track mapping

- **1inch / Build an Aqua App** — official Aqua deployment on the Base fork
  (`0x499943E7…36d31`); TermRouter is the explicitly-allowed modified SwapVM
  redeployment; three custom opcodes composed with native instructions (limit, dutch
  auction, salt, fees); Aqua-mode settlement is the product's core mechanism;
  continuous commit history from hour 1.
- **Hedera / Cross-Chain Automation Hub (+ Axelar)** — Schedule Service as the maturity
  clock AND a self-rescheduling health sentinel (one-shot HIP-1215 schedules re-arm
  themselves); schedule IDs surfaced in the UI from the mirror node; full
  trigger→execution loop proven live five times, zero keepers.
- **The Graph / Standardized products** — ONE Messari-standardized query, four
  protocols (Aave v3, Compound v3, Moonwell, Seamless), one chain, zero per-protocol
  code; live decentralized-gateway endpoints at demo time; `rates/` is MIT and
  self-contained for the standalone-repo split.

## Notes for reviewers

- **No official Aqua exists on any testnet** — the live Base Sepolia stack runs an
  UNMODIFIED Aqua deployment; the judged Aqua-app demo runs on the Base mainnet fork
  against the official address.
- Hedera EVM quirk (found live): `msg.value` is denominated in tinybars (8 dec) although
  the JSON-RPC layer speaks 18-dec weibars.
- Axelar quirk (found live): try/catch + relayer gas estimation can swallow an inner
  out-of-gas as success — the executor carries a `MIN_CHECK_GAS` loud-fail floor.
- swap-vm is source-available (`LicenseRef-Degensoft-SwapVM-1.1`); router redeployment is
  permitted by the 1inch brief. `rates/` is MIT.
