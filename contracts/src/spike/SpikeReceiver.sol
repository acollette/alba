// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AxelarExecutable} from "axelar-gmp-sdk-solidity/contracts/executable/AxelarExecutable.sol";

/// @notice Dumb GMP receiver for the trigger-leg spike: proves a Hedera-origin
/// Axelar message executes on Base Sepolia. Emits the decoded payload, nothing else.
contract SpikeReceiver is AxelarExecutable {
    event TriggerReceived(
        bytes32 indexed commandId, string sourceChain, string sourceAddress, uint256 facilityId, uint256 drawId, string action
    );

    constructor(address gateway_) AxelarExecutable(gateway_) {}

    function _execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) internal override {
        (uint256 facilityId, uint256 drawId, string memory action) = abi.decode(payload, (uint256, uint256, string));
        emit TriggerReceived(commandId, sourceChain, sourceAddress, facilityId, drawId, action);
    }
}
