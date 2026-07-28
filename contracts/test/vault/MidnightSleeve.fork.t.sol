// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {AlbaVault} from "../../src/vault/AlbaVault.sol";
import {MetaMorphoSleeve} from "../../src/vault/MetaMorphoSleeve.sol";
import {MidnightSleeve} from "../../src/vault/MidnightSleeve.sol";
import {IMidnight, Market, Offer} from "../../src/vault/interfaces/IMidnight.sol";
import {MidnightForkBase} from "./MidnightForkBase.sol";

/// @notice T2 — MidnightSleeve against the REAL Midnight core on a pinned Base
/// fork: real fill from the API fixture, partial fills, every on-chain guard,
/// accretion-to-par NAV, warp-to-maturity redemption funded by a realistic
/// prank-repay (the ask maker is a borrower-issuer), the FCFS-underfunded
/// edge, a real emergencySell into a standing bid, and the full vault
/// lifecycle with the MetaMorpho buffer first in registry order.
contract MidnightSleeveForkTest is MidnightForkBase {
    /// @dev Midnight's own error for a take exceeding the offer's remaining size.
    error ConsumedAssets();

    /// @dev Moonwell Flagship USDC — same buffer target as the T4 fork test.
    IERC4626 constant MOONWELL_USDC = IERC4626(0xc1256Ae5FF1cf2719D4937adb3bbCCab2E00A2Ca);
    /// @dev Market cash pool already funded with this much at the pin (an
    /// early borrower repayment) — real pre-maturity claimable par.
    uint256 constant POOL_AT_PIN = 11_052_966;

    AlbaVault vault;
    MetaMorphoSleeve buffer;
    MidnightSleeve sleeve;

    address admin = makeAddr("admin");
    address curator = makeAddr("curator");
    address allocator = makeAddr("allocator");
    address alice = makeAddr("alice");

    function setUp() public {
        _selectFork();
        vault = new AlbaVault(IERC20(USDC), admin, address(0));
        buffer = new MetaMorphoSleeve(address(vault), MOONWELL_USDC);
        sleeve = new MidnightSleeve(address(vault), IMidnight(MIDNIGHT));

        vm.startPrank(admin);
        vault.grantRole(vault.CURATOR_ROLE(), curator);
        vault.grantRole(vault.ALLOCATOR_ROLE(), allocator);
        vm.stopPrank();
        vm.startPrank(curator);
        vault.addSleeve(address(buffer), 200_000e6); // buffer FIRST in registry
        vault.addSleeve(address(sleeve), 100_000e6);
        sleeve.allowMarket(MARKET_ID, 50_000e6);
        sleeve.setMaxBuyAssets(25_000e6);
        sleeve.setMinYield(0.02e18); // 2%/yr floor; the top ask yields ~3.9%
        vm.stopPrank();

        deal(USDC, alice, 50_000e6);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), 50_000e6);
        vault.deposit(50_000e6, alice);
        vm.stopPrank();
        vm.prank(allocator);
        vault.allocate(address(sleeve), 30_000e6);
    }

    function _buy(uint256 units, uint256 maxAssets) internal returns (uint256 cost) {
        vm.prank(allocator);
        cost = sleeve.buy(_topAsk(), _topRatifierData(), units, maxAssets);
    }

    // ------------------------------------------------------------- real fill

    function test_Fork_Buy_RealFill_NavNeutral() public {
        uint256 cost = _buy(10_000e6, 10_000e6);

        // Paid the tick price (settlement fee = 0 at pin), rounded up, sub-par.
        assertApproxEqRel(cost, 10_000e6 * TOP_PRICE_WAD / 1e18, 0.0001e18);
        assertLt(cost, 10_000e6);
        assertEq(IMidnight(MIDNIGHT).credit(MARKET_ID, address(sleeve)), 10_000e6);
        (uint128 units, uint128 costStored,,,,,) = sleeve.book(MARKET_ID);
        assertEq(units, 10_000e6);
        assertEq(costStored, cost);

        // Amortized cost: book carries exactly what was paid => NAV unchanged.
        assertEq(sleeve.totalAssets(), 30_000e6);
        assertEq(vault.totalAssets(), 50_000e6);
    }

    function test_Fork_Buy_PartialFillsAccumulate() public {
        _buy(5_000e6, 5_000e6);
        _buy(5_000e6, 5_000e6);
        assertEq(IMidnight(MIDNIGHT).credit(MARKET_ID, address(sleeve)), 10_000e6);
        (uint128 units,,,,,,) = sleeve.book(MARKET_ID);
        assertEq(units, 10_000e6);

        // Consumption accumulates on (maker, group): a take beyond the offer's
        // remaining max_assets reverts inside Midnight (ConsumedAssets).
        vm.prank(curator);
        sleeve.setMaxBuyAssets(type(uint128).max);
        vm.prank(curator);
        sleeve.setMarketCap(MARKET_ID, type(uint128).max);
        vm.expectRevert(ConsumedAssets.selector);
        vm.prank(allocator);
        sleeve.buy(_topAsk(), _topRatifierData(), 101_000e6, type(uint256).max);
    }

    // ----------------------------------------------------------------- guards

    function test_Fork_Guard_CostAboveAllocatorMax() public {
        vm.expectRevert(abi.encodeWithSelector(MidnightSleeve.CostAboveMax.selector, 9_966_842_000, 9_900e6));
        _buy(10_000e6, 9_900e6);
    }

    function test_Fork_Guard_CostAboveCuratorMaxBuy() public {
        vm.prank(curator);
        sleeve.setMaxBuyAssets(5_000e6);
        vm.expectRevert(abi.encodeWithSelector(MidnightSleeve.CostAboveMax.selector, 9_966_842_000, 5_000e6));
        _buy(10_000e6, 10_000e6);
    }

    function test_Fork_Guard_YieldBelowCuratorFloor() public {
        vm.prank(curator);
        sleeve.setMinYield(0.1e18); // 10%/yr floor rejects the ~3.9% ask
        vm.expectRevert(abi.encodeWithSelector(MidnightSleeve.YieldTooLow.selector, 10_000e6, 9_966_842_000));
        _buy(10_000e6, 10_000e6);
    }

    function test_Fork_Guard_MarketConcentrationCap() public {
        vm.prank(curator);
        sleeve.setMarketCap(MARKET_ID, 8_000e6);
        vm.expectRevert(abi.encodeWithSelector(MidnightSleeve.MarketCapExceeded.selector, 10_000e6, 8_000e6));
        _buy(10_000e6, 10_000e6);
    }

    function test_Fork_Guard_ForgedMarketNotAllowed() public {
        // Same-looking offer, hostile market (one field off) => not allow-listed.
        Offer memory forged = _topAsk();
        forged.market.rcfThreshold += 1;
        vm.expectRevert(MidnightSleeve.MarketNotAllowed.selector);
        vm.prank(allocator);
        sleeve.buy(forged, _topRatifierData(), 10_000e6, 10_000e6);
    }

    function test_Fork_Guard_WrongSideAndRoles() public {
        vm.expectRevert(MidnightSleeve.WrongSide.selector);
        vm.prank(allocator);
        sleeve.buy(_topBid(), _topBidRatifierData(), 100e6, 100e6);

        vm.expectRevert(abi.encodeWithSelector(MidnightSleeve.NotAuthorized.selector, keccak256("ALLOCATOR_ROLE")));
        vm.prank(alice);
        sleeve.buy(_topAsk(), _topRatifierData(), 10_000e6, 10_000e6);

        vm.expectRevert(abi.encodeWithSelector(MidnightSleeve.NotAuthorized.selector, keccak256("CURATOR_ROLE")));
        vm.prank(allocator);
        sleeve.emergencySell(_topBid(), _topBidRatifierData(), 100e6, 0);
    }

    // -------------------------------------------------------- NAV accretion

    function test_Fork_AccretionLinearToParThenFlat() public {
        uint256 cost = _buy(10_000e6, 10_000e6);
        uint256 discount = 10_000e6 - cost;
        uint256 nav0 = vault.totalAssets();
        uint256 ttm = MATURITY - block.timestamp;

        vm.warp(block.timestamp + ttm / 2);
        assertApproxEqAbs(vault.totalAssets(), nav0 + discount / 2, 10); // floor dust on odd seconds

        vm.warp(MATURITY);
        assertApproxEqAbs(vault.totalAssets(), nav0 + discount, 1); // par (floor dust)
        uint256 navAtPar = vault.totalAssets();

        vm.warp(MATURITY + 30 days); // accretion stops at maturity
        assertEq(vault.totalAssets(), navAtPar);
    }

    // ------------------------------------------------------------ redemption

    /// @dev Fund the FCFS pool the realistic way: the ask maker is a borrower
    /// (debt 22,021e6 pre-fill, +units after our take) — prank-repay them.
    /// repay() touches no oracle, so warping past maturity is safe.
    function _repay(uint256 units) internal {
        address maker = TOP_MAKER;
        deal(USDC, maker, units);
        vm.startPrank(maker);
        IERC20(USDC).approve(MIDNIGHT, units);
        IMidnight(MIDNIGHT).repay(_market(), units, maker, address(0), "");
        vm.stopPrank();
    }

    function test_Fork_RedeemAtMaturity_ParExactly() public {
        _buy(10_000e6, 10_000e6);
        vm.warp(MATURITY + 1);
        _repay(10_000e6);

        uint256 navBefore = vault.totalAssets(); // fully accreted to par
        uint256 idleBefore = IERC20(USDC).balanceOf(address(sleeve));

        vm.prank(makeAddr("anyone")); // redemption is permissionless
        uint256 claimed = sleeve.redeem(MARKET_ID);

        assertEq(claimed, 10_000e6); // par, no fee, exact
        assertEq(IERC20(USDC).balanceOf(address(sleeve)), idleBefore + 10_000e6);
        assertEq(IMidnight(MIDNIGHT).credit(MARKET_ID, address(sleeve)), 0);
        (uint128 units,,,,,,) = sleeve.book(MARKET_ID);
        assertEq(units, 0);
        // Par cash replaces par book; the accrual floor dust realizes as gain.
        assertGe(vault.totalAssets(), navBefore);
        assertApproxEqAbs(vault.totalAssets(), navBefore, 1);
    }

    function test_Fork_RedeemUnderfundedPool_ClampsToFCFS() public {
        _buy(10_000e6, 10_000e6);
        vm.warp(MATURITY + 1);
        // Nobody repaid: only the pre-existing pool cash is claimable. This is
        // the honest "claim window" — FCFS, no revert, take what exists.
        uint256 claimed = sleeve.redeem(MARKET_ID);
        assertEq(claimed, POOL_AT_PIN);
        assertEq(IMidnight(MIDNIGHT).credit(MARKET_ID, address(sleeve)), 10_000e6 - POOL_AT_PIN);
        assertEq(sleeve.redeem(MARKET_ID), 0); // pool drained; second crank is a no-op
    }

    function test_Fork_LiquidAssets_CountsClaimablePreMaturity() public {
        uint256 cost = _buy(10_000e6, 10_000e6);
        uint256 idle = 30_000e6 - cost;
        // Pre-maturity: idle plus the min(credit, pool) FCFS claim, honestly.
        assertEq(sleeve.liquidAssets(), idle + POOL_AT_PIN);

        // The vault can actually pull exactly that much — no overstatement.
        vm.prank(allocator);
        uint256 back = vault.deallocate(address(sleeve), idle + POOL_AT_PIN);
        assertEq(back, idle + POOL_AT_PIN);
        // Early redemption realized (10,000 - cost) accretion pro-rata on the
        // claimed units — NAV may only step UP, never down.
        assertGe(vault.totalAssets(), 50_000e6);
        // Paper remains; nothing further is liquid; withdraw clamps, no revert.
        vm.prank(allocator);
        assertEq(vault.deallocate(address(sleeve), 1_000e6), 0);
    }

    // -------------------------------------------------------- emergency sell

    function test_Fork_EmergencySell_RealBid() public {
        uint256 cost = _buy(10_000e6, 10_000e6);
        uint256 navBefore = vault.totalAssets();

        vm.prank(curator);
        uint256 proceeds = sleeve.emergencySell(_topBid(), _topBidRatifierData(), 300e6, 298e6);

        // Sold at the bid tick (settlement fee 0 at pin).
        assertApproxEqRel(proceeds, 300e6 * BID_PRICE_WAD / 1e18, 0.0001e18);
        assertEq(IMidnight(MIDNIGHT).credit(MARKET_ID, address(sleeve)), 9_700e6);
        (uint128 units, uint128 costStored,,,,,) = sleeve.book(MARKET_ID);
        assertEq(units, 9_700e6);
        assertApproxEqAbs(costStored, cost * 9_700 / 10_000, 1);

        // P&L realized at execution: sold at the bid, carried near the ask =>
        // NAV moves by (proceeds - carried value), a small realized loss here.
        uint256 carried = cost * 300 / 10_000;
        assertApproxEqAbs(vault.totalAssets(), navBefore + proceeds - carried, 2);
    }

    function test_Fork_EmergencySell_SlippageGuard() public {
        _buy(10_000e6, 10_000e6);
        vm.expectRevert(abi.encodeWithSelector(MidnightSleeve.ProceedsBelowMin.selector, 298_964_910, uint256(300e6)));
        vm.prank(curator);
        sleeve.emergencySell(_topBid(), _topBidRatifierData(), 300e6, 300e6);
    }

    // ---------------------------------------------------- T7-style lifecycle

    function test_Fork_Integration_FullLifecycle_NavHandChecked() public {
        assertEq(vault.sleeves(0), address(buffer)); // buffer first: pulled first
        assertEq(vault.sleeves(1), address(sleeve));

        // deposit (50k in setUp) -> allocate buffer -> buy paper
        vm.prank(allocator);
        vault.allocate(address(buffer), 15_000e6);
        uint256 cost = _buy(20_000e6, 20_000e6);
        uint256 discount = 20_000e6 - cost;
        assertApproxEqAbs(vault.totalAssets(), 50_000e6, 2); // buys are NAV-neutral

        // warp to maturity: paper fully accreted, buffer earned Moonwell yield
        vm.warp(MATURITY + 1);
        uint256 bufferAssets = buffer.totalAssets();
        uint256 expectedNav = 5_000e6 + bufferAssets + (30_000e6 - cost) + 20_000e6;
        //                    ^idle     ^buffer         ^sleeve idle        ^par face
        assertApproxEqAbs(vault.totalAssets(), expectedNav, 2);
        assertGe(vault.totalAssets(), 50_000e6 + discount);

        // borrower repays; anyone cranks redemption at par
        _repay(20_000e6);
        assertEq(sleeve.redeem(MARKET_ID), 20_000e6);
        assertEq(sleeve.totalAssets(), (30_000e6 - cost) + 20_000e6); // all idle now

        // exit: everything is liquid; alice withdraws the whole NAV
        uint256 max = vault.maxWithdraw(alice);
        assertApproxEqAbs(max, vault.totalAssets(), 2);
        vm.prank(alice);
        vault.withdraw(max, alice, alice);
        assertEq(IERC20(USDC).balanceOf(alice), max);
        assertGe(max, 50_000e6 + discount); // realized at least the paper yield
        assertLe(vault.totalAssets(), 4); // dust only
    }
}
