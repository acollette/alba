// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Simulator} from "@1inch/solidity-utils/contracts/mixins/Simulator.sol";

import {SwapVM} from "swap-vm/src/SwapVM.sol";
import {Context} from "swap-vm/src/libs/VM.sol";
import {ChronosInstructionSet} from "./opcodes/ChronosInstructionSet.sol";

/// @title TermRouter — SwapVM router for term credit (Chronos)
/// @notice Redeployment of the SwapVM router (allowed by the 1inch Aqua brief) pointing at the
/// OFFICIAL Aqua deployment. Executes the shared ChronosInstructionSet table. Order
/// construction lives in the separately-deployed ChronosOrderBuilder (EIP-170), which
/// inherits the SAME table mixin — program bytes stay single-sourced.
contract TermRouter is Simulator, SwapVM, ChronosInstructionSet {
    constructor(address aqua, address weth, address owner)
        SwapVM(aqua, weth, owner, "Chronos TermRouter", "1.0.0")
        ChronosInstructionSet(aqua)
    {}

    function _instructions()
        internal
        pure
        override
        returns (function(Context memory, bytes calldata) internal[] memory result)
    {
        return _chronosInstructions();
    }
}
