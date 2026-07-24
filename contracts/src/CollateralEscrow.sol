// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeERC20, IERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

/// @title CollateralEscrow — per-draw collateral custody for Chronos
/// @notice Collateral never enters Aqua while a loan is healthy: pull-rights over a wallet
/// the borrower controls are worthless, so collateral sits in code. Only after a confirmed
/// failed repayment pull does `armAuction` ship auction rights from the escrow (item 9).
///
/// INVARIANT (single-claim collateral): each draw's collateral can be claimed by exactly
/// one path — `release` (healthy settlement / surplus) or the auction strategy armed by
/// `armAuction` — and only via the settlement executor. No other path moves escrow funds.
contract CollateralEscrow {
    using SafeERC20 for IERC20;

    error OnlyExecutor(address caller);
    error DrawAlreadyExists(bytes32 drawId);
    error DrawNotLocked(bytes32 drawId);

    enum DrawState {
        NONE,
        LOCKED,
        RELEASED,
        AUCTIONING
    }

    struct Draw {
        address borrower;
        IERC20 token;
        uint256 amount;
        DrawState state;
    }

    event CollateralLocked(bytes32 indexed drawId, address indexed borrower, address token, uint256 amount);
    event CollateralReleased(bytes32 indexed drawId, address indexed borrower, uint256 amount);

    /// @notice Settlement executor (AxelarSettlementExecutor in production, manual in tests).
    /// Immutable by principle: no owner can re-point custody authority.
    address public immutable EXECUTOR;

    mapping(bytes32 drawId => Draw) public draws;

    modifier onlyExecutor() {
        require(msg.sender == EXECUTOR, OnlyExecutor(msg.sender));
        _;
    }

    constructor(address executor) {
        EXECUTOR = executor;
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
}
