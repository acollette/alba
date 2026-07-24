// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Calldata} from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import {Context, ContextLib} from "swap-vm/src/libs/VM.sol";

library NotBeforeArgsBuilder {
    error NotBeforeMissingTimestampArg();

    function build(uint40 timestamp) internal pure returns (bytes memory) {
        return abi.encodePacked(timestamp);
    }

    function parse(bytes calldata args) internal pure returns (uint256 timestamp) {
        timestamp = uint40(bytes5(Calldata.slice(args, 0, 5, NotBeforeMissingTimestampArg.selector)));
    }
}

library OnlyTakerArgsBuilder {
    error OnlyTakerMissingExecutorArg();

    function build(address executor) internal pure returns (bytes memory) {
        return abi.encodePacked(executor);
    }

    function parse(bytes calldata args) internal pure returns (address executor) {
        executor = address(bytes20(Calldata.slice(args, 0, 20, OnlyTakerMissingExecutorArg.selector)));
    }
}

library StopWhenCoveredArgsBuilder {
    error StopWhenCoveredMissingArgs();

    /// @param targetCountsAmountIn true = target denominated in amountIn (auction: USDC raised),
    ///        false = target denominated in amountOut (facility: USDC drawn)
    function build(bool targetCountsAmountIn, uint256 target) internal pure returns (bytes memory) {
        return abi.encodePacked(targetCountsAmountIn, target);
    }

    function parse(bytes calldata args) internal pure returns (bool targetCountsAmountIn, uint256 target) {
        bytes calldata data = Calldata.slice(args, 0, 33, StopWhenCoveredMissingArgs.selector);
        targetCountsAmountIn = uint8(bytes1(data)) != 0;
        target = uint256(bytes32(data[1:33]));
    }
}

/// @title AlbaOpcodes — custom SwapVM instructions for term credit
/// @notice Storage and static-context discipline mirror swap-vm's Invalidators pattern:
/// checks run in both contexts, storage writes only when `!isStaticContext`.
contract AlbaOpcodes {
    using ContextLib for Context;

    error TooEarly(uint256 notBefore, uint256 currentTime);
    error UnauthorizedTaker(address taker, address executor);
    error OrderCovered(bytes32 orderHash);
    error StopWhenCoveredExceeded(uint256 requested, uint256 remaining);
    error StopWhenCoveredExpectsAmountToBeComputed();

    /// @dev Cumulative filled amount per (maker, orderHash), denominated in the leg's target register
    mapping(address maker => mapping(bytes32 orderHash => uint256 filled)) public coveredAmount;

    /// @dev args.timestamp | 5 bytes (uint40). Mirror of `_deadline`. Reverts in BOTH static and
    /// swap context before T — an unmatured position is not executable, quotes included.
    function _notBefore(Context memory, bytes calldata args) internal view {
        uint256 notBefore = NotBeforeArgsBuilder.parse(args);
        require(block.timestamp >= notBefore, TooEarly(notBefore, block.timestamp));
    }

    /// @dev args.executor | 20 bytes (address). SKIPS the check in static context so anyone
    /// (UI) can quote the settlement amount without impersonating the executor.
    function _onlyTaker(Context memory ctx, bytes calldata args) internal view {
        if (ctx.vm.isStaticContext) {
            return;
        }
        address executor = OnlyTakerArgsBuilder.parse(args);
        require(ctx.query.taker == executor, UnauthorizedTaker(ctx.query.taker, executor));
    }

    /// @dev args: [targetCountsAmountIn:1][target:32]. Caps cumulative fills at `target`
    /// (facility size / auction debt). Fill accounting keyed (maker, orderHash).
    ///
    /// Clamping: TakerTraits.validate pins the taker-specified register to the request, so only
    /// the DERIVED register may be adjusted. The single maker-safe clamp is exact-in against an
    /// amountOut-denominated target (facility draw): amountOut is clamped to the remainder.
    /// Every other overfill reverts with the remaining capacity so the filler can size the last
    /// fill exactly (coveredAmount is public; quote returns clamped numbers where clamping applies).
    /// NEVER writes storage in static context — quoting must not corrupt fill accounting.
    function _stopWhenCovered(Context memory ctx, bytes calldata args) internal {
        (bool targetCountsAmountIn, uint256 target) = StopWhenCoveredArgsBuilder.parse(args);

        // Wait until pricing computed the tracked register (invalidator pattern)
        uint256 amount = targetCountsAmountIn ? ctx.swap.amountIn : ctx.swap.amountOut;
        if (amount == 0) {
            ctx.runLoop();
            amount = targetCountsAmountIn ? ctx.swap.amountIn : ctx.swap.amountOut;
        }
        require(amount > 0, StopWhenCoveredExpectsAmountToBeComputed());

        uint256 filled = coveredAmount[ctx.query.maker][ctx.query.orderHash];
        uint256 remaining = target > filled ? target - filled : 0;
        require(remaining > 0, OrderCovered(ctx.query.orderHash));

        uint256 effective = amount;
        if (amount > remaining) {
            bool amountIsDerived = targetCountsAmountIn ? !ctx.query.isExactIn : ctx.query.isExactIn;
            if (amountIsDerived && !targetCountsAmountIn) {
                // Facility, exact-in: clamp maker's give to the remainder (maker-favorable)
                ctx.swap.amountOut = remaining;
                effective = remaining;
            } else {
                revert StopWhenCoveredExceeded(amount, remaining);
            }
        }

        if (!ctx.vm.isStaticContext) {
            coveredAmount[ctx.query.maker][ctx.query.orderHash] = filled + effective;
        }
    }
}
