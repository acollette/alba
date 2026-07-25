# STATUS — gate tracking

## Hours 1–5: Spike + trigger leg

### Item 1 — Axelar/Hedera spike ✅ GREEN (~15 min)

**Hedera IS a supported Axelar GMP source chain on testnet.**
- Registry: chainId 296, axelarId `hedera`, chainType `evm`; gateway live on-chain (verified via Hashio RPC).
- Axelarscan GMP API: 1,005 messages with Hedera as source; **45 on the exact
  `hedera → base-sepolia` route, all `executed`** (recent activity ~1 day old).
- Scheduled contract calls live on testnet since v0.68 (HIP-1215, system contract `0x16b`).

| Contract | Hedera testnet (296) | Base Sepolia (84532) |
|---|---|---|
| AxelarGateway | `0xe432150cce91c13a887f7D836923d5597adD8E31` | same address |
| AxelarGasService | `0xbE406F0189A0B4cf3A05C286473D23791Dd44Cc6` | same address |

RPCs: `https://testnet.hashio.io/api` · `https://sepolia.base.org`. Chain ids: `"hedera"`, `"base-sepolia"`.

### Item 2 — live trigger leg 🟢 MANUAL LEG EXECUTED; scheduled leg in flight

- [x] Wallets funded; `SpikeReceiver` deployed Base Sepolia `0x8a3BDF1311504e2cf492382DcF6b3D6BE3a4c97F`
- [x] `AlbaTriggerSpike` deployed Hedera testnet (same address), funded 30 HBAR
- [x] **Manual dispatch EXECUTED end-to-end** — Hedera tx
      `0x80eca48ba7f61d89b6cf4bfb44bfd2c9bfaa68076d2b3381a97e6f464ae0e3bc` → Axelarscan
      status `executed` on base-sepolia. Gotcha captured: Hedera EVM denominates
      `msg.value` in TINYBARS (8 dec) though the RPC layer shows 18 — Axelar gas paid as
      2e8, and Axelarscan credits it correctly.
- [x] **SCHEDULED DISPATCH EXECUTED — keeper-free loop complete.** HSS schedule
      `0.0.9733816` (EVM `0x...009486b8`, created in tx `0xe0aa47b7...9a4a11`) was executed
      BY THE HEDERA NETWORK at exactly its expiry second (`executed_timestamp
      1784920405.111`); the resulting GMP message executed on Base Sepolia —
      `TriggerReceived` at block 44,576,146, tx
      `0xad12f6ab8f805f1f4ca004248c0265c274c88657c5656f0b91514bc6a3a317ce`.
      No keeper, no bot, no cron anywhere in the path. NO FALLBACK NEEDED.

**Demo evidence pack (Beat 3):**
| Step | Chain | Reference |
|---|---|---|
| Schedule created | Hedera | tx `0xe0aa47b7b5f49becc803953372baa986b9fbb54a545d1854913d6064769a4a11` |
| Schedule executed by network | Hedera | schedule `0.0.9733816`, ts `1784920405.111` (mirror node) |
| Manual dispatch (route proof) | Hedera→Base Sepolia | `0x80eca48b...ae0e3bc` → executed; event at block 44,575,949 |
| Scheduled dispatch executed | Base Sepolia | `TriggerReceived` block 44,576,146, tx `0xad12f6ab...a3a317ce` |

Quirk log: Hedera EVM denominates `msg.value` in tinybars (8 dec) although the JSON-RPC
layer uses 18-dec weibars — Axelar gas must be paid as e.g. `2e8`, not `2e18`.

## Hours 5–14: Foundry on Base mainnet fork ✅ ALL GREEN — 21/21 tests

Fork pinned to block 49,062,000; **official Aqua** `0x499943E74FB0cE105688beeE8Ef2ABec5D936d31`.

- ✅ swap-vm v1.0.1 dependency; its full suite 712/712; findings in `prep/FINDINGS.md`
- ✅ Test 1: ship→execute round trip (strategyHash == orderHash by construction —
  shipped strategy bytes ARE `abi.encode(order)`; single source of truth in `AlbaProgramBuilder`)
- ✅ Tests 2–4: `_notBefore` (reverts pre-T in swap AND quote), `_onlyTaker` (skips check in
  static context), `_stopWhenCovered` (cumulative cap, remainder-exact last fill, `OrderCovered`
  halt, staticcall never mutates fill accounting)
- ✅ Test 5: happy path — publish 300k → draw 100k + 50k → warp → executor settles repayment
  straight to lender (zero-in Aqua pull, **no signature anywhere**) → pro-rata collateral release
