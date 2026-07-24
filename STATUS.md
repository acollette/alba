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
- [x] `ChronosTriggerSpike` deployed Hedera testnet (same address), funded 30 HBAR
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
  shipped strategy bytes ARE `abi.encode(order)`; single source of truth in `ChronosProgramBuilder`)
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
