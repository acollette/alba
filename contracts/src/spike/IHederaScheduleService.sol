// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Hedera Schedule Service system contract (HIP-1215), deployed at address 0x16b.
/// Calls never revert: failures return a zero schedule address and a non-22 response code
/// (ordinals of the HAPI ResponseCodeEnum; 22 == SUCCESS).
interface IHederaScheduleService {
    function scheduleCall(
        address to,
        uint256 expirySecond,
        uint256 gasLimit,
        uint64 value,
        bytes memory callData
    ) external returns (int64 responseCode, address scheduleAddress);

    function scheduleCallWithPayer(
        address to,
        address payer,
        uint256 expirySecond,
        uint256 gasLimit,
        uint64 value,
        bytes memory callData
    ) external returns (int64 responseCode, address scheduleAddress);

    function deleteSchedule(address scheduleAddress) external returns (int64 responseCode);

    function hasScheduleCapacity(uint256 expirySecond, uint256 gasLimit) external view returns (bool);
}

address constant HSS_ADDRESS = address(0x16b);
int64 constant HSS_SUCCESS = 22;
