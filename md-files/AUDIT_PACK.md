# AUDIT_PACK.md — v1 vault external-audit package

Prepared: WS8 (2026-07-28). Companion documents the auditor should read first:
`VAULT_PLAN.md` (design decisions), `MIDNIGHT_INTEGRATION.md` (the verified
on-chain trading spec every sleeve assumption rests on), `VAULT_RUNBOOK.md`
(ops posture the code assumes).

## 1. Scope — all novel Solidity

Everything in `contracts/src/vault/`; nothing else in the repo is in scope for
v1 (the hackathon contracts under `contracts/src/` are a separate, unlaunched
v2 track and share no code with the vault).

| File | Lines | Contents |
|---|---:|---|
| `contracts/src/vault/AlbaVault.sol` | 315 | ERC-4626 USDC vault: sleeve registry + caps, fee accrual as share dilution, pause, roles (OZ AccessControlEnumerable), liquidity-honest maxWithdraw/maxRedeem |
| `contracts/src/vault/MidnightSleeve.sol` | 399 | buy-and-hold Midnight zero-coupon paper: `take()` fills under atomic guards, O(1)-per-market amortized-cost accretion, lossFactor slash sync, FCFS redemption, curator emergencySell |
| `contracts/src/vault/MetaMorphoSleeve.sol` | 74 | thin 4626-in-4626 adapter to one fixed MetaMorpho vault (liquidity buffer) |
| `contracts/src/vault/interfaces/ISleeve.sol` | 31 | sleeve trust contract (4 functions + `kind()` discriminator) |
| `contracts/src/vault/interfaces/IMidnight.sol` | 73 | types copied **verbatim** from the verified deployed Midnight source; no logic |
| **Total** | **892** | (target from VAULT_PLAN §2 was < 900) |

Deployment path in scope for review (not for line count):
`contracts/script/DeployVault.s.sol` — role bootstrap/handoff ordering and the
buffer-first registry ordering are wiring-level security properties.

