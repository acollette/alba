// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAxelarGateway} from "axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGateway.sol";
import {IAxelarGasService} from "axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGasService.sol";
import {IHederaScheduleService, HSS_ADDRESS, HSS_SUCCESS} from "./IHederaScheduleService.sol";

/// @notice Hedera-side trigger for the spike: dispatches a GMP payload to Base Sepolia,
/// either immediately (`dispatch`) or via a native Hedera scheduled transaction
/// (`scheduleDispatch` → HIP-1215 Schedule Service executes `dispatch` at T, no keeper).
///
/// The contract funds Axelar gas from its own HBAR balance so the scheduled execution
/// is fully self-contained. Fund it after deploy; `withdraw` recovers leftovers.
contract ChronosTriggerSpike {
    error ScheduleFailed(int64 code);
    error NotOwner();

    event Dispatched(uint256 indexed facilityId, uint256 indexed drawId, string action, uint256 gasPaid);
    event DispatchScheduled(address scheduleAddress, uint256 expirySecond);

    IAxelarGateway public immutable gateway;
    IAxelarGasService public immutable gasService;
    address public immutable owner;
    string public destinationChain;
    string public destinationAddress; // receiver address as checksummed hex string

    constructor(address gateway_, address gasService_, string memory destinationChain_, string memory destinationAddress_) {
        gateway = IAxelarGateway(gateway_);
        gasService = IAxelarGasService(gasService_);
        destinationChain = destinationChain_;
        destinationAddress = destinationAddress_;
        owner = msg.sender;
    }

    /// @notice Send the GMP message now. `axelarGasTinybars` is taken from the contract's
    /// own balance and forwarded to the gas service (native-token gas payment).
    function dispatch(uint256 facilityId, uint256 drawId, string calldata action, uint256 axelarGasTinybars) public {
        bytes memory payload = abi.encode(facilityId, drawId, action);
        if (axelarGasTinybars > 0) {
            gasService.payNativeGasForContractCall{value: axelarGasTinybars}(
                address(this), destinationChain, destinationAddress, payload, owner
            );
        }
        gateway.callContract(destinationChain, destinationAddress, payload);
        emit Dispatched(facilityId, drawId, action, axelarGasTinybars);
    }

    /// @notice Ask the Hedera network itself to run `dispatch` at `expirySecond`.
    function scheduleDispatch(
        uint256 facilityId,
        uint256 drawId,
        string calldata action,
        uint256 expirySecond,
        uint256 scheduleGasLimit,
        uint256 axelarGasTinybars
    ) external returns (address scheduleAddress) {
        bytes memory callData = abi.encodeCall(this.dispatch, (facilityId, drawId, action, axelarGasTinybars));
        (int64 code, address addr) =
            IHederaScheduleService(HSS_ADDRESS).scheduleCall(address(this), expirySecond, scheduleGasLimit, 0, callData);
        if (code != HSS_SUCCESS) revert ScheduleFailed(code);
        emit DispatchScheduled(addr, expirySecond);
        return addr;
    }

    function hasCapacity(uint256 expirySecond, uint256 gasLimit) external view returns (bool) {
        return IHederaScheduleService(HSS_ADDRESS).hasScheduleCapacity(expirySecond, gasLimit);
    }

    function withdraw() external {
        if (msg.sender != owner) revert NotOwner();
        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable {}
}
