// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMidnight, Market, Offer} from "./interfaces/IMidnight.sol";
import {ISleeve} from "./interfaces/ISleeve.sol";

/// @title MidnightSleeve — buy-and-hold Midnight zero-coupon paper for AlbaVault
/// @notice Buys credit units on curator-allow-listed Midnight markets (asks,
/// via `take()`), holds them to maturity, and redeems par from the market's
/// FCFS `withdrawable` cash pool. Paper is NEVER sold to serve a withdrawal;
/// the only pre-maturity exit is the curator's {emergencySell} escape hatch.
///
/// ## Accounting (amortized cost, O(1) per market)
/// Lots accrete linearly from cost to face: each buy of `units` face for
/// `cost` USDC adds `(units - cost) / ttm` per second to a per-market
/// accretion rate. Because every lot in a market shares the market's maturity,
/// accretion aggregates into one accumulator per market — `totalAssets()`
/// loops over the curator-bounded market list (<= MAX_MARKETS), never over
/// lots. Book value at time t = cost + accrued(t), reaching face at maturity.
///
/// Midnight reduces positions lazily by the market `lossFactor` (socialized
/// bad debt) and `pendingFee` (continuous fee; zero on current markets).
/// Valuation therefore cross-checks the book against Midnight's own
/// `updatePositionView`: if effective credit (credit - pendingFee) has fallen
/// below book face, the whole book value is haircut pro-rata. State-mutating
/// flows (`buy`/`redeem`/`emergencySell`) re-sync book face to actual credit,
/// so a slash permanently reduces face/cost/accrual proportionally.
///
/// Edge cases, honestly:
/// - A slash haircuts accrued discount pro-rata across the whole market book,
///   not per lot; lots bought after a slash are already synced, so error only
///   spans slashes since the last state-touch (bounded by the discount, bps).
/// - Redeeming before maturity (post-liquidation cash is claimable early)
///   realizes remaining accretion to par instantly: NAV steps up, never down.
/// - Accrual rounds down (floor) everywhere: book value <= true value; the
///   dust realizes as gain at redemption.
/// - `totalAssets()`/`liquidAssets()` make external view calls into Midnight
///   (`toMarket` + `updatePositionView`); Midnight has no pause or admin able
///   to make these revert (verified in md-files/MIDNIGHT_INTEGRATION.md).
///
/// ## Guards (a rogue allocator can only do small, in-policy trades)
/// On-chain, enforced atomically on `take()`'s returned cost: allocator's
/// maxAssets bound; curator's max single-buy size; never above par; a global
/// curator-set minimum annualized simple yield floor ((face - cost) / cost
/// annualized over time-to-maturity — chosen over per-tenor price tables as
/// the simplest sound bound: it subsumes tick, settlement fee and rounding in
/// one check); and a per-market face cap (concentration). Offers only fill on
/// allow-listed markets: the offer's Market struct is bound to the curator's
/// market id via Midnight's own `toMarket` at allow-list time, so hostile
/// look-alike markets in forged offers cannot match.
///
/// Roles are read from the AlbaVault's AccessControl (single source of truth).
contract MidnightSleeve is ISleeve {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ------------------------------------------------------------- immutables
    /// @notice The AlbaVault this sleeve serves: sole depositor/withdrawer and
    /// the AccessControl instance CURATOR/ALLOCATOR membership is read from.
    address public immutable VAULT;
    /// @notice The Midnight core contract (sole USDC approval target).
    IMidnight public immutable MIDNIGHT;
    /// @notice Underlying asset (USDC), read from the vault.
    IERC20 public immutable ASSET;

    bytes32 internal constant CURATOR_ROLE = keccak256("CURATOR_ROLE");
    bytes32 internal constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");
    /// @notice Market-list bound — keeps totalAssets() iteration cheap.
    uint256 public constant MAX_MARKETS = 8;
    uint256 internal constant WAD = 1e18;

    // ---------------------------------------------------------------- storage
    struct Book {
        uint128 units; // outstanding face (= Midnight credit as of last sync)
        uint128 cost; // amortized cost basis of the outstanding face
        uint128 maxUnits; // curator concentration cap on face
        uint64 lastAccrual; // last accretion settlement timestamp
        uint64 maturity; // market maturity; nonzero marks the market allowed
        uint256 accruedWad; // settled accretion, WAD-scaled asset units
        uint256 ratePerSecWad; // aggregate accretion rate, WAD asset units / s
    }

    /// @notice Allow-listed Midnight market ids (iteration = redemption order).
    bytes32[] public marketIds;
    /// @notice Per-market aggregate lot book.
    mapping(bytes32 id => Book) public book;
    /// @notice keccak256(abi.encode(Market)) => market id; binds offer structs
    /// to allow-listed ids (never trust offer fields directly).
    mapping(bytes32 marketHash => bytes32 id) public marketIdOf;

    /// @notice Curator floor on annualized simple yield (WAD; 0.05e18 = 5%/yr).
    uint256 public minYieldWad;
    /// @notice Curator cap on the cost of a single {buy}.
    uint256 public maxBuyAssets;

    // ----------------------------------------------------------------- events
    event MarketAllowed(bytes32 indexed id, uint256 maturity, uint128 maxUnits);
    event MarketRemoved(bytes32 indexed id);
    event MarketCapSet(bytes32 indexed id, uint128 maxUnits);
    event MinYieldSet(uint256 minYieldWad);
    event MaxBuyAssetsSet(uint256 maxBuyAssets);
    /// @dev Mutation events carry the post-operation book state (bookUnits =
    /// outstanding face, bookCost = amortized cost basis) AFTER slash re-sync
    /// and pro-rata scaling, so indexers can track exact lot-level state
    /// without replaying Midnight's lossFactor math.
    event Bought(bytes32 indexed id, uint256 units, uint256 cost, uint256 bookUnits, uint256 bookCost);
    event Redeemed(bytes32 indexed id, uint256 units, uint256 bookUnits, uint256 bookCost);
    event EmergencySold(bytes32 indexed id, uint256 units, uint256 proceeds, uint256 bookUnits, uint256 bookCost);

    // ----------------------------------------------------------------- errors
    error NotVault();
    error NotAuthorized(bytes32 role);
    error MarketNotAllowed();
    error MarketAlreadyAllowed(bytes32 id);
    error MarketNotEmpty(bytes32 id);
    error TooManyMarkets();
    error AssetMismatch();
    error MarketMatured();
    error WrongSide();
    error ZeroUnits();
    error CostAboveMax(uint256 cost, uint256 bound);
    error AbovePar(uint256 cost, uint256 units);
    error YieldTooLow(uint256 units, uint256 cost);
    error MarketCapExceeded(uint256 units, uint256 cap);
    error ProceedsBelowMin(uint256 proceeds, uint256 minAssets);

    /// @param vault The AlbaVault (ERC-4626 on USDC) this sleeve serves.
    /// @param midnight The Midnight core contract.
    constructor(address vault, IMidnight midnight) {
        VAULT = vault;
        MIDNIGHT = midnight;
        ASSET = IERC20(IERC4626(vault).asset());
        ASSET.forceApprove(address(midnight), type(uint256).max);
    }

    modifier onlyVault() {
        if (msg.sender != VAULT) revert NotVault();
        _;
    }

    modifier onlyRole(bytes32 role) {
        if (!IAccessControl(VAULT).hasRole(role, msg.sender)) revert NotAuthorized(role);
        _;
    }

    // ------------------------------------------------------------ ISleeve
    /// @inheritdoc ISleeve
    function deposit(uint256 assets) external onlyVault {
        ASSET.safeTransferFrom(VAULT, address(this), assets);
    }

    /// @inheritdoc ISleeve
    /// @dev Serves idle USDC first, then pulls synchronously-claimable par
    /// (matured or liquidation-funded, FCFS pool permitting) market by market.
    /// NEVER sells paper; clamps instead of reverting.
    function withdraw(uint256 assets) external onlyVault returns (uint256 withdrawn) {
        uint256 idle = ASSET.balanceOf(address(this));
        uint256 n = marketIds.length;
        for (uint256 i; i < n && idle < assets; ++i) {
            idle += _claim(marketIds[i], assets - idle);
        }
        withdrawn = Math.min(assets, idle);
        if (withdrawn != 0) ASSET.safeTransfer(VAULT, withdrawn);
    }

    /// @inheritdoc ISleeve
    function totalAssets() external view returns (uint256 assets) {
        assets = ASSET.balanceOf(address(this));
        uint256 n = marketIds.length;
        for (uint256 i; i < n; ++i) {
            assets += _bookValue(marketIds[i]);
        }
    }

    /// @inheritdoc ISleeve
    function kind() external pure returns (string memory) {
        return "midnight";
    }

    /// @inheritdoc ISleeve
    /// @dev Claimable par (min(effective credit, FCFS pool)) additionally
    /// clamps to carried book value: pulling par pre-maturity realizes the
    /// remaining accretion at execution time, and the view must never report
    /// more liquidity than NAV carries (vault invariant: liquid <= total).
    function liquidAssets() external view returns (uint256 liquid) {
        liquid = ASSET.balanceOf(address(this));
        uint256 n = marketIds.length;
        for (uint256 i; i < n; ++i) {
            bytes32 id = marketIds[i];
            if (book[id].units == 0) continue;
            uint256 claimable = Math.min(_effectiveCredit(id), MIDNIGHT.withdrawable(id));
            liquid += Math.min(claimable, _bookValue(id));
        }
    }

    // ------------------------------------------------------------- allocation
    /// @notice Fill an allow-listed ask: buy `units` of face via Midnight
    /// `take()`. Offer struct + ratifier proof come from the REST API and are
    /// passed through as opaque calldata; every economic bound is re-checked
    /// on-chain against the actual settlement cost.
    /// @param offer The full signed offer (ask: `offer.buy == false`).
    /// @param ratifierData Opaque maker-ratification proof, forwarded verbatim.
    /// @param units Face units to take (partial fills are first-class).
    /// @param maxAssets Allocator's cost bound for this fill.
    /// @return cost USDC actually paid (`buyerAssets`, fee & rounding included).
    function buy(Offer calldata offer, bytes calldata ratifierData, uint256 units, uint256 maxAssets)
        external
        onlyRole(ALLOCATOR_ROLE)
        returns (uint256 cost)
    {
        bytes32 id = marketIdOf[keccak256(abi.encode(offer.market))];
        if (id == bytes32(0)) revert MarketNotAllowed();
        if (offer.buy) revert WrongSide();
        if (units == 0) revert ZeroUnits();
        Book storage b = book[id];
        if (block.timestamp >= b.maturity) revert MarketMatured();

        (cost,) = MIDNIGHT.take(offer, ratifierData, units, address(this), address(0), address(0), "");

        if (cost > maxAssets) revert CostAboveMax(cost, maxAssets);
        if (cost > maxBuyAssets) revert CostAboveMax(cost, maxBuyAssets);
        if (cost > units) revert AbovePar(cost, units);
        uint256 ttm = b.maturity - block.timestamp;
        // annualized simple yield floor: (units - cost) / (cost * ttm) >= minYield / year
        if ((units - cost) * 365 days * WAD < minYieldWad * cost * ttm) revert YieldTooLow(units, cost);

        _settle(b);
        // take() settled Midnight's lazy lossFactor/fee on our old credit; re-sync.
        uint256 syncedOld = MIDNIGHT.credit(id, address(this)) - units;
        if (syncedOld < b.units) _scale(b, syncedOld, b.units);
        b.units += uint128(units);
        b.cost += uint128(cost);
        b.ratePerSecWad += (units - cost) * WAD / ttm;
        if (b.units > b.maxUnits) revert MarketCapExceeded(b.units, b.maxUnits);
        emit Bought(id, units, cost, b.units, b.cost);
    }

    /// @notice Pull whatever par is claimable for `id` (up to the market's
    /// FCFS `withdrawable` pool) into sleeve idle. Permissionless: it can only
    /// move funds toward the sleeve at par — and the pool is first-come-first-
    /// served, so anyone being able to crank it is a liveness feature.
    /// @return claimed Units redeemed (1 unit = 1 base unit USDC).
    function redeem(bytes32 id) external returns (uint256 claimed) {
        if (book[id].maturity == 0) revert MarketNotAllowed();
        claimed = _claim(id, type(uint256).max);
    }

    /// @notice Curator-only escape hatch: sell paper before maturity into a
    /// standing bid (other lenders' demand) via `take()`. Realizes P&L at
    /// execution price — NAV moves by proceeds minus carried book value.
    /// @param offer The bid to hit (`offer.buy == true`); market must be allowed.
    /// @param ratifierData Opaque maker-ratification proof.
    /// @param units Face units to sell.
    /// @param minAssets Floor on USDC proceeds (slippage guard).
    function emergencySell(Offer calldata offer, bytes calldata ratifierData, uint256 units, uint256 minAssets)
        external
        onlyRole(CURATOR_ROLE)
        returns (uint256 proceeds)
    {
        bytes32 id = marketIdOf[keccak256(abi.encode(offer.market))];
        if (id == bytes32(0)) revert MarketNotAllowed();
        if (!offer.buy) revert WrongSide();
        Book storage b = book[id];

        (uint128 credit,,) = MIDNIGHT.updatePosition(offer.market, address(this));
        _settle(b);
        if (credit < b.units) _scale(b, credit, b.units);
        (, proceeds) = MIDNIGHT.take(offer, ratifierData, units, address(this), address(this), address(0), "");
        if (proceeds < minAssets) revert ProceedsBelowMin(proceeds, minAssets);
        _scale(b, credit - units, credit);
        emit EmergencySold(id, units, proceeds, b.units, b.cost);
    }

    // --------------------------------------------------------------- curation
    /// @notice Allow-list a Midnight market. The Market struct is fetched from
    /// Midnight itself (`toMarket`), so the id<->struct binding used by {buy}
    /// cannot be spoofed by look-alike markets.
    /// @param id Midnight market id.
    /// @param maxUnits Concentration cap on face held in this market.
    function allowMarket(bytes32 id, uint128 maxUnits) external onlyRole(CURATOR_ROLE) {
        if (book[id].maturity != 0) revert MarketAlreadyAllowed(id);
        if (marketIds.length >= MAX_MARKETS) revert TooManyMarkets();
        Market memory m = MIDNIGHT.toMarket(id);
        if (m.loanToken != address(ASSET)) revert AssetMismatch();
        if (m.maturity <= block.timestamp) revert MarketMatured();
        marketIds.push(id);
        book[id].maturity = uint64(m.maturity);
        book[id].maxUnits = maxUnits;
        marketIdOf[keccak256(abi.encode(m))] = id;
        emit MarketAllowed(id, m.maturity, maxUnits);
    }

    /// @notice Deregister a fully-redeemed market.
    function removeMarket(bytes32 id) external onlyRole(CURATOR_ROLE) {
        if (book[id].maturity == 0) revert MarketNotAllowed();
        if (book[id].units != 0 || MIDNIGHT.credit(id, address(this)) != 0) revert MarketNotEmpty(id);
        uint256 n = marketIds.length;
        for (uint256 i; i < n; ++i) {
            if (marketIds[i] == id) {
                marketIds[i] = marketIds[n - 1];
                marketIds.pop();
                break;
            }
        }
        delete marketIdOf[keccak256(abi.encode(MIDNIGHT.toMarket(id)))];
        delete book[id];
        emit MarketRemoved(id);
    }

    /// @notice Update a market's concentration cap (checked on future buys).
    function setMarketCap(bytes32 id, uint128 maxUnits) external onlyRole(CURATOR_ROLE) {
        if (book[id].maturity == 0) revert MarketNotAllowed();
        book[id].maxUnits = maxUnits;
        emit MarketCapSet(id, maxUnits);
    }

    /// @notice Set the annualized simple-yield floor for {buy} (WAD).
    function setMinYield(uint256 minYieldWad_) external onlyRole(CURATOR_ROLE) {
        minYieldWad = minYieldWad_;
        emit MinYieldSet(minYieldWad_);
    }

    /// @notice Set the max cost of a single {buy}.
    function setMaxBuyAssets(uint256 maxBuyAssets_) external onlyRole(CURATOR_ROLE) {
        maxBuyAssets = maxBuyAssets_;
        emit MaxBuyAssetsSet(maxBuyAssets_);
    }

    /// @notice Number of allow-listed markets.
    function marketCount() external view returns (uint256) {
        return marketIds.length;
    }

    // -------------------------------------------------------------- internals
    /// @dev Settle linear accretion up to min(now, maturity).
    function _settle(Book storage b) internal {
        uint256 t = Math.min(block.timestamp, b.maturity);
        if (t > b.lastAccrual) {
            b.accruedWad += b.ratePerSecWad * (t - b.lastAccrual);
            b.lastAccrual = uint64(t);
        }
    }

    /// @dev Scale the whole book by num/den <= 1 (redemption, sale, slash
    /// sync). The remainder rounds UP so redeeming par never marks NAV down by
    /// rounding dust (overstatement is <= 1 wei per field and clears at full
    /// redemption: num == 0 zeroes the book; num == den is exact).
    function _scale(Book storage b, uint256 num, uint256 den) internal {
        b.units = uint128(uint256(b.units).mulDiv(num, den, Math.Rounding.Ceil));
        b.cost = uint128(uint256(b.cost).mulDiv(num, den, Math.Rounding.Ceil));
        b.accruedWad = b.accruedWad.mulDiv(num, den, Math.Rounding.Ceil);
        b.ratePerSecWad = b.ratePerSecWad.mulDiv(num, den, Math.Rounding.Ceil);
    }

    /// @dev Sync Midnight's lazy position state, then withdraw up to
    /// `maxUnits_` of claimable par (bounded by effective credit and the FCFS
    /// pool) to sleeve idle, reducing the book pro-rata in credit terms.
    function _claim(bytes32 id, uint256 maxUnits_) internal returns (uint256 claimed) {
        Book storage b = book[id];
        if (b.units == 0) return 0;
        Market memory m = MIDNIGHT.toMarket(id);
        (uint128 credit, uint128 pendingFee,) = MIDNIGHT.updatePosition(m, address(this));
        _settle(b);
        if (credit < b.units) _scale(b, credit, b.units);
        uint256 effective = credit > pendingFee ? credit - pendingFee : 0;
        claimed = Math.min(Math.min(effective, MIDNIGHT.withdrawable(id)), maxUnits_);
        if (claimed == 0) return 0;
        MIDNIGHT.withdraw(m, claimed, address(this), address(this));
        _scale(b, credit - claimed, credit);
        emit Redeemed(id, claimed, b.units, b.cost);
    }

    /// @dev Effective credit (credit - pendingFee) as Midnight's own lazy
    /// valuation (`updatePositionView`) would report it right now.
    function _effectiveCredit(bytes32 id) internal view returns (uint256) {
        (uint128 credit, uint128 pendingFee,) = MIDNIGHT.updatePositionView(MIDNIGHT.toMarket(id), id, address(this));
        return credit > pendingFee ? credit - pendingFee : 0;
    }

    /// @dev Amortized book value: cost + linear accretion, clamped to face,
    /// then haircut pro-rata if Midnight's effective credit fell below face
    /// (lossFactor slash / continuous fee accrued since last state-touch).
    function _bookValue(bytes32 id) internal view returns (uint256 v) {
        Book storage b = book[id];
        uint256 faceUnits = b.units;
        if (faceUnits == 0) return 0;
        uint256 t = Math.min(block.timestamp, b.maturity);
        v = b.cost + (b.accruedWad + b.ratePerSecWad * (t - b.lastAccrual)) / WAD;
        if (v > faceUnits) v = faceUnits;
        uint256 effective = _effectiveCredit(id);
        if (effective < faceUnits) v = v.mulDiv(effective, faceUnits);
    }
}
