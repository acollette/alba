# PRODUCT.md — Post-hackathon roadmap (ideation of 2026-07-27)

Alba goes from hackathon project to product. This captures the decisions and the
sequence; supersedes the prize-driven architecture where noted.

## Decisions taken

- **Drop Hedera + Axelar from the money path.** They were prize architecture; two
  external liveness dependencies (we watched the Axelar Hedera lane stall ~1h live).
  The real innovation stays: settlement is PRE-AUTHORIZED (Aqua maturity leg:
  time-gated, amount-capped, double-settlement-proof), so initiation is only a
  liveness concern — worst case late, never wrong. Replace with defense in depth:
  1. permissionless poke with a small tip (loosen `_onlyTaker` to a settlement
     contract anyone can call after maturity),
  2. our own bots as baseline,
  3. lender manual settle button (the interested party never depends on anyone).
  Core contracts never referenced Hedera (it lives in `spike/`) — deletion, not refactor.
- **Production gap to fill:** default interest (penalty rate accruing past maturity).
  Makes late settlement economically neutral for the lender; more important than
  keeper choice.
- **No desk balance sheet in v1.** Pure curation: nobody's credit intermediates.

## The product ladder (each ships alone; nothing thrown away)

### v1 — Curated fixed-income vault (ERC-4626)
One vault, sleeves with curator caps (MetaMorpho governance pattern applied to
fixed income):
- **Sleeve 1 — direct Midnight paper:** bots take standing borrower bids (the empty
  side of Midnight is the LEND side — our own curve data); the VAULT owns the bonds.
  Market risk only; Midnight's cbBTC machinery (86% LLTV) secures the paper. No
  escrow needed for this sleeve.
- **Sleeve 3 — floating buffer:** idle capital in blue-chip MetaMorpho vaults;
  capped share + liquidity buffer (variable-vault withdrawals tighten exactly when
  you need cash).
- Yield = blend of fixed (paper) + floating (idle). Near-zero audit surface:
  OZ-standard 4626 + bot plumbing.
- Custody note: pooling custodializes the retail→vault boundary BY DEFINITION;
  Aqua keeps custody-minimization at the vault→markets boundary (undrawn capital
  stays in the vault's address, everything downstream is scoped pull-rights, never
  blanket approvals). Retail and institutions land on identical rails.

### v2 — Permissionless repo on Midnight paper (becomes Sleeve 2)
Any bondholder deposits paper into the escrow → draws USDC instantly → repays by
term or the escrow collects par. Key properties:
- **Collateral = eligibility basket + haircut schedule by duration bucket**
  (e.g. ≤7d: 2%, ≤30d: 5%, ≤90d: 10%), NOT per-maturity markets. Bond's own rate
  is irrelevant to the lender; mark value + time-to-maturity are everything.
- **Marks from our curve engine** (clip-VWAP, depth floor), posted on-chain as the
  oracle — the most audit-sensitive piece (thin-book manipulation → haircuts lie).
- **Self-liquidating collateral:** primary default remedy is WAITING — paper
  redeems par (made good by Midnight's machinery), escrow repays itself, returns
  excess. Ladder: cure from borrower's Aqua balance → hold-to-par → Dutch auction
  only as lenders' early-exit option. If the bond matures before the loan, escrow
  auto-redeems and collateral becomes cash (risk-free from that moment).
- **Loan sizing rule:** cap exposure per maturity relative to that book's exit
  depth (or hold-to-par sizing) — thin books stop being a risk.
- Demand regimes: repo rate > bond yield → liquidity borrowers (pay ~bps for cash
  without selling); repo rate < bond yield → leverage loops (haircuts bound them).
  Worked example in the ideation log: 500k face 34d paper, 4% haircut, draw 450k
  at 4.9%/21d; negative carry ≈ $180 = the price of liquidity.
- Lenders: the vault's Sleeve 2 (pooled) + bilateral facilities (institutions with
  their own haircut schedule / rate band). Same rails either way.
- Strategic flywheel: paper you can repo is paper people buy bigger → deepens
  Midnight's books → better marks → tighter haircuts. A product Morpho should
  actively want to exist.
- **New machinery (the audit budget):** (1) basket collateral + haircut schedule
  in the escrow, (2) adapter for Midnight's per-maturity unit tokens, (3) on-chain
  curve mark oracle, (4) auto-redeem at bond maturity. Everything else is running
  code (facilities, atomic draw, cure/maturity legs, permissionless liquidate,
  auction).

### v3 — The desk layer (Keyrock JV shape)
When the JV firms up: Keyrock quotes (traders, risk, appetite), Alba funds and
settles. Bilateral facilities fund the desk; desk's collateral = the paper it buys
(repo config); revenue share. Don't become an MM to compete with the MM you're
pitching. Products 1+3 (credit lines, auto-roll) then distribute to their client
base. Borrow-side quoting needs cbBTC on Midnight → launch with desk-owned
collateral; the collateral vault ("earn on idle cbBTC", agency-securities-lending
analog, first-loss desk tranche) is the scale-up, not the launch.

## Facility design notes (from ideation)

- **Rate collar:** facilities can carry a band ("4–5%"): each draw fixes its rate
  at draw time from the on-chain benchmark, clamped to the band. Keeps one
  facility usable across rate regimes.
- **Commitment fee** (25–50bps on undrawn capacity): fixes multi-lender allocation
  fairness — every LP earns for standing ready; drawn capital earns the full rate.
  Allocation policy = cheapest-capital-first (desk-side choice, not FIFO).
- **JIT liquidity:** SwapVM maker pre-transfer-out hooks can atomically redeem
  MetaMorpho shares to cover a pull (v2 polish; v1 = 20% liquid buffer + bots).
- Facility-per-LP stays the base layer (self-custody until drawn, negotiated
  terms); pooling is a LAYER ON TOP (the 4626 is just one big maker). Never invert.

## Tail risk to own before any pitch

Correlated crash: violent BTC move triggers Midnight liquidations that impair
paper WHILE marks gap down (two liquidation engines interact). Mitigations:
haircuts calibrated to Midnight LLTV stress, short ladders (book self-liquidates
in days), per-maturity concentration caps. This is the risk head's first
question — make it our first slide.

## Open items

- [ ] Keyrock pitch (v3 shape; vault AUM as proof)
- [ ] Morpho/Midnight team conversation (liquidity roadmap; repo flywheel pitch)
- [ ] Haircut/margining spec for bond-as-collateral (the one new mechanism)
- [ ] Default-interest design
- [ ] Software vs balance sheet / regulatory shape (open)
