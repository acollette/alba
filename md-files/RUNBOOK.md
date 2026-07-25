# Demo runbook — accounts, tabs, clicks

## Wallets (import BOTH into your browser wallet, network = Base Sepolia)

| Role | Address | Key location |
|---|---|---|
| **LENDER** (desk) | `0xA2a0423aB76D9AA97d466D19D1A58F11973aDe3D` | `contracts/.env` → `PRIVATE_KEY` |
| **BORROWER** (fund/market-maker) | `0x71551F0BdE3bCCF3C3449219EfCF95BA0F160209` | `contracts/.env` → `BORROWER_PK` |

Any other wallet (e.g. your personal …9365) is an **observer**: the app now shows an
explicit "observer — not a party" badge, read-only. Use it only if you want to show the
auditor view. Both demo wallets hold test tokens and gas; testnet-only keys.

## Pre-flight (10 min before)

```bash
GRAPH_API_KEY=... node rates/src/server.mjs     # :8787 — dashboard + desk quotes
cd frontend && npm run dev                       # :3001 (:3000 is taken on this machine)
```
Browser tabs, in order: app (:3001) · dashboard (:8787) · HashScan trigger account ·
Axelarscan testnet (filter addr `0xe636…801f`) · Basescan/Blockscout on the escrow.
Wallet: both accounts imported, Base Sepolia selected. Terminal visible for Beat 4.

## The story → the clicks

**Beat 0 — context (dashboard tab):** live Midnight curve (depth-filtered, labeled
extrapolation), weighted floating composite, desk model quote. "One Messari query, four
protocols, zero per-protocol code — and this is how the deal gets priced."

**Beat 1 — origination is social (say it, don't show it):** "A fund wants stables
against cbBTC inventory. They message a desk. Terms agreed in Telegram. We don't
pretend to replace that."

**Beat 2 — the deal link (app, LENDER wallet):** Lender tab → *New deal*: paste the
borrower address, 300k / 4.60% / 90d → **Publish** (3 wallet prompts: approve pull
rights → ship to Aqua → register). Point at the wallet: "funds never left." Copy the
deal link — "this is the term sheet now; it goes out in Telegram."

**Beat 3 — accept & draw (switch wallet to BORROWER, open the deal link):** tabs flip,
"YOU" chip moves to Borrower — "the contract knows who I am; the deal was sold to one
name." Review terms-as-code → **Accept & approve cbBTC** → set 100000 → **Draw**: one
transaction, collateral in, cash out. Obligations card appears with the health meter.

**Beat 4 — the machine (timeline + explorer tabs):** the EXISTING v6 history — Hedera
schedule IDs "executed by the network", the settled draw with interest exact to six
decimals (`0xfb74e7ca…deff`: lender +100,000.061263), and the sentinel-cure tx
(`0xb6e9d53d…d284`): "price crashed 20% — the network noticed on schedule and CURED the
position from pre-authorized funds. Zero penalty. The auction only exists for a drained
borrower — and it stops the moment the lender is whole." If asked for the default path
live: `forge test --match-contract Test6 -vv` in the terminal.

**Beat 5 — close (lender tab):** the book: receivables, statuses, the settled row.
"Positions are one ERC-721 from a secondary market. Midnight built the bond market —
we built everything that isn't standard, and made it settle itself."

## Fallbacks

- RPC flaky → dashboard + explorer tabs carry the story; screenshots folder as last resort.
- New-deal publish hiccup on stage → fall back to the standing 0xFAC facility (default view).
- Live draw fails → the timeline already shows a real one; narrate over it.

## Judge questions — one-liners live in DEMO.md (Q&A section) and PRICING.md (the spread).
