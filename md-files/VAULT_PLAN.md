# VAULT_PLAN.md — v1 build plan: the curated fixed-income vault

Scope: PRODUCT.md "v1" — an ERC-4626 USDC vault with two sleeves (direct Midnight
paper + MetaMorpho floating buffer), pure curation, no desk, no repo yet, minimal
audit surface. This document is the work breakdown for the multi-agent build.

**Note what v1 does NOT use: Aqua.** Sleeve 1 buys bonds for the vault's own
account; sleeve 3 is a 4626-in-4626 adapter. The Alba rails (facilities, escrow,
legs) return in v2 (repo sleeve). v1's job is AUM, track record, and the Midnight
integration — on the smallest possible trusted-code base.

---

## 0. The blocking unknown: Midnight on-chain trading mechanics

Everything in the hackathon READ Midnight (REST API). v1 must TRADE it. Before any
sleeve code, produce an integration spec answering:

- What is a "unit" on-chain? Token standard (ERC-1155 / ERC-6909 / custom
  per-market balance?), transferability, decimals, dust behavior.
- How does a taker fill a standing offer on-chain? Which contract, which function,
  what arguments (market id, offer/tick ids, amounts), partial fills, slippage
  expression. (Core contract: `0xadedd8ab6de832766fedf0fac4992e5c4d3ea18a`, Base
  mainnet; SDK: `@morpho-org/midnight-sdk` — read the SDK's write paths.)
- Redemption at maturity: claim function, timing (exact second vs claim window),
  who can trigger, what happens to unclaimed par.
- What happens to a unit if the underlying cbBTC borrower is liquidated before
  maturity (does par change? timing?).
- Fees on fill/redemption, if any.
- Whether ANY testnet deployment exists (assume no → mainnet-fork testing + small
  mainnet pilot; confirm).

Deliverable: `md-files/MIDNIGHT_INTEGRATION.md` + a fork-test proving one real
fill and one simulated redemption against pinned mainnet state. **All sleeve-1
work is blocked on this.**

## 1. Architecture

```
Depositors ──deposit/withdraw──▶ AlbaVault (ERC-4626, USDC)
                                   │  totalAssets = idle + Σ sleeve.totalAssets()
                     ┌─────────────┼──────────────┐
              MidnightSleeve   MetaMorphoSleeve   (idle USDC in vault)
              (bond lots,      (4626 adapter,
               amortized cost)  instant-ish liquidity)
Roles: owner (multisig+timelock) · curator (caps, sleeve registry, fees)
       · allocator (bots: rebalance + execute buys within caps) · guardian (pause)
Off-chain: allocator bot (extends rates/) — watches Midnight bids, enforces
strategy config, triggers buys/redemptions/rebalances; rates service = decision
inputs only (NO on-chain oracle in v1).
```

Design decisions (settled in ideation, restated as binding):

- **Accounting: amortized cost (pull-to-par), not mark-to-market.** Each bond lot
  is valued at purchase price + linear accretion to par. Deterministic NAV, no
  oracle, no manipulation surface — the money-market-fund trick. Enforced by
  policy: sleeve 1 is buy-and-hold; an early sale (curator-only escape hatch)
  realizes P&L at execution price. Mark-to-market arrives with the v2 oracle.
- **Withdrawal liquidity = honesty, not magic.** `maxWithdraw/maxRedeem` reflect
  liquid assets only (idle + MetaMorpho instantly-redeemable). The ladder policy
  (below) keeps a steady maturity stream; a withdrawal queue is v1.1 IF demand
  shows it's needed. Never promise instant exit from term paper.
- **On-chain guards, off-chain brains.** The bot picks trades; the contracts bound
  them: per-buy max price (= min yield) passed by allocator but checked against a
  curator-set floor spread over a reference; per-maturity concentration caps;
  global sleeve caps; max single-buy size. A rogue/buggy bot can only do
  small, in-policy trades.
- **Ladder policy (bot config, curator caps on-chain):** target buckets (e.g.
  ≤14d / 15–45d / 46–90d weights), per-maturity cap ≤ min(X% of AUM, Y% of that
  book's visible depth), min spread over the floating benchmark before a bid is
  worth taking.
- **Fees:** flat management fee (bps/yr, accrued as share dilution to
  feeRecipient). No performance fee in v1.
- **Base mainnet only** (Midnight exists nowhere else). Testing = pinned-fork;
  launch = guarded pilot with own capital and a hard AUM cap.

## 2. Contract inventory (the whole audit surface)

| Contract | Contents | Est. size |
|---|---|---|
| `AlbaVault.sol` | OZ ERC-4626 (decimals-offset inflation guard) + sleeve registry + caps + fee accrual + pause + roles | ~400 loc |
| `MidnightSleeve.sol` | lot table {face, cost, buyTime, maturity, marketId}; `buy()` with price/cap guards; `redeem()` at maturity; `totalAssets()` accretion; curator-only `emergencySell()` | ~350 loc |
| `MetaMorphoSleeve.sol` | thin 4626→4626 adapter, allow-listed target vaults | ~100 loc |
| (roles) | OZ AccessControl + TimelockController, no custom code | — |

Target: **< 900 lines of novel Solidity.** Anything pushing past that gets
challenged in review.

## 3. Test plan (Foundry, Base mainnet fork pinned)

- **T1 Vault core:** 4626 invariants (round-trip, preview*, limits), inflation
  attack vectors, fee math, pause, role matrix.
- **T2 Midnight sleeve:** real fill on forked mainnet book; partial fill; slippage
  guard rejects over-price; redemption at warp-to-maturity; lot accounting.
- **T3 NAV/accretion:** share price monotonic (modulo fees) under
  deposit/withdraw/buy/mature interleavings — fuzz + invariant suite.
- **T4 MetaMorpho adapter:** deposit/withdraw round-trip vs live vault; behavior
  at high utilization (withdraw revert path → maxWithdraw honesty).
- **T5 Liquidity honesty:** maxWithdraw == what actually works, under every mix.
- **T6 Caps & guards:** per-maturity cap, sleeve cap, floor-spread, max-buy;
  allocator cannot exceed any bound.
- **T7 Lifecycle sim:** 90-day warp ladder — deposits, weekly buys, maturities,
  redemptions, withdrawals; NAV vs hand-computed expectation.
- **T8 Adversarial:** rogue allocator, curator misconfig, MetaMorpho freeze,
  Midnight claim-window edge, donation attacks on both sleeves.

## 4. Allocator bot (extends `rates/`)

- Inputs: Midnight books (existing fetcher), floating benchmark + trailing
  composite (existing), vault state (new reads), strategy config file.
- Loop: score standing bids (yield vs benchmark + spread floor) → check ladder
  bucket room + caps → size vs book depth → submit `buy` with maxPrice → track
  lots → at maturity submit `redeem` → rebalance idle vs MetaMorpho buffer to
  target → alert on anomalies (NAV jump, failed tx, stale books).
- Modes: dry-run (log-only, runs against mainnet reads from day one — build this
  FIRST, it validates strategy before any contract exists), then live with keys.
- Ops: systemd/container, alerting to Telegram, state in sqlite/json, idempotent
  restarts.

## 5. Frontend (repurpose the desk terminal)

- **Vault page:** NAV, share price, blended APY, sleeve allocation, the maturity
  ladder (reuse curve-chart machinery), deposit/withdraw with honest liquidity
  display ("instant: $X; next maturities: …").
- **Transparency page:** every lot on-chain with Basescan links (the desk-terminal
  timeline pattern — our differentiator: a fund whose book is public).
- **Curator console** (roles-gated): caps, sleeve registry, fee — reuse
  wallet-derived-role pattern.
- Rates dashboard stays as the "why this yield" page.

## 6. Ops, governance, launch

- Multisig (owner) + 24–48h timelock on cap raises/sleeve additions; guardian
  pause is instant. Allocator key is hot but power-limited by on-chain guards.
- Deployment scripts + address book; monitoring = bot alerting + a watchdog that
  recomputes NAV independently.
- Launch path: internal review → invariant suite green → external audit
  (~900 loc) → mainnet deploy with hard cap (own capital only, e.g. $50–100k)
  → 4–6 weeks of clean operation → raise cap / open deposits → (Keyrock/Morpho
  conversations run in parallel on the live track record).

## 7. Work packages for the multi-agent build

| WS | Package | Depends on | Parallel? |
|---|---|---|---|
| WS1 | Midnight integration research → `MIDNIGHT_INTEGRATION.md` + proof-of-fill fork test | — | start first, blocks WS3/WS5-live |
| WS2 | `AlbaVault` core + roles + fees + tests T1 | — | yes |
| WS3 | `MidnightSleeve` + tests T2/T3 | WS1 | after WS1 |
| WS4 | `MetaMorphoSleeve` + tests T4 | — | yes (small) |
| WS5 | Allocator bot — dry-run mode first, live mode after WS3 | WS1 (partial) | yes |
| WS6 | Fork-test harness, invariant/fuzz infra, T5–T8 | WS2 interfaces | yes |
| WS7 | Frontend | WS2 interfaces stable | mid-build |
| WS8 | Docs, audit pack, deployment scripts, runbook | all | end |

Suggested wave order: **Wave 1** = WS1 + WS2 + WS4 + WS5(dry-run) + WS6(harness).
**Wave 2** = WS3 + WS5(live) + WS7. **Wave 3** = WS8 + audit + pilot.

Repo layout: `contracts/src/vault/` (new, beside existing src — hackathon
contracts stay untouched for v2), bots in `bots/allocator/` sharing `rates/src`
fetchers, frontend as a new route in the existing app.

## 8. Decisions still open (decide before Wave 2)

- [ ] Withdrawal model if buffer proves insufficient: queue vs epochs (default: ship buffer-only, decide on data)
- [ ] Which MetaMorpho vault(s) allow-listed (curator risk choice — pick 1–2 blue-chip)
- [ ] Management fee level + fee recipient entity
- [ ] Legal wrapper / regulatory shape (open from PRODUCT.md — does not block code, blocks marketing)
- [ ] Vault name/branding (Alba Yield? — bikeshed later)

## 9. Risks register (top 5)

1. **Midnight mechanics surprise us** (WS1 exists to de-risk; nothing else starts on sleeve 1 until the proof-of-fill passes).
2. **Thin books = little to buy** → AUM sits in floating sleeve, headline APY ≈ MetaMorpho + ε. Honest answer: size AUM to the opportunity; the vault is also the instrument that *deepens* the books.
3. **Withdrawal run vs term paper** → maxWithdraw honesty + ladder + buffer; never promise what the paper can't do.
4. **Allocator key compromise** → on-chain guards bound damage to in-policy trades; guardian pause; small caps early.
5. **Correlated crash impairing paper pre-maturity** (Midnight liquidation cascade) → v1 exposure is buy-and-hold small-cap AUM; the full haircut framework arrives with v2 — keep v1 caps modest accordingly.
