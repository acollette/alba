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
(set -a; source contracts/.env; set +a; node rates/src/server.mjs)  # :8787 — dashboard + desk quotes
cd frontend && npm run dev                       # :3001 (:3000 is taken on this machine)
```

Browser tabs, in story order (v9 stack / v10 trigger):

1. App desk overview — http://localhost:3001/ (all facilities, timeline, New-deal card)
2. Rates dashboard — http://localhost:8787
3. HashScan trigger — https://hashscan.io/testnet/contract/0x2F1A66A0Cea351B3308d317a96107B4528fc0E37
4. Axelarscan — https://testnet.axelarscan.io/address/0x2F1A66A0Cea351B3308d317a96107B4528fc0E37
   (filter flaky for contracts → fall back to the app timeline's direct GMP links)
5. Basescan escrow — https://sepolia.basescan.org/address/0x8dB282dBBd0fc55f1d231616BdA2dFd0d2Db951A
6. Basescan Aqua — https://sepolia.basescan.org/address/0x29C10C31eB844D038A0Dc858997f8ADea1da3270
   ("the pull-rights ledger — holds zero tokens")

Spares: router `0xa99e81a3ff4eD108c3C145dba9137EBD422b6914` · executor
`0x8376c8b6198530d54EC09aDb84986FA1E4754812` · builder `0x6CB061163D5Bed7801611b1670603979EaB3EA13`
· oracle `0x37BcB44C38932A87789e97214A927d87490F426E`.
Wallet: both accounts imported, Base Sepolia selected. Terminal visible for Beat 4.

## The story → the clicks

**Beat 0 — context (dashboard tab):** live Midnight curve (depth-filtered, labeled
extrapolation), weighted floating composite, desk model quote. "One Messari query, four
protocols, zero per-protocol code — and this is how the deal gets priced."

**Beat 1 — origination is social (say it, don't show it):** "A fund wants stables
against cbBTC inventory. They message a desk. Terms agreed in Telegram. We don't
pretend to replace that."

**Beat 2 — the deal link (app, LENDER wallet):** Connect the LENDER wallet on the desk
OVERVIEW (`/` lists every facility; the New-deal card lives here now) → *New deal*:
paste the borrower address, 300k / 4.60% / 90d → **Publish** (3 wallet prompts: approve
pull rights → ship to Aqua → register). Point at the wallet: "funds never left." Copy
the deal link — "this is the term sheet now; it goes out in Telegram."

**Beat 3 — accept & draw (switch wallet to BORROWER, open the deal link):** the page
re-renders as the borrower AUTOMATICALLY — no tabs, the wallet IS the role: "the
contract knows who I am; the deal was sold to one name." Review terms-as-code → **Accept & approve cbBTC** → set 100000 → **Draw**: one
transaction, collateral in, cash out. Obligations card appears with the health meter.

**Beat 4 — the machine (timeline + explorer tabs):** the EXISTING v6 history — Hedera
schedule IDs "executed by the network", the settled draw with interest exact to six
decimals (`0xfb74e7ca…deff`: lender +100,000.061263), and the sentinel-cure tx
(`0xb6e9d53d…d284`): "price crashed 20% — the network noticed on schedule and CURED the
position from pre-authorized funds. Zero penalty. The auction only exists for a drained
borrower — and it stops the moment the lender is whole." If asked for the default path
live: `forge test --match-contract Test6 -vv` in the terminal.

**Beat 5 — close (reconnect LENDER wallet):** the book: receivables, statuses, the settled row.
"Positions are one ERC-721 from a secondary market. Midnight built the bond market —
we built everything that isn't standard, and made it settle itself."

## Fallbacks

- RPC flaky → dashboard + explorer tabs carry the story; screenshots folder as last resort.
- New-deal publish hiccup on stage → fall back to the standing 0xFAC facility (default view).
- Live draw fails → the timeline already shows a real one; narrate over it.

## Judge questions — one-liners live in DEMO.md (Q&A section) and PRICING.md (the spread).
