# Alba — On-Chain Revolving Credit, Settled by Schedule

> Working name. Register final name + domain before the event.

**One-liner:** Committed credit facilities (revolvers) and bespoke term loans written as SwapVM programs, backed by Aqua pull-rights, recorded and clocked on Hedera, settled anywhere by Axelar — priced live off the Morpho Midnight benchmark curve. No bots, no keepers, no servers.

**Pitch sentence:** *"Midnight built the bond market; we built the revolver — committed credit facilities that draw on demand and settle themselves, priced off Midnight's live curve."*

## Target prizes (ETHGlobal Lisbon 2026)

| Sponsor | Track | Prize | Our angle |
|---|---|---|---|
| 1inch | Build an Aqua App | $2,500 / $1,500 / $1,000 | Fixed-income positions on SwapVM; 3 custom opcodes; Aqua-mode settlement; auction liquidation (SwapVM scores higher in judging) |
| Hedera | Cross-Chain Automation Hub (+ Axelar) | 3 × $1,000 | Schedule Service as maturity clock; registry as deal hub; full trigger→execution loop on-chain, zero keepers |
| The Graph | Composable/Standardized Products | $2,500 / $1,500 / $1,000 | One Messari standardized-lending query across Aave/Morpho/Compound → fixed-vs-floating pricing context |

## The product in three layers

1. **Benchmark layer** — Midnight cbBTC/USDC fixed curve (live, on-chain read) + floating band from The Graph standardized lending subgraphs, on one chart.
2. **Instrument layer** — SwapVM programs for a committed USDC facility against cbBTC collateral: draw on demand (partial fills), interest only on drawn, per-draw maturity legs, Dutch-auction liquidation with `_stopWhenCovered` (partial liquidation).
3. **Automation layer** — Hedera Schedule Service + registry dispatches Axelar GMP messages that fire settlement on Base at each maturity. The term loan is a facility drawn once.

## Positioning (say this to judges)

- We **concede**: standard term loans, fungibility, liquidity, and rate discovery belong to Midnight. We integrate their live rates as our benchmark.
- We **own**: revolving facilities (no on-chain incumbent), keeper-free scheduled settlement, cross-asset forwards (roadmap), bespoke dates/named counterparties (roadmap), auto-rollover of Midnight positions (stretch demo).
- We deliberately stop short of pooling — pooled fixed-rate is Morpho's lane; the bespoke bilateral end is undefended.

## Repo map

```
contracts/           Foundry project (see docs/ARCHITECTURE.md)
  src/
    TermRouter.sol         AquaSwapVMRouter + custom opcodes
    opcodes/AlbaOpcodes.sol
    CollateralEscrow.sol
    AxelarSettlementExecutor.sol
    hedera/DealRegistry.sol
  test/
frontend/            Next.js app (offer card, facility view, timeline, curves)
services/rates/      Graph standardized-lending query + Midnight curve reader
docs/                This planning pack
```

## Docs pack

- `docs/ARCHITECTURE.md` — system design, contracts, flows, trust model
- `docs/OPCODES.md` — spec for the three custom instructions
- `docs/PLAN.md` — prep week + 2-day build schedule + priority stack + gates
- `docs/DEMO.md` — demo script, presentation plan (live demo + screenshots; video optional), qualification checklists per sponsor
- `docs/PRICING.md` — desk methodology: curve construction, weighted composite, gap-risk pricing
- `CLAUDE.md` — execution guide for AI-assisted development

## Licensing (decided)

- `services/rates/` → **MIT**, separate public repo for The Graph submission (their brief requires open source).
- `contracts/` → license TBD pending swap-vm LICENSE review (we *inherit* SwapVM — check copyleft terms; ask 1inch team in person). Aqua itself is source-available (Degensoft Aqua-Source-1.1): free to call/deploy until >$100k fees/12mo or >$10M liquidity under control. File next to Edelvault paperwork; not a hackathon issue.
- Copyright headers from first commit. Teammate IP assignment agreed in writing on day zero.
- Commit continuously — 1inch disqualifies single-commit dumps.
