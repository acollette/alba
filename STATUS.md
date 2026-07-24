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

### Item 2 — live trigger leg 🔶 BUILT, BLOCKED ON WALLET FUNDING (human step)

- [x] `ChronosTriggerSpike` (HSS `scheduleCall` @0x16b + Axelar gas/`callContract`) and
      `SpikeReceiver` (`AxelarExecutable`) compile; runbook: `contracts/script/spike-runbook.sh`
- [ ] **FUND `0xA2a0423aB76D9AA97d466D19D1A58F11973aDe3D`** — Hedera testnet HBAR
      (faucet.hedera.com) + Base Sepolia ETH. Faucets are captcha-gated. Throwaway key in
      `contracts/.env` (gitignored).
- [ ] Then: `spike-runbook.sh deploy-receiver` → `deploy-trigger` → fund trigger → `dispatch`
      → `schedule` → `watch`. HOUR-5 GATE fallback (manual relay) stands if the live leg misbehaves.

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

## END-OF-DAY-1 GATE

- Message arrives → repayment settles via Aqua, no signature: ✅ proven on fork (Test 7).
- Schedule fires live (real or fallback): 🔶 pending wallet funding (see Item 2). Decision
  point preserved: fallback = manual relay + honest narration.
- Commits: 13 conventional commits so far.

## Day 2 items (NOT touched, per plan)
Midnight rates, Graph query, frontend, DealRegistry (thin), position NFT.
