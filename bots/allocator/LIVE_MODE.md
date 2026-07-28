# LIVE_MODE.md — TODO spec for wiring the allocator live (WS5 → live)

Status: **specification only, no live-mode code exists.** The dry-run bot
(`allocator.mjs`, see README.md) stays the decision engine unchanged; live mode
replaces the *simulated* `buy` / `redeem` / `rebalance` actions with
transactions through the deployed contracts. Everything below is derived from
the WS5 handoff (README "Dry-run → live"), `md-files/MIDNIGHT_INTEGRATION.md`
(Q2/Q3), and the deployed `MidnightSleeve` source — re-verify signatures
against `contracts/src/vault/` before implementing.

## 1. The transactions live mode submits

All vault-side calls are made by the **allocator hot key** (holds
`ALLOCATOR_ROLE` on the vault — see the address book from
`script/DeployVault.s.sol`).

| Decision entry | On-chain call | Notes |
|---|---|---|
| `buy` | `MidnightSleeve.buy(offer, ratifierData, units, maxAssets)` | allocator-only; see §2 |
| `redeem` | `MidnightSleeve.redeem(marketId)` | permissionless crank; claims `min(effective credit, FCFS pool)` |
| `rebalance` (to buffer) | `AlbaVault.allocate(bufferSleeve, assets)` | allocator-only, cap-checked on-chain |
| `rebalance` (from buffer) | `AlbaVault.deallocate(bufferSleeve, assets)` | clamps, never reverts on partial |
| fund the Midnight sleeve before a buy | `AlbaVault.allocate(midnightSleeve, assets)` | `buy` spends the sleeve's idle USDC |

Exact sleeve signature (from `contracts/src/vault/MidnightSleeve.sol`):

```solidity
function buy(Offer calldata offer, bytes calldata ratifierData, uint256 units, uint256 maxAssets)
    external onlyRole(ALLOCATOR_ROLE) returns (uint256 cost);
```

- `units` — face units to take (1 unit = 1e-6 USDC of par); partial fills of an
  offer are first-class.
- `maxAssets` — the bot's own cost bound for this fill. The sleeve reverts if
  `take()`'s actual settlement cost exceeds it. Set it to the quoted cost plus
  a small tolerance (rounding is against the taker); do NOT set it to
  `type(uint256).max` — it is the bot's slippage/fee-activation guard.
- Reverts to expect and treat as "refetch book, retry": `OfferExpired`,
  `OfferNotStarted`, `ConsumedUnits`/`ConsumedAssets` (raced by another taker),
  `RatifierFailed` (maker cancelled the root), `SellerIsLiquidatable`, plus the
  sleeve's own guards (`CostAboveMax`, `YieldTooLow`, `MarketCapExceeded`,
  `AbovePar`, `MarketMatured`, `MarketNotAllowed`).

## 2. Calldata the bot must fetch from the REST API

Midnight is an **off-chain order book with on-chain settlement**: offers are
signed maker intents distributed by the API, not on-chain state. For each fill
the bot needs exactly two opaque blobs, both served ABI-ready by:

```
GET https://api.morpho.org/v0/midnight/books/{marketId}/asks/takeable-offers
```

- **`offer`** — the full `Offer` struct (15 fields, including the embedded
  `Market` struct with its `collateralParams[]` array). Forward it verbatim;
  the sleeve validates it by hashing `offer.market` against the curator
  allow-list (`marketIdOf[keccak256(abi.encode(offer.market))]`), so any field
  mutation makes the fill revert `MarketNotAllowed`. Only take `asks`
  (`offer.buy == false`); the sleeve rejects the wrong side.
- **`ratifier_data`** — opaque maker-ratification proof bytes (Merkle proof for
  SetterRatifier, + EIP-712 sig for EcrecoverRatifier). Never parse, never
  cache across re-quotes — forward verbatim.

Optional server-side routing for sizing:
`GET /books/{id}/asks/quote?assets=…` returns an ordered fill list +
`average_worst_price` — useful for choosing `units`, but the on-chain
`maxAssets` + curator guards are what actually protect the vault.

**API-outage fallback:** raw offers remain valid until expiry/cancel; cache the
last-fetched takeable set (with fetch timestamp) so a short API outage does not
strand a redemption-heavy cycle — but never submit a cached offer without the
pre-submit re-quote below succeeding, so in practice a dead API means "no new
buys", which is the safe failure mode.

## 3. Pre-submit re-quote rule (mandatory)

Live offers are short-lived (~30 h windows observed; legs can be cancelled by
the maker at any second via `setConsumed` or root un-ratification) and are
consumed FCFS by other takers. A decision computed at scan time is therefore
stale by submit time. Before EVERY `buy` submission:

1. **Re-fetch** the takeable-offers list for the target market (fresh
   `offer` + `ratifier_data`; do not reuse scan-time bytes).
2. **Re-validate the window:** `start ≤ now` and `expiry ≥ now + margin`
   (margin ≥ 60 s to cover inclusion latency; skip offers expiring sooner).
