// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AlbaProgramBuilder} from "./lib/ProgramBuilder.sol";
import {AlbaInstructionSet} from "./opcodes/AlbaInstructionSet.sol";

/// @title AlbaOrderBuilder — deployed order-construction views
/// @notice Split from TermRouter for EIP-170 size only; inherits the same
/// AlbaInstructionSet mixin, so its program bytes are byte-identical to what the
/// router executes. Every leg (facility, maturity, auction) is built here on-chain.
contract AlbaOrderBuilder is AlbaProgramBuilder {
    constructor(address aqua) AlbaInstructionSet(aqua) {}
}
