// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Simulator } from "@1inch/solidity-utils/contracts/mixins/Simulator.sol";

import { SwapVM } from "swap-vm/src/SwapVM.sol";
import { Context } from "swap-vm/src/libs/VM.sol";
import { Opcodes } from "swap-vm/src/opcodes/Opcodes.sol";

import { ChronosProgramBuilder } from "./lib/ProgramBuilder.sol";

/// @title TermRouter — SwapVM router for term credit (Chronos)
/// @notice Redeployment of the SwapVM router (allowed by the 1inch Aqua brief) pointing at the
/// OFFICIAL Aqua deployment. Composes the full built-in instruction set with three custom
/// opcodes appended at the end of the table: `_notBefore`, `_onlyTaker`, `_stopWhenCovered`.
contract TermRouter is Simulator, SwapVM, ChronosProgramBuilder {
    constructor(address aqua, address weth, address owner)
        SwapVM(aqua, weth, owner, "Chronos TermRouter", "1.0.0")
        Opcodes(aqua)
    { }

    /// @dev Built-in table (46 entries) + Chronos opcodes at indices 46/47/48
    function _instructions()
        internal
        pure
        override(SwapVM, ChronosProgramBuilder)
        returns (function(Context memory, bytes calldata) internal[] memory result)
    {
        function(Context memory, bytes calldata) internal[] memory base = _opcodes();
        result = new function(Context memory, bytes calldata) internal[](base.length + 3);
        for (uint256 i = 0; i < base.length; i++) {
            result[i] = base[i];
        }
        result[base.length] = _notBefore;
        result[base.length + 1] = _onlyTaker;
        result[base.length + 2] = _stopWhenCovered;
    }
}