- ✅ Test 6: default path — drained borrower → pull reverts → auction armed → two partial fills
  at decaying price (assert p2 < p1 < start, > floor) → halts when lender whole → waterfall exact
  (debt → 0.5% immutable fee → surplus collateral to borrower)
- ✅ Item 10: `AxelarSettlementExecutor._execute` → `termRouter.swap()`; source validation;
  failed pull arms auction in the SAME tx (Test 7, gateway mocked on fork)

### Design decisions logged in prep/FINDINGS.md (as-built deviations)
1. Draw/maturity legs are **zero-amountIn exact-out Aqua pulls** (live Aqua balances make
   balance-ratio pricing drift; economics computed in the builder, zero-coupon).
2. Overfill **reverts with remaining** instead of clamping the taker-specified register
   (TakerTraits.validate pins it); last filler reads public `coveredAmount` for the remainder.
3. **Auction is signature-mode via ERC-1271** (escrow signs its own armed orders): Aqua push
   would inflate bid-side pricing and break the decay curve. Collateral capped by bounded allowance.

### Post-gate hardening (still Day 1; suite now 22/22)
4. **Atomic collateralized draws** — facility leg carries `_onlyTaker(escrow)`; the ONLY
   way to draw is `escrow.draw()`: pro-rata collateral in + zero-in facility pull out, one
   tx, proceeds to the borrower. Closed a real gap (uncollateralized direct draws); test
   asserts the direct path reverts `UnauthorizedTaker`. No upfront collateral ever —
   undrawn capacity costs the borrower nothing.
5. **Oracle-marked collateral** — `collateralForDraw = amount × ratioBps / freshPrice`
   (staleness + positivity guarded, constants immutable); `armAuction` marks its 105%
   start premium to the oracle AT ARM TIME (the registered `startBidRef` was price-stale).
   Honest token decimals in tests (USDC 6 / cbBTC 8); mock Chainlink-shaped feed on
   testnet (no cbBTC/USD feed on Base Sepolia); real Chainlink on Base mainnet is the
   production wiring.
6. Auction disarm pinned by tests: covered → `OrderCovered`; post-sweep → `BadSignature`
   at the signature layer + allowance zeroed + armed flag cleared.

## LIVE PRODUCT SETTLEMENT ✅ ×3 — full loop on real networks, real contracts

The spike receiver is retired: the live GMP payload drives the REAL
`AxelarSettlementExecutor`, which settles actual Aqua maturity legs on Base Sepolia.
The loop has now run **three times**, once per iteration of the stack — each time fully
autonomous after the schedule was set (no human, no keeper, no bot):

| Run | Stack | Hedera schedule (network-executed) | Settled on Base Sepolia |
|---|---|---|---|
| v1 | first wiring | `0.0.9734303` @ `1784923518.097` | block 44,577,701 · `0x89dab018...be3d495` |
| v2 | atomic draws | (schedule fired on v2 trigger) | block 44,578,399 · `0xf4bc86f3...bce9a1f` |
| v3 | + oracle marking | `0.0.9734648` @ `1784925648.266` | block 44,578,764 · `0x842b2e6e...24384ca2` |

Each run: schedule executed by the Hedera network at exactly its expiry second → trigger
dispatched `(facilityId, drawId, epoch, "SETTLE")` via Axelar GMP → executor validated the
source, pulled the 102,021.917808 USDC repayment via **Aqua — zero signatures** — straight
to the lender, and released the collateral (draw state RELEASED). In v3 the draw itself
had been sized by the on-chain oracle through `escrow.draw()` (atomic collateral+draw).

**Current live Base Sepolia stack (v3)** (Aqua = unmodified deployment
`0x29C10C31eB844D038A0Dc858997f8ADea1da3270` — no official testnet Aqua exists; the judged
1inch demo runs on the Base mainnet fork against the official
`0x499943E74FB0cE105688beeE8Ef2ABec5D936d31`):
TermRouter `0xF6Ad8045FdD4A07c2B6f36E9b5043d13a86598a7` · Builder `0xc9E8e751b8352287116d8F41665923d1775E1E3B`
· Executor `0xE31aDC4aE42aC04A0E8C88337F5Fb79fDF1bb0b7` · Escrow `0x8BbE713f6940434f809a87Fb37B6818dC1Abb410`
· Oracle `0xB6C296EDDBc0872Ff746DD88443cbf9160393645` · USDC `0x859199F7e042127D8e476c5BA5927B48b7c425f1`
· cbBTC `0x95745b9880f33f321e49063cc142465f81597dA4` · Hedera trigger `0xd4589b1a5d2Ed7259a1a85C6d98DF33f55f7e6FC`

