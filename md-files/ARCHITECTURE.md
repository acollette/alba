# Architecture

## System overview

```
HEDERA (hub)                      AXELAR                     BASE (money layer)
┌──────────────────┐                                  ┌────────────────────────────┐
│ DealRegistry     │   GMP: (facilityId, drawId,      │ AxelarSettlementExecutor   │
│  - facilities    │──── epoch, action) ─────────────▶│  - validates source        │
│  - schedules     │                                  │  - calls TermRouter.swap() │
│ Schedule Service │                                  └─────────────┬──────────────┘
│  (native alarm)  │                                                │
└──────────────────┘                                                ▼
                                                      ┌────────────────────────────┐
                                                      │ TermRouter                 │
                                                      │  (AquaSwapVMRouter +       │
                                                      │   AlbaOpcodes)          │
                                                      └───┬────────────────┬───────┘
                                                          │                │
                                                     ┌────▼─────┐   ┌──────▼──────────┐
                                                     │  AQUA    │   │ CollateralEscrow│
                                                     │ (official│   │  - locks cbBTC  │
                                                     │  deploy) │   │  - Aqua maker   │
                                                     └──────────┘   │    for auction  │
                                                                    └─────────────────┘
```

Frontend (Next.js) + services/rates (Graph standardized-lending query + Midnight on-chain curve reader) sit above; display-layer only, never settlement-critical.

## Instruments

**Facility (flagship).** Lender publishes committed USDC facility (e.g. 300k) against cbBTC collateral at a fixed rate, fixed per-draw term. A **term loan is a facility drawn once** — one product, two stories.

- **Open/draw leg:** static-balance SwapVM order, Aqua mode. Each draw = partial fill. `_stopWhenCovered(facilitySize)` caps cumulative draws.
- **Per draw:** pro-rata cbBTC locks in `CollateralEscrow` (150%, model-sized — see PRICING.md); a maturity leg arms; `DealRegistry` creates a Hedera scheduled tx for `now + term`.
- **Maturity leg:** SwapVM order pulling `drawn × (1 + rate·term)` USDC from borrower via Aqua. Gated by `_notBefore(T)` and `_onlyTaker(executor)`. Zero-coupon: no per-block accrual; yield realized atomically at settlement.
- **Default path:** repayment pull reverts → same tx arms the pre-registered Dutch auction program. Escrow acts as Aqua maker for cbBTC; price starts ~105% of oracle and decays; permissionless fillers (existing Aqua solver network) fill partially; `_stopWhenCovered(debt)` halts sales the moment the lender is made whole; surplus cbBTC reclaimable by borrower. Decay is floored (~85% of oracle) — never race to zero.

## Contract specs

### TermRouter.sol
`contract TermRouter is AquaSwapVMRouter, AlbaOpcodes` — override `_instructions()` to append custom opcodes to the standard set. Official Aqua deployment underneath (qualification requirement: official contracts used; redeployed modified SwapVM explicitly allowed).

### AlbaOpcodes.sol
See `docs/OPCODES.md`. Three instructions: `_notBefore`, `_onlyTaker`, `_stopWhenCovered`.

### CollateralEscrow.sol
- `draw(facilityId, drawId, amount)` — atomic: pulls oracle-sized collateral from the borrower AND executes the facility pull, one tx.
- `armAuction(drawId)` — callable only by `AxelarSettlementExecutor` after a failed repayment pull; ships auction pull-rights to Aqua (`aqua.ship(termRouter, auctionStrategy, [cbBTC], [amount])`).
- `release(drawId)` — returns collateral on successful settlement / surplus after auction covers debt.
- **Invariant: single-claim collateral.** Escrow never ships rights to more than one strategy per draw; auction rights ship only post-default-confirmation. No productive-collateral rehypothecation (V2: yield-bearing ERC-4626 wrappers with 140% haircut instead).
- Waterfall enforced in auction program: lender up to debt → liquidation fee (protocol-fee opcode) → remainder to borrower.

### AxelarSettlementExecutor.sol
`AxelarExecutable`. Validates `sourceChain == "hedera"` && `sourceAddress == DealRegistry`. Decodes `(facilityId, drawId, epoch, action)`, executes:
- `SETTLE`: `termRouter.swap()` on the maturity leg (Aqua mode — no signature exists or is needed; the order struct is on-chain data). On revert → `escrow.armAuction(drawId)` in the same tx.
- Skip-if-static handling: none needed here (always state-changing), but the opcodes must handle `isStaticContext` (see OPCODES.md).

### hedera/DealRegistry.sol
Thin, deliberately. Canonical record: facility terms, parties, draws, states (ACTIVE / SETTLED / DEFAULTED / LIQUIDATED). `registerDraw()` creates the scheduled tx; on schedule fire, dispatches the GMP payload via Axelar Gateway. This is "Hedera as hub" as real code (~1 hour), not a slide.

## Key mechanism notes (learned the hard way in research — do not rediscover on-site)

1. **Aqua is permissionless for apps.** Balances keyed `(maker, app, strategyHash, token)`; `ship()` takes our router's address as `app`. No whitelist, no forked Aqua needed.
2. **The strategyHash round-trip is the trap.** `ship(strategy bytes)` must hash to exactly the order the router executes. Byte mismatch presents as a confusing "insufficient balance" revert. → Single source of truth: one TS/Solidity helper derives both `ship()` calldata and the executable order. **First Foundry test = ship-then-execute round trip.**
3. **Aqua-mode = no signature.** `useAquaInsteadOfSignature = true` → authorization is a balance lookup. This is the load-bearing fact: machines can't sign EIP-712, machines can read a ledger. It is the entire reason scheduled settlement works.
4. **`ship()` is immutable; `dock()` withdraws.** Facility sized once; draws decrement naturally; *increasing* a live facility = dock + reship (fine; roadmap line).
5. **Same-address SwapVM on 12 chains** — recipe language is universal; our router deploys per chain. Cross-chain = routing problem, not rewrite.
6. **Collateral is NOT Aqua.** Pull-rights over a wallet the borrower controls are worthless (they can empty it). Escrow = code, can't defect → Aqua rights *from the escrow* are fine (auction). Know why; judges may probe.

## Cross-chain levels (scope honesty)

- **Level 0 (core, Day 1):** Hedera trigger → Axelar GMP → Base settlement. The requirement.
- **Level 1 (garnish, item 10):** Axelar ITS disbursement/repayment to/from other chains.
- **Level 2 (roadmap only):** cross-chain collateral. Non-atomic; two-phase with timeout-and-recourse. Say the atomicity boundary out loud — it scores better than a fragile demo.
- **Level 3 (thin, item 7):** DealRegistry as multi-chain hub — built as the thin contract above.

## Trust model / known cuts (state these proactively)

- **Maturity-only collateral checks**, model-sized (150% — the gap-risk put priced in PRICING.md; auction floor ~85% of oracle). Continuous margining + Graph-based sentinel = roadmap. Scope cut, not quality cut — partial liquidation via `_stopWhenCovered` is *better* than fixed-chunk liquidations in production protocols.
- **No secondary market**, but positions are one ERC-721 wrapper from transferable (receiver field). Item 8; strongest scaling slide.
- **Oracle:** Chainlink cbBTC/USD on Base for auction start price. Single oracle, acknowledged.
- **Fee design principle (stolen from Midnight):** caps in code — settlement bps + liquidation fee constants, immutable. "Infrastructure that can't reprice you is infrastructure a treasurer can underwrite."
