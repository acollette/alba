// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeERC20, IERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import {ISwapVM} from "swap-vm/src/interfaces/ISwapVM.sol";

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

    struct Auction {
        bytes32 orderHash;
        address lender;
        IERC20 bidToken;
        uint256 debt;
        uint256 fee;
    }

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
    address public immutable FEE_SINK;

    mapping(bytes32 drawId => Draw) public draws;
    mapping(bytes32 drawId => Auction) public auctions;
    /// @dev ERC-1271 authorization set: order hashes of currently armed auctions
    mapping(bytes32 orderHash => bool) public armedOrders;

    modifier onlyExecutor() {
        require(msg.sender == EXECUTOR, OnlyExecutor(msg.sender));
        _;
    }

    constructor(address executor, TermRouter router, address feeSink) {
        EXECUTOR = executor;
        ROUTER = router;
        FEE_SINK = feeSink;
    }

    /// @notice ERC-1271: the escrow "signs" exactly the auction orders it has armed.
    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        return armedOrders[hash] ? ERC1271_MAGIC : bytes4(0xffffffff);
    }

    /// @notice Lock collateral for a draw; pulls from the caller (the borrower).
    function lockFor(bytes32 drawId, IERC20 token, uint256 amount) external {
        require(draws[drawId].state == DrawState.NONE, DrawAlreadyExists(drawId));
        draws[drawId] = Draw({borrower: msg.sender, token: token, amount: amount, state: DrawState.LOCKED});
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit CollateralLocked(drawId, msg.sender, address(token), amount);
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
        ISwapVM.Order memory order = ROUTER.buildAuctionLeg(
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