**Ops notes:** EIP-170 forced the router/builder split (fork tests don't enforce code
size; router now 18.5KB). Hedera EVM `msg.value` is tinybars (8 dec) though the RPC layer
is 18-dec. HSS rejects byte-identical duplicate schedules (built-in replay safety —
mention to Hedera judges).

## END-OF-DAY-1 GATE ✅ PASSED — REAL PATH, NO FALLBACK

- Schedule fires live: ✅ Hedera network executed the schedule itself; message delivered
  and executed on Base Sepolia via Axelar GMP (evidence pack above).
- Message arrives → repayment settles via Aqua, no signature: ✅ proven on fork (Test 7);
  21/21 tests green.
- Remaining seam (Day 2): point the live GMP payload at the deployed
  AxelarSettlementExecutor instead of the spike receiver (same `_execute` shape).

## Day 2 items (NOT touched, per plan)
Midnight rates, Graph query, frontend, DealRegistry (thin), position NFT.

## Day 2 — continuous margining upgrade ✅ (suite 37/37)

- **Liquidation is continuous, not maturity-only**: permissionless oracle-verified
  `liquidate` + Hedera sentinel (`sentinelTick` — self-rescheduling HIP-1215 schedule,
  each network execution re-arms the next; keeper-free health checks).
- **Three-tier waterfall, gentlest first**: full cure from the borrower's Aqua-authorized
  cure leg (early close, ZERO penalty) → partial cure (health restored, draw lives) →
  Dutch auction only for a drained borrower. Cures reconcile into maturity settlement.
- Credit terms (rate 4.60%, term, 130% initial / 115% maintenance, auction params) are
  facility-immutable ON-CHAIN; maturity + repayment derive from them.
- Pricing simplified: Black–Scholes gap-risk term removed BY CONSTRUCTION (the margin
  buffer + check frequency replace the option premium); build-up = benchmark + 25bps
  residual + 50bps liquidity. Model 90d ≈ 4.2%; demo quote 4.60%.
- Rates layer (earlier today): executable Midnight curve ($25k clip VWAP, depth-filtered,
  log-DF interpolation, labeled extrapolation), SOFR-style weighted floating composite,
  live dashboard. Day-2 spikes green (Midnight API + tick math; 4 Base subgraphs).
- Pending: live redeploy (v4) + live sentinel/cure demo; frontend (facility card+timeline).

## LIVE SENTINEL CURE ✅ — the machine watches, and it is merciful

Stack v5 (gas-guarded executor `0x27f0caacf933Fb767b7c71D74e3D1b70c1519630`, escrow
`0x1cCe09DEa73c584D01B00D23b0DA36040e7C0EBa`, trigger v6
`0xeb3D736b5Ce06fe875011Bae95218BD1616bC2f8`):

1. cbBTC oracle CRASHED 100k → 80k on Base Sepolia (position: 104k value < 115% × 100k debt).
2. Sentinel started on Hedera (`sentinelTick` — dispatches CHECK + self-reschedules;
   recurrence proven on v4: 4 consecutive network-executed ticks).
3. The CHECK arrived via Axelar and — in ONE transaction, block 44,584,639,
   tx `0xb6e9d53d2048b725704a6994f73b0d979f5e7e5f26a9f92c3ff02e63757dd284` —
   noticed the breach, pulled the accrued debt from the borrower's Aqua-authorized
   cure leg straight to the lender, released the collateral, and reported
   `HealthChecked(intervened=true)`. **Zero penalty. Zero keepers. Zero humans.**

Backup evidence (v4): manual permissionless cure tx
`0x8365d548daf619ea5bdde69ca470120d17d428065bee197aeeb48a98955026b6` (same waterfall,
called directly — `liquidate` is permissionless by design).

**Live-fire lesson (fixed + committed):** try/catch + Axelar relayer gas estimation is a
footgun — the inner cure can OOG, the catch swallows it, the tx "succeeds" cheaply as
`intervened=false`, and the simulation therefore never allocates real gas. Fix:
`MIN_CHECK_GAS` floor makes under-allocation revert retryably. Great Q&A material.

## LIVE RUN #5 ✅ — two wallets, two names, interest exact

Stack v6 (guard: lender ≠ borrower enforced on-chain). Lender = deployer; borrower =
its own funded key `0x71551F0BdE3bCCF3C3449219EfCF95BA0F160209`, signing its own
approvals, atomic draw, cure + maturity legs, and settlement registration.

- Hedera SETTLE schedule (tx `0x491be5f6...9ed5ae`) → Axelar → executor settled at
  Base Sepolia block 44,604,624, tx
  `0xfb74e7ca337c20c3a15dd23325f26a1a1b852cae89645611131e6a7b1c5edeff`.
