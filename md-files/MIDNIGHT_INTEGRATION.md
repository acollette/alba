# MIDNIGHT_INTEGRATION.md — WS1: on-chain trading spec for Morpho Midnight

Status: research complete (2026-07-28). Answers below are labeled **[VERIFIED — contract source]**
(read from the verified deployed source), **[VERIFIED — on-chain read]** (queried live from Base
mainnet), **[DOCS/SDK]** (Morpho docs or `@morpho-org/midnight-sdk@1.3.0` — authoritative but not
bytecode), or **[INFERRED]**.

## Primary sources

- **Core contract (Base mainnet, chainId 8453):** `0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A`.
  Verified on Sourcify (match, verifiedAt 2026-07-06) and Blockscout:
  - https://sourcify.dev/server/v2/contract/8453/0xadedd8ab6de832766fedf0fac4992e5c4d3ea18a
  - https://base.blockscout.com/address/0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A?tab=contract
  - Fully-qualified name `lib/midnight/src/Midnight.sol:Midnight`, Solidity 0.8.34, BUSL-1.1,
    "Copyright (c) 2026 Morpho Association". Single flat contract, no proxy. ~1,018 lines + small libs.
  - Line references below ("Midnight.sol:N") are against the Sourcify source tree
    (downloaded during this research; re-fetch with the URL above).
- **SDK:** `@morpho-org/midnight-sdk@1.3.0` (npm, published 2026-07-24, repo `morpho-org/sdks`).
- **Docs:** https://docs.morpho.org/developers/midnight/get-started/ and
  https://docs.morpho.org/get-started/resources/addresses/
- **REST API:** `https://api.morpho.org/v0/midnight` (what `rates/` already uses).

### Official deployed addresses [DOCS, cross-checked on-chain]

| Contract | Address (Base) | Role |
|---|---|---|
| Midnight (core) | `0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A` | all positions, take/withdraw/repay/liquidate |
| SetterRatifier | `0x800B5F12A61B8198a5a6EfD794Cac6699B294d63` | offer validation for smart-contract makers (verified source read) |
| EcrecoverRatifier | `0xd6e70365C8E8DDa9a4ca662C07bbE663b017755E` | offer validation for EOA / EIP-7702 makers |
| EcrecoverAuthorizer | `0x292bEa9f1443d54E0E509120c919106765c6a493` | periphery (source not reviewed — see unknowns) |
| Mempool | `0xdD6DCE32e21f7b020898a8258dA37355b4017993` | on-chain distribution of signed offer payloads (maker-side) |

Key architectural fact that reframes everything: **Midnight is an off-chain order book with
on-chain settlement.** Offers are NOT resting on-chain state. An `Offer` is a struct signed/ratified
by its maker off-chain (distributed via the Morpho API / Mempool contract); the on-chain contract only
tracks cumulative consumption per offer group. A taker submits the full `Offer` struct + a ratifier
proof in the `take()` call. The REST API's `takeable-offers` endpoints return exactly the two things
`take()` needs: the ABI-ready `offer` struct and opaque `ratifier_data` bytes. **[VERIFIED — contract
source `take()` Midnight.sol:363-515 + SDK `api/helpers.js mapTakeableOffer`]**

---

## Q1. What is a "unit" on-chain?

**A unit is NOT a token.** There is no ERC-1155, ERC-6909, or ERC-20 per market. A lender position
is an internal balance in the core contract:

```solidity
mapping(bytes32 id => mapping(address user => Position)) public position;   // Midnight.sol:196
struct Position { uint128 credit; uint128 pendingFee; uint128 lastLossFactor;
                  uint128 lastAccrual; uint128 debt; uint128 collateralBitmap;
                  uint128[128] collateral; }                                // IMidnight.sol:59-67
```

- **`credit` = units held.** 1 unit redeems for exactly 1 base unit of the loan token at par:
  `withdraw()` does `safeTransfer(market.loanToken, receiver, units)` (Midnight.sol:535). For USDC
  markets, **1 unit = 1e-6 USDC of face value** (unit decimals ≡ loan-token decimals, 6).
  **[VERIFIED — contract source]**
- Docs phrase it: "Credit units represent claims on loan tokens at maturity; debt units represent
  obligations to repay loan tokens." **[DOCS]**
- **Transferability: none.** There is no transfer function. The only ways credit moves between
  addresses are (a) a trade via `take()` (which requires a ratified offer and pays the settlement
  fee) and (b) `withdraw()` to cash. A vault sleeve therefore **holds units in its own address's
  position** — no wrapping, no custody adapter possible without a trade. **[VERIFIED — contract
  source: exhaustive read of all entry points]**
