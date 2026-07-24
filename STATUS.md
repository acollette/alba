# STATUS — gate tracking

## Hours 1–5: Spike + trigger leg

### Item 1 — Axelar/Hedera spike (30 min timebox) ✅ GREEN (~15 min)

**Verdict: Hedera IS a supported Axelar GMP source chain on testnet.** Evidence:

- Hedera testnet (chainId 296, axelarId `hedera`, chainType `evm`) is in the canonical
  Axelar chain registry (`axelar-contract-deployments/axelar-chains-config/info/testnet.json`).
- Gateway contract verified live on-chain via Hashio RPC (`eth_getCode` returns proxy code).
- Axelarscan GMP API: **1,005 messages with Hedera as source**, recent ones executed
  (latest ~1 day old). **45 messages on the exact `hedera → base-sepolia` route, all `executed`.**
- Scheduled contract calls: HIP-1215 (generalized scheduled contract calls via the
  Schedule Service system contract at `0x16b`) is live on testnet since v0.68 (Dec 2025).
  A contract can schedule a future call to itself/another contract — the network executes it.

**Testnet addresses (both from registry):**

| Contract | Hedera testnet (296) | Base Sepolia (84532) |
|---|---|---|
| AxelarGateway | `0xe432150cce91c13a887f7D836923d5597adD8E31` | `0xe432150cce91c13a887f7D836923d5597adD8E31` |
| AxelarGasService | `0xbE406F0189A0B4cf3A05C286473D23791Dd44Cc6` | `0xbE406F0189A0B4cf3A05C286473D23791Dd44Cc6` |

- Hedera RPC: `https://testnet.hashio.io/api` · Base Sepolia RPC: `https://sepolia.base.org`
- Axelar chain identifiers for GMP calls: `"hedera"`, `"base-sepolia"`.

**Known quirks to respect while building:**
- Hedera EVM `msg.value` is denominated differently (tinybars, 8 decimals) than the
  JSON-RPC layer (weibars, 18 decimals) — verify gas-service payment amounts empirically.
- Hedera finality wait ~1 (fast); Base Sepolia ~30.

### Item 2 — Hedera scheduled tx → Axelar GMP → Base Sepolia receiver 🔨 IN PROGRESS

- [ ] Foundry scaffold + spike contracts (sender on Hedera, dumb receiver on Base Sepolia)
- [ ] Wallets funded (Hedera testnet HBAR + Base Sepolia ETH)
- [ ] Manual `dispatch()` → message executes on Base Sepolia
- [ ] Scheduled dispatch via HSS (`0x16b`) → fires without any keeper
- **HOUR-5 GATE:** if not firing → fallback per PLAN.md (manual relay, honest narration)

## Hours 5–10: Foundry on Base mainnet fork — not started
## Hours 10–14: Default path + real wiring — not started
## END-OF-DAY-1 GATE — not reached
