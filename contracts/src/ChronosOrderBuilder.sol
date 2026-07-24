// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ChronosProgramBuilder} from "./lib/ProgramBuilder.sol";
import {ChronosInstructionSet} from "./opcodes/ChronosInstructionSet.sol";

/// @title ChronosOrderBuilder — deployed order-construction views
/// @notice Split from TermRouter for EIP-170 size only; inherits the same
/// ChronosInstructionSet mixin, so its program bytes are byte-identical to what the
/// router executes. Every leg (facility, maturity, auction) is built here on-chain.
contract ChronosOrderBuilder is ChronosProgramBuilder {
    constructor(address aqua) ChronosInstructionSet(aqua) {}
}
