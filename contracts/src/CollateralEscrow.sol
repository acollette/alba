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

/// @title CollateralEscrow — per-draw collateral custody + auction maker for Alba
/// @notice Collateral never enters Aqua while a loan is healthy: pull-rights over a wallet
/// the borrower controls are worthless, so collateral sits in code. Only after a confirmed
/// failed repayment pull does `armAuction` open a sale path over the collateral.
///
/// The auction is a signature-mode SwapVM order the escrow authorizes via ERC-1271 —
/// code signing for code. Sale exposure is capped by a bounded allowance to the router
/// (this draw's collateral only), pricing is purely time-decayed (static balances), and
/// `_stopWhenCovered` halts sales the moment the lender-side target is raised.
///
/// INVARIANT (single-claim collateral): each draw's collateral leaves by exactly one path —
/// `release` (healthy settlement) or the auction armed once by `armAuction` — both gated by
/// the settlement executor. `sweepAuction` closes the auction path (revokes allowance +
/// de-authorizes the order) before paying out the waterfall: lender up to debt →
/// liquidation fee → surplus collateral back to the borrower.
///
/// Fees are immutable constants by principle: infrastructure that can't reprice you.
contract CollateralEscrow {
    using SafeERC20 for IERC20;

    error OnlyExecutor(address caller);
    error FacilityAlreadyRegistered(bytes32 facilityId);
    error FacilityUnknown(bytes32 facilityId);
    error OnlyFacilityLender(address caller, address lender);
    error OnlyFacilityBorrower(address caller, address borrower);
    error DrawAlreadyExists(bytes32 drawId);
    error DrawNotLocked(bytes32 drawId);
    error AuctionNotArmed(bytes32 drawId);
    error AuctionNotCovered(bytes32 drawId, uint256 raised, uint256 target);
    error OracleInvalidPrice(int256 answer);
    error OracleStale(uint256 updatedAt, uint256 maxStaleness);

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
        uint256 amount;
        DrawState state;
    }

    struct Facility {
        ISwapVM.Order order; // facility leg built with _onlyTaker(this escrow)
        address lender;
        address borrower; // named counterparty; address(0) = open to any collateralized borrower
        IERC20 loanToken;
        IERC20 collateralToken;
        IAggregatorV3 oracle; // collateral/USD feed; loan token assumed USD-stable
        uint256 collateralRatioBps; // e.g. 13_000 = 130%
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
    event AuctionArmed(bytes32 indexed drawId, bytes32 orderHash, uint256 target);
    event AuctionSwept(
        bytes32 indexed drawId, uint256 lenderPaid, uint256 feePaid, uint256 collateralSold, uint256 surplusReturned
    );

    bytes4 private constant ERC1271_MAGIC = 0x1626ba7e;

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

    modifier onlyExecutor() {
        require(msg.sender == EXECUTOR, OnlyExecutor(msg.sender));
        _;
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

    /// @notice Lender registers a facility whose draw leg names THIS escrow as sole taker.
    /// From then on the only way to draw is `draw()` — collateral in, cash out, atomically.
    function registerFacility(
        bytes32 facilityId,
        ISwapVM.Order calldata order,
        address borrower,
        IERC20 loanToken,
        IERC20 collateralToken,
        IAggregatorV3 oracle,
        uint256 collateralRatioBps
    ) external {
        require(!facilities[facilityId].exists, FacilityAlreadyRegistered(facilityId));
        require(msg.sender == order.maker, OnlyFacilityLender(msg.sender, order.maker));
        facilities[facilityId] = Facility({
            order: order,
            lender: msg.sender,
            borrower: borrower,
            loanToken: loanToken,
            collateralToken: collateralToken,
            oracle: oracle,
            collateralRatioBps: collateralRatioBps,
            loanDecimals: IERC20Metadata(address(loanToken)).decimals(),
            collateralDecimals: IERC20Metadata(address(collateralToken)).decimals(),
            feedDecimals: oracle.decimals(),
            exists: true
        });
        emit FacilityRegistered(facilityId, msg.sender, collateralRatioBps);
    }

    /// @notice Live collateral requirement for a draw of `amount` loan tokens, at the
    /// current oracle price: amount × ratio / price, in collateral token units.
    function collateralForDraw(bytes32 facilityId, uint256 amount) public view returns (uint256) {
        Facility storage f = facilities[facilityId];
        require(f.exists, FacilityUnknown(facilityId));
        uint256 price = _freshPrice(f);
        return Math.ceilDiv(
            amount * f.collateralRatioBps * 10 ** (f.feedDecimals + f.collateralDecimals),
            10_000 * 10 ** f.loanDecimals * price
        );
    }

    function _freshPrice(Facility storage f) private view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = f.oracle.latestRoundData();
        require(answer > 0, OracleInvalidPrice(answer));
        require(block.timestamp - updatedAt <= ORACLE_MAX_STALENESS, OracleStale(updatedAt, ORACLE_MAX_STALENESS));
        return uint256(answer);
    }

    /// @notice THE draw: pulls pro-rata collateral from the caller and executes the facility
    /// pull in the same transaction, loan proceeds straight to the borrower. It is
    /// structurally impossible to hold drawn funds without the matching collateral locked —
    /// the facility leg's `_onlyTaker` rejects every other taker.
    /// @dev Collateral only locks per-draw: publishing/undrawn capacity costs the borrower nothing.
    function draw(bytes32 facilityId, bytes32 drawId, uint256 amount) external returns (uint256 collateral) {
        Facility storage f = facilities[facilityId];
        require(f.exists, FacilityUnknown(facilityId));
        require(f.borrower == address(0) || msg.sender == f.borrower, OnlyFacilityBorrower(msg.sender, f.borrower));
        require(draws[drawId].state == DrawState.NONE, DrawAlreadyExists(drawId));

        collateral = collateralForDraw(facilityId, amount);
        draws[drawId] = Draw({
            facilityId: facilityId,
            borrower: msg.sender,
            token: f.collateralToken,
            amount: collateral,
            state: DrawState.LOCKED
        });
        f.collateralToken.safeTransferFrom(msg.sender, address(this), collateral);
        emit CollateralLocked(drawId, msg.sender, address(f.collateralToken), collateral);

        ROUTER.swap(f.order, address(f.collateralToken), address(f.loanToken), amount, _drawTakerData(msg.sender));
        emit Drawn(facilityId, drawId, msg.sender, amount, collateral);
    }

    function _drawTakerData(address borrower) private view returns (bytes memory) {
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: address(this),
                isExactIn: false, // exact-out: amount = loan tokens drawn
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: false,
                useTransferFromAndAquaPush: false,
                threshold: "",
                to: borrower, // proceeds land with the borrower, not the escrow
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

    /// @notice Return collateral to the borrower after a successful repayment settlement.
    function release(bytes32 drawId) external onlyExecutor {
        Draw storage draw = draws[drawId];
        require(draw.state == DrawState.LOCKED, DrawNotLocked(drawId));
        draw.state = DrawState.RELEASED;
        draw.token.safeTransfer(draw.borrower, draw.amount);
        emit CollateralReleased(drawId, draw.borrower, draw.amount);
    }

    /// @notice Arm the Dutch-auction liquidation after a confirmed failed repayment pull.
    /// The order is built by the router's program builder — the same single source of truth
    /// as every other leg — and covers THIS draw's collateral only (bounded allowance).
    /// The start price is marked to the oracle AT ARM TIME (105% premium, immutable constant),
    /// never a stale registration-time number. Lender and bid token derive from the facility.
    /// @param debt Outstanding repayment owed to the lender
    /// @param duration Auction lifetime seconds; expiry enforces the price floor
    /// @param decayFactor Per-second decay ×1e18; floor = start × decay^duration (~85% oracle)
    function armAuction(bytes32 drawId, uint256 debt, uint16 duration, uint64 decayFactor)
        external
        onlyExecutor
        returns (bytes32 orderHash)
    {
        Draw storage draw = draws[drawId];
        require(draw.state == DrawState.LOCKED, DrawNotLocked(drawId));
        draw.state = DrawState.AUCTIONING;

        Facility storage f = facilities[draw.facilityId];
        uint256 startBidRef = (draw.amount * _freshPrice(f) * AUCTION_START_PREMIUM_BPS * 10 ** f.loanDecimals)
            / (10_000 * 10 ** (f.collateralDecimals + f.feedDecimals));

        uint256 fee = (debt * LIQ_FEE_BPS) / 10_000;
        ISwapVM.Order memory order = BUILDER.buildAuctionLeg(
            AlbaProgramBuilder.AuctionTerms({
                maker: address(this),
                bidToken: address(f.loanToken),
                collateralToken: address(draw.token),
                collateralAmount: draw.amount,
                startBidRef: startBidRef,
                target: debt + fee,
                startTime: uint40(block.timestamp),
                duration: duration,
                decayFactor: decayFactor,
                salt: uint256(drawId)
            })
        );
        orderHash = ROUTER.hash(order);

        draw.token.forceApprove(address(ROUTER), draw.amount);
        armedOrders[orderHash] = true;

        auctions[drawId] =
            Auction({orderHash: orderHash, lender: f.lender, bidToken: f.loanToken, debt: debt, fee: fee});
        emit AuctionArmed(drawId, orderHash, debt + fee);
    }

    /// @notice Waterfall once the auction halted at target: lender up to debt →
    /// liquidation fee → surplus collateral back to the borrower. Permissionless.
    function sweepAuction(bytes32 drawId) external {
        Draw storage draw = draws[drawId];
        Auction storage auction = auctions[drawId];
        require(draw.state == DrawState.AUCTIONING, AuctionNotArmed(drawId));

        uint256 target = auction.debt + auction.fee;
        uint256 raised = ROUTER.coveredAmount(address(this), auction.orderHash);
        require(raised >= target, AuctionNotCovered(drawId, raised, target));

        draw.state = DrawState.LIQUIDATED;

        // Sold = allowance consumed by router pulls; close every path to the collateral
        uint256 sold = draw.amount - draw.token.allowance(address(this), address(ROUTER));
        uint256 surplus = draw.amount - sold;
        draw.token.forceApprove(address(ROUTER), 0);
        armedOrders[auction.orderHash] = false;

        auction.bidToken.safeTransfer(auction.lender, auction.debt);
        auction.bidToken.safeTransfer(FEE_SINK, auction.fee);
        if (surplus > 0) {
            draw.token.safeTransfer(draw.borrower, surplus);
        }
        emit AuctionSwept(drawId, auction.debt, auction.fee, sold, surplus);
    }
}
