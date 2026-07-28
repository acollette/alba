// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MetaMorphoSleeve} from "../../src/vault/MetaMorphoSleeve.sol";
import {VaultTestBase} from "./VaultTestBase.sol";

/// @notice T4 (mock leg) — MetaMorphoSleeve round-trip against a mock 4626
/// target, liquidity clamping at high utilization, and access control.
contract MetaMorphoSleeveTest is VaultTestBase {
    function setUp() public override {
        super.setUp();
        _addSleeves(type(uint96).max, type(uint96).max);
    }

    function test_RoundTrip_ThroughVault() public {
        assertEq(sleeveA.kind(), "metamorpho");
        _deposit(alice, 50_000e6);
        vm.prank(allocator);
        vault.allocate(address(sleeveA), 50_000e6);

        assertEq(sleeveA.totalAssets(), 50_000e6);
        assertEq(targetA.balanceOf(address(sleeveA)), 50_000e6); // 1:1 fresh target
        assertEq(usdc.balanceOf(address(sleeveA)), 0); // nothing stranded

        vm.prank(allocator);
        assertEq(vault.deallocate(address(sleeveA), 50_000e6), 50_000e6);
        assertEq(usdc.balanceOf(address(vault)), 50_000e6);
        assertEq(sleeveA.totalAssets(), 0);
    }

    function test_TargetYield_FlowsToVaultNAV() public {
        _deposit(alice, 100_000e6);
        vm.prank(allocator);
        vault.allocate(address(sleeveA), 100_000e6);

        usdc.mint(address(targetA), 1_000e6); // target earns 1%
        assertApproxEqAbs(sleeveA.totalAssets(), 101_000e6, 2);
        assertApproxEqAbs(vault.totalAssets(), 101_000e6, 2);
        assertApproxEqAbs(vault.previewRedeem(vault.balanceOf(alice)), 101_000e6, 2);
    }

    function test_Withdraw_ClampsToTargetLiquidity() public {
        _deposit(alice, 10_000e6);
        vm.prank(allocator);
        vault.allocate(address(sleeveA), 10_000e6);

        targetA.setLiquid(3_000e6); // 4626 freeze / high utilization
        assertEq(sleeveA.liquidAssets(), 3_000e6);
        assertEq(sleeveA.totalAssets(), 10_000e6); // value unchanged

        vm.prank(allocator);
        assertEq(vault.deallocate(address(sleeveA), 10_000e6), 3_000e6); // no revert: partial
        assertEq(usdc.balanceOf(address(vault)), 3_000e6);

        targetA.setLiquid(type(uint256).max); // liquidity returns
        vm.prank(allocator);
        assertEq(vault.deallocate(address(sleeveA), type(uint256).max), 7_000e6);
    }

    function test_OnlyVault_CanOperate() public {
        vm.startPrank(alice);
        vm.expectRevert(MetaMorphoSleeve.NotVault.selector);
        sleeveA.deposit(1);
        vm.expectRevert(MetaMorphoSleeve.NotVault.selector);
        sleeveA.withdraw(1);
        vm.stopPrank();
    }

    function test_StrandedIdleUSDC_IsCountedAndRecoverable() public {
        usdc.mint(address(sleeveA), 500e6); // donation straight to the sleeve
        assertEq(sleeveA.totalAssets(), 500e6);
        assertEq(sleeveA.liquidAssets(), 500e6);
        vm.prank(allocator);
        assertEq(vault.deallocate(address(sleeveA), type(uint256).max), 500e6);
    }
}
