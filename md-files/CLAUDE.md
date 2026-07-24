# CLAUDE.md — Execution Guide

You are assisting on **Chronos**: revolving credit facilities + term loans as SwapVM programs, Aqua-mode settlement, Hedera Schedule Service + Axelar GMP as the keeper-free maturity trigger, liquidated by Dutch auction. Two-day hackathon build (ETHGlobal Lisbon 2026). Read `docs/ARCHITECTURE.md`, `docs/OPCODES.md`, `docs/PLAN.md` before writing code.

## Non-negotiables

1. **Priority stack is law** (PLAN.md). Never start item N+1 while item N is red. Never add unlisted scope; propose it for the roadmap slide instead.
2. **Official contracts:** Aqua = official deployment, never forked/modified. Our router inherits `AquaSwapVMRouter` — that redeployment is explicitly allowed by the 1inch brief.
3. **Commit small and constantly.** Conventional messages (`feat:`, `test:`, `fix:`). Single-commit dumps disqualify.
4. **Tests before wiring.** The Foundry matrix in OPCODES.md is the definition of done per component. Test 1 (ship→execute round trip) must be green before any opcode work.
5. **Fees are immutable constants** (settlement bps, liquidation bps). No owner setters. This is a product principle, not a shortcut.

## Critical technical invariants (violating these = silent multi-hour bugs)

- **strategyHash round trip:** every order is built by the shared program-builder helper; `aqua.ship()` calldata and the executable order derive from the SAME bytes. Never hand-assemble program bytes in two places.
- **`isStaticContext` discipline:** `_stopWhenCovered` must NEVER write storage during static execution; `_onlyTaker` must SKIP its check during static execution; `_notBefore` reverts in both. Every opcode PR includes a staticcall test asserting no storage mutation.
- **Single-claim collateral:** `CollateralEscrow` ships Aqua rights for at most one strategy per draw, and only via `armAuction()` after a confirmed failed pull. No other path ships escrow rights. No rehypothecation.
- **Auction floor:** decay never below the configured floor (~85% of oracle). No race-to-zero.
- **Clamp, don't revert, the final partial fill** in `_stopWhenCovered` (facility and auction both).
- **Registers denomination:** facility target counts loan-token (USDC) drawn; auction target counts USDC raised for the lender. Check `isExactIn` before choosing which register to clamp.

## Codebase conventions

- Solidity ^0.8.x, Foundry. `forge fmt` before commit. Custom errors, no revert strings. NatSpec on external functions.
- Layout: `src/TermRouter.sol`, `src/opcodes/ChronosOpcodes.sol`, `src/CollateralEscrow.sol`, `src/AxelarSettlementExecutor.sol`, `src/hedera/DealRegistry.sol`, `src/lib/ProgramBuilder.sol` (+ TS mirror in `frontend/lib/program.ts` generated or hand-synced with a fixture test proving byte equality).
- Fork tests: Base mainnet fork pinned to a block; addresses in `.env` (`AQUA`, `SWAPVM_*`, `CHAINLINK_CBBTC_USD`, `AXELAR_GATEWAY_*`, `MIDNIGHT_*`).
- Frontend: Next.js + wagmi/viem. Functional > pretty until Day 2 hour 8. No component-library rabbit holes.
- `services/rates` lives in the SEPARATE MIT repo (`chronos-rates`) — Graph submission requires open source; keep it decoupled from contracts repo.

## When blocked (in order)

1. Re-read the relevant swap-vm source (especially invalidator instructions and `PROGRAMS.md`) — the answer is usually a pattern to copy.
2. Check the prep-week scripts (P1–P7 outputs in `/prep`) before re-deriving anything about Hedera schedules, Axelar payloads, Midnight ABIs, or the Messari query.
3. If an external leg is flaky (Axelar↔Hedera), switch to the rehearsed fallback (manual relay + honest narration) rather than burning >45 min debugging infrastructure we don't control.
4. If a feature threatens the Day-1/Day-2 gates, cut it per the stack and note it in `docs/ROADMAP_NOTES.md` for the pitch.

## Definition of done (per gate)

- **Day 1:** tests 1–6 green on fork; trigger loop fires end-to-end (real or fallback); 20+ commits.
- **Day 2 hour 8:** UI demos Beats 1–3; Midnight + Graph lines live; STOP BUILDING → videos, READMEs, rehearsal.
- **Submission:** both repos public, videos uploaded, checklists in DEMO.md all ticked, submitted ≥2h before deadline.
