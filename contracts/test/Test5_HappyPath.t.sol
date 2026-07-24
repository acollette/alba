// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {TokenMock} from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import {IERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import {ISwapVM} from "swap-vm/src/interfaces/ISwapVM.sol";
import {TakerTraitsLib} from "swap-vm/src/libs/TakerTraits.sol";

import {TermRouter} from "../src/TermRouter.sol";
import {CollateralEscrow} from "../src/CollateralEscrow.sol";
import {ChronosProgramBuilder} from "../src/lib/ProgramBuilder.sol";

/// @notice Test 5 — full happy path with a manual executor:
/// publish 300k facility → draw 100k → draw 50k → warp to maturity →
/// executor settles draw 1 (repayment lands with the LENDER, zero signatures) →
/// collateral released pro-rata (draw 1's lock only; draw 2 stays locked).
contract Test5_HappyPath is Test {
    IAqua constant AQUA = IAqua(0x499943E74FB0cE105688beeE8Ef2ABec5D936d31);
    address constant WETH = 0x4200000000000000000000000000000000000006;
    uint256 constant FORK_BLOCK = 49_062_000;

    uint256 constant FACILITY = 300_000e6;
    uint256 constant RATE_BPS = 820; // 8.20% simple annual
    uint256 constant TERM = 90 days;

    uint256 constant DRAW1 = 100_000e6;
    uint256 constant DRAW2 = 50_000e6;
    // 130% collateralization at 100k USDC per cbBTC-mock unit price
    uint256 constant COLLAT1 = 1.3e8;
    uint256 constant COLLAT2 = 0.65e8;

    TermRouter router;
    CollateralEscrow escrow;
    TokenMock usdc;
    TokenMock cbbtc;

    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");
    address executor = makeAddr("executor"); // manual stand-in for AxelarSettlementExecutor

    ISwapVM.Order facilityOrder;
    bytes32 facilityHash;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_MAINNET_RPC", string("https://mainnet.base.org")), FORK_BLOCK);
        router = new TermRouter(address(AQUA), WETH, address(this));
        escrow = new CollateralEscrow(executor, router, makeAddr("feeSink"));
        usdc = new TokenMock("Mock USDC", "USDC");
        cbbtc = new TokenMock("Mock cbBTC", "CBBTC");

        // Lender publishes the facility: funds never leave the wallet, only approval + ship
        usdc.mint(lender, FACILITY);
        vm.prank(lender);
        usdc.approve(address(AQUA), type(uint256).max);

        bytes memory strategy;
        address[] memory tokens;
        uint256[] memory amounts;
        (facilityOrder, strategy, tokens, amounts) = router.buildFacilityLeg(
            ChronosProgramBuilder.PullLegTerms({
                maker: lender,
                counterToken: address(cbbtc),
                pullToken: address(usdc),
                amount: FACILITY,
                salt: 1
            })
        );
        vm.prank(lender);
        facilityHash = AQUA.ship(address(router), strategy, tokens, amounts);

        cbbtc.mint(borrower, COLLAT1 + COLLAT2);
        vm.prank(borrower);
        cbbtc.approve(address(escrow), type(uint256).max);
        vm.prank(borrower);
        usdc.approve(address(AQUA), type(uint256).max);
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

    /// @dev One draw: lock collateral → draw USDC from the standing facility order →
    /// arm the maturity leg (borrower ships repayment pull-rights; no funds move)
    function _draw(uint256 drawId, uint256 drawAmount, uint256 collateral, uint40 maturity)
        internal
        returns (ISwapVM.Order memory maturityOrder, bytes32 maturityHash, uint256 repayment)
    {
        vm.prank(borrower);
        escrow.lockFor(bytes32(drawId), IERC20(address(cbbtc)), collateral);

        vm.prank(borrower);
        router.swap(facilityOrder, address(cbbtc), address(usdc), drawAmount, _pullData(borrower, address(0)));

        repayment = router.repaymentAmount(drawAmount, RATE_BPS, TERM);
        bytes memory strategy;
        address[] memory tokens;
        uint256[] memory amounts;
        (maturityOrder, strategy, tokens, amounts) = router.buildMaturityLeg(
            ChronosProgramBuilder.PullLegTerms({
                maker: borrower,
                counterToken: address(cbbtc),
                pullToken: address(usdc),
                amount: repayment,
                salt: drawId
            }),
            maturity,
            executor
        );
        vm.prank(borrower);
        maturityHash = AQUA.ship(address(router), strategy, tokens, amounts);
    }

    function test_FullHappyPath() public {
        uint40 maturity1 = uint40(block.timestamp + TERM);

        // Two draws = the revolver exists
        (ISwapVM.Order memory maturity1Order,, uint256 repayment1) = _draw(1, DRAW1, COLLAT1, maturity1);
        _draw(2, DRAW2, COLLAT2, uint40(block.timestamp + 1 hours + TERM));

        assertEq(usdc.balanceOf(borrower), DRAW1 + DRAW2, "borrower did not receive both draws");
        assertEq(router.coveredAmount(lender, facilityHash), DRAW1 + DRAW2, "facility accounting wrong");
        assertEq(cbbtc.balanceOf(address(escrow)), COLLAT1 + COLLAT2, "collateral not in escrow");
        assertEq(repayment1, DRAW1 + (DRAW1 * RATE_BPS * TERM) / (10_000 * 365 days), "zero-coupon math");

        // The alarm rings: warp to maturity, executor settles draw 1 — repayment goes
        // STRAIGHT to the lender via Aqua pull; no signature exists anywhere
        vm.warp(maturity1);
        vm.prank(executor);
        (uint256 aIn, uint256 aOut,) =
            router.swap(maturity1Order, address(cbbtc), address(usdc), repayment1, _pullData(executor, lender));

        assertEq(aIn, 0, "settlement must be zero-in");
        assertEq(aOut, repayment1);
        // lender wallet = undrawn commitment (funds never left until drawn) + repayment
        assertEq(usdc.balanceOf(lender), FACILITY - DRAW1 - DRAW2 + repayment1, "repayment did not land with lender");

        // Executor releases draw 1 collateral pro-rata; draw 2 stays locked
        vm.prank(executor);
        escrow.release(bytes32(uint256(1)));

        assertEq(cbbtc.balanceOf(borrower), COLLAT1, "draw-1 collateral not returned");
        assertEq(cbbtc.balanceOf(address(escrow)), COLLAT2, "draw-2 collateral must remain locked");

        // Facility remains usable: borrower still has 150k of capacity
        vm.prank(borrower);
        (, uint256 aOut3,) =
            router.swap(facilityOrder, address(cbbtc), address(usdc), 150_000e6, _pullData(borrower, address(0)));
        assertEq(aOut3, 150_000e6, "remaining capacity not drawable");
        assertEq(router.coveredAmount(lender, facilityHash), FACILITY, "facility should now be fully drawn");
    }

    function test_Release_OnlyExecutor() public {
        vm.prank(borrower);
        escrow.lockFor(bytes32(uint256(9)), IERC20(address(cbbtc)), 1e8);

        vm.expectRevert(abi.encodeWithSelector(CollateralEscrow.OnlyExecutor.selector, borrower));
        vm.prank(borrower);
        escrow.release(bytes32(uint256(9)));
    }
}