3. **Re-check remaining size:** re-read `consumed(maker, group)` on-chain (or
   trust the API's remaining field) and clip `units` to it.
4. **Re-score:** recompute the offer's yield vs the current hurdle
   (benchmark + `minSpreadBps`) and re-run the sizing constraints on *current*
   `state.json`. If the best price moved outside policy, log a `skip` and drop
   the decision — never "chase" a filled level to the next tick without
   re-scoring it.
5. **Set `maxAssets` from the re-quote**, not the original scan:
   `ceil(units × price) + ε` (ε covers a possible settlement-fee activation up
   to the ~4 bp 30 d cap; larger deviations should fail on-chain).
6. **Submit with a deadline:** if the tx is not mined within N blocks
   (config), replace-by-fee or abandon; on any revert, re-enter at step 1 at
   most `maxRetries` times per cycle, then log and move on.

Staleness budget: total time from re-quote to submission must stay under ~30 s;
if it is exceeded (slow RPC, gas estimation retries), restart from step 1.

## 4. Allocator key threat model

The allocator key is **hot by design and power-limited by construction**. What
a full key compromise can and cannot do:

Cannot (on-chain guards, curator/admin-controlled):
- touch user funds or shares — the allocator has no transfer surface; USDC only
  ever moves vault ↔ registered sleeves ↔ Midnight core;
- buy on a non-allow-listed market (`marketIdOf` binding, curator-set);
- pay above par, above `maxBuyAssets` per fill, or below the curator's
  `minYieldWad` floor;
- exceed the per-market face cap or a sleeve's vault-level cap;
- sell paper (emergencySell is CURATOR-only), change any cap/fee/registry
  entry, or unpause.

Can (accepted, bounded damage):
- execute *in-policy but ill-advised* trades: buy the worst price that still
  clears the yield floor, up to `maxBuyAssets` per tx and the market/sleeve
  caps in aggregate — bounded loss ≈ (worst-allowed vs best-available price) ×
  cap, tuned via the guarded-launch caps schedule (VAULT_RUNBOOK.md);
- churn allocations between vault idle and sleeves (grief: buffer yield drag,
  gas), including deallocating the buffer to vault idle (funds stay in the
  vault — not a theft path);
- burn its own gas; go silent (see liveness below).

Response to suspected compromise: GUARDIAN pauses (blocks `allocate` and user
flows; `deallocate` deliberately still works — recovery moves funds toward the
vault), ADMIN revokes `ALLOCATOR_ROLE` (enumerable on-chain), new key is
granted. Practice this drill before live mode ships.

**Liveness is the flip side:** a dead bot means no redemptions cranked (NAV
unaffected — accretion is on-chain math — but liquidity honesty degrades to
buffer-only) and no buys. `redeem()` being permissionless is the escape hatch:
anyone can crank claims. Run the bot under systemd with alerting on missed
cycles (README ops notes).

Key handling requirements for the live PR: key in an env var/secret store, not
in `config.json`; a distinct key per environment; the key holds only gas ETH;
spending alarms on the address.

## 5. Reconciliation watchdog (state.json vs on-chain)

Dry-run's `state.json` becomes a *shadow book* in live mode. Every cycle,
BEFORE acting, reconcile it against chain truth and refuse to trade on
divergence:

| Shadow field | On-chain truth | Tolerance |
|---|---|---|
| per-market lot {face, cost} | `MidnightSleeve.book(id)` → `(units, cost, …)` | exact after event replay |
| position existence | `IMidnight.credit(id, sleeve)` / `updatePositionView` | `credit ≥ book.units` (pendingFee/slash pending) |
| sleeve idle | `USDC.balanceOf(midnightSleeve)` | exact |
| buffer balance | `bufferSleeve.totalAssets()` | interest drift only (monotone up) |
| vault idle | `USDC.balanceOf(vault)` | exact |
| NAV | independent recompute: idle + Σ book accretion + buffer, cross-checked vs `vault.totalAssets()` | ≤ 1e-6 relative |
| liquidity | `vault.liquidAssets()` ≤ `vault.totalAssets()` | invariant, alert on violation |

Event sources (the contracts were extended for exactly this): `Bought`,
`Redeemed`, `EmergencySold` on the sleeve carry the **post-operation book
state** (`bookUnits`, `bookCost` after slash re-sync and pro-rata scaling), so
the watchdog can rebuild exact lot-level state from logs alone — a mid-run
crash recovers by replaying events since the last checkpoint, no RPC state
archaeology.

Alert (Telegram, per VAULT_PLAN §4) and **halt trading** (redeem cranks may
continue) on any of:
- shadow-vs-chain mismatch beyond tolerance (likely: missed event, reorg,
  manual curator action such as `emergencySell`);
- NAV recompute vs `totalAssets()` divergence (accounting bug — page a human);
- a Midnight `Liquidate` event with `badDebt > 0` on an allow-listed market
  (socialized slash: expect the book haircut, verify the next `buy`/`redeem`
  re-sync matches prediction);
- `SetFeeSetter` / `SetMarketSettlementFee` / `SetMarketContinuousFee` events
  (fees activating: re-tune spread floors before further buys);
- vault paused, roles changed (`RoleGranted`/`RoleRevoked`), or sleeve
  registry changed while the bot holds stale config;
- `withdrawable(id)` stuck at ~0 for > 2 h past a maturity (liquidation stall
  — the main liveness tail, MIDNIGHT_INTEGRATION Q7).

## 6. Implementation order (when live mode is actually built)

1. Read-only reconciliation watchdog against the anvil profile of
   `DeployVault.s.sol` (mock Midnight) — prove event replay = state.
2. `redeem()` cranking on mainnet against a manually-bought test lot (the
   permissionless, zero-risk call).
3. Buffer rebalance (`allocate`/`deallocate`) under tiny caps.
4. `buy()` behind a `--live` flag + per-run spend ceiling, starting at
   `maxBuyAssets` ≪ caps, on the guarded-launch schedule (VAULT_RUNBOOK.md).
5. The compromise drill (§4) executed once on mainnet before caps are raised.
