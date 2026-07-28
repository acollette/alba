// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {AlbaVault} from "../../src/vault/AlbaVault.sol";
import {MetaMorphoSleeve} from "../../src/vault/MetaMorphoSleeve.sol";

/// @notice T4 (fork leg) — MetaMorphoSleeve against the live Moonwell Flagship
/// USDC MetaMorpho vault on Base mainnet, pinned block (same pin as the
/// hackathon fork tests). Proves the adapter round-trips real MetaMorpho
/// share accounting and that liquidAssets tracks the live maxWithdraw.
contract MetaMorphoSleeveForkTest is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    /// @dev Moonwell Flagship USDC (MetaMorpho), ~ $7.5M totalAssets at pin.
    IERC4626 constant MOONWELL_USDC = IERC4626(0xc1256Ae5FF1cf2719D4937adb3bbCCab2E00A2Ca);
    uint256 constant FORK_BLOCK = 49_062_000;

    AlbaVault vault;
    MetaMorphoSleeve sleeve;

    address admin = makeAddr("admin");
    address curator = makeAddr("curator");
    address allocator = makeAddr("allocator");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_MAINNET_RPC", string("https://mainnet.base.org")), FORK_BLOCK);
        assertEq(MOONWELL_USDC.asset(), USDC, "target vault is not a USDC MetaMorpho");

        vault = new AlbaVault(IERC20(USDC), admin, address(0));
        sleeve = new MetaMorphoSleeve(address(vault), MOONWELL_USDC);

        vm.startPrank(admin);
        vault.grantRole(vault.CURATOR_ROLE(), curator);
        vault.grantRole(vault.ALLOCATOR_ROLE(), allocator);
        vm.stopPrank();
        vm.prank(curator);
        vault.addSleeve(address(sleeve), 500_000e6);

        deal(USDC, alice, 250_000e6);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), 250_000e6);
        vault.deposit(250_000e6, alice);
        vm.stopPrank();
    }

    function test_Fork_AllocateRoundTrip() public {
        vm.prank(allocator);
        vault.allocate(address(sleeve), 200_000e6);

        // Real MetaMorpho share accounting: value survives the hop (±rounding).
        assertGt(MOONWELL_USDC.balanceOf(address(sleeve)), 0);
        assertApproxEqAbs(sleeve.totalAssets(), 200_000e6, 2);
        assertApproxEqAbs(vault.totalAssets(), 250_000e6, 2);

        // Live liquidity is deep at the pinned block; sleeve reports it honestly.
        assertGe(sleeve.liquidAssets(), sleeve.totalAssets() - 2);

        vm.prank(allocator);
        uint256 back = vault.deallocate(address(sleeve), 120_000e6);
        assertEq(back, 120_000e6);
        assertEq(IERC20(USDC).balanceOf(address(vault)), 170_000e6);
        assertApproxEqAbs(sleeve.totalAssets(), 80_000e6, 2);
    }

    function test_Fork_UserWithdrawPullsFromLiveSleeve() public {
        vm.prank(allocator);
        vault.allocate(address(sleeve), 200_000e6);

        uint256 max = vault.maxWithdraw(alice);
        assertApproxEqAbs(max, 250_000e6, 2); // NAV fully liquid via Moonwell

        vm.prank(alice);
        vault.withdraw(max, alice, alice); // idle 50k + 200k pulled live
        assertEq(IERC20(USDC).balanceOf(alice), max);
        assertLe(vault.totalAssets(), 4); // dust only
    }
}
