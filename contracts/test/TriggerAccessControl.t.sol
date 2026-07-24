// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {AlbaTriggerSpike} from "../src/spike/AlbaTriggerSpike.sol";
import {HSS_ADDRESS} from "../src/spike/IHederaScheduleService.sol";

/// @dev Minimal Axelar stand-ins: `dispatch` only needs these two calls to not revert.
contract MockGateway {
    function callContract(string calldata, string calldata, bytes calldata) external {}
}

contract MockGasService {
    function payNativeGasForContractCall(address, string calldata, string calldata, bytes calldata, address)
        external
        payable
    {}
}

/// @notice Locks down the access control added to AlbaTriggerSpike: only allowlisted
/// callers may `dispatch`, gas is capped per call, and — critically — the self-call path
/// (msg.sender == address(this)) that the Hedera schedule relies on is accepted.
///
/// NOTE: this proves the GUARD LOGIC. It cannot prove which address the live Hedera Schedule
/// Service presents as msg.sender — that is a network-runtime fact and still requires one
/// testnet `scheduleDispatch` run to confirm end-to-end.
contract TriggerAccessControl is Test {
    AlbaTriggerSpike trigger;
    address owner = makeAddr("owner");
    address stranger = makeAddr("stranger");

    function setUp() public {
        address gw = address(new MockGateway());
        address gs = address(new MockGasService());
        vm.prank(owner); // must be the call that immediately precedes the CREATE
        trigger = new AlbaTriggerSpike(gw, gs, "base", "0xReceiver");
        vm.deal(address(trigger), 100e8); // HBAR for the gas-service path
    }

    // ---- allowlist seeding ----

    function test_SeedsOwnerSelfAndHss() public view {
        assertTrue(trigger.isDispatcher(owner), "owner must be seeded");
        assertTrue(trigger.isDispatcher(address(trigger)), "self (scheduled path) must be seeded");
        assertTrue(trigger.isDispatcher(HSS_ADDRESS), "HSS must be seeded");
        assertFalse(trigger.isDispatcher(stranger), "stranger must not be seeded");
    }

    // ---- who may dispatch ----

    function test_StrangerCannotDispatch() public {
        vm.expectRevert(abi.encodeWithSelector(AlbaTriggerSpike.NotDispatcher.selector, stranger));
        vm.prank(stranger);
        trigger.dispatch(1, 1, "SETTLE", 0);
    }

    function test_OwnerCanDispatch() public {
        vm.prank(owner);
        trigger.dispatch(1, 1, "SETTLE", 2e8); // within default 5e8 cap
    }

    /// @dev The exact shape of a network-executed schedule: the contract calling its own
    /// dispatch. If this reverted, the live scheduled path would break.
    function test_ScheduledSelfCallAllowed() public {
        vm.prank(address(trigger));
        trigger.dispatch(1, 2, "SETTLE", 2e8);
    }

    // ---- gas cap ----

    function test_GasCapReverts() public {
        vm.expectRevert(abi.encodeWithSelector(AlbaTriggerSpike.GasCapExceeded.selector, 5e8 + 1, 5e8));
        vm.prank(owner);
        trigger.dispatch(1, 1, "SETTLE", 5e8 + 1);
    }

    function test_OwnerCanRaiseCap() public {
        vm.prank(owner);
        trigger.setMaxAxelarGas(10e8);
        vm.prank(owner);
        trigger.dispatch(1, 1, "SETTLE", 6e8); // now under the raised cap
    }

    // ---- owner-only admin ----

    function test_SetDispatcherOnlyOwner() public {
        vm.expectRevert(AlbaTriggerSpike.NotOwner.selector);
        vm.prank(stranger);
        trigger.setDispatcher(stranger, true);
    }

    function test_OwnerCanAuthorizeNewDispatcher() public {
        vm.prank(owner);
        trigger.setDispatcher(stranger, true);
        vm.prank(stranger);
        trigger.dispatch(1, 1, "SETTLE", 0); // now allowed
    }
}
