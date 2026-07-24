// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20, IERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import {ISwapVM} from "swap-vm/src/interfaces/ISwapVM.sol";
import {TakerTraitsLib} from "swap-vm/src/libs/TakerTraits.sol";

import {TermRouter} from "./TermRouter.sol";
import {ChronosProgramBuilder} from "./lib/ProgramBuilder.sol";

/// @title CollateralEscrow — per-draw collateral custody + auction maker for Chronos
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
    error DrawAlreadyExists(bytes32 drawId);
    error DrawNotLocked(bytes32 drawId);
    error AuctionNotArmed(bytes32 drawId);
    error AuctionNotCovered(bytes32 drawId, uint256 raised, uint256 target);

    enum DrawState {
        NONE,
        LOCKED,
        RELEASED,
        AUCTIONING,
        LIQUIDATED
    }

    struct Draw {
        address borrower;
        IERC20 token;
        uint256 amount;
        DrawState state;
    }

    struct Facility {
        ISwapVM.Order order; // facility leg built with _onlyTaker(this escrow)
        address lender;
        IERC20 loanToken;
        IERC20 collateralToken;
        uint256 collateralPerLoan1e18; // collateral units per loan unit, 1e18-scaled (130% etc.)
        bool exists;
    }

    struct Auction {
        bytes32 orderHash;
        address lender;
        IERC20 bidToken;
        uint256 debt;
        uint256 fee;
    }

    event FacilityRegistered(bytes32 indexed facilityId, address indexed lender, uint256 collateralPerLoan1e18);
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

    /// @notice Settlement executor (AxelarSettlementExecutor in production, manual in tests)
    address public immutable EXECUTOR;
    TermRouter public immutable ROUTER;
    ChronosProgramBuilder public immutable BUILDER;
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

    constructor(address executor, TermRouter router, ChronosProgramBuilder builder, address feeSink) {
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
        IERC20 loanToken,
        IERC20 collateralToken,
        uint256 collateralPerLoan1e18
    ) external {
        require(!facilities[facilityId].exists, FacilityAlreadyRegistered(facilityId));
        require(msg.sender == order.maker, OnlyFacilityLender(msg.sender, order.maker));
        facilities[facilityId] = Facility({
            order: order,
            lender: msg.sender,
            loanToken: loanToken,
            collateralToken: collateralToken,
            collateralPerLoan1e18: collateralPerLoan1e18,
            exists: true
        });
        emit FacilityRegistered(facilityId, msg.sender, collateralPerLoan1e18);
    }

    /// @notice THE draw: pulls pro-rata collateral from the caller and executes the facility
    /// pull in the same transaction, loan proceeds straight to the borrower. It is
    /// structurally impossible to hold drawn funds without the matching collateral locked —
    /// the facility leg's `_onlyTaker` rejects every other taker.
    /// @dev Collateral only locks per-draw: publishing/undrawn capacity costs the borrower nothing.
    function draw(bytes32 facilityId, bytes32 drawId, uint256 amount) external returns (uint256 collateral) {
        Facility storage f = facilities[facilityId];
        require(f.exists, FacilityUnknown(facilityId));
        require(draws[drawId].state == DrawState.NONE, DrawAlreadyExists(drawId));

        collateral = Math.ceilDiv(amount * f.collateralPerLoan1e18, 1e18);
        draws[drawId] =
            Draw({borrower: msg.sender, token: f.collateralToken, amount: collateral, state: DrawState.LOCKED});
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
    /// @param debt Outstanding repayment owed to the lender
    /// @param startBidRef Bid reference at start ≈ collateral × ~105% oracle price
    /// @param duration Auction lifetime seconds; expiry enforces the price floor
    /// @param decayFactor Per-second decay ×1e18; floor = start × decay^duration (~85% oracle)
    function armAuction(
        bytes32 drawId,
        address lender,
        IERC20 bidToken,
        uint256 debt,
        uint256 startBidRef,
        uint16 duration,
        uint64 decayFactor
    ) external onlyExecutor returns (bytes32 orderHash) {
        Draw storage draw = draws[drawId];
        require(draw.state == DrawState.LOCKED, DrawNotLocked(drawId));
        draw.state = DrawState.AUCTIONING;

        uint256 fee = (debt * LIQ_FEE_BPS) / 10_000;
        ISwapVM.Order memory order = BUILDER.buildAuctionLeg(
            ChronosProgramBuilder.AuctionTerms({
                maker: address(this),
                bidToken: address(bidToken),
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

        auctions[drawId] = Auction({orderHash: orderHash, lender: lender, bidToken: bidToken, debt: debt, fee: fee});
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
