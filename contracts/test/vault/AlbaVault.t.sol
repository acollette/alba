// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {AlbaVault} from "../../src/vault/AlbaVault.sol";
import {VaultTestBase} from "./VaultTestBase.sol";

/// @notice T1 — vault core: 4626 invariants, inflation-attack vector, fee math
/// over warped time, pause behavior, full role matrix, sleeve registry rules.
contract AlbaVaultTest is VaultTestBase {
    // ------------------------------------------------------- 4626 invariants

    function test_Metadata() public view {
        assertEq(vault.asset(), address(usdc));
        assertEq(vault.decimals(), 12); // 6 (USDC) + 6 (inflation-guard offset)
        assertEq(vault.name(), "Alba USDC Vault");
        assertEq(vault.symbol(), "albaUSDC");
    }

    function test_DepositWithdrawRoundTrip() public {
        uint256 shares = _deposit(alice, 100_000e6);
        assertEq(shares, vault.balanceOf(alice));
        assertEq(vault.totalAssets(), 100_000e6);

        vm.prank(alice);
        vault.withdraw(100_000e6, alice, alice);
        assertEq(usdc.balanceOf(alice), 100_000e6);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_MintRedeemRoundTrip() public {
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        uint256 assetsIn = vault.mint(1_000e12, alice);
        uint256 assetsOut = vault.redeem(1_000e12, alice, alice);
        vm.stopPrank();
        assertLe(assetsOut, assetsIn); // rounding never favors the user
        assertApproxEqAbs(assetsOut, assetsIn, 1);
    }

    function test_PreviewConsistency() public {
        _deposit(bob, 37_123e6); // non-trivial share price state
        usdc.mint(address(vault), 913e6); // plus a donation

        uint256 assets = 12_345_678_901; // ~12.3k USDC
        assertEq(_deposit(alice, assets), vault.previewDeposit(assets));

        uint256 shares = vault.balanceOf(alice) / 3;
        uint256 previewed = vault.previewRedeem(shares);
        vm.prank(alice);
        assertEq(vault.redeem(shares, alice, alice), previewed);

        uint256 wAssets = 1_000e6;
        uint256 previewedShares = vault.previewWithdraw(wAssets);
        vm.prank(alice);
        assertEq(vault.withdraw(wAssets, alice, alice), previewedShares);
    }

    function testFuzz_RoundTripNeverProfits(uint256 assets) public {
        assets = bound(assets, 1, 1e15); // up to 1B USDC
        _deposit(bob, 5_000e6);
        usdc.mint(address(vault), 1_234_567); // skew share price
        uint256 shares = _deposit(alice, assets);
        vm.prank(alice);
        uint256 back = vault.redeem(shares, alice, alice);
        assertLe(back, assets);
    }

    function test_InflationAttack_NotProfitable() public {
        uint256 victimDeposit = 10_000e6;

        // Attacker front-runs: 1 wei deposit + large donation to skew the rate.
        address attacker = makeAddr("attacker");
        usdc.mint(attacker, victimDeposit + 1);
        vm.startPrank(attacker);
        usdc.approve(address(vault), 1);
        vault.deposit(1, attacker);
        usdc.transfer(address(vault), victimDeposit); // donation
        vm.stopPrank();

        uint256 victimShares = _deposit(alice, victimDeposit);
        assertGt(victimShares, 0); // victim is not zeroed out

        // Victim's loss is dust (decimals-offset absorbs the attack)...
        uint256 victimValue = vault.previewRedeem(victimShares);
        assertGe(victimValue + 0.02e6, victimDeposit); // ≤ 2 cents on $10k

        // ...and the attacker burned the donation: strictly unprofitable.
        vm.startPrank(attacker);
        uint256 attackerOut = vault.redeem(vault.balanceOf(attacker), attacker, attacker);
        vm.stopPrank();
        assertLt(attackerOut, victimDeposit + 1); // got back less than in
    }

    // ------------------------------------------------------------------ fees

    function test_FeeAccrual_OneYear() public {
        vm.prank(curator);
        vault.setFee(100); // 1%/yr
        _deposit(alice, 1_000_000e6);

        skip(365 days);

        // Views are fee-aware BEFORE settlement: alice already sees dilution.
        assertApproxEqAbs(vault.previewRedeem(vault.balanceOf(alice)), 990_000e6, 5);

        _deposit(bob, 1); // any flow settles the fee
        assertApproxEqAbs(vault.maxWithdraw(feeRecipient), 10_000e6, 5);

        // Fee shares redeem for real assets.
        uint256 feeShares = vault.balanceOf(feeRecipient);
        vm.prank(feeRecipient);
        uint256 got = vault.redeem(feeShares, feeRecipient, feeRecipient);
        assertApproxEqAbs(got, 10_000e6, 5);
    }

    function test_FeeAccrual_PartialPeriod_OnSleeveAssetsToo() public {
        _addSleeves(type(uint96).max, type(uint96).max);
        vm.prank(curator);
        vault.setFee(250); // 2.5%/yr
        _deposit(alice, 800_000e6);
        vm.prank(allocator);
        vault.allocate(address(sleeveA), 500_000e6); // fee accrues on NAV, not idle

        skip(73 days); // 1/5 year → 0.5% of 800k = 4k
        vm.prank(curator);
        vault.setFee(250); // param change settles
        assertApproxEqAbs(vault.maxWithdraw(feeRecipient), 4_000e6, 5);
    }

    function test_FeeSettledOnParamChange_NoRetroactiveFee() public {
        _deposit(alice, 100_000e6);
        skip(365 days); // feeBps = 0 the whole time
        vm.prank(curator);
        vault.setFee(500); // settlement stamps the clock: nothing owed for the past
        skip(1);
        vm.prank(curator);
        vault.setFee(0);
        // Only the 1 second at 5% accrued (~158 wei on 100k) — nothing retroactive.
        assertLe(vault.previewRedeem(vault.balanceOf(feeRecipient)), 200);
    }

    function test_SetFee_RevertsAboveMaxOrWithoutRecipient() public {
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(AlbaVault.FeeTooHigh.selector, 501));
        vault.setFee(501);

        vm.prank(curator);
        vault.setFeeRecipient(address(0)); // allowed while fee is 0
        vm.prank(curator);
        vm.expectRevert(AlbaVault.ZeroAddress.selector);
        vault.setFee(100);

        vm.prank(curator);
        vault.setFeeRecipient(feeRecipient);
        vm.startPrank(curator);
        vault.setFee(100);
        vm.expectRevert(AlbaVault.ZeroAddress.selector);
        vault.setFeeRecipient(address(0)); // not while fee > 0
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- pause

    function test_Pause_BlocksFlowsAndZeroesLimits() public {
        _deposit(alice, 1_000e6);
        vm.prank(guardian);
        vault.pause();

        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);

        usdc.mint(alice, 1e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1e6);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.deposit(1e6, alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.mint(1e6, alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.withdraw(1e6, alice, alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.redeem(1e6, alice, alice);
        vm.stopPrank();

        vm.prank(admin);
        vault.unpause();
        vm.prank(alice);
        vault.withdraw(1_000e6, alice, alice); // flows restored
    }

    function test_Pause_AllocateBlocked_DeallocateAllowed() public {
        _addSleeves(type(uint96).max, type(uint96).max);
        _deposit(alice, 10_000e6);
        vm.prank(allocator);
        vault.allocate(address(sleeveA), 4_000e6);

        vm.prank(guardian);
        vault.pause();

        vm.prank(allocator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.allocate(address(sleeveA), 1_000e6);

        vm.prank(allocator); // recovery direction stays open
        assertEq(vault.deallocate(address(sleeveA), 4_000e6), 4_000e6);
    }

    // ----------------------------------------------------------- role matrix

    function _expectUnauthorized(address account, bytes32 role) internal {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, role));
    }

    function test_RoleMatrix() public {
        bytes32 curatorRole = vault.CURATOR_ROLE();
        bytes32 allocatorRole = vault.ALLOCATOR_ROLE();
        bytes32 guardianRole = vault.GUARDIAN_ROLE();

        // Curator-only surface — allocator as representative intruder.
        vm.startPrank(allocator);
        _expectUnauthorized(allocator, curatorRole);
        vault.addSleeve(address(sleeveA), 1);
        _expectUnauthorized(allocator, curatorRole);
        vault.removeSleeve(address(sleeveA));
        _expectUnauthorized(allocator, curatorRole);
        vault.setSleeveCap(address(sleeveA), 1);
        _expectUnauthorized(allocator, curatorRole);
        vault.setFee(1);
        _expectUnauthorized(allocator, curatorRole);
        vault.setFeeRecipient(bob);
        vm.stopPrank();

        // Allocator-only surface — curator as intruder.
        vm.prank(curator);
        vault.addSleeve(address(sleeveA), type(uint96).max);
        _deposit(alice, 100e6);
        vm.startPrank(curator);
        _expectUnauthorized(curator, allocatorRole);
        vault.allocate(address(sleeveA), 100e6);
        _expectUnauthorized(curator, allocatorRole);
        vault.deallocate(address(sleeveA), 100e6);
        vm.stopPrank();

        // Guardian pauses; guardian cannot unpause; admin can.
        vm.prank(allocator);
        _expectUnauthorized(allocator, guardianRole);
        vault.pause();
        vm.prank(guardian);
        vault.pause();
        vm.prank(guardian);
        _expectUnauthorized(guardian, bytes32(0));
        vault.unpause();
        vm.prank(admin);
        vault.unpause();

        // Positive curator/allocator paths.
        vm.prank(curator);
        vault.setSleeveCap(address(sleeveA), type(uint96).max);
        vm.prank(allocator);
        vault.allocate(address(sleeveA), 100e6);
        vm.prank(allocator);
        vault.deallocate(address(sleeveA), 100e6);

        // Admin is not operational: cannot curate or allocate directly.
        vm.startPrank(admin);
        _expectUnauthorized(admin, curatorRole);
        vault.setFee(1);
        _expectUnauthorized(admin, allocatorRole);
        vault.allocate(address(sleeveA), 1);
        vm.stopPrank();
    }

    // -------------------------------------------------------- sleeve registry

    function test_SleeveRegistry_Rules() public {
        vm.startPrank(curator);
        vm.expectRevert(AlbaVault.ZeroAddress.selector);
        vault.addSleeve(address(0), 1);

        vault.addSleeve(address(sleeveA), 1_000e6);
        assertEq(vault.sleeveCount(), 1);
        vm.expectRevert(abi.encodeWithSelector(AlbaVault.SleeveAlreadyActive.selector, address(sleeveA)));
        vault.addSleeve(address(sleeveA), 1);

        vm.expectRevert(abi.encodeWithSelector(AlbaVault.SleeveNotActive.selector, address(sleeveB)));
        vault.setSleeveCap(address(sleeveB), 1);
        vm.expectRevert(abi.encodeWithSelector(AlbaVault.SleeveNotActive.selector, address(sleeveB)));
        vault.removeSleeve(address(sleeveB));
        vm.stopPrank();

        // Cap enforced on allocation (post-deposit sleeve NAV vs cap).
        _deposit(alice, 5_000e6);
        vm.prank(allocator);
        vm.expectRevert(
            abi.encodeWithSelector(AlbaVault.SleeveCapExceeded.selector, address(sleeveA), 1_001e6, 1_000e6)
        );
        vault.allocate(address(sleeveA), 1_001e6);
        vm.prank(allocator);
        vault.allocate(address(sleeveA), 1_000e6);

        // Unregistered sleeve cannot be allocated to.
        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(AlbaVault.SleeveNotActive.selector, address(sleeveB)));
        vault.allocate(address(sleeveB), 1e6);

        // Non-empty sleeve cannot be removed; emptied sleeve can.
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(AlbaVault.SleeveNotEmpty.selector, address(sleeveA)));
        vault.removeSleeve(address(sleeveA));
        vm.prank(allocator);
        vault.deallocate(address(sleeveA), type(uint256).max);
        vm.prank(curator);
        vault.removeSleeve(address(sleeveA));
        assertEq(vault.sleeveCount(), 0);
    }

    function test_TotalAssets_AcrossSleeves() public {
        _addSleeves(type(uint96).max, type(uint96).max);
        _deposit(alice, 90_000e6);
        vm.startPrank(allocator);
        vault.allocate(address(sleeveA), 30_000e6);
        vault.allocate(address(sleeveB), 20_000e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(vault)), 40_000e6);
        assertEq(vault.totalAssets(), 90_000e6); // idle + Σ sleeves
        assertEq(vault.liquidAssets(), 90_000e6); // everything liquid in mocks

        // Withdraw beyond idle pulls from sleeves transparently.
        vm.prank(alice);
        vault.withdraw(90_000e6, alice, alice);
        assertEq(usdc.balanceOf(alice), 90_000e6);
        assertEq(vault.totalAssets(), 0);
    }
}
