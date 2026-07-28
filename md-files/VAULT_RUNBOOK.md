# VAULT_RUNBOOK.md — v1 vault operations

Audience: whoever holds the curator/guardian/admin seats and runs the
allocator. Companion docs: `AUDIT_PACK.md` (trust model), `MIDNIGHT_INTEGRATION.md`
(protocol mechanics), `bots/allocator/LIVE_MODE.md` (bot live-mode spec).

## 1. Deploy checklist (Base mainnet)

Script: `contracts/script/DeployVault.s.sol` (forge ≥ 1.5.x — the repo's
`evm_version = "osaka"` will not build on forge 1.0.0).

Pre-flight, in order:

1. **Role addresses exist and are what they claim to be:**
   - `ADMIN` — the multisig-behind-timelock (24–48 h). Verify the timelock is
     the role holder, not the bare Safe; verify signers and threshold.
   - `CURATOR` — ops multisig (can be the same signers, different threshold).
   - `ALLOCATOR` — the bot's hot key. Fresh key, gas-only balance, in the
     secret store (never in `config.json`).
   - `GUARDIAN` — pause key(s). Optimize for *speed* (a warm key per on-call
     human is acceptable — guardian can only pause, and cannot unpause).
   - `FEE_RECIPIENT` — optional at deploy; fee stays 0 until curator sets it.
2. **Caps for launch week 0** (see §5 schedule): `BUFFER_CAP=75000e6`,
   `MIDNIGHT_CAP=25000e6`, `MAX_BUY_ASSETS=5000e6`, `MIN_YIELD_WAD` = current
   floating benchmark + 75 bp, expressed as annualized simple yield (WAD).
3. **Target choice:** `METAMORPHO_TARGET` defaults to Moonwell Flagship USDC
   (fork-tested). Any change requires re-running the T4 fork suite against the
   new target first.
4. **Dry-run the exact command** on anvil (`anvil --port 8547`, same env, plus
   `PAUSE_ON_DEPLOY=true` to rehearse the mainnet path) and read the address
   book + post-condition asserts.
5. **Deploy:** `forge script script/DeployVault.s.sol --rpc-url $BASE_RPC --broadcast --verify`.
   Mainnet deploys **PAUSED** by default — go-live is the ADMIN (through the
   timelock) calling `unpause()`, which simultaneously proves the admin
   handoff worked.
6. **Post-deploy verification (before unpause):**
   - address book recorded in the ops repo; contracts verified on Basescan;
   - `sleeves(0)` = buffer sleeve, `sleeves(1)` = Midnight sleeve (pull order);
   - role enumeration (`getRoleMember*`) shows exactly the intended holders,
     deployer nowhere;
   - `MidnightSleeve.kind() == "midnight"`, `MetaMorphoSleeve.kind() ==
     "metamorpho"`, `TARGET()` is the intended MetaMorpho vault.
7. **Curator actions after unpause:** `allowMarket(id, maxUnits)` for each
   chosen market — verify `id` against the REST API AND `toMarket(id)`
   maturity/loanToken on-chain; set per-market caps per §5. Only ungated
   markets (`enterGate == liquidatorGate == 0`), USDC loan token, maturity
   inside the ladder window.

## 2. Bot operation

**Dry-run (default, safe):** `node bots/allocator/allocator.mjs --loop 300` —
no keys, no transactions; paper-trades live books, writes `decisions.jsonl` +
`state.json`. Run it continuously even after live mode exists — it is the
strategy's control group.

**Live (once implemented per `LIVE_MODE.md` — spec only today):**
- separate systemd unit, separate key, `--live` flag, per-run spend ceiling;
- every `buy` follows the mandatory pre-submit re-quote rule (offers expire in
  hours and get consumed FCFS; never submit scan-time calldata);
- the reconciliation watchdog (§3) runs in the same cycle BEFORE any action
  and halts trading on divergence;
- `redeem()` cranking and buffer rebalancing go live first; `buy()` last.

Restart safety: single-flight lock file; state rebuilds from on-chain events
(`Bought`/`Redeemed`/`EmergencySold` carry post-operation book state).

## 3. Monitoring — what the watchdog checks

Independent NAV recompute every cycle (VAULT_PLAN §6): idle + Σ per-market
(cost + accretion, haircut by `updatePositionView`) + buffer, compared to
`vault.totalAssets()`. Alert thresholds and full reconciliation table:
`LIVE_MODE.md` §5. Headlines:

| Check | Alert when |
|---|---|
| shadow book vs `book(id)` / `credit(id, sleeve)` | any mismatch beyond event replay |
| NAV recompute vs `totalAssets()` | > 1e-6 relative — accounting bug, page a human |
| `liquidAssets() ≤ totalAssets()` | violated — invariant break, PAUSE |
| Midnight `Liquidate` events | `badDebt > 0` on an allow-listed market (slash — see §4.4) |
| Midnight fee events (`SetFeeSetter`, `SetMarket*Fee`) | any — retune spread floors before further buys |
| `withdrawable(id)` after maturity | ~0 for > 2 h (liquidation stall) |
| vault `RoleGranted`/`RoleRevoked`, `Paused`, sleeve registry events | anything the ops log didn't expect |
| bot heartbeat | missed cycle > 2× loop interval |
| allocator key balance/spend | gas drain or unexpected nonce activity |

