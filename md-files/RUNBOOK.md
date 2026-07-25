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

Browser tabs, in story order (v10 stack / v11 trigger):

1. App desk overview — http://localhost:3001/ (all facilities, timeline, New-deal card)
2. Rates dashboard — http://localhost:8787
3. HashScan trigger — https://hashscan.io/testnet/contract/0xF6Ad8045FdD4A07c2B6f36E9b5043d13a86598a7
4. Axelarscan — https://testnet.axelarscan.io/address/0xF6Ad8045FdD4A07c2B6f36E9b5043d13a86598a7
   (filter flaky for contracts → fall back to the app timeline's direct GMP links)
5. Basescan escrow — https://sepolia.basescan.org/address/0x27a192BB64B3537BeEE6A458E609D4F89Cfa49ca
6. Basescan Aqua — https://sepolia.basescan.org/address/0x29C10C31eB844D038A0Dc858997f8ADea1da3270
   ("the pull-rights ledger — holds zero tokens")

Spares: router `0x67bC67135A153EEAFDbF352f70EbaA0428d6636b` · executor
`0x81C35F38B209e7F4A025588cb93be8b51c3897E4` · builder `0x99928dACccf994868bC9ba80de0B47c8DA54151B`
· oracle `0xeBcC1E49Fb8AeBF95C9653821783e4887ae3aD45`.

Wallet: both accounts imported, Base Sepolia selected, and IMPORT THE v10 TOKENS so
balances show: USDC `0x9EB96112863ad3286e1f893532c676838D44E393` (6 dec) · cbBTC
`0x2E08FE4EF972DD20dCCdA57066d7735Ae8aF55d2` (8 dec). Balances: lender 400k USDC,
borrower ~10k USDC + 2.13 cbBTC. Terminal visible for Beat 4.

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
contract knows who I am; the deal was sold to one name." Review terms-as-code →
**Accept & approve cbBTC** → set 100000 → **Draw**: SIX chained prompts — draw (cash
out, collateral in), authorize repayment pulls, ship CURE leg, ship maturity leg,
register settlement, then the wallet SWITCHES TO HEDERA TESTNET for one signature
(the schedule — first time asks to add the network) and switches back. Narrate: "each
prompt is one leg of the term sheet — and the last one gives the network the
appointment." Obligations card appears: health meter + ticking term bar. The draw now
settles ITSELF at maturity — if the term is short (420s), it lands during Q&A.

**Beat 4 — the machine (timeline + explorer tabs):** the run-#9 history already on this
stack — Hedera schedule `0.0.9751046` "executed by the network" (HashScan), the Axelar
message hedera→base (executed), and the settle tx
`0x51057c09ecc8eaff85e2f56a064b1ad65ab7ebccad3968d553225b548e92b8c7`: lender
+100,000.061263 — interest exact to six decimals, capacity refilled 200k→300k in the
same tx. For the sentinel cure, narrate from STATUS/screenshots (it lives on an earlier
stack): "price crashed 20% — the network noticed on schedule and CURED the position from
pre-authorized funds. Zero penalty. The auction only exists for a drained borrower — and
it stops the moment the lender is whole." If asked for the default path live:
`forge test --match-contract Test6 -vv` in the terminal.

**Beat 5 — close (reconnect LENDER wallet):** the book: receivables, statuses, the settled row.
"Positions are one ERC-721 from a secondary market. Midnight built the bond market —
we built everything that isn't standard, and made it settle itself."

## Fallbacks

- RPC flaky → dashboard + explorer tabs carry the story; screenshots folder as last resort.
- New-deal publish hiccup on stage → fall back to the standing 0xFAC facility (default view).
- Live draw fails → the timeline already shows a real one; narrate over it.

## Judge questions — one-liners live in DEMO.md (Q&A section) and PRICING.md (the spread).