- **Delegation:** `setIsAuthorized(authorized, true, onBehalf)` lets another address act on the
  position (take as taker, withdraw, etc.). Authorization is blanket, not scoped — the contract
  natspec itself says "to scope authorizations one should authorize a smart-contract with scoped
  behavior" (Midnight.sol:110-119). For v1 the sleeve should act for itself and authorize nobody.
- **Accounting the sleeve must replicate:** current face value of a position is NOT raw `credit`.
  Two adjustments apply lazily at each interaction (Midnight.sol:837-890 `updatePositionView`):
  1. **Slashing:** credit is scaled by the market `lossFactor` accrued since the position's
     `lastLossFactor` (bad-debt socialization, see Q4).
  2. **Continuous fee:** `pendingFee` (set at buy time = creditIncrease × continuousFee × TTM)
     accrues linearly from `lastAccrual` to maturity and is deducted from credit.
  Effective par at maturity = `credit - pendingFee` (contract natspec, Midnight.sol:54). The
  view `updatePositionView(market, id, user)` returns up-to-date `(credit, pendingFee, accruedFee)`
  — use it for `totalAssets()` inputs rather than the raw getters. Currently continuousFee = 0 on
  all USDC markets (see Q5), so today credit is exact face. **[VERIFIED — contract source + on-chain read]**
- **Dust:** no minimum position or trade size on-chain; all amounts uint128. (The API's maker-side
  mempool policy has a `min_offer_assets_usd` rule, but that binds makers posting offers, not takers.)
  **[VERIFIED — contract source; SDK `api/types.js MempoolPayloadValidationRule`]**

## Q2. How does a taker fill a standing offer on-chain?

One function on the core contract (Midnight.sol:363):

```solidity
function take(
    Offer memory offer,             // full struct, served by the API
    bytes memory ratifierData,      // opaque proof bytes, served by the API
    uint256 units,                  // how many units WE choose to take (partial fill)
    address taker,                  // must be msg.sender (or authorizer of msg.sender)
    address receiverIfTakerIsSeller,// MUST be address(0) when taking a sell offer (we are buyer)
    address takerCallback,          // 0 for plain pre-approved fill
    bytes memory takerCallbackData
) external returns (uint256 buyerAssets, uint256 sellerAssets);
```

with (IMidnight.sol:23-39):

```solidity
struct Offer {
    Market market;          // full market params embedded (chainId, midnight, loanToken,
                            //  collateralParams[], maturity, rcfThreshold, gates)
    bool buy;               // false = maker SELLS units (borrower issuing / lender exiting)
    address maker;
    uint256 start;          // offer validity window (unix s)
    uint256 expiry;
    uint256 tick;           // price = TickLib.tickToPrice(tick), logistic curve, WAD-scaled
    bytes32 group;          // shared consumption bucket ("one cancels the other")
    address callback;       // maker-side callback
    bytes callbackData;
    address receiverIfMakerIsSeller; // where the borrower wants proceeds
    address ratifier;       // SetterRatifier or EcrecoverRatifier
    bool reduceOnly;
    uint128 maxUnits;       // exactly one of maxUnits/maxAssets is nonzero
    uint128 maxAssets;
    uint256 continuousFeeCap;
}
```

Mechanics, all **[VERIFIED — contract source]**:

- **Which side we take:** the vault lends ⇒ we are the **buyer** of units, so we take offers with
  `offer.buy == false` — the API's **`asks`** book (`GET /books/{marketId}/asks/takeable-offers`;
  SDK asserts `side "asks" ⇒ offer.buy == false`). The maker is a borrower issuing a zero-coupon
  bond (their `debt` increases; health-checked against their cbBTC at the end of the take,
  Midnight.sol:512) or a lender exiting (their `credit` decreases). Best ask = **lowest tick**
  (lowest price = highest yield); the SDK sorts asks ascending by tick.
- **Market/offer identifiers:** there is no on-chain order id. The market id is
  `keccak256(0xff ‖ midnight ‖ 0 ‖ keccak256(SSTORE2_PREFIX ‖ abi.encode(market)))` (IdLib.sol) —
  i.e., derived from the full Market struct, which travels inside the offer. The offer is identified
  by its full contents; consumption is tracked per `(maker, group)` in
  `consumed[maker][group]` (uint128).