## 4. Incident procedures

Principle: **guardian pauses fast, admin (timelocked) fixes slow.** Pause
blocks deposits/withdrawals/allocate; `deallocate` and permissionless
`redeem()` still work — recovery always moves funds toward the vault.

### 4.1 Pause criteria (guardian, immediately, no committee)
- invariant break (`liquid > total`, NAV mismatch) or any suspected
  accounting bug;
- suspected allocator key compromise (unexpected buys/allocations);
- suspected curator key compromise;
- Midnight-wide anomaly (mass bad debt, oracle exploit in an allow-listed
  market's collateral);
- any unexplained role or registry change.
Unpause requires ADMIN through the timelock — treat every unpause as a
post-mortem gate.

### 4.2 Rogue/compromised allocator
1. GUARDIAN: `pause()` (stops `allocate` and new user flows; on-chain guards
   have already bounded trade damage to in-policy fills).
2. ADMIN (timelock): `revokeRole(ALLOCATOR_ROLE, oldKey)` — holders are
   enumerable on-chain, nothing hides in logs.
3. Assess: replay `Bought` events vs policy; paper bought in-policy is kept to
   maturity (it is money-good paper bought at a defensible yield).
4. New key, drill checklist from `LIVE_MODE.md` §4, then unpause.

### 4.3 MetaMorpho freeze / high utilization
Symptom: buffer `liquidAssets()` collapses; vault `maxWithdraw` honestly
shrinks toward idle-only. This is designed-for, not an emergency:
1. Do NOT pause for utilization alone — limits self-adjust; depositors see
   the honest number.
2. ALLOCATOR: `deallocate(buffer, …)` cranks whatever the target frees.
3. CURATOR: if structural (target governance incident), stop new buffer
   allocations (cap → current level, timelocked), pick replacement target,
   migrate as liquidity returns, `removeSleeve` when empty.
4. Communicate: "instant liquidity = X; maturity ladder pays Y on dates Z" —
   the frontend already renders this.

### 4.4 Midnight bad-debt event (lossFactor slash)
Symptom: `Liquidate` with `badDebt > 0`; watchdog projects the haircut.
1. NAV haircuts automatically at the next read (`_bookValue` uses Midnight's
   own valuation) — no action needed for accounting.
2. Verify the next state-touch (`buy`/`redeem`) re-syncs the book to the
   watchdog's predicted face/cost (events carry post-sync state).
3. CURATOR: freeze the market for new buys (`setMarketCap(id,
   currentFace)` — cap checks bind future buys only), decide hold-vs-
   emergencySell on the residual (default: hold; the paper still pays
   post-slash par).
4. If cascade risk (cbBTC crash, multiple markets): GUARDIAN pause while
   assessing total exposure; remember paper cannot be un-bought — pausing
   protects against panic-priced exits and mispriced deposits, not the loss
   itself.
5. Disclose the slash and NAV impact same-day (the book is public; someone
   else will read it if we don't).

### 4.5 Vault-bug class (worst case)
Pause; `deallocate` everything liquid to vault idle; hold Midnight paper to
maturity redeeming into the paused vault; admin-timelock a fix/migration.
There is no upgrade path by design — migration = new vault + user opt-in.

## 5. Guarded-launch caps schedule (VAULT_PLAN §6)

Gates, not dates: each phase requires the previous one's exit criteria.
Cap raises are CURATOR actions behind the ADMIN timelock policy — announce
before raising.

| Phase | Deposits | Sleeve caps (buffer / midnight) | maxBuy / per-market | Exit criteria |
|---|---|---|---|---|
| 0 — deploy | paused | 75k / 25k set, unused | 5k / 10k | address book verified, roles enumerated, watchdog live on mainnet reads |
| 1 — pilot (own capital, ~$50–100k) | team only (unpause, but do not market) | 75k / 25k | 5k / 10k | 4–6 weeks clean: ≥ 3 maturities redeemed at par, ≥ 1 pause/unpause drill, ≥ 1 allocator-key rotation drill, watchdog zero unexplained alerts |
| 2 — friends & family | ~250k AUM | 150k / 75k | 10k / 25k | 4 weeks clean; withdrawal honesty observed under a real exit; external audit **scheduled** |
| 3 — open (post-audit) | audit findings closed | 500k / 250k | 25k / 50k, ≥ 3 markets | audit published; 8 weeks track record; Keyrock/Morpho conversations on live numbers |
| 4+ — scale | raise with book depth | cap ≤ ~20% of visible ask depth per market; buffer ≥ 20% NAV | per curve | quarterly review; v1.1 withdrawal-queue decision on demand data |

Standing constraints at every phase (from the plan's ladder policy):
per-maturity ≤ min(10% AUM, 25% of that book's visible depth); tenor window
2–90 d; min spread ≥ 75 bp over the floating benchmark (curator floor
`setMinYield` tracks it); buffer target 20% of NAV.

Cut-and-run rule: if Midnight books stay too thin to deploy (< ~30% of the
Midnight cap productive for a month), do not chase yield down — shrink the
Midnight cap and say so. "Nothing worth buying" is the strategy working
(WS5's live verdict on day one).
