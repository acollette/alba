# Custom Opcodes Specification

Router: `TermRouter is AquaSwapVMRouter, ChronosOpcodes`, overriding `_instructions()` to append these to the standard set. Each instruction receives the SwapVM `Context`: VM state (`isStaticContext`, `nextPC`, `programPtr`, `takerArgsPtr`), read-only `SwapQuery` (`orderHash`, `maker`, `taker`, `tokenIn`, `tokenOut`, `isExactIn`), and mutable `SwapRegisters` (`balanceIn/Out`, `amountIn/Out`, `amountNetPulled`).

Before writing any of these: **read the existing invalidator instructions** (`_invalidateTokenIn1D` / `_invalidateTokenOut1D`) and reuse their per-orderHash storage pattern. Less code + stronger "composed with their primitives" story for judging.

---

## 1. `_notBefore(uint40 timestamp)`

Mirror of the built-in `_deadline`.

- **Args source:** program bytecode (NOT taker args) — maturity is baked into the shipped/signed order; taker cannot manipulate it.
- **Logic:** `if (block.timestamp < T) revert TooEarly(T);`
- **Static context:** revert applies in both static and state-changing execution (a quote before maturity should also fail — the position is not executable, full stop). *Decision point: if the UI needs to price unmatured positions, add a `quoteOverride` flag read from bytecode; default no.*
- **Used by:** maturity legs, auction activation gating.
- **Est:** ~15 lines + tests. Trivial; write first for momentum.

## 2. `_onlyTaker(address executor)`

- **Args source:** program bytecode.
- **Logic:** `if (ctx.query.taker != executor) revert UnauthorizedTaker();`
- **Static context:** SKIP the check when `isStaticContext` is true — the UI must be able to quote the settlement amount without impersonating the executor.
- **Used by:** maturity legs (only the Axelar executor path can settle → no front-running the settlement).
- **Est:** ~15 lines + tests.

## 3. `_stopWhenCovered(uint256 target)`

The one with substance. Dual duty: facility draw cap AND partial-liquidation halt.

- **Args source:** program bytecode (`target` = facility size, or debt owed for auctions).
- **Storage:** `mapping(bytes32 orderHash => uint256 filled)` — mirror the invalidator pattern.
- **Logic (state-changing execution only):**
  1. `remaining = target - filled[orderHash]`; if `remaining == 0` revert `OrderCovered()`.
  2. If the current fill amount > remaining → **clamp to remaining** (clean UX: last filler takes exactly the remainder) by adjusting the relevant register. Decide clamp direction from `isExactIn` and which side (`amountIn`/`amountOut`) denominates the target — for the facility, target is denominated in loan-token (USDC) drawn; for the auction, in USDC raised for the lender.
  3. `filled[orderHash] += effectiveAmount`.
- **Static context: NEVER write storage when `isStaticContext == true`** — quoting must not corrupt fill accounting. Read-only path: compute against current `filled` and return the clamped quote.
- **Order of operations:** placement in the program matters — it must run AFTER the pricing instructions set final amounts and BEFORE settlement transfers. Document the canonical program layout in the program-builder helper.
- **Used by:** facility open/draw leg (`target = facilitySize`), auction (`target = debt`). Same opcode, two products — say it to judges.
- **Est:** ~40–60 lines + the most test time of the three.

---

## Program layouts (canonical, built by the shared helper — single source of truth with `ship()` calldata)

**Facility draw leg (Aqua mode):**
```
_limitSwap1D(rate terms)          # static-balance pricing
_stopWhenCovered(facilitySize)    # cap cumulative draws, clamp last draw
[_protocolFee...]                 # settlement fee bps (capped constant)
```

**Maturity leg (per draw, Aqua mode):**
```
_notBefore(maturityTs)
_onlyTaker(axelarExecutor)
_limitSwap1D(repayment terms)     # drawn × (1 + rate·term)
```

**Liquidation auction (escrow as Aqua maker):**
```
_notBefore(maturityTs)                    # can't fire early
_dutchAuctionBalanceIn1D(start≈105% oracle, floor≈85%, duration)
_stopWhenCovered(debtOwed)                # partial liquidation; halt when lender whole
[_protocolFee...]                         # liquidation fee (capped constant)
```
Auction is armed (rights shipped) only post-default by `CollateralEscrow.armAuction()`.

## Optional (build only if ahead)

- `_epochGate` — one fill per schedule epoch; needed only for recurring schedules (not for single-maturity draws). Skip.
- `_redeem4626` — unwrap yield-bearing collateral mid-program. V2 (productive collateral). Skip; pitch line only.

## Test matrix (Foundry, Base fork)

1. **Ship→execute round trip** (the strategyHash trap) — FIRST test written.
2. `_notBefore`: reverts before T, passes at/after T.
3. `_onlyTaker`: reverts for stranger, passes for executor, passes static quote for anyone.
4. `_stopWhenCovered`: multiple partial draws sum correctly; over-draw clamps; covered order reverts; static quote never mutates storage (assert storage unchanged after staticcall).
5. Full happy path: publish facility → draw 100k → draw 50k → warp to maturity → executor settles draw 1 → collateral released pro-rata.
6. Default path: drain borrower Aqua balance → settle reverts → auction armed → two partial fills at decaying price → auction halts at debt covered → surplus released to borrower → waterfall amounts exact.
7. Transfer test (item 8, if built): position NFT transferred → settlement proceeds land at new holder.
