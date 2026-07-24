// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Simulator} from "@1inch/solidity-utils/contracts/mixins/Simulator.sol";

import {SwapVM} from "swap-vm/src/SwapVM.sol";
import {Context} from "swap-vm/src/libs/VM.sol";
import {AlbaInstructionSet} from "./opcodes/AlbaInstructionSet.sol";

/// @title TermRouter — SwapVM router for term credit (Alba)
/// @notice Redeployment of the SwapVM router (allowed by the 1inch Aqua brief) pointing at the
/// OFFICIAL Aqua deployment. Executes the shared AlbaInstructionSet table. Order
/// construction lives in the separately-deployed AlbaOrderBuilder (EIP-170), which
/// inherits the SAME table mixin — program bytes stay single-sourced.
contract TermRouter is Simulator, SwapVM, AlbaInstructionSet {
    constructor(address aqua, address weth, address owner)
        SwapVM(aqua, weth, owner, "Alba TermRouter", "1.0.0")
        AlbaInstructionSet(aqua)
    {}

    function _instructions()
        internal
        pure
        override
        returns (function(Context memory, bytes calldata) internal[] memory result)
    {
        return _albaInstructions();
    }
}