- **Ratification:** `take` requires `isAuthorized[offer.maker][offer.ratifier]` and
  `IRatifier(offer.ratifier).isRatified(offer, ratifierData, taker) == CALLBACK_SUCCESS`
  (Midnight.sol:386-387). For the SetterRatifier (used by the live offers we sampled),
  `ratifierData = abi.encode(bytes32 root, uint256 leafIndex, bytes32[] proof)` — a Merkle proof
  that the offer is in a tree whose root the maker ratified on-chain (SetterRatifier source, verified
  on Sourcify/Blockscout). For EcrecoverRatifier it additionally carries an EIP-712 (v,r,s) over the
  tree root (SDK `signatures/EcrecoverRatifierUtils.js`). **The taker treats `ratifier_data` from the
  API as opaque bytes and forwards it verbatim.**
- **Pricing & what we pay:** `offerPrice = tickToPrice(tick)` (same logistic curve `rates/` already
  implements: `1e18 / (1 + e^(0.004987541511039073 · (3372 − tick)))`, rounded to 1e11 steps;
  TickLib.sol). For a sell offer: `sellerPrice = offerPrice`, `buyerPrice = offerPrice +
  settlementFee(id, timeToMaturity)`;
  `buyerAssets = mulDivUp(units, buyerPrice, 1e18)` — **rounded against the taker**
  (Midnight.sol:389-395). We pay `buyerAssets` USDC for `units` units of par.
- **Money flow / approvals:** with no taker callback, `payer = msg.sender`. Midnight executes
  `transferFrom(USDC, payer, midnight, buyerAssets − sellerAssets)` (the fee part) and
  `transferFrom(USDC, payer, offer.receiverIfMakerIsSeller, sellerAssets)` (Midnight.sol:491-492).
  ⇒ **the sleeve approves USDC to the Midnight core contract `0xAdedD8ab…18A`, nothing else.**
  (Alternative: set `takerCallback` to a contract implementing `IBuyCallback.onBuy` and Midnight
  pulls from the callback contract instead — not needed for v1.)
- **Partial fills:** first-class. The taker picks any `units`; the only cap is the offer's remaining
  size: `consumed[maker][group] + units ≤ maxUnits` (or the assets analog, Midnight.sol:397-404).
  Several offers can share a `group` (fixed-rate "offer chains" — SDK `OfferChainUtils` builds
  adjacent time-windowed ticks sharing one reserve), so remaining size must be read as
  `max − consumed` at fill time, and two of our own fills in the same block compound.
- **Filling depth:** one `take()` per offer. To sweep several price levels atomically use the core's
  own `multicall(bytes[])` (Midnight.sol:219, delegatecall loop — but note `msg.sender` semantics
  make this suitable only when the sleeve itself is the caller) or loop takes inside one sleeve
  `buy()` transaction.
- **Slippage / limit price:** there is **no slippage parameter on-chain** — each offer's price is
  exact by construction. The only execution-price variable is the settlement fee, which the feeSetter
  could change between quote and inclusion (contract natspec Midnight.sol:355-358 explicitly
  recommends a smart-contract wrapper for atomic price checks). **Sleeve guard: pass `maxBuyerAssets`
  (or min-yield ⇒ max price) into `MidnightSleeve.buy()` and revert if `take`'s returned
  `buyerAssets` exceeds it.** That single check subsumes tick, fee, and rounding. The API also offers
  a server-side router: `GET /books/{id}/{side}/quote?assets|units=…&slippage=…` returns an ordered
  list of takeable offers + `average_worst_price` — useful for the bot, but the on-chain guard is
  what protects us.
- **Failure modes to handle:** `OfferExpired` / `OfferNotStarted` (offers observed live are
  short-lived, ~30 h legs), `ConsumedUnits/ConsumedAssets` (raced by another taker),
  `AlreadyConsumed`-style cancels (maker can bump `setConsumed` to cancel, or un-ratify the root in
  SetterRatifier at any time ⇒ `RatifierFailed`), `SellerIsLiquidatable` (borrower-maker's oracle
  health check fails at fill time), `TickNotAccessible`, `SelfTake` (maker == taker reverts —
  relevant later if Alba ever runs maker-side too), `MarketLossFactorMaxedOut`,
  `CannotIncreaseDebtPostMaturity` (no new borrowing after maturity — buying from an exiting lender
  still works). The bot should treat all of these as "refetch book, retry".

Sanity check against live data **[VERIFIED — on-chain read + API, 2026-07-28, block ~49,218,924]**:
the Aug-28-2026 15:00 UTC cbBTC/USDC market (`market_id
0x05959752fdeff325962b9d263edb421efc6e2186a49360dba6c32e86ebf6c84c`) had 3 takeable ask offers
totaling ≈ $234.7k par (was ≈ $297k when scoped earlier); top offer: maker
`0xd418…6ee4`, tick 4516 ⇒ price ≈ 0.99668 ⇒ ≈ 3.9% APR at 31 d TTM, `max_assets = 100,000e6`,
ratifier = SetterRatifier, settlement fee currently 0 ⇒ buyerPrice = tick price exactly.