- **Lender: 300,000.061263 USDC** — commitment home + EXACTLY the 61.263 USDC accrued
  (4.60% × 100k × 420s/365d). **Borrower: 1.5 cbBTC home**, lighter by the same 61.263.
  Bilateral, autonomous, exact to six decimals.

**Current live stack (v6):** Router `0xe51FD28546EB5449e7C9607Ef937706c5e2AfB95` ·
Builder `0xB84a8eaCaa349A50e9F7C87e2aDbF7EaC98DEa1c` · Executor
`0x9c781F36F6070101B6B6771474a73fB44A3dB032` · Escrow
`0x4CD5fa75186bEccc51215207037D5c1Fbe4ADebb` · USDC `0xa816781C4Fb9700476e38b73fED09c5dD6DC1fFb`
· cbBTC `0x3a53c0117Edfc8E745f7254F75d11e5085E210a8` · Oracle
`0x869105F636D6Ac7fDa4E49B6787359E114c96Ddb` · Hedera trigger v7
`0xe636135Bc58B5c732479B3303425C47653B8801f`. Frontend defaults point here.

## LIVE RUN #6 ✅ — THE REVOLVER REVOLVES ON-CHAIN

Stack v7: after the Hedera-scheduled settlement executed (Base Sepolia block 44,606,624,
tx `0xf064dcbbeb2e94fbc8e38c4e0e26d67e94e47af656bbef036db277fb1bdd6229`),
`availableToDraw` snapped from 200,000 back to the FULL 300,000 commitment — the
repayment recycled into the lender's facility strategy via Aqua `push` (lender paid the
real USDC in the same call that refilled pullable capacity). Repayment replenishes
capacity: observed live, not just tested (fork proof: cumulative 400k drawn on a 300k
commitment, 41→44 tests).

## Margining upgrade (44/44 tests)

- **Real-facility mechanics:** on-chain `commitment` + `availabilityEnd` (the
  commitment's own term, like a 364-day revolver); escrow meters outstanding principal;
  `_stopWhenCovered` demoted to a 4× gross safety rail.
- **DeFi-precise terms in the UI:** max LTV 76.9% (post ≥130%) · liquidation threshold
  87.0% LTV (<115%) · per-draw liquidation PRICE displayed and previewed at draw time.
- **Borrower margin controls:** voluntary extra collateral at draw, `topUpCollateral`
  (moves the liquidation price down — tested: a topped-up position survives a crash that
  breaches the minimum-margin one), `withdrawCollateral` gated at the INITIAL ratio.

**Current live stack (v8):** Router `0x973aB7E04dBAc82255d94f11F8FB2518b4Fd9dAE` ·
Builder `0x3AE1b534f15966C815FaCA58eCf368a806488232` · Executor
`0x4173d77703566F99909cC1485cb6B9C04F32D492` · Escrow
`0xFC4D35C361fD5D0518a116ab56d2E4181ebf59ec` · USDC `0xc0832552c1cc746eba1B2fAC11484AAe1d943Dc0`
· cbBTC `0x23391447bE5122149fE370102515226cE799Ab2D` · Oracle
`0xf38939758b0074CE6e80E1206AD56F4Aef872237` · Hedera trigger v9
`0x952dE361ae3392A483049517088c51C2618DFD18` (SETTLE scheduled). Frontend on v8.

## LIVE RUNS #7–#8 ✅ — revolving under margin controls + Aave-calibrated terms

- **Run #7 (stack v8, margin controls):** Hedera-scheduled settlement executed;
  `availableToDraw` refilled to the full 300k commitment on-chain. Stack carries the new
  margin features: voluntary extra collateral at draw, `topUpCollateral`,
  `withdrawCollateral` (gated at the initial ratio).
- **Run #8 (stack v9, CURRENT):** margining calibrated to **Aave v3 Base cbBTC live
  params — max LTV 73%, liquidation threshold 78%** (13,699/12,821 bps), read via the
  same Messari-standardized Graph query and exposed as `collateralBenchmark` in
  /api/rates. Scheduled settlement executed and capacity refilled to 300k again —
  see Settled event on executor `0x8376C8b6198530D54ec09adB84986FA1E4754812`.
- Frontend: DeFi-precise terms (max LTV / liq threshold / per-draw liquidation price),
  readable draw ids with Basescan links, HashScan links on schedule IDs, rate +
  per-second interest accrual columns in the lender book.

Eight autonomous live runs total: 4 scheduled settlements, 1 sentinel cure,
3 revolving-refill proofs, across 9 stack iterations. Zero keepers throughout.
