// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Context } from "swap-vm/src/libs/VM.sol";

library NotBeforeArgsBuilder {
    function build(uint40 timestamp) internal pure returns (bytes memory) {
        return abi.encodePacked(timestamp);
    }
}

library OnlyTakerArgsBuilder {
    function build(address executor) internal pure returns (bytes memory) {
        return abi.encodePacked(executor);
    }
}

library StopWhenCoveredArgsBuilder {
    function build(uint256 target) internal pure returns (bytes memory) {
        return abi.encodePacked(target);
    }
}

/// @title ChronosOpcodes — custom SwapVM instructions for term credit
/// @notice `_notBefore` gates maturity legs, `_onlyTaker` restricts settlement to the
/// Axelar executor, `_stopWhenCovered` caps cumulative fills (facility size / auction debt).
/// Storage and static-context discipline mirror swap-vm's Invalidators pattern.
contract ChronosOpcodes {
    error ChronosOpcodeNotImplemented();

    /// @dev Cumulative filled amount per (maker, orderHash), denominated per _stopWhenCovered target
    mapping(address maker => mapping(bytes32 orderHash => uint256 filled)) public coveredAmount;

    /// @dev args.timestamp | 5 bytes (uint40) — reverts in BOTH static and swap context before T
    function _notBefore(Context memory, bytes calldata) internal view {
        revert ChronosOpcodeNotImplemented();
    }

    /// @dev args.executor | 20 bytes (address) — SKIPS check in static context (quotes open to all)
    function _onlyTaker(Context memory, bytes calldata) internal view {
        revert ChronosOpcodeNotImplemented();
    }

    /// @dev args.target | 32 bytes (uint256) — clamps final partial fill; NEVER writes storage when static
    function _stopWhenCovered(Context memory, bytes calldata) internal {
        revert ChronosOpcodeNotImplemented();
    }
}