## Q3. Redemption at maturity

**There is no separate "redeem at par" function and no claim window. Redemption = `withdraw()`
against a shared FIFO cash pool.** **[VERIFIED — contract source]**

```solidity
function withdraw(Market memory market, uint256 units, address onBehalf, address receiver) external;
// Midnight.sol:517-536
```

- Callable by the position owner or an authorized address, any time — **including before maturity**.
  The binding constraint is `marketState.withdrawable -= units` (reverts on underflow):
  `withdrawable` is the pool of loan tokens paid in by borrower `repay()`s and liquidation
  repayments. Pays exactly `units` loan tokens (1:1 par), pro-rata reduces `pendingFee`.
- **Timing:** maturity (`market.maturity`, exact unix second) is not a payout event. Nothing pushes
  cash to lenders. The sequence is: borrowers repay (any time; post-maturity they can no longer
  increase debt — Midnight.sol:422 — and anyone may liquidate them, see below) → `withdrawable`
  fills → lenders pull. **First-come-first-served**: the contract natspec (Midnight.sol:27-29)
  explicitly notes lenders "might race to withdraw first" when assets become withdrawable early.
  If borrowers have repaid in full by maturity, everything is claimable at maturity+1s.
- **If borrowers don't repay by maturity:** `liquidate(..., postMaturityMode=true, ...)` becomes
  permissionlessly available the second `block.timestamp > maturity` (Midnight.sol:661). The
  liquidation incentive ramps linearly from 1.0× at maturity to `maxLif` at maturity + 60 min
  (`TIME_TO_MAX_LIF`, ConstantsLib). For the cbBTC params in use (lltv 0.86, cursor 0.30),
  `maxLif = 1/(1 − 0.30·0.14) ≈ 1.0438` — up to ≈ 4.38% bonus, so liquidators clear the market
  within roughly an hour of maturity under normal conditions. Each liquidation's `repaidUnits`
  lands in `withdrawable`. Our bot can itself liquidate as a backstop (and capture the bonus).
- **Unclaimed par:** sits as `credit` indefinitely — no expiry, no sweep, no fee on idle claims
  (continuous fee stops accruing at maturity: accrual is pro-rated to `min(now, maturity)`,
  Midnight.sol:851). Nobody but the owner/authorized can move it.
- **Fees on redemption: none** (see Q5; settlement fee applies to trades, not withdrawals).
- **Sleeve consequence:** `MidnightSleeve.redeem(lot)` = `withdraw(market, units, sleeve, sleeve)`,
  callable by the allocator bot any time `withdrawable ≥ units` (poll `withdrawable(id)` — it's a
  public getter). Handle partial availability: withdraw `min(credit, withdrawable)` and retry.

## Q4. Par claim if a cbBTC borrower is liquidated before maturity

**[VERIFIED — contract source, Midnight.sol:619-758]** Two regimes:

1. **Solvent liquidation (normal case).** Pre-maturity, an unhealthy borrower (debt > Σ collateral ×
   price × lltv) is liquidated: the liquidator pays `repaidUnits` loan tokens INTO the market
   (`withdrawable += repaidUnits`, Midnight.sol:713) and seizes collateral worth `repaidUnits × LIF`
   at oracle price (LIF = maxLif ≈ 1.0438 pre-maturity). **Lender par is untouched — and the cash
   backing it becomes claimable EARLY.** A liquidated 30-day bond effectively becomes a T+0 claim;
   the sleeve keeps full accretion-to-par and simply gets optionality to withdraw sooner. (The
   natspec notes the second-order effect: early withdrawable cash creates an incentive race between
   lenders withdrawing and arbitrageurs buying discounted asks to withdraw instantly.)
