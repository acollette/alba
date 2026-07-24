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
contract AlbaTriggerSpike {
    error ScheduleFailed(int64 code);
    error NotOwner();
    error NotDispatcher(address caller);
    error GasCapExceeded(uint256 requested, uint256 cap);

    event Dispatched(uint256 indexed facilityId, uint256 indexed drawId, string action, uint256 gasPaid);
    event DispatchScheduled(address scheduleAddress, uint256 expirySecond);
    event DispatcherSet(address indexed dispatcher, bool allowed);
    event MaxAxelarGasSet(uint256 maxAxelarGasTinybars);

    IAxelarGateway public immutable gateway;
    IAxelarGasService public immutable gasService;
    address public immutable owner;
    string public destinationChain;
    string public destinationAddress; // receiver address as checksummed hex string

    /// @notice Addresses permitted to call `dispatch`. Seeded with `owner` (manual demo runs),
    /// `address(this)` (the network-executed scheduled call — the contract scheduled a call to
    /// itself, so the inner `dispatch` sees `msg.sender == address(this)`), and the HSS system
    /// contract as belt-and-suspenders. Without this, `dispatch` is a public spend of the
    /// contract's HBAR: anyone could drain the Axelar-gas budget on junk messages.
    mapping(address dispatcher => bool allowed) public isDispatcher;

    /// @notice Upper bound on `axelarGasTinybars` per call. A caller (even an authorized one, or a
    /// mis-sized schedule) cannot forward more than this to the gas service in a single dispatch.
    /// Denominated in TINYBARS (Hedera EVM `msg.value` unit; 1 HBAR = 1e8 tinybars).
    uint256 public maxAxelarGasTinybars = 5e8; // 5 HBAR

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        address gateway_,
        address gasService_,
        string memory destinationChain_,
        string memory destinationAddress_
    ) {
        gateway = IAxelarGateway(gateway_);
        gasService = IAxelarGasService(gasService_);
        destinationChain = destinationChain_;
        destinationAddress = destinationAddress_;
        owner = msg.sender;

        isDispatcher[msg.sender] = true;
        isDispatcher[address(this)] = true;
        isDispatcher[HSS_ADDRESS] = true;
    }

    /// @notice Add or remove a permitted `dispatch` caller.
    function setDispatcher(address dispatcher, bool allowed) external onlyOwner {
        isDispatcher[dispatcher] = allowed;
        emit DispatcherSet(dispatcher, allowed);
    }

    /// @notice Adjust the per-call Axelar-gas cap (tinybars).
    function setMaxAxelarGas(uint256 maxAxelarGasTinybars_) external onlyOwner {
        maxAxelarGasTinybars = maxAxelarGasTinybars_;
        emit MaxAxelarGasSet(maxAxelarGasTinybars_);
    }

    /// @notice Send the GMP message now. `axelarGasTinybars` is taken from the contract's
    /// own balance and forwarded to the gas service (native-token gas payment). Restricted to
    /// authorized dispatchers and capped at `maxAxelarGasTinybars` so a stray call cannot drain
    /// the gas budget.
    function dispatch(uint256 facilityId, uint256 drawId, string calldata action, uint256 axelarGasTinybars) public {
        require(isDispatcher[msg.sender], NotDispatcher(msg.sender));
        require(axelarGasTinybars <= maxAxelarGasTinybars, GasCapExceeded(axelarGasTinybars, maxAxelarGasTinybars));
        // Payload shape per ARCHITECTURE.md: (facilityId, drawId, epoch, action); epoch 0 for single-shot
        bytes memory payload = abi.encode(facilityId, drawId, uint256(0), action);
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

    function withdraw() external onlyOwner {
        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable {}
}
