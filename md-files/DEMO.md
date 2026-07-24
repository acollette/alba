# Demo Script & Qualification Checklists

## Live demo (3 minutes; rehearse ×2 on Day 2)

**Beat 0 — Open with Midnight, not with us (15s).**
"Fixed-rate credit arrived on-chain days ago — Morpho Midnight, cbBTC/USDC on Base. Here's what a desk builds *around* a rates market: the revolver. Committed credit that draws on demand and settles itself. No bots, no keepers, no servers."

**Beat 1 — Publish the facility (30s).**
Lender card: 300k USDC facility, cbBTC collateral 130%, 90-day draws, rate 8.20%. Point at the two live lines: "Midnight 90d curve: x% — we price off it. Floating band via one Graph standardized query across Aave, Morpho, Compound: a–b%. Same query, three protocols, zero per-protocol code." Publish → Aqua `ship()` — "funds never left the lender's wallet."

**Beat 2 — Two draws = the revolver exists (30s).**
Borrower draws 100k (collateral locks, Hedera schedule created — show the schedule ID on the timeline). Draws 50k more. Facility view: "300k committed · 150k drawn · 150k available. Each draw is a partial fill against the standing Aqua order — one opcode, `_stopWhenCovered`, caps the facility. A term loan is just a facility drawn once."

**Beat 3 — The alarm rings (45s). THE money shot.**
Fast-forward the fork clock / trigger the Hedera schedule. Watch live: schedule fires on Hedera → Axelar message → executor settles on Base → timeline flips green → "102,022 USDC pulled via Aqua — no signature exists anywhere; authorization is on-chain balance state. That's why a machine can settle this. Trigger to execution, fully on-chain."

**Beat 4 — The failure path works (45s).**
Rehearsed Foundry test output on screen: borrower drained → pull reverts → auction arms → decaying price → two partial fills by permissionless arbs → **auction halts the moment the lender is whole** → surplus back to borrower. "Liquidations settle as native Aqua orders — every existing Aqua filler is already our liquidator. And we sell only what's needed: partial liquidation, better than fixed-chunk engines."

**Beat 5 — Close on scale (15s).**
(If item 8 built: NFT transfer test on screen.) "Positions are one ERC-721 wrapper from a secondary market. Primary desk → traded curve → benchmark data. Midnight built the bond market; we built everything that isn't standard — and made it settle itself."

## Q&A prepared answers

- *"Why not just use Midnight?"* → Concede standard loans fully. We own: revolvers (no incumbent), automation (they ship no auto-rolling), bespoke dates/counterparties, cross-asset forwards. We price off their curve — they're our benchmark, not our competitor.
- *"Chicken-and-egg liquidity?"* → Wrong premise: marketplaces need liquidity; settlement rails need two users. Deal links → RFQ to ~5 desks (BD, not bootstrapping) → bulletin board as side effect.
- *"Mid-term collateral crash?"* → Maturity-only checks, sized for it (130/115 floor). Scope cut stated proudly; sentinel via Graph is roadmap.
- *"Monetization?"* → Clearinghouse model: settlement bps compiled into the bytecode (protocol-fee opcode — survives forking), liquidation fee, per-deal execution COGS+margin, data exhaust of a market that trades in Telegram today. Fees capped in code, Midnight-style.
- *"Dependency on Aqua/SwapVM?"* → Chose it for the filler network + no-signature settlement. Rail is portable; liquidity network isn't. Honest trade.

## Qualification checklists

### 1inch — Build an Aqua App
- [ ] Official Aqua/SwapVM contracts used (Aqua official; TermRouter = allowed modified-SwapVM redeployment)
- [ ] On-chain token transfers in final demo (local fork OK) — Beats 3–4
- [ ] Proper git history — commit continuously from Day 1 hour 1; NO single-commit final-day dump
- [ ] SwapVM used (scores higher): 3 custom opcodes + composed native instructions (limit, dutch auction, fees, invalidator pattern)

### Hedera — Cross-Chain Automation Hub
- [ ] Hedera Schedule Service = native scheduling primitive (schedule IDs visible in UI)
- [ ] Axelar GMP carries trigger to destination-chain execution
- [ ] Full trigger→execution loop on-chain; zero bots/keepers/cron — Beat 3 proves it live
- [ ] Real-world workflow, production-ready feel (revolver + treasury framing; failure path shown)

### The Graph — Composable/Standardized
- [ ] Messari Standardized Lending schema: ONE query pattern across ≥3 protocols (Aave v3, Morpho Blue, Compound v3)
- [ ] LIVE Graph endpoints at demo/video time — mocked/static data disqualifies
- [ ] Separate public MIT repo (`chronos-rates`) with README naming subgraphs + endpoints
- [ ] 2–4 minute video recorded Day 2 hours 8–10
- [ ] Standards leverage stated explicitly on camera: "same query, three protocols, zero per-protocol code"

### ETHGlobal general
- [ ] Built during event (prep = throwaway experiments only)
- [ ] Check event T&Cs at registration for submission licensing requirements
- [ ] Video(s) + public repos submitted before deadline (set alarm 2h before)

## Video plan (Day 2, hours 8–10)

1. **Graph video (2–4 min, required):** the rates service + dashboard, live queries on screen, standards-leverage sentence, how it feeds pricing in the product. Screen recording + voiceover.
2. **Main video (3–4 min):** the live-demo beats recorded as backup + submission asset. Record the Beat 3 alarm-fire twice — it's the clip that carries everything.