2. **Bad debt.** If, at any liquidation, worst-case proceeds can't cover the debt
   (`badDebt = debt − Σ collateral·price/maxLif`, computed with maxLif to "always assume the worst
   case"), the shortfall is **socialized immediately and pro-rata across all lender credit in that
   market** via the market `lossFactor` (Midnight.sol:665-680). Each lender's credit is scaled down
   at their next interaction (`updatePosition`); rounding is against the lender. **There is no
   insurance fund, no make-whole, no later top-up.** Par is only as good as 86%-LLTV cbBTC
   liquidations executing in time.

So: "is par still made whole?" — **yes, automatically and possibly early, as long as liquidations
are solvent; no, permanently and immediately, for any realized shortfall.** This is exactly the
correlated-crash tail risk already in PRODUCT.md; v1 mitigations (small caps, short ladder) stand.
Sleeve accounting must read credit via `updatePositionView` so a slash shows up in `totalAssets()`
at the next NAV computation rather than at the next trade.

## Q5. Protocol fees

**[VERIFIED — on-chain read, Base block ~49,218,924, 2026-07-28]** — **all fees are currently ZERO
and no fee roles are even staffed:**

- `feeSetter() = address(0)`, `feeClaimer() = address(0)`, `tickSpacingSetter() = address(0)`.
- `defaultSettlementFeeCbp(USDC, 0..6) = 0`; the Aug-28 market's `settlementFeeCbps = [0×7]`,
  `continuousFee = 0`; `defaultContinuousFee(USDC) = 0`.

Fee machinery that exists in code **[VERIFIED — contract source]**:

- **Settlement fee (on `take` only):** buyer pays `price + fee`, seller receives `price` (sell-offer
  case); the spread accrues to `claimableSettlementFee`. Piecewise-linear in time-to-maturity over
  breakpoints {0d,1d,7d,30d,90d,180d,360d}, stored per market, immutably capped in ConstantsLib:
  max 0.14 bp at ≤1 d, 0.98 bp at 7 d, 4.17 bp at 30 d, 12.5 bp at 90 d, 25 bp at 180 d, 50 bp at
  ≥360 d. These are caps on a *price* spread (not APR) — worst case ≈ 0.5 bp/week of tenor.
- **Continuous fee (on holding credit):** per-second rate fixed at buy time for the position
  (`pendingFee = creditIncrease × continuousFee × TTM`), accrues linearly to maturity, deducted
  from credit. Immutable cap `MAX_CONTINUOUS_FEE = 1%/yr` (ConstantsLib).
- **Withdraw/redemption: no fee path at all.** `repay`: none. `liquidate`: no protocol cut (LIF goes
  to the liquidator).
- Fees can only be activated if the configurator appoints a feeSetter; a change applies to *new*
  takes/positions (existing positions' pendingFee is fixed — Midnight.sol:51-53). Sleeve guard =
  the `maxBuyerAssets` check (Q2); bot should subscribe to `SetFeeSetter` / `SetMarketSettlementFee`
  / `SetMarketContinuousFee` / `SetDefaultContinuousFee` events.

## Q6. Testnet deployment

- **No official testnet.** The Morpho addresses page lists Midnight on **Base only** (it lists
  Base Sepolia/Sepolia rows for Blue and Vault V2, none for Midnight). The Midnight REST API serves
  only Base mainnet — querying `chainId=84532` or `1` silently returns the 8453 data set (verified
  empirically). No offer mempool/book infrastructure exists for any testnet, and books are the
  product — so even a contract deployment without the API is not a usable market. **[DOCS + VERIFIED
  — API probe]**
- **However**, a bytecode-identical, source-verified `Midnight` contract EXISTS on **Base Sepolia**
  at `0xBf06409d6785BB4EE84992FedE03Ead58EB9D10B` (same `lib/midnight/src/Midnight.sol`, solc
  0.8.34, BUSL-1.1 Morpho Association header; deployer/configurator `0xF90c756b4aFb77cd36736Db05340EEFD0F19c93d`
  — not a documented Morpho address, so treat as a dev/unofficial deployment). It has the mainnet
  cbBTC params enabled (`isLltvEnabled(0.86e18) = true`, `isLiquidationCursorEnabled(0.3e18) =
  true`). **[VERIFIED — on-chain read, Base Sepolia]** Usable only in self-serve mode (we would be
  our own maker AND taker, with mock tokens/oracle) — occasionally handy for gas/rehearsal, but the
  plan's assumption stands: **primary testing = pinned Base-mainnet fork; launch = small mainnet
  pilot.** (VAULT_PLAN §0 assumption "no testnet" is confirmed for any *practical* purpose.)

## Q7. Everything else a lender-side integrator must know

All **[VERIFIED — contract source]** unless noted:

- **No pause, no upgradeability, no admin over funds.** Plain non-proxy contract; no owner, no
  pauser, no fund-moving admin function. Roles are: `configurator` (appoints roles, enables LLTV
  tiers / liquidation cursors — enable-only, can never disable), `feeSetter` (bounded, Q5),
  `feeClaimer` (claims accrued fees only), `tickSpacingSetter` (can only *decrease* market tick
  spacing to a divisor — makers gain price granularity, takers unaffected). Configurator is
  currently `0xcBa28b38103307Ec8dA98377ffF9816C164f9AFa` = a **Safe with threshold 5 of 9 owners**
  **[VERIFIED — on-chain read]**. Worst-case governance action against us as lender: appoint a
  feeSetter and set fees to caps (≤50 bp price spread on new fills, ≤1%/yr continuous on new
  positions). No retroactive reach into existing positions except future continuous-fee = 0 already
  locked in at buy time.
- **Market creation is permissionless** (`touchMarket`); markets are immutable once touched; market
  data is SSTORE2'd and recoverable on-chain via `toMarket(id)` (handy for the sleeve: the full
  Market struct can be fetched from the id, though passing the struct from calldata is cheaper).
  **The sleeve must pin allow-listed market ids (curator), not trust loanToken/collateral fields of
  arbitrary offers** — anyone can create look-alike markets with a hostile oracle.
- **Oracle dependencies (lender exposure is at FILL time, not holding time):** the Aug-28 market's
  collateral param is cbBTC, lltv 0.86, cursor 0.30, oracle `0x663BECd10daE6C4A3Dcd89F1d76c1174199639B9`
  = verified `MorphoChainlinkOracleV2` (Chainlink-based, 1e36 scale), `rcfThreshold = 3,000e6`
  (3,000 USDC), `enterGate = liquidatorGate = address(0)` (ungated). **[VERIFIED — on-chain +
  Sourcify]** `take` against a borrower-maker calls the oracle for the seller health check ⇒ an
  oracle outage blocks *fills*, never *withdrawals* (`withdraw` touches no oracle). Liquidations
  revert if any activated collateral oracle reverts (liveness note, Midnight.sol:150-166) — a
  liquidation stall near maturity delays `withdrawable` funding; that is our main liveness tail.
- **Gates:** markets MAY have an `enterGate` that can block credit increases (i.e., block our buys —
  but never block exit/withdraw) and a `liquidatorGate` that can restrict liquidators (a market with
  a restrictive liquidator gate has worse bad-debt dynamics — curator should only allow-list
  ungated markets, as the current cbBTC/USDC set is).
- **Min sizes / dust rules:** none on-chain (Q1). Tick spacing (currently 4 everywhere;
  `DEFAULT_TICK_SPACING = 4`) constrains maker price granularity only.
- **EVM requirements:** the contract "relies on the clz opcode (Osaka), mcopy/tload/tstore (Cancun),
  push0 (Shanghai)" (Midnight.sol:187-188). **Fork tests need a Foundry recent enough to execute
  Osaka opcodes** — pin foundry nightly ≥ Osaka support and `evm_version = "osaka"`; verify first
  (see unknowns).
- **Reentrancy/callback surface:** `take` runs maker callbacks between state update and token pulls;
  the seller is liquidation-locked (transient storage) during callbacks. For our plain
  no-callback taker flow the relevant fact is: state is final before our USDC leaves, and `take`
  returns `(buyerAssets, sellerAssets)` for the atomic price check.
- **Monitoring events** (EventsLib.sol): `Take(caller, offerHash, id, …, taker, buyerAssets,
  sellerAssets, …)`, `Withdraw`, `Repay`, `Liquidate(…, badDebt, latestLossFactor, …)` (watch
  `badDebt > 0` — that is a slash on our book), `SetMarketSettlementFee`, `SetMarketContinuousFee`,
  `SetFeeSetter`, `SetMarketTickSpacing`.
- **Free flash loans** exist on the core (`flashLoan`, no fee) — irrelevant to the sleeve but nice
  for the future repo/liquidation bots.
- **API surface for the bot** (SDK `MidnightApi`): `GET /books`, `GET /books/{id}`,
  `GET /books/{id}/{side}` (levels), `GET /books/{id}/{side}/takeable-offers` (ABI-ready),
  `GET /books/{id}/{side}/quote?units|assets&slippage|average_worst_price` (server-side routing),
  `GET /takeable-offers?maker=…`. Sides: `asks` ⇒ `offer.buy=false` (what we take), `bids` ⇒
  `offer.buy=true`.

---

## Interface summary — what `MidnightSleeve` calls

```solidity
// Types (copy verbatim from verified source: interfaces/IMidnight.sol)
struct CollateralParams { address token; uint256 lltv; uint256 liquidationCursor; address oracle; }
struct Market {
    uint256 chainId; address midnight; address loanToken;
    CollateralParams[] collateralParams; uint256 maturity; uint256 rcfThreshold;
    address enterGate; address liquidatorGate;
}
struct Offer {
    Market market; bool buy; address maker; uint256 start; uint256 expiry; uint256 tick;
    bytes32 group; address callback; bytes callbackData; address receiverIfMakerIsSeller;
    address ratifier; bool reduceOnly; uint128 maxUnits; uint128 maxAssets; uint256 continuousFeeCap;
}

interface IMidnightLender {
    // --- writes the sleeve makes ---
    function take(
        Offer memory offer, bytes memory ratifierData, uint256 units,
        address taker,                       // = address(this) sleeve
        address receiverIfTakerIsSeller,     // = address(0)  (we are the buyer)
        address takerCallback,               // = address(0)  (plain pre-approved fill)
        bytes memory takerCallbackData       // = ""
    ) external returns (uint256 buyerAssets, uint256 sellerAssets);

    function withdraw(Market memory market, uint256 units, address onBehalf, address receiver) external;

    function updatePosition(Market memory market, address user)
        external returns (uint128 newCredit, uint128 newPendingFee, uint128 accruedFee);

    // --- views for accounting / guards ---
    function updatePositionView(Market memory market, bytes32 id, address user)
        external view returns (uint128 newCredit, uint128 newPendingFee, uint128 accruedFee);
    function withdrawable(bytes32 id) external view returns (uint128);
    function lossFactor(bytes32 id) external view returns (uint128);
    function continuousFee(bytes32 id) external view returns (uint32);
    function settlementFee(bytes32 id, uint256 timeToMaturity) external view returns (uint256);
    function credit(bytes32 id, address user) external view returns (uint128);
    function totalUnits(bytes32 id) external view returns (uint128);
    function toMarket(bytes32 id) external view returns (Market memory);
}
```

Sleeve `buy()` shape (allocator-callable, curator-bounded):

```solidity
function buy(Offer calldata offer, bytes calldata ratifierData, uint256 units, uint256 maxBuyerAssets)
    external onlyAllocator
{
    bytes32 id = _marketId(offer.market);                 // IdLib hash, computed locally
    require(allowedMarket[id], MarketNotAllowed());       // curator allow-list — never trust offer fields
    require(!offer.buy, NotAnAsk());
    // per-maturity cap, sleeve cap, floor-spread checks vs maxBuyerAssets/units here …
    USDC.approve(MIDNIGHT, maxBuyerAssets);               // or one-time max approval to MIDNIGHT only
    (uint256 buyerAssets,) = IMidnightLender(MIDNIGHT).take(
        offer, ratifierData, units, address(this), address(0), address(0), "");
    require(buyerAssets <= maxBuyerAssets, PriceTooHigh()); // atomic price/fee/rounding guard
    _recordLot(id, units, buyerAssets, offer.market.maturity);
}
```

Redemption: `IMidnightLender.withdraw(market, min(lotUnits, withdrawable(id)), address(this),
address(this))`. `totalAssets()`: Σ over lots of amortized cost, with credit cross-checked (and
slash detected) via `updatePositionView`.

---

## Fork-test outline (proof-of-fill + warp-to-maturity redemption)

Do NOT write yet — this is the T2 spec. Key twist vs a normal fork test: **the order book is
off-chain**, so a pinned block alone does not contain offers. The fixture is (pinned block, API
snapshot captured at the same wall-clock moment), and the offer is only takeable while
`start ≤ warp target ≤ expiry` (live offers run ~30 h windows).

**Fixture capture (small script, run once):**
1. `block = cast block-number` on Base; record `blockTimestamp`.
2. `GET /books/0x05959752…c84c/asks/takeable-offers` → save raw JSON (offer structs + ratifier_data).
   Market: cbBTC/USDC, maturity **1787929200 = 2026-08-28T15:00Z**, the deepest book (≈ $234.7k
   takeable par on 2026-07-28 at block ≈ 49,218,924 — re-capture fresh when writing the test;
   commit block + JSON together).
3. Record borrower addresses of the market (from `Take`/`SupplyCollateral` events or API) for the
   repay leg.

**Test A — proof of fill** (Foundry, `vm.createSelectFork(BASE_RPC, PINNED_BLOCK)`,
`evm_version = "osaka"`):
1. Deploy nothing (first iteration = raw take from a test EOA; second iteration = through
   `MidnightSleeve` once WS3 exists).
2. `deal(USDC, taker, 100_000e6)`; `vm.prank(taker); USDC.approve(MIDNIGHT, type(uint256).max)`.
3. Reconstruct `Offer` + `ratifierData` from fixture JSON; `vm.warp` into `[start, expiry]` if the
   pinned block timestamp isn't already (it will be, if captured together).
4. `take(offer, ratifierData, units = 10_000e6, taker, 0, 0, "")`.
5. Assert: `buyerAssets ≈ units × tickToPrice(tick) / 1e18` rounded up (settlementFee = 0 at pin);
   `credit(id, taker) == units`; USDC delta == buyerAssets; maker's `consumed[maker][group]`
   increased; `Take` event emitted.
6. Partial-fill variant: two consecutive takes of the same offer; assert consumption accumulates and
   a take exceeding remaining size reverts `ConsumedAssets`.
7. Guard variant: assert a wrapper `maxBuyerAssets` one wei below reverts.

**Test B — warp-to-maturity redemption** (continues from A's state):
1. `vm.warp(1787929200 + 1)`.
2. Fund `withdrawable` by one of (in order of realism):
   a. **Prank-repay:** for each borrower with debt, `deal` USDC and `vm.prank(borrower);
      repay(market, debt, borrower, 0, "")` (repay is gated to `onBehalf == msg.sender ||
      authorized` — prank is required).
   b. **Post-maturity liquidation path (also covers Q4 mechanics):** `liquidate(market, 0,
      0, repaidUnits, borrower, true, receiver, 0, "")` as an unauthorized third party; requires
      the MorphoChainlinkOracleV2 `price()` to still return on the warped fork (Chainlink aggregator
      answers are read without staleness checks in Morpho oracles — verify on fork; if it reverts,
      `vm.mockCall` the aggregator).
3. `withdraw(market, units, taker, taker)`; assert USDC received == units exactly (par, no fee),
   `credit == 0`, `Withdraw` event.
4. Edge assertions: withdraw of `units+1` reverts (arithmetic underflow on credit or withdrawable);
   withdraw before funding reverts (withdrawable underflow) — this IS the "claim window" honesty
   test (T8 "Midnight claim-window edge" in VAULT_PLAN becomes "withdrawable-underfunded edge").
5. Optional slash rehearsal (feeds T3/T8): mock the oracle price down 40%, normal-mode liquidate a
   borrower to force `badDebt > 0`, then `updatePosition(taker)` and assert credit shrank by
   lossFactor pro-rata — proves our NAV pipeline sees slashes.

**Tooling note:** verify the pinned foundry build executes `clz` (Osaka) before anything else — a
plain `credit(id, user)` call on the fork is a sufficient canary.

---

## Remaining unknowns & how to resolve

1. **Foundry/Osaka compatibility** — the deployed bytecode uses the `clz` opcode; older forge revm
   builds will fail on ANY call to the contract on a fork. Resolve: canary test above; pin a
   foundryup nightly that passes. (Local `cast 1.0.0-stable` is likely too old.)
2. **Offer fixtures go stale by design** (short-lived offer legs, maker can cancel via
   `setConsumed`/root un-ratification at any second). Resolve: fixture-capture script committed
   beside the test; capture block + API JSON atomically; accept that the fixture must be refreshed
   if we ever re-pin. Must test on fork.
3. **MorphoChainlinkOracleV2 behavior under `vm.warp`** (does `price()` revert when the underlying
   Chainlink round is months old on the warped fork?). Believed no staleness check in Morpho
   oracles; must test on fork (Test B step 2b), fallback `vm.mockCall`.
4. **Empirical redemption latency on live markets** (how fast does `withdrawable` reach
   `totalUnits` after maturity in practice — repay-before vs liquidate-after mix, and how often
   lenders race). Resolve: have the allocator bot (WS5 dry-run) log `withdrawable/totalUnits` around
   the next few maturities (e.g., 2026-07-30, 2026-07-31 markets) before we size the ladder.
5. **The docs' "Router" for quotes** — docs' get-started mentions lenders "request quotes from the
   Router"; everything we verified says quotes come from the REST API and fills go straight to the
   core. No taker-router periphery is listed on the addresses page. Resolve: ask the Morpho team
   whether a taker periphery exists/is planned (also affects whether they'd route flow to our
   maker-side later); not blocking — direct `take()` is fully specified.
6. **`EcrecoverAuthorizer` (`0x292b…a493`) purpose** — periphery source not reviewed; appears
   maker-side (EIP-712 authorization helper). Resolve when/if we run maker-side flows (v2 repo);
   irrelevant to taker v1.
7. **API terms/rate limits & SLA** for `takeable-offers` (our fill path depends on API liveness for
   offer bytes; on-chain fallback = reading Mempool contract payloads `0xdD6D…7993`, format in SDK
   `signatures/Payload.js`). Resolve: ask Morpho about API stability guarantees; implement bot-side
   caching of raw offers (they remain valid until expiry/cancel regardless of API uptime).
8. **Base Sepolia deployment provenance** (`0xBf06…D10B`, deployer `0xF90c…c93d`) — unofficial?
   Resolve: ask Morpho team; nice-to-have only.
9. **Settlement-fee activation risk pricing** — fees are zero today; if the feeSetter is staffed,
   short-tenor fills lose ≤ ~1–4 bp of price. Resolve: monitoring events (Q7) + the on-chain
   `maxBuyerAssets` guard already absorbs it; strategy config should re-check spread floors if fees
   activate.
