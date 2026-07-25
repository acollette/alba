// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {TokenCustomDecimalsMock} from "@1inch/solidity-utils/contracts/mocks/TokenCustomDecimalsMock.sol";
import {IERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import {ISwapVM} from "swap-vm/src/interfaces/ISwapVM.sol";
import {TakerTraitsLib} from "swap-vm/src/libs/TakerTraits.sol";

import {TermRouter} from "../src/TermRouter.sol";
import {AlbaOrderBuilder} from "../src/AlbaOrderBuilder.sol";
import {MockV3Aggregator} from "../src/mocks/MockV3Aggregator.sol";
import {CollateralEscrow} from "../src/CollateralEscrow.sol";
import {AlbaProgramBuilder} from "../src/lib/ProgramBuilder.sol";

/// @notice Test 8 — continuous margining: permissionless `liquidate` with the three-tier
/// waterfall. Healthy draws are untouchable; a breached draw is first CURED from the
/// borrower's Aqua-authorized USDC (full → early close, zero penalty; partial → health
/// restored, draw lives), and only a drained borrower meets the auction. Cures reconcile
/// against the maturity settlement.
contract Test8_ContinuousLiquidation is Test {
    IAqua constant AQUA = IAqua(0x499943E74FB0cE105688beeE8Ef2ABec5D936d31);
    address constant WETH = 0x4200000000000000000000000000000000000006;
    uint256 constant FORK_BLOCK = 49_062_000;

    uint256 constant FACILITY = 300_000e6;
    uint256 constant RATE_BPS = 460;
    uint256 constant TERM = 90 days;
    uint256 constant DRAW1 = 100_000e6;
    uint256 constant COLLAT1 = 1.3e8; // 130% initial at 100k oracle
    bytes32 constant FACILITY_ID = bytes32(uint256(0xFAC));
    bytes32 constant DRAW_ID = bytes32(uint256(1));

    TermRouter router;
    AlbaOrderBuilder builder;
    MockV3Aggregator oracle;
    CollateralEscrow escrow;
    TokenCustomDecimalsMock usdc;
    TokenCustomDecimalsMock cbbtc;

    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");
    address executor = makeAddr("executor");
    address stranger = makeAddr("stranger");
    address feeSink = makeAddr("feeSink");

    ISwapVM.Order facilityOrder;
    ISwapVM.Order maturityOrder;
    uint256 repayment;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_MAINNET_RPC", string("https://mainnet.base.org")), FORK_BLOCK);
        router = new TermRouter(address(AQUA), WETH, address(this));
        builder = new AlbaOrderBuilder(address(AQUA));
        oracle = new MockV3Aggregator(8, 100_000e8);
        escrow = new CollateralEscrow(executor, router, builder, feeSink);
        usdc = new TokenCustomDecimalsMock("Mock USDC", "USDC", 0, 6);
        cbbtc = new TokenCustomDecimalsMock("Mock cbBTC", "CBBTC", 0, 8);

        usdc.mint(lender, FACILITY);
        vm.startPrank(lender);
        usdc.approve(address(AQUA), type(uint256).max);
        bytes memory strategy;
        address[] memory tokens;
        uint256[] memory amounts;
        (facilityOrder, strategy, tokens, amounts) = builder.buildFacilityLeg(
            AlbaProgramBuilder.PullLegTerms({
                maker: lender,
                counterToken: address(cbbtc),
                pullToken: address(usdc),
                amount: FACILITY * 4, // gross Aqua ceiling; the escrow meters the revolving capacity
                salt: 1
            }),
            address(escrow)
        );
        AQUA.ship(address(router), strategy, tokens, amounts);
        escrow.registerFacility(
            FACILITY_ID,
            facilityOrder,
            CollateralEscrow.FacilityParams({
                borrower: borrower,
                loanToken: IERC20(address(usdc)),
                collateralToken: IERC20(address(cbbtc)),
                oracle: oracle,
                collateralRatioBps: 13_000,
                maintenanceRatioBps: 11_500,
                rateBps: RATE_BPS,
                termSeconds: uint40(TERM),
                auctionDuration: 3600,
                auctionDecay: 0.99994e18,
                commitment: FACILITY,
                availabilityEnd: uint40(block.timestamp + 364 days)
            })
        );
        vm.stopPrank();

        cbbtc.mint(borrower, COLLAT1);
        repayment = builder.repaymentAmount(DRAW1, RATE_BPS, TERM);

        vm.startPrank(borrower);
        cbbtc.approve(address(escrow), type(uint256).max);
        usdc.approve(address(AQUA), type(uint256).max);
        escrow.draw(FACILITY_ID, DRAW_ID, DRAW1, 0);

        // Opt into no-penalty cures: ship the deterministic cure leg the escrow derives
        (, bytes memory cStrategy, address[] memory cTokens, uint256[] memory cAmounts) = escrow.cureOrder(DRAW_ID);
        AQUA.ship(address(router), cStrategy, cTokens, cAmounts);

        // Ship the maturity leg too (for the reconciliation test)
        (,,,,,,, uint40 maturity,) = escrow.draws(DRAW_ID);
        bytes memory mStrategy;
        (maturityOrder, mStrategy, cTokens, cAmounts) = builder.buildMaturityLeg(
            AlbaProgramBuilder.PullLegTerms({
                maker: borrower,
                counterToken: address(cbbtc),
                pullToken: address(usdc),
                amount: repayment,
                salt: 1
            }),
            maturity,
            executor
        );
        AQUA.ship(address(router), mStrategy, cTokens, cAmounts);
        vm.stopPrank();
    }

    function _crash() internal {
        // 100k → 80k: collateral value 104k < 115% × ~100k debt — breached
        oracle.setAnswer(80_000e8);
    }

    function test_ExtraCollateral_LowersLiquidationPrice() public {
        // Second draw posted with voluntary over-collateralization: +0.5 cbBTC
        cbbtc.mint(borrower, 1.8e8);
        vm.prank(borrower);
        escrow.draw(FACILITY_ID, bytes32(uint256(2)), 50_000e6, 0.5e8);
        (,,, uint256 total,,,,,) = escrow.draws(bytes32(uint256(2)));
        assertEq(total, 0.65e8 + 0.5e8, "required initial margin + voluntary extra");

        // A crash that breaches the minimum-margin draw leaves the padded one healthy
        oracle.setAnswer(80_000e8);
        (bool healthy1,,) = escrow.isHealthy(DRAW_ID);
        (bool healthy2,,) = escrow.isHealthy(bytes32(uint256(2)));
        assertFalse(healthy1, "minimum-margin draw breaches at 80k");
        assertTrue(healthy2, "over-collateralized draw survives the same crash");
    }

    function test_TopUp_PreventsLiquidation() public {
        // Borrower sees trouble coming and tops up BEFORE the crash
        cbbtc.mint(borrower, 0.4e8);
        vm.prank(borrower);
        escrow.topUpCollateral(DRAW_ID, 0.4e8);

        oracle.setAnswer(80_000e8); // would breach the original 1.3 lot: 104k < 115k
        (bool healthy, uint256 value,) = escrow.isHealthy(DRAW_ID);
        assertTrue(healthy, "1.7 cbBTC x 80k = 136k covers 115% x 100k");
        assertEq(value, 136_000e6);
        vm.expectRevert(); // DrawHealthy — liquidation cannot touch a topped-up position
        escrow.liquidate(DRAW_ID);
    }

    function test_WithdrawCollateral_OnlyDownToInitialRatio() public {
        cbbtc.mint(borrower, 0.5e8);
        vm.prank(borrower);
        escrow.topUpCollateral(DRAW_ID, 0.5e8); // 1.8 total; initial requirement 1.3

        vm.prank(borrower);
        escrow.withdrawCollateral(DRAW_ID, 0.5e8); // back to exactly the initial margin
        (,,, uint256 total,,,,,) = escrow.draws(DRAW_ID);
        assertEq(total, 1.3e8);

        // One more sat below the initial ratio must fail — withdrawals are gated at 130%,
        // not at the 115% liquidation threshold
        vm.expectRevert();
        vm.prank(borrower);
        escrow.withdrawCollateral(DRAW_ID, 0.1e8);
    }

    function test_Liquidate_HealthyReverts() public {
        (bool healthy, uint256 value, uint256 required) = escrow.isHealthy(DRAW_ID);
        assertTrue(healthy);
        vm.expectRevert(abi.encodeWithSelector(CollateralEscrow.DrawHealthy.selector, DRAW_ID, value, required));
        escrow.liquidate(DRAW_ID);
    }

    function test_Crash_FullCure_ZeroPenalty() public {
        _crash();
        uint256 debt = escrow.debtOf(DRAW_ID);
        uint256 lenderBefore = usdc.balanceOf(lender);
        uint256 collatBefore = cbbtc.balanceOf(borrower);

        vm.prank(stranger); // permissionless
        CollateralEscrow.DrawState outcome = escrow.liquidate(DRAW_ID);

        assertEq(uint8(outcome), uint8(CollateralEscrow.DrawState.RELEASED), "full cure should close the draw");
        assertEq(usdc.balanceOf(lender) - lenderBefore, debt, "lender must receive the accrued debt");
        assertEq(cbbtc.balanceOf(borrower) - collatBefore, COLLAT1, "collateral must come home, zero penalty");
        assertEq(cbbtc.balanceOf(address(escrow)), 0, "no collateral left behind");
    }

    function test_Crash_PartialCure_DrawLivesOn() public {
        // Borrower keeps only 30k liquid
        vm.prank(borrower);
        usdc.transfer(makeAddr("elsewhere"), DRAW1 - 30_000e6);

        _crash();
        uint256 lenderBefore = usdc.balanceOf(lender);

        CollateralEscrow.DrawState outcome = escrow.liquidate(DRAW_ID);

        assertEq(uint8(outcome), uint8(CollateralEscrow.DrawState.LOCKED), "partial cure should keep the draw alive");
        assertEq(usdc.balanceOf(lender) - lenderBefore, 30_000e6, "cure pays the lender down");
        assertEq(escrow.debtOf(DRAW_ID), DRAW1 - 30_000e6, "debt reduced by the cure");
        (bool healthy,,) = escrow.isHealthy(DRAW_ID);
        assertTrue(healthy, "health restored at 104k value vs 115% x 70k");
        assertEq(cbbtc.balanceOf(address(escrow)), COLLAT1, "no collateral sold");
    }

    function test_PartialCure_MaturityReconciliation() public {
        vm.prank(borrower);
        usdc.transfer(makeAddr("elsewhere"), DRAW1 - 30_000e6);
        _crash();
        escrow.liquidate(DRAW_ID); // cures 30k

        uint256 outstanding = escrow.maturityOutstanding(DRAW_ID);
        assertEq(outstanding, repayment - 30_000e6, "maturity settlement must shrink by the cure");

        // Fund the borrower for the reduced settlement and run the manual executor
        usdc.mint(borrower, outstanding);
        (,,,,,,, uint40 maturity,) = escrow.draws(DRAW_ID);
        vm.warp(maturity);
        uint256 lenderBefore = usdc.balanceOf(lender);
        vm.prank(executor);
        router.swap(maturityOrder, address(cbbtc), address(usdc), outstanding, _pullData(executor, lender));
        vm.prank(executor);
        escrow.release(DRAW_ID);

        assertEq(usdc.balanceOf(lender) - lenderBefore, outstanding, "lender receives K minus cures");
        assertEq(cbbtc.balanceOf(borrower), COLLAT1, "collateral home after settlement");
    }

    function test_Crash_Drained_AuctionArmed() public {
        vm.startPrank(borrower);
        usdc.transfer(makeAddr("elsewhere"), usdc.balanceOf(borrower));
        vm.stopPrank();

        _crash();
        uint256 debt = escrow.debtOf(DRAW_ID);

        vm.prank(stranger); // permissionless
        CollateralEscrow.DrawState outcome = escrow.liquidate(DRAW_ID);

        assertEq(uint8(outcome), uint8(CollateralEscrow.DrawState.AUCTIONING), "drained borrower meets the auction");
        (, address auctionLender,, uint256 auctionDebt, uint256 fee) = escrow.auctions(DRAW_ID);
        assertEq(auctionDebt, debt, "auction targets the uncured debt");
        assertEq(auctionLender, lender);
        assertEq(fee, (debt * escrow.LIQ_FEE_BPS()) / 10_000);
        assertEq(cbbtc.balanceOf(address(escrow)), COLLAT1, "collateral stays until fills");
    }

    function _pullData(address taker, address to) internal pure returns (bytes memory) {
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: taker,
                isExactIn: false,
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: false,
                useTransferFromAndAquaPush: false,
                threshold: "",
                to: to,
                deadline: 0,
                hasPreTransferInCallback: false,
                hasPreTransferOutCallback: false,
                preTransferInHookData: "",
                postTransferInHookData: "",
                preTransferOutHookData: "",
                postTransferOutHookData: "",
                preTransferInCallbackData: "",
                preTransferOutCallbackData: "",
                instructionsArgs: "",
                signature: ""
            })
        );
    }
}
