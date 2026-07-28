// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MidnightSleeve} from "../../src/vault/MidnightSleeve.sol";
import {IMidnight, Market, Offer} from "../../src/vault/interfaces/IMidnight.sol";
import {MockMidnight} from "./MockMidnight.sol";
import {VaultTestBase} from "./VaultTestBase.sol";

/// @notice T2 (mock leg) + T3 support — MidnightSleeve accounting against the
/// faithful MockMidnight: amortized-cost accretion, lossFactor slash haircuts
/// and re-sync (not producible on the fork without a real bad-debt event),
/// pendingFee, FCFS clamping, guards, curation and role wiring.
contract MidnightSleeveTest is VaultTestBase {
    MockMidnight mid;
    MidnightSleeve mSleeve;
    Market mkt;
    bytes32 id;
    uint256 maturity;

    function setUp() public override {
        super.setUp();
        mid = new MockMidnight(IERC20(address(usdc)));
        mSleeve = new MidnightSleeve(address(vault), IMidnight(address(mid)));
        maturity = block.timestamp + 30 days;
        mkt = _mkMarket(maturity, 0);
        id = mid.touch(mkt);

        vm.startPrank(curator);
        vault.addSleeve(address(mSleeve), type(uint96).max);
        mSleeve.allowMarket(id, 100_000e6);
        mSleeve.setMaxBuyAssets(50_000e6);
        vm.stopPrank();

        _deposit(alice, 100_000e6);
        vm.prank(allocator);
        vault.allocate(address(mSleeve), 50_000e6);
    }

    function _mkMarket(uint256 maturity_, uint256 salt) internal view returns (Market memory m) {
        m.chainId = block.chainid;
        m.midnight = address(mid);
        m.loanToken = address(usdc);
        m.maturity = maturity_;
        m.rcfThreshold = salt;
    }

    function _offer(Market memory m, bool buy) internal pure returns (Offer memory o) {
        o.market = m;
        o.buy = buy;
    }

    function _buyUnits(uint256 units) internal returns (uint256 cost) {
        vm.prank(allocator);
        cost = mSleeve.buy(_offer(mkt, false), "", units, type(uint256).max);
    }

    // ------------------------------------------------------- book & accretion

    function test_Buy_RecordsLotAndStaysNavNeutral() public {
        uint256 cost = _buyUnits(10_000e6); // price 0.99
        assertEq(cost, 9_900e6);
        (uint128 units, uint128 costStored,,,,, uint256 rate) = mSleeve.book(id);
        assertEq(units, 10_000e6);
        assertEq(costStored, 9_900e6);
        assertEq(rate, uint256(100e6) * 1e18 / 30 days);
        assertEq(mSleeve.totalAssets(), 50_000e6); // idle 40,100 + book 9,900
        assertEq(vault.totalAssets(), 100_000e6);
    }

    function test_Accretion_LinearToParThenFlat() public {
        _buyUnits(10_000e6);
        skip(15 days);
        assertApproxEqAbs(mSleeve.totalAssets(), 50_050e6, 1);
        skip(15 days);
        assertApproxEqAbs(mSleeve.totalAssets(), 50_100e6, 1);
        skip(10 days); // past maturity: accretion stops at par
        assertApproxEqAbs(mSleeve.totalAssets(), 50_100e6, 1);
    }

    function test_Accretion_TwoLotsAggregateIntoOneRate() public {
        _buyUnits(10_000e6); // 30d lot
        skip(10 days);
        _buyUnits(10_000e6); // 20d lot, same market: rates aggregate
        uint256 nav0 = mSleeve.totalAssets(); // 50,000 + 10d accretion of lot 1
        assertApproxEqAbs(nav0, 50_000e6 + uint256(100e6) / 3, 1);
        skip(20 days); // both lots at par
        assertApproxEqAbs(mSleeve.totalAssets(), 30_200e6 + 20_000e6, 1);
    }

    // ----------------------------------------------------------------- guards

    function test_Guard_AbovePar() public {
        mid.setPrice(1.01e18);
        vm.expectRevert(abi.encodeWithSelector(MidnightSleeve.AbovePar.selector, 10_100e6, 10_000e6));
        vm.prank(allocator);
        mSleeve.buy(_offer(mkt, false), "", 10_000e6, type(uint256).max);
    }

    function test_Guard_MinYieldFloor() public {
        // price 0.99 over 30d ~= 12.3%/yr simple: 12% floor passes, 13% rejects
        vm.prank(curator);
        mSleeve.setMinYield(0.13e18);
        vm.expectRevert(abi.encodeWithSelector(MidnightSleeve.YieldTooLow.selector, 10_000e6, 9_900e6));
        vm.prank(allocator);
        mSleeve.buy(_offer(mkt, false), "", 10_000e6, type(uint256).max);

        vm.prank(curator);
        mSleeve.setMinYield(0.12e18);
        _buyUnits(10_000e6);
    }

    function test_Guard_MaturedMarketAndZeroUnits() public {
        vm.expectRevert(MidnightSleeve.ZeroUnits.selector);
        vm.prank(allocator);
        mSleeve.buy(_offer(mkt, false), "", 0, type(uint256).max);

        skip(31 days);
        vm.expectRevert(MidnightSleeve.MarketMatured.selector);
        vm.prank(allocator);
        mSleeve.buy(_offer(mkt, false), "", 10_000e6, type(uint256).max);
    }

    // ----------------------------------------------- lossFactor & pendingFee

    function test_Slash_HaircutsNavLazily() public {
        _buyUnits(10_000e6);
        mid.setLoss(id, 0.1e18); // 10% socialized bad debt
        // book 9,900 * (9,000 effective / 10,000 face) = 8,910 — the haircut
        // shows up in the NEXT NAV read, with no sleeve state change needed.
        assertEq(mSleeve.totalAssets(), 40_100e6 + 8_910e6);
        assertEq(vault.totalAssets(), 99_010e6);
    }

    function test_Slash_BuyAfterSlashResyncsBook() public {
        _buyUnits(10_000e6);
        mid.setLoss(id, 0.1e18);
        uint256 navBefore = vault.totalAssets(); // 99,010e6
        _buyUnits(10_000e6); // take() settles the slash; sleeve re-syncs face
        (uint128 units, uint128 costStored,,,,,) = mSleeve.book(id);
        assertEq(units, 19_000e6); // 9,000 survived + 10,000 new
        assertEq(costStored, 8_910e6 + 9_900e6);
        assertEq(vault.totalAssets(), navBefore); // buys stay NAV-neutral
    }

    function test_Slash_RedeemReconcilesAndRealizes() public {
        _buyUnits(10_000e6);
        mid.setLoss(id, 0.1e18);
        usdc.mint(address(mid), 9_000e6);
        mid.fund(id, 9_000e6);
        skip(30 days);
        assertEq(mSleeve.redeem(id), 9_000e6); // slashed face, at par
        (uint128 units,,,,,,) = mSleeve.book(id);
        assertEq(units, 0);
        assertEq(mSleeve.totalAssets(), 40_100e6 + 9_000e6); // 900e6 loss real
    }

    function test_PendingFee_ReducesEffectiveValue() public {
        _buyUnits(10_000e6);
        mid.setPendingFee(id, address(mSleeve), 50e6);
        // effective credit 9,950: book 9,900 * 9,950/10,000 = 9,850.5 (floor)
        assertEq(mSleeve.totalAssets(), 40_100e6 + 9_850_500_000);
    }

    // ------------------------------------------------- liquidity & honesty

    function test_LiquidAssets_ClampsToPoolAndBookValue() public {
        _buyUnits(10_000e6);
        assertEq(mSleeve.liquidAssets(), 40_100e6); // pool empty: idle only
        usdc.mint(address(mid), 10_000e6);
        mid.fund(id, 3_000e6);
        assertEq(mSleeve.liquidAssets(), 40_100e6 + 3_000e6); // pool-bound
        mid.fund(id, 7_000e6);
        // claimable par (10,000) exceeds carried value (9,900): clamp to book
        // so vault-wide liquidAssets never exceeds totalAssets.
        assertEq(mSleeve.liquidAssets(), 40_100e6 + 9_900e6);
        assertLe(vault.liquidAssets(), vault.totalAssets());
    }

    function test_VaultWithdraw_PullsClaimableNeverSellsPaper() public {
        _buyUnits(10_000e6);
        usdc.mint(address(mid), 3_000e6);
        mid.fund(id, 3_000e6);
        vm.prank(allocator);
        assertEq(vault.deallocate(address(mSleeve), 43_100e6), 43_100e6); // idle+pool
        assertEq(mid.credit(id, address(mSleeve)), 7_000e6); // paper kept
        vm.prank(allocator);
        assertEq(vault.deallocate(address(mSleeve), 1_000e6), 0); // clamp, no revert
    }

    function test_Redeem_Permissionless_EarlyPullRealizesGain() public {
        _buyUnits(10_000e6);
        usdc.mint(address(mid), 10_000e6);
        mid.fund(id, 10_000e6);
        vm.prank(bob); // anyone can crank
        assertEq(mSleeve.redeem(id), 10_000e6);
        assertEq(mSleeve.totalAssets(), 50_100e6); // accretion realized early
        assertEq(vault.totalAssets(), 100_100e6); // NAV stepped UP, never down
    }

    // ---------------------------------------------------------- emergency

    function test_EmergencySell_RealizesPnlAtExecution() public {
        _buyUnits(10_000e6);
        mid.setPrice(0.98e18); // bid side is lower than our 0.99 carry
        vm.prank(curator);
        uint256 proceeds = mSleeve.emergencySell(_offer(mkt, true), "", 3_000e6, 2_940e6);
        assertEq(proceeds, 2_940e6);
        (uint128 units, uint128 costStored,,,,,) = mSleeve.book(id);
        assertEq(units, 7_000e6);
        assertEq(costStored, 6_930e6);
        // realized 30e6 loss vs carry: NAV moves at execution, honestly.
        assertEq(mSleeve.totalAssets(), 40_100e6 + 2_940e6 + 6_930e6);

        vm.expectRevert(abi.encodeWithSelector(MidnightSleeve.ProceedsBelowMin.selector, 980e6, 1_000e6));
        vm.prank(curator);
        mSleeve.emergencySell(_offer(mkt, true), "", 1_000e6, 1_000e6);
    }

    // ------------------------------------------------------ curation & roles

    function test_Curation_AllowRules() public {
        vm.startPrank(curator);
        vm.expectRevert(abi.encodeWithSelector(MidnightSleeve.MarketAlreadyAllowed.selector, id));
        mSleeve.allowMarket(id, 1);

        bytes32 wrongAsset = mid.touch(_mkMarketWrongAsset());
        vm.expectRevert(MidnightSleeve.AssetMismatch.selector);
        mSleeve.allowMarket(wrongAsset, 1);

        bytes32 matured = mid.touch(_mkMarket(block.timestamp, 99));
        vm.expectRevert(MidnightSleeve.MarketMatured.selector);
        mSleeve.allowMarket(matured, 1);

        for (uint256 i = 1; i < 8; ++i) {
            mSleeve.allowMarket(mid.touch(_mkMarket(maturity, i)), 1);
        }
        bytes32 ninth = mid.touch(_mkMarket(maturity, 8));
        vm.expectRevert(MidnightSleeve.TooManyMarkets.selector);
        mSleeve.allowMarket(ninth, 1);
        vm.stopPrank();
    }

    function test_Curation_RemoveMarket() public {
        _buyUnits(10_000e6);
        vm.expectRevert(abi.encodeWithSelector(MidnightSleeve.MarketNotEmpty.selector, id));
        vm.prank(curator);
        mSleeve.removeMarket(id);

        usdc.mint(address(mid), 10_000e6);
        mid.fund(id, 10_000e6);
        mSleeve.redeem(id);
        vm.prank(curator);
        mSleeve.removeMarket(id);
        assertEq(mSleeve.marketCount(), 0);

        vm.expectRevert(MidnightSleeve.MarketNotAllowed.selector); // binding cleared
        vm.prank(allocator);
        mSleeve.buy(_offer(mkt, false), "", 1e6, type(uint256).max);
    }

    function test_Roles_ReadFromVaultAccessControl() public {
        bytes32 allocatorRole = keccak256("ALLOCATOR_ROLE");
        bytes32 curatorRole = keccak256("CURATOR_ROLE");

        vm.expectRevert(abi.encodeWithSelector(MidnightSleeve.NotAuthorized.selector, allocatorRole));
        vm.prank(curator);
        mSleeve.buy(_offer(mkt, false), "", 1e6, 1e6);

        vm.expectRevert(abi.encodeWithSelector(MidnightSleeve.NotAuthorized.selector, curatorRole));
        vm.prank(allocator);
        mSleeve.setMinYield(0);

        vm.expectRevert(MidnightSleeve.NotVault.selector);
        vm.prank(allocator);
        mSleeve.withdraw(1);

        // Vault roles are the single source of truth: revoke and it's gone.
        vm.prank(admin);
        vault.revokeRole(allocatorRole, allocator);
        vm.expectRevert(abi.encodeWithSelector(MidnightSleeve.NotAuthorized.selector, allocatorRole));
        vm.prank(allocator);
        mSleeve.buy(_offer(mkt, false), "", 1e6, 1e6);
    }

    function _mkMarketWrongAsset() internal view returns (Market memory m) {
        m = _mkMarket(maturity, 7_777);
        m.loanToken = address(0xBEEF);
    }
}
