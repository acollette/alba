// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {VaultTestBase} from "./VaultTestBase.sol";

/// @notice T5 — liquidity honesty: maxWithdraw/maxRedeem equal exactly what
/// executes, under every idle/liquid/illiquid allocation mix. The vault must
/// never promise instant exit from assets its sleeves cannot free right now.
contract LiquidityHonestyTest is VaultTestBase {
    function setUp() public override {
        super.setUp();
        _addSleeves(type(uint96).max, type(uint96).max);
        _deposit(alice, 100_000e6);
        // Mixed book: 20k idle, 30k in liquid sleeve A, 50k in sleeve B.
        vm.startPrank(allocator);
        vault.allocate(address(sleeveA), 30_000e6);
        vault.allocate(address(sleeveB), 50_000e6);
        vm.stopPrank();
    }

    /// @dev maxWithdraw must be executable to the last unit and one over must revert.
    function _assertHonest(address user) internal {
        uint256 max = vault.maxWithdraw(user);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, user, max + 1, max));
        vault.withdraw(max + 1, user, user);

        uint256 before = usdc.balanceOf(user);
        vm.prank(user);
        vault.withdraw(max, user, user);
        assertEq(usdc.balanceOf(user), before + max);
    }

    function test_FullyLiquid_MaxIsWholePosition() public {
        assertApproxEqAbs(vault.maxWithdraw(alice), 100_000e6, 1);
        _assertHonest(alice);
    }

    function test_IlliquidSleeve_CapsMaxWithdraw() public {
        targetB.setLiquid(5_000e6); // 45k of B is stuck
        assertEq(vault.liquidAssets(), 55_000e6); // 20k idle + 30k A + 5k B
        assertEq(vault.maxWithdraw(alice), 55_000e6); // liquidity binds, not NAV
        _assertHonest(alice);
    }

    function test_FrozenSleeve_OnlyIdlePlusLiquid() public {
        targetB.setLiquid(0);
        assertEq(vault.maxWithdraw(alice), 50_000e6); // 20k idle + 30k A
        _assertHonest(alice);
        // NAV still counts the frozen assets — only *exit* is limited.
        assertApproxEqAbs(vault.totalAssets(), 50_000e6, 1);
    }

    function test_MaxRedeem_MatchesExecutableShares() public {
        targetB.setLiquid(7_777e5); // awkward number
        uint256 maxShares = vault.maxRedeem(alice);
        assertLt(maxShares, vault.balanceOf(alice));
        vm.prank(alice);
        uint256 out = vault.redeem(maxShares, alice, alice);
        assertLe(out, 20_000e6 + 30_000e6 + 7_777e5);
        assertEq(usdc.balanceOf(alice), out);
    }

    function testFuzz_MaxWithdrawAlwaysExecutable(uint256 liquidB) public {
        liquidB = bound(liquidB, 0, 60_000e6);
        targetB.setLiquid(liquidB);
        uint256 max = vault.maxWithdraw(alice);
        vm.prank(alice);
        vault.withdraw(max, alice, alice);
        assertEq(usdc.balanceOf(alice), max);
    }
}
