// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20, IERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import {ISwapVM} from "swap-vm/src/interfaces/ISwapVM.sol";
import {TakerTraitsLib} from "swap-vm/src/libs/TakerTraits.sol";

import {TermRouter} from "./TermRouter.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {AlbaProgramBuilder} from "./lib/ProgramBuilder.sol";

/// @title CollateralEscrow — custody, continuous margining, and liquidation for Alba
/// @notice Collateral never enters Aqua while a loan is healthy: pull-rights over a wallet
/// the borrower controls are worthless, so collateral sits in code.
///
/// CONTINUOUS MARGINING. Health is `collateralValue ≥ maintenanceRatio × accruedDebt(t)`,
/// checkable by anyone at any time (`liquidate` is permissionless but only proceeds on a
/// real, oracle-verified breach). The Hedera sentinel schedule drives periodic CHECKs
/// through the executor; any third party can race it. On breach, a three-tier waterfall
/// runs — gentlest first:
///   1. FULL CURE   pull the whole accrued debt from the borrower's Aqua-authorized cure
///                  leg → early settlement, collateral home, zero penalty;
///   2. PARTIAL CURE pull what is available; if health is restored the draw lives on;
///   3. AUCTION     only then: Dutch auction over the collateral for the remaining debt.
///
/// The auction is a signature-mode SwapVM order the escrow authorizes via ERC-1271 —
/// code signing for code — with partial fills and `_stopWhenCovered` halting sales the
/// moment the lender-side target is raised.
///
/// INVARIANT (single-claim collateral): each draw's collateral leaves by exactly one path —
/// `release` / full cure (healthy exits) or the auction armed once — and `sweepAuction`
/// closes the auction path (revokes allowance + de-authorizes the order) before paying the
/// waterfall: lender up to debt → liquidation fee → surplus collateral back to the borrower.
///
/// Fees and margining constants are immutable by principle: infrastructure that can't
/// reprice you.
contract CollateralEscrow {
    using SafeERC20 for IERC20;

    error OnlyExecutor(address caller);
    error FacilityAlreadyRegistered(bytes32 facilityId);
    error FacilityUnknown(bytes32 facilityId);
    error OnlyFacilityLender(address caller, address lender);
    error OnlyFacilityBorrower(address caller, address borrower);
    error DrawAlreadyExists(bytes32 drawId);
    error DrawNotLocked(bytes32 drawId);
    error DrawHealthy(bytes32 drawId, uint256 collateralValue, uint256 requiredValue);
    error AuctionNotArmed(bytes32 drawId);
    error AuctionNotCovered(bytes32 drawId, uint256 raised, uint256 target);
    error OracleInvalidPrice(int256 answer);
    error OracleStale(uint256 updatedAt, uint256 maxStaleness);
    error OnlySelf(address caller);
    error Reentrancy();

    enum DrawState {
        NONE,
        LOCKED,
        RELEASED,
        AUCTIONING,
        LIQUIDATED
    }

    struct Draw {
        bytes32 facilityId;
        address borrower;
        IERC20 token;
        uint256 amount; // collateral locked
        uint256 principal; // loan tokens drawn
        uint256 cured; // loan tokens already pulled via the cure leg
        uint40 start;
        uint40 maturity;
        DrawState state;
    }

    /// @dev Credit terms are per-facility and immutable at registration
    struct FacilityParams {
        address borrower; // named counterparty; address(0) = open to any collateralized borrower
        IERC20 loanToken;
        IERC20 collateralToken;
        IAggregatorV3 oracle; // collateral/USD feed; loan token assumed USD-stable
        uint256 collateralRatioBps; // initial, e.g. 13_000 = 130%
        uint256 maintenanceRatioBps; // liquidation threshold, e.g. 11_500 = 115%
        uint256 rateBps; // simple annual interest, ACT/365
        uint40 termSeconds; // per-draw tenor
        uint16 auctionDuration; // liquidation auction lifetime (expiry = price floor)
        uint64 auctionDecay; // per-second decay ×1e18
    }

    struct Facility {
        ISwapVM.Order order; // facility leg built with _onlyTaker(this escrow)
        address lender;
        FacilityParams params;
        uint8 loanDecimals;
        uint8 collateralDecimals;
        uint8 feedDecimals;
        bool exists;
    }

    struct Auction {
        bytes32 orderHash;
        address lender;
        IERC20 bidToken;
        uint256 debt;
        uint256 fee;
    }

    event FacilityRegistered(bytes32 indexed facilityId, address indexed lender, uint256 collateralRatioBps);
    event Drawn(
        bytes32 indexed facilityId, bytes32 indexed drawId, address indexed borrower, uint256 amount, uint256 collateral
    );
    event CollateralLocked(bytes32 indexed drawId, address indexed borrower, address token, uint256 amount);
    event CollateralReleased(bytes32 indexed drawId, address indexed borrower, uint256 amount);
    event DrawCured(bytes32 indexed drawId, uint256 amountPulled, bool fullClose);
    event AuctionArmed(bytes32 indexed drawId, bytes32 orderHash, uint256 target);
    event AuctionSwept(
        bytes32 indexed drawId, uint256 lenderPaid, uint256 feePaid, uint256 collateralSold, uint256 surplusReturned
    );

    bytes4 private constant ERC1271_MAGIC = 0x1626ba7e;
    uint256 private constant CURE_SALT = uint256(keccak256("ALBA_CURE_LEG"));

    /// @notice Liquidation fee in basis points — a constant, not a knob.
    uint256 public constant LIQ_FEE_BPS = 50; // 0.50%
    /// @notice Auction start premium over oracle price, and feed staleness bound — constants too.
    uint256 public constant AUCTION_START_PREMIUM_BPS = 10_500; // 105% of oracle at arm time
    uint256 public constant ORACLE_MAX_STALENESS = 1 days;

    /// @notice Settlement executor (AxelarSettlementExecutor in production, manual in tests)
    address public immutable EXECUTOR;
    TermRouter public immutable ROUTER;
    AlbaProgramBuilder public immutable BUILDER;
    address public immutable FEE_SINK;

    mapping(bytes32 facilityId => Facility) public facilities;
    mapping(bytes32 drawId => Draw) public draws;
    mapping(bytes32 drawId => Auction) public auctions;
    /// @dev ERC-1271 authorization set: order hashes of currently armed auctions
    mapping(bytes32 orderHash => bool) public armedOrders;

    bool private _entered;

    modifier onlyExecutor() {
        require(msg.sender == EXECUTOR, OnlyExecutor(msg.sender));
        _;
    }

    modifier nonReentrant() {
        require(!_entered, Reentrancy());
        _entered = true;
        _;
        _entered = false;
    }

    constructor(address executor, TermRouter router, AlbaProgramBuilder builder, address feeSink) {
        EXECUTOR = executor;
        ROUTER = router;
        BUILDER = builder;
        FEE_SINK = feeSink;
    }

    /// @notice ERC-1271: the escrow "signs" exactly the auction orders it has armed.
    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        return armedOrders[hash] ? ERC1271_MAGIC : bytes4(0xffffffff);
    }

    // ---------------------------------------------------------------- registration & draw

    /// @notice Lender registers a facility whose draw leg names THIS escrow as sole taker.
    /// From then on the only way to draw is `draw()` — collateral in, cash out, atomically.
    function registerFacility(bytes32 facilityId, ISwapVM.Order calldata order, FacilityParams calldata p) external {
        require(!facilities[facilityId].exists, FacilityAlreadyRegistered(facilityId));
        require(msg.sender == order.maker, OnlyFacilityLender(msg.sender, order.maker));
        facilities[facilityId] = Facility({
            order: order,
            lender: msg.sender,
            params: p,
            loanDecimals: IERC20Metadata(address(p.loanToken)).decimals(),
            collateralDecimals: IERC20Metadata(address(p.collateralToken)).decimals(),
            feedDecimals: p.oracle.decimals(),
            exists: true
        });
        emit FacilityRegistered(facilityId, msg.sender, p.collateralRatioBps);
    }

    /// @notice Live collateral requirement for a draw of `amount` loan tokens, at the
    /// current oracle price: amount × initialRatio / price, in collateral token units.
    function collateralForDraw(bytes32 facilityId, uint256 amount) public view returns (uint256) {
        Facility storage f = facilities[facilityId];
        require(f.exists, FacilityUnknown(facilityId));
        return Math.ceilDiv(
            amount * f.params.collateralRatioBps * 10 ** (f.feedDecimals + f.collateralDecimals),
            10_000 * 10 ** f.loanDecimals * _freshPrice(f)
        );
    }

    /// @notice THE draw: pulls pro-rata collateral from the caller and executes the facility
    /// pull in the same transaction, loan proceeds straight to the borrower. Maturity and
    /// repayment derive from the facility's immutable terms.
    /// @dev Collateral only locks per-draw: publishing/undrawn capacity costs the borrower nothing.
    function draw(bytes32 facilityId, bytes32 drawId, uint256 amount)
        external
        nonReentrant
        returns (uint256 collateral)
    {
        Facility storage f = facilities[facilityId];
        require(f.exists, FacilityUnknown(facilityId));
        require(
            f.params.borrower == address(0) || msg.sender == f.params.borrower,
            OnlyFacilityBorrower(msg.sender, f.params.borrower)
        );
        require(draws[drawId].state == DrawState.NONE, DrawAlreadyExists(drawId));

        collateral = collateralForDraw(facilityId, amount);
        draws[drawId] = Draw({
            facilityId: facilityId,
            borrower: msg.sender,
            token: f.params.collateralToken,
            amount: collateral,
            principal: amount,
            cured: 0,
            start: uint40(block.timestamp),
            maturity: uint40(block.timestamp) + f.params.termSeconds,
            state: DrawState.LOCKED
        });
        f.params.collateralToken.safeTransferFrom(msg.sender, address(this), collateral);
        emit CollateralLocked(drawId, msg.sender, address(f.params.collateralToken), collateral);

        ROUTER.swap(
            f.order, address(f.params.collateralToken), address(f.params.loanToken), amount, _pullTakerData(msg.sender)
        );
        emit Drawn(facilityId, drawId, msg.sender, amount, collateral);
    }

    // ---------------------------------------------------------------- health & debt views

    /// @notice Accrued debt at time t: P(1 + r·min(t,T)/365), simple interest ACT/365.
    function debtOf(bytes32 drawId) public view returns (uint256) {
        Draw storage d = draws[drawId];
        Facility storage f = facilities[d.facilityId];
        uint256 elapsed = Math.min(block.timestamp - d.start, uint256(f.params.termSeconds));
        return d.principal + (d.principal * f.params.rateBps * elapsed) / (10_000 * 365 days) - d.cured;
    }

    /// @notice Full repayment at maturity (the maturity/cure legs' cap), before cures.
    function repaymentOf(bytes32 drawId) public view returns (uint256) {
        Draw storage d = draws[drawId];
        Facility storage f = facilities[d.facilityId];
        return BUILDER.repaymentAmount(d.principal, f.params.rateBps, f.params.termSeconds);
    }

    /// @notice What the maturity settlement should pull: K − cured; 0 unless still LOCKED.
    function maturityOutstanding(bytes32 drawId) public view returns (uint256) {
        Draw storage d = draws[drawId];
        if (d.state != DrawState.LOCKED) return 0;
        return repaymentOf(drawId) - d.cured;
    }

    /// @notice Collateral marked at the live oracle, in loan-token units.
    function collateralValueInLoan(bytes32 drawId) public view returns (uint256) {
        Draw storage d = draws[drawId];
        Facility storage f = facilities[d.facilityId];
        return (d.amount * _freshPrice(f) * 10 ** f.loanDecimals) / (10 ** (f.collateralDecimals + f.feedDecimals));
    }

    /// @notice Healthy iff collateralValue ≥ maintenanceRatio × accruedDebt.
    function isHealthy(bytes32 drawId) public view returns (bool healthy, uint256 value, uint256 required) {
        Draw storage d = draws[drawId];
        Facility storage f = facilities[d.facilityId];
        value = collateralValueInLoan(drawId);
        required = (debtOf(drawId) * f.params.maintenanceRatioBps) / 10_000;
        healthy = value >= required;
    }

    function stateOf(bytes32 drawId) external view returns (DrawState) {
        return draws[drawId].state;
    }

    function lenderOf(bytes32 drawId) external view returns (address) {
        return facilities[draws[drawId].facilityId].lender;
    }

    /// @notice The borrower's cure leg for a draw — deterministic, built by the same single
    /// source of truth as every leg. Borrower ships this to Aqua to opt into no-penalty cures.
    function cureOrder(bytes32 drawId)
        public
        view
        returns (
            ISwapVM.Order memory order,
            bytes memory shipStrategy,
            address[] memory tokens,
            uint256[] memory amounts
        )
    {
        Draw storage d = draws[drawId];
        Facility storage f = facilities[d.facilityId];
        return BUILDER.buildCureLeg(
            AlbaProgramBuilder.PullLegTerms({
                maker: d.borrower,
                counterToken: address(f.params.collateralToken),
                pullToken: address(f.params.loanToken),
                amount: repaymentOf(drawId),
                salt: uint256(drawId) ^ CURE_SALT
            }),
            address(this)
        );
    }

    // ---------------------------------------------------------------- continuous liquidation

    /// @notice PERMISSIONLESS continuous liquidation — anyone may call, it only proceeds on an
    /// oracle-verified breach. Three tiers, gentlest first: full cure (early settlement, zero
    /// penalty) → partial cure (health restored, draw lives) → Dutch auction for the remainder.
    function liquidate(bytes32 drawId) external nonReentrant returns (DrawState outcome) {
        Draw storage d = draws[drawId];
        require(d.state == DrawState.LOCKED, DrawNotLocked(drawId));
        (bool healthy, uint256 value, uint256 required) = isHealthy(drawId);
        require(!healthy, DrawHealthy(drawId, value, required));

        Facility storage f = facilities[d.facilityId];
        uint256 debt = debtOf(drawId);

        // Available cure capacity: what the wallet holds, capped by the cure leg's remaining rights
        uint256 cureRights = repaymentOf(drawId) - d.cured;
        uint256 available = Math.min(f.params.loanToken.balanceOf(d.borrower), cureRights);
        uint256 pull = Math.min(available, debt);

        uint256 pulled = 0;
        if (pull > 0) {
            try this.pullCure(drawId, pull) {
                pulled = pull;
                d.cured += pull;
            } catch {} // not shipped / no allowance — fall through to the auction tier
        }

        if (pulled == debt) {
            // Tier 1 — full cure: early settlement at accrued value, collateral home, no penalty
            d.state = DrawState.RELEASED;
            d.token.safeTransfer(d.borrower, d.amount);
            emit DrawCured(drawId, pulled, true);
            emit CollateralReleased(drawId, d.borrower, d.amount);
            return DrawState.RELEASED;
        }

        (healthy,,) = isHealthy(drawId);
        if (pulled > 0 && healthy) {
            // Tier 2 — partial cure restored health: the draw lives on
            emit DrawCured(drawId, pulled, false);
            return DrawState.LOCKED;
        }

        // Tier 3 — auction whatever debt remains (any partial pull above still shrank it)
        if (pulled > 0) emit DrawCured(drawId, pulled, false);
        _armAuction(drawId, debt - pulled);
        return DrawState.AUCTIONING;
    }

    /// @notice External self-call target so cure pulls can be try/caught.
    function pullCure(bytes32 drawId, uint256 amount) external {
        require(msg.sender == address(this), OnlySelf(msg.sender));
        Draw storage d = draws[drawId];
        Facility storage f = facilities[d.facilityId];
        (ISwapVM.Order memory order,,,) = cureOrder(drawId);
        // Cure proceeds go straight to the lender: debt paydown, not escrow custody
        ROUTER.swap(
            order, address(f.params.collateralToken), address(f.params.loanToken), amount, _pullTakerData(f.lender)
        );
    }

    // ---------------------------------------------------------------- settlement-path exits

    /// @notice Return collateral to the borrower after a successful repayment settlement.
    function release(bytes32 drawId) external onlyExecutor {
        Draw storage d = draws[drawId];
        require(d.state == DrawState.LOCKED, DrawNotLocked(drawId));
        d.state = DrawState.RELEASED;
        d.token.safeTransfer(d.borrower, d.amount);
        emit CollateralReleased(drawId, d.borrower, d.amount);
    }

    /// @notice Maturity-default path: executor arms the auction after a confirmed failed pull.
    function armAuction(bytes32 drawId) external onlyExecutor returns (bytes32 orderHash) {
        Draw storage d = draws[drawId];
        require(d.state == DrawState.LOCKED, DrawNotLocked(drawId));
        return _armAuction(drawId, repaymentOf(drawId) - d.cured);
    }

    /// @dev Start price marked to the oracle AT ARM TIME (105% premium); auction params are
    /// facility-immutable. Covers THIS draw's collateral only (bounded allowance).
    function _armAuction(bytes32 drawId, uint256 debt) private returns (bytes32 orderHash) {
        Draw storage d = draws[drawId];
        Facility storage f = facilities[d.facilityId];
        d.state = DrawState.AUCTIONING;

        uint256 startBidRef = (d.amount * _freshPrice(f) * AUCTION_START_PREMIUM_BPS * 10 ** f.loanDecimals)
            / (10_000 * 10 ** (f.collateralDecimals + f.feedDecimals));

        uint256 fee = (debt * LIQ_FEE_BPS) / 10_000;
        ISwapVM.Order memory order = BUILDER.buildAuctionLeg(
            AlbaProgramBuilder.AuctionTerms({
                maker: address(this),
                bidToken: address(f.params.loanToken),
                collateralToken: address(d.token),
                collateralAmount: d.amount,
                startBidRef: startBidRef,
                target: debt + fee,
                startTime: uint40(block.timestamp),
                duration: f.params.auctionDuration,
                decayFactor: f.params.auctionDecay,
                salt: uint256(drawId)
            })
        );
        orderHash = ROUTER.hash(order);

        d.token.forceApprove(address(ROUTER), d.amount);
        armedOrders[orderHash] = true;

        auctions[drawId] =
            Auction({orderHash: orderHash, lender: f.lender, bidToken: f.params.loanToken, debt: debt, fee: fee});
        emit AuctionArmed(drawId, orderHash, debt + fee);
    }

    /// @notice Waterfall once the auction halted at target: lender up to debt →
    /// liquidation fee → surplus collateral back to the borrower. Permissionless.
    function sweepAuction(bytes32 drawId) external {
        Draw storage d = draws[drawId];
        Auction storage auction = auctions[drawId];
        require(d.state == DrawState.AUCTIONING, AuctionNotArmed(drawId));

        uint256 target = auction.debt + auction.fee;
        uint256 raised = ROUTER.coveredAmount(address(this), auction.orderHash);
        require(raised >= target, AuctionNotCovered(drawId, raised, target));

        d.state = DrawState.LIQUIDATED;

        // Sold = allowance consumed by router pulls; close every path to the collateral
        uint256 sold = d.amount - d.token.allowance(address(this), address(ROUTER));
        uint256 surplus = d.amount - sold;
        d.token.forceApprove(address(ROUTER), 0);
        armedOrders[auction.orderHash] = false;

        auction.bidToken.safeTransfer(auction.lender, auction.debt);
        auction.bidToken.safeTransfer(FEE_SINK, auction.fee);
        if (surplus > 0) {
            d.token.safeTransfer(d.borrower, surplus);
        }
        emit AuctionSwept(drawId, auction.debt, auction.fee, sold, surplus);
    }

    // ---------------------------------------------------------------- internals

    function _freshPrice(Facility storage f) private view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = f.params.oracle.latestRoundData();
        require(answer > 0, OracleInvalidPrice(answer));
        require(block.timestamp - updatedAt <= ORACLE_MAX_STALENESS, OracleStale(updatedAt, ORACLE_MAX_STALENESS));
        return uint256(answer);
    }

    function _pullTakerData(address to) private view returns (bytes memory) {
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: address(this),
                isExactIn: false, // exact-out zero-in pull
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: false,
                useTransferFromAndAquaPush: false,
                threshold: "",
                to: to,
                deadline: 0,
                hasPreTransferInCallback: false,
                hasPreTransferOutCallback: false,
                preTransferInHookData: "",
                postTransferInHookData: "",
                preTransferOutHookData: "",
                postTransferOutHookData: "",
                preTransferInCallbackData: "",
                preTransferOutCallbackData: "",
                instructionsArgs: "",
                signature: ""
            })
        );
    }
}