Compiler: solc 0.8.30, via-IR, optimizer 700 runs, `evm_version = "osaka"`
(required only to *execute* the deployed Midnight bytecode in fork tests; the
vault's own artifacts normalize to prague-or-earlier codegen).

## 2. Architecture summary

```
Depositors ── deposit/withdraw ──▶ AlbaVault (ERC-4626, USDC, 12-dec shares)
                                     │ totalAssets = idle + Σ sleeve.totalAssets()
                                     │ maxWithdraw bounded by liquidAssets() — honesty
                     ┌───────────────┴───────────────┐
             MetaMorphoSleeve                 MidnightSleeve
             (buffer; registry slot 0 —       (bond book, amortized cost,
              pulled FIRST on withdrawals)     never sold to fund exits)
                     │                                │
             MetaMorpho target                Midnight core (verified,
             (Moonwell Flagship USDC)          non-upgradeable, no admin
                                               over funds)
```

Key mechanisms an auditor should internalize before reading code:

- **NAV is oracle-free.** Bond lots are carried at amortized cost (purchase
  price + linear accretion to par), aggregated per market into a single
  accumulator (`Book`): no loops over lots, no mark-to-market, no price feed.
  The only external truth consulted is Midnight's own lazy position valuation
  (`updatePositionView`) — used to *haircut* the book when Midnight has
  socialized bad debt (lossFactor) or accrued a continuous fee.
- **Withdrawal liquidity is honest, not promised.** `maxWithdraw` = idle +
  Σ `sleeve.liquidAssets()`; the Midnight sleeve reports only synchronously
  claimable par (min of effective credit, the market's FCFS `withdrawable`
  pool, and carried book value). Withdrawals pull sleeves in registry order;
  paper is never sold to serve an exit.
- **On-chain guards, off-chain brains.** The allocator bot picks trades; the
  sleeve re-checks everything atomically on `take()`'s returned cost: caller's
  `maxAssets`, curator `maxBuyAssets`, never above par, curator min-yield
  floor, per-market face cap, market allow-list bound to Midnight's own
  `toMarket` struct hash (anti-spoofing).
- **Fees as dilution.** Management fee mints shares to `feeRecipient`;
  `_convertTo*` fold *pending* (unsettled) fee shares into every conversion so
  previews equal post-settlement execution.
- **Sleeves are trusted code** (ISleeve natspec): the vault believes sleeve
  accounting and uses no reentrancy guard (USDC has no hooks; sleeves are
  curator-registered behind the admin timelock). A malicious sleeve is a
  malicious vault — this is a deliberate, documented trust boundary, and the
  reason sleeve implementations are kept tiny.

## 3. Trust model — who can do what

| Actor | Powers | Cannot |
|---|---|---|
| **Depositor** (anyone) | deposit/mint/withdraw/redeem within honest limits; crank `MidnightSleeve.redeem(id)` (permissionless, par-only, toward the sleeve) | withdraw more than liquid assets; touch allocation or paper |
| **ALLOCATOR** (bot hot key) | `allocate`/`deallocate` vault↔sleeves (cap-checked); `MidnightSleeve.buy` within every guard in §2 | move funds anywhere but vault↔sleeve↔Midnight; exceed caps/floors; sell paper; change any parameter. Compromise = bounded in-policy bad trades (threat model: `bots/allocator/LIVE_MODE.md` §4) |
| **CURATOR** (ops multisig) | sleeve registry + caps, market allow-list + per-market caps, min-yield floor, max-buy size, fee (≤ 5%/yr hard cap) + recipient, `emergencySell` (with `minAssets` slippage floor) | pause/unpause; grant roles; withdraw funds to itself (emergencySell proceeds go to the sleeve; fee flows only via share dilution to the pre-set recipient) |
| **GUARDIAN** | `pause()` (instant circuit breaker: blocks deposits, withdrawals, `allocate`) | unpause (deliberately admin-only: a compromised guardian must not be able to reopen); anything else. `deallocate` still works while paused — recovery moves funds toward the vault |
| **DEFAULT_ADMIN** (multisig + 24–48 h timelock) | grant/revoke all roles (enumerable on-chain); `unpause` | directly curate or allocate (asserted in `test_RoleMatrix`) — admin is a role-manager, not an operator |
| **Midnight itself** | non-upgradeable, no pause, no fund-moving admin. Residual governance surface: a 5-of-9 configurator Safe could staff a feeSetter → capped fees (≤ 50 bp price spread on *new* fills, ≤ 1%/yr continuous on *new* positions — absorbed by the buy guards). Bad debt in an allow-listed market is socialized pro-rata onto our credit (lossFactor) with no insurance fund | reach retroactively into existing positions beyond lossFactor mechanics; block `withdraw` (touches no oracle, no gate) |
| **MetaMorpho target** | its own curator/allocator govern its markets; utilization or a freeze can gate `maxWithdraw` to 0 | take more than the buffer allocation; the sleeve clamps withdrawals to the target's stated liquidity and never reverts the vault's exit path |

## 4. External dependencies

| Dependency | Version / address | Notes |
|---|---|---|
| OpenZeppelin Contracts | **5.4.0** (vendored via `lib/swap-vm/node_modules`) | ERC4626 (decimals-offset 6 → 12-dec shares), AccessControlEnumerable, Pausable, SafeERC20, Math |
| Midnight core | Base `0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A`, solc 0.8.34, **non-upgradeable, verified** (Sourcify + Blockscout) | full lender-side behavior spec in MIDNIGHT_INTEGRATION.md; `IMidnight.sol` types copied verbatim from its source |
| MetaMorpho target | Moonwell Flagship USDC `0xc1256Ae5FF1cf2719D4937adb3bbCCab2E00A2Ca` (deploy-time constructor arg; curator choice) | trusted as an ERC-4626 with honest `maxWithdraw`; fork-tested (T4) |
| USDC (Base) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | no transfer hooks — the stated basis for omitting reentrancy guards |
| forge-std / Foundry | forge ≥ 1.5.x required (osaka fork tests) | test-only |

## 5. Known, accepted risks (do not report as findings — challenge the *reasoning*)

1. **FCFS redemption race.** Midnight's `withdrawable` pool is first-come-
   first-served across all lenders in a market. Our claims can be beaten to
   the pool; `liquidAssets()` reads the pool live so the vault never
   *promises* the contested cash, but realized redemption latency is
   market-dependent. Accepted: ladder + buffer sizing; permissionless
   `redeem()` cranking.
2. **lossFactor socialization pass-through.** Midnight bad debt slashes lender
   credit pro-rata, immediately, with no make-whole. The sleeve passes this
   through to NAV lazily-but-honestly (view haircut at once; state re-sync at
   next touch). Depositors who exit between a slash and the next NAV read
   cannot profit (the haircut is in the view path), but the *per-lot* error
   noted in the sleeve natspec (pro-rata haircut across the market book, not
   per lot) is accepted as bounded by the discount (bps).
3. **Amortized cost vs forced early sale.** Book value assumes hold-to-
   maturity. `emergencySell` realizes execution price, which can be below
   carry — NAV steps down at that moment. Accepted: curator-only, slippage-
   floored; the alternative (mark-to-market) imports an oracle/manipulation
   surface v1 deliberately excludes.
4. **Allocator liveness.** A dead bot stops buys and redemption cranks;
   accretion and NAV are unaffected, liquidity honesty degrades toward
   buffer-only. Accepted: permissionless `redeem`, watchdog alerting,
   guarded caps.
5. **Midnight settlement-fee activation.** Currently all fees are zero and
   roles unstaffed; caps are immutable and small (§3). The buy guards absorb
   activation; monitoring watches the fee events.
6. **Donations.** USDC donated to vault or sleeves raises share price
   (up-only); the 1e6 decimals-offset makes inflation attacks strictly
   unprofitable (`test_InflationAttack_NotProfitable`).

## 6. Invariants claimed (and where they are machine-checked)

| Invariant | Enforced/checked |
|---|---|
| Share price never decreases absent a slash, an emergencySell loss, or fees | `VaultInvariant.t.sol::invariant_SharePriceMonotonicModuloFees` (fee=0, no-loss handler over deposit/withdraw/allocate/buy/warp/redeem interleavings) |
| `liquidAssets() ≤ totalAssets() (+1 wei dust)` — never promise more exit than value | `VaultInvariant.t.sol::invariant_LiquidNeverExceedsTotal`; per-market clamp in `MidnightSleeve.liquidAssets` |
| Midnight book never carried above face (par) | `VaultInvariant.t.sol::invariant_MidnightBookNeverExceedsFace`; `_bookValue` clamp + `AbovePar` guard |
| `maxWithdraw` is exactly executable; `maxWithdraw + 1` reverts | `LiquidityHonesty.t.sol` (incl. fuzz `testFuzz_MaxWithdrawAlwaysExecutable`) |
| Buys are NAV-neutral at cost; accretion is linear to par then flat | `MidnightSleeve.t.sol`, `MidnightSleeve.fork.t.sol` (real fill, pinned Base fork) |
| Redemption pays par exactly, never marks NAV down (rounding: `_scale` ceils, accrual floors) | `test_Fork_RedeemAtMaturity_ParExactly`, `test_Redeem_Permissionless_EarlyPullRealizesGain` |
| Allocator cannot exceed any curator bound | guard tests in both MidnightSleeve suites (`CostAboveMax`, `YieldTooLow`, `MarketCapExceeded`, cap tests in `AlbaVault.t.sol`) |
| Role matrix: admin non-operational, guardian cannot unpause, sleeve roles read from vault | `test_RoleMatrix`, `test_Roles_ReadFromVaultAccessControl` |
| Fee previews equal post-settlement execution (pending-fee-aware conversions) | `test_FeeAccrual_*`, `test_PreviewConsistency` |

Suite: 109 tests / 15 suites, including fork tests against pinned Base block
49,219,332 with a real off-chain offer fixture (`test/vault/fixtures/`).

## 7. Open questions the auditor should challenge

1. **`_scale` rounding asymmetry.** Book scaling rounds UP (units, cost,
   accrued, rate) to avoid NAV dips on par redemption. Can repeated partial
   claims/sells accumulate overstatement beyond the claimed "≤ 1 wei per
   field", and can `units` overstatement vs Midnight credit ever make
   `liquidAssets` overstate? (We claim the credit-side `Math.min` clamps it.)
2. **Slash-window accounting.** Between a lossFactor slash and the next
   state-touch, `_bookValue` haircuts pro-rata on *face* while accretion keeps
   running on the pre-slash rate. Is there an interleaving (slash → warp →
   partial claim) where NAV steps *up* incorrectly or a depositor games
   entry/exit around the re-sync?
3. **`buy()` re-sync trust.** `syncedOld = credit(id) - units` assumes
   `take()` credited exactly `units` and that no other flow touched our
   position in-between (no donations of credit are possible — verified — but
   challenge it). Underflow here would brick buys for the market.
4. **Fee-share math.** `_pendingFeeShares` dilution formula (esp. the
   `assets - feeAssets + 1` denominator and the interaction with the virtual
   offset) — is it exact for `feeRecipient` redemption, and can a zero
   `feeRecipient` with nonzero pending fees ever occur (setter ordering)?
5. **Paused-state asymmetries.** `deallocate` and `MidnightSleeve.redeem`
   work while paused (deliberate); `redeem` is also permissionless. Any grief
   via cranking redemptions during an incident (e.g., realizing accretion
   early to move NAV while shares are frozen)?
6. **MetaMorpho honesty dependence.** The buffer sleeve trusts
   `TARGET.maxWithdraw` to be executable (4626 spec). Known MetaMorpho
   versions comply; if the target overstated, `AlbaVault.maxWithdraw` would
   overpromise and `_withdraw` could revert mid-pull. Is the trust
   justified for the chosen target; should the sleeve try/catch?
7. **Registry-order withdrawal loop.** `_withdraw` decrements `missing` by
   each sleeve's returned amount; a sleeve returning *more* than requested
   would underflow (revert). ISleeve forbids it — but it is a trusted-code
   assumption worth stating adversarially.
8. **Small-supply edge.** With the 1e6 offset, first-depositor and
   dust-supply behavior around fee accrual (`feeAssets >= assets` clamp) —
   any path to minting absurd fee shares at near-zero supply?
9. **`uint96`/`uint128` casts.** Sleeve cap is uint96 (~7.9e28 — fine for
   USDC), book fields uint128; `b.units += uint128(units)` after guards —
   confirm no cap-bypass via truncation for adversarial `units`
   (bounded by offer consumption ≤ uint128 and the cap check *after* add).
10. **Event-derived indexing.** WS7/watchdog rebuild lot state purely from
    `Bought/Redeemed/EmergencySold` post-state fields — confirm every
    book-mutating path emits (allowMarket/removeMarket cover the rest; no
    mutation path silent).
