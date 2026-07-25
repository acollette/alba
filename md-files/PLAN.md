# Build Plan

Team-size note: written for solo; if teammates, split = one owns the Hedera→Axelar leg end-to-end, one owns Foundry/SwapVM, one starts frontend + rates on Day 1.

## Prep week (before the event — LEARN, don't build the project)

No project code before the hackathon (qualification), but throwaway experiments are the whole game. Walk in with zero tooling unknowns.

| # | Task | Output / gate |
|---|---|---|
| P1 | Hedera testnet: create a scheduled transaction; test recurrence semantics and max schedule horizon | Working script; known limits |
| P2 | **Axelar GMP Hedera→Base testnet: send ONE message end-to-end** | THE critical unknown. If unsupported/flaky → decide fallback now (see D1 gate) |
| P3 | Clone swap-vm; run Foundry suite; read `docs/PROGRAMS.md`; read invalidator instruction source | Comfortable composing programs; storage pattern understood |
| P4 | Read swap-vm LICENSE (copyleft on inherited routers?) + note question for 1inch team in person | Licensing decision unblocked |
| P5 | Find Midnight contract addresses + ABI on Base; write throwaway read-only script pulling offer-book rates per maturity | Rates readable, or known-awkward from the sofa in Brussels, not hour 30 in Lisbon |
| P6 | Messari standardized lending subgraph: write the one query (USDC borrow/supply rates), run against Aave v3 / Morpho Blue / Compound v3 endpoints | Query text + endpoint list saved |
| P7 | Aqua repo: read `ship()/pull()/push()/dock()`; sketch the strategyHash derivation helper | Helper design on paper |
| P8 | Write demo script draft (DEMO.md); register name + domain; teammate IP assignment in writing; create org + two repos (contracts, rates-MIT) | Admin done; scoping tool in hand |
| P9 | Pre-fund testnet wallets (Hedera testnet HBAR, Base Sepolia ETH, test USDC/cbBTC or mocks); save RPC endpoints in `.env.example` | No faucet-hunting on site |

## Day 1 — the machine (no pixels)

**Hours 1–4: the risky leg first.**
- Hedera scheduled tx → Axelar GMP → dumb receiver on Base emitting an event. Nothing else matters until this fires.
- **HOUR-4 GATE:** if broken → fallback = Hedera-testnet schedule EXISTS and fires on Hedera + manually-relayed message to Base fork, narrated honestly ("relay is Axelar in production; here's the P2 tx proving the path"). Decide at hour 4, not hour 20.

**Hours 5–9: Foundry on a Base fork.**
- Scaffold `TermRouter` (inherit `AquaSwapVMRouter` + `AlbaOpcodes`).
- Shared program-builder helper (single source of truth: ship calldata ⟷ executable order).
- Test 1 (ship→execute round trip) GREEN before anything else.
- Opcodes in order: `_notBefore` → `_onlyTaker` → `_stopWhenCovered`. Tests 2–4.
- `CollateralEscrow` skeleton + draw flow. Test 5 (happy path, manual executor).

**Hours 10–12: default path + real wiring.**
- Auction program + `armAuction` + Test 6.
- Wire real `AxelarSettlementExecutor` → `termRouter.swap()`.
- **END-OF-DAY-1 GATE:** full happy path runs — schedule fires (or fallback relay), message arrives, repayment settles. Commit log already has 20+ commits.

## Day 2 — the story

**Hours 1–4: frontend.**
- Facility card (publish), accept/draw flow, position timeline, "300k committed · 150k drawn · 150k available" facility view.
- Ruthlessly static: fixed 90d term, fixed 150% collateral (model-sized), one facility, two wallets. Rate field is the only input.

**Hours 5–7: rates layer (isolated, safe while tired).**
- Midnight live curve reader (P5 script → small service/route) → "Midnight 90d: x% · this offer: +z bps" in the card.
- Graph standardized query (P6) → floating band "USDC borrow today: a–b% across Aave/Morpho/Compound".
- Dashboard chart: fixed curve + floating band. Graph qualification: LIVE endpoints at demo time — no cached JSON.

**Hours 8–10: STOP BUILDING.**
- Presentation prep: live-demo choreography + screenshot pack (NO video by default — optional extra; verify whether the Graph track's submission form hard-requires one).
- READMEs finalized (Graph repo must name the subgraphs/endpoints consumed; one sentence: "same query, three protocols, zero per-protocol code").
- Rehearse live demo ×2. Pre-warm fork, pre-fund wallets, terminal windows arranged. Default-path demo = rehearsed Foundry test output with narration (more reliable than live UI theater).

**Hours 11–12: buffer.** Things slipped; this absorbs it. If genuinely green, pull from stretch list below in order.

## Priority stack (cut from the bottom; renegotiation with adrenaline is forbidden)

1. SwapVM legs + 3 opcodes on fork (tests green)
2. Hedera→Axelar trigger loop
3. Minimal UI (facility card + timeline)
4. Midnight live rates in the card
5. Graph floating band
6. Auction/default path in tests
7. Hedera `DealRegistry` (thin hub)
8. Transferable position NFT (receiver field; ~2–3h; hour-8-of-day-2 decision)
9. Scheduled Midnight rollover (hour-10 decision; rehearsed narration fallback: "this same message carries a Midnight rollover — here's the call")
10. Axelar ITS cross-chain disbursement

Cutting 10 and 9 entirely still leaves both main prizes intact.

## Environment / stack

- Solidity ^0.8.x, Foundry (forge/anvil Base fork), official Aqua deployment address on Base, swap-vm as dependency (npm `@1inch/swap-vm`).
- Axelar: `AxelarExecutable` base, testnet gateway addresses (Hedera + Base Sepolia) from P2.
- Hedera: Schedule Service via SDK or system contract (P1 decides which).
- Frontend: Next.js + wagmi/viem; no design-system yak-shaving — functional over pretty until hour 8.
- Rates service: Next.js API routes (or FastAPI if preferred muscle memory), 60–120s cache.
- Oracle: Chainlink cbBTC/USD feed on Base (address in `.env`).

## Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| Axelar↔Hedera GMP not workable on testnet | Medium | P2 discovers it pre-event; manual-relay fallback rehearsed |
| strategyHash mismatch burns hours | High if unmanaged | Shared helper + Test 1 first |
| Midnight ABI archaeology slow (protocol days old) | Medium | P5 pre-event; feature is display-only — degrade to Graph-only band |
| `_stopWhenCovered` static-context storage bug | Medium | Explicit test asserting no storage mutation on staticcall |
| Scope creep (Level 2, sentinel, revolver top-ups) | Certain | Priority stack is the contract; roadmap slides exist for a reason |
| Demo-day live-network flakiness | Medium | Everything critical demoable on fork; live legs pre-warmed + recorded backup clip |
