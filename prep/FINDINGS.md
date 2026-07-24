# swap-vm findings (item 4 — timeboxed)

`1inch/swap-vm` v1.0.1 installed at `contracts/lib/swap-vm`. **Full suite green: 712/712 tests**
(needs `cd lib/swap-vm && yarn` first — its remappings point at node_modules for
`@openzeppelin`, `@1inch/solidity-utils`, `@1inch/aqua`). Pragma is **exact 0.8.30** —
our project must compile with solc 0.8.30.

## Program encoding (libs/VM.sol)

Bytecode = concatenated `[opcode:1byte][argsLength:1byte][args:N]`. `runLoop` walks it,
dispatching `ctx.vm.opcodes[opcode](ctx, args)`. Instructions can re-enter `runLoop()`
mid-instruction to "wait" for later instructions to compute amounts (see invalidators),
then resume — that's how post-pricing checks read final amounts.

## Opcode tables — CRITICAL DISCOVERY

`AquaOpcodes` (what `AquaSwapVMRouter` uses) is a REDUCED 34-slot table: it does NOT
include `_limitSwap1D`, `_dutchAuctionBalanceIn1D`, `_staticBalancesXD`, or the
invalidators. Those live only in the full `Opcodes` table (`SwapVMRouter`, 46 slots).
→ **TermRouter must define its own table**: clone the full `Opcodes` layout (so indices
stay compatible with the debug tooling) and append our three custom opcodes at the end.
Opcode index = position in `_instructions()` array; `test/utils/ProgramBuilder.sol`
resolves indices by function-pointer search, so building programs with OUR table is
automatically consistent.

## The strategyHash round trip (resolved concretely)

- Order struct: `ISwapVM.Order { address maker; uint256 traits; bytes data }`.
  `MakerTraitsLib.build(Args{... useAquaInsteadOfSignature: true, program: bytecode})`
  packs flags into `traits` and hooks+program into `data`.
- Aqua-mode orderHash: `keccak256(abi.encode(order))` (no EIP-712, no signature).
- `Aqua.ship(app, strategy, tokens, amounts)` sets `strategyHash = keccak256(strategy)`.
- **Therefore: `aqua.ship(address(termRouter), abi.encode(order), ...)` — the shipped
  strategy bytes ARE the abi-encoded order.** One `ProgramBuilder` produces the order;
  both ship calldata and the executable order derive from it. Reference implementation:
  `test/AquaAccounting.t.sol::shipStrategy` (asserts strategyHash == swapVM.hash(order)).
- Settlement pulls via `AQUA.pull(maker, orderHash, token, amount, to)`; balances read
  via `AQUA.safeBalances(maker, app=router, orderHash, tokenIn, tokenOut)` → registers.

## Invalidator storage pattern (to mirror in _stopWhenCovered)

`Invalidators.sol`: `mapping(address maker => mapping(bytes32 orderHash => mapping(address token => uint256 filled)))`.
Pattern per `_invalidateTokenIn1D`:
1. If the needed register is still 0 (amount not yet computed), call `ctx.runLoop()` to
   let downstream pricing instructions run, then continue.
2. `require(prefilled + amount <= cap)`.
3. **Write storage only `if (!ctx.vm.isStaticContext)`** — quote mode checks but never
   mutates. Their NatSpec documents quote/swap divergence + "no backward jumps".

Our `_stopWhenCovered` differs: instead of reverting on overfill it CLAMPS the register
to `target - filled` (and reverts only when remaining == 0). Key it
`maker => orderHash => filled` like theirs.

## Entry points

`swap(order, tokenIn, tokenOut, amount, takerTraitsAndData)` (state-changing) and
`quote(...)` (static). Taker side built by `TakerTraitsLib.build(Args{...})` — for our
manual/executor fills: `isExactIn`, no callbacks, empty signature (Aqua mode).
Per-orderHash transient reentrancy guard; transfers: maker→taker via `AQUA.pull`,
taker→maker via push-balance check or `useTransferFromAndAquaPush`.

## Useful built-ins for our programs

- `_staticBalancesXD` + `_limitSwap1D` = fixed-rate partially-fillable leg (facility, maturity).
- `_dutchAuctionBalanceIn1D` / `_dutchAuctionBalanceOut1D` = decaying-price auction.
- `_deadline` (mirror for `_notBefore`), `Fee._protocolFeeAmountInXD` (settlement fee),
  `_salt` for order uniqueness (distinct orderHash per draw with same terms).
- Canonical composition per PROGRAMS.md example B: balances → pricing → invalidator/cap.

## Licensing note (P4)

swap-vm is `LicenseRef-Degensoft-SwapVM-1.1` (source-available, not OSI). Inheriting
`AquaSwapVMRouter` in our redeployment is explicitly allowed by the 1inch brief; confirm
distribution terms with the 1inch team in person before choosing contracts-repo license.
