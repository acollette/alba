// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {TokenMock} from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import {ISwapVM} from "swap-vm/src/interfaces/ISwapVM.sol";
import {TakerTraitsLib} from "swap-vm/src/libs/TakerTraits.sol";

import {TermRouter} from "../src/TermRouter.sol";
import {AlbaOrderBuilder} from "../src/AlbaOrderBuilder.sol";
import {AlbaOpcodes} from "../src/opcodes/AlbaOpcodes.sol";
import {AlbaProgramBuilder} from "../src/lib/ProgramBuilder.sol";

/// @notice Tests 2-4 (OPCODES.md matrix): _notBefore, _onlyTaker, _stopWhenCovered on
/// zero-in pull legs, including static-context discipline (quote never mutates storage).
contract Test2to4_Opcodes is Test {
    IAqua constant AQUA = IAqua(0x499943E74FB0cE105688beeE8Ef2ABec5D936d31);
    address constant WETH = 0x4200000000000000000000000000000000000006;
    uint256 constant FORK_BLOCK = 49_062_000;

    uint256 constant FACILITY_USDC = 300_000e6;
    uint256 constant REPAYMENT_USDC = 102_022e6;

    TermRouter router;
    AlbaOrderBuilder builder;
    TokenMock usdc;
    TokenMock cbbtc;

    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");
    address executor = makeAddr("executor");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_MAINNET_RPC", string("https://mainnet.base.org")), FORK_BLOCK);
        router = new TermRouter(address(AQUA), WETH, address(this));
        builder = new AlbaOrderBuilder(address(AQUA));
        usdc = new TokenMock("Mock USDC", "USDC");
        cbbtc = new TokenMock("Mock cbBTC", "CBBTC");

        usdc.mint(lender, FACILITY_USDC);
        vm.prank(lender);
        usdc.approve(address(AQUA), type(uint256).max);

        usdc.mint(borrower, REPAYMENT_USDC);
        vm.prank(borrower);
        usdc.approve(address(AQUA), type(uint256).max);
    }

    // ---------- helpers ----------

    function _facilityTerms(address maker, uint256 amount)
        internal
        view
        returns (AlbaProgramBuilder.PullLegTerms memory)
    {
        return AlbaProgramBuilder.PullLegTerms({
            maker: maker,
            counterToken: address(cbbtc),
            pullToken: address(usdc),
            amount: amount,
            salt: 42
        });
    }

    /// @dev Zero-in exact-out pull: taker specifies the pullToken amount, pays nothing via the VM
    function _pullData(address taker) internal pure returns (bytes memory) {
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: taker,
                isExactIn: false,
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: false,
                useTransferFromAndAquaPush: false,
                threshold: "",
                to: address(0),
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

    function _pullAs(address taker, ISwapVM.Order memory order, uint256 amount)
        internal
        returns (uint256 aIn, uint256 aOut)
    {
        vm.prank(taker);
        (aIn, aOut,) = router.swap(order, address(cbbtc), address(usdc), amount, _pullData(taker));
    }

    function _shipFacilityLeg() internal returns (ISwapVM.Order memory order, bytes32 orderHash) {
        bytes memory strategy;
        address[] memory tokens;
        uint256[] memory amounts;
        (order, strategy, tokens, amounts) = builder.buildFacilityLeg(_facilityTerms(lender, FACILITY_USDC), borrower);
        vm.prank(lender);
        orderHash = AQUA.ship(address(router), strategy, tokens, amounts);
    }

    function _shipMaturityLeg(uint40 maturity) internal returns (ISwapVM.Order memory order, bytes32 orderHash) {
        bytes memory strategy;
        address[] memory tokens;
        uint256[] memory amounts;
        (order, strategy, tokens, amounts) =
            builder.buildMaturityLeg(_facilityTerms(borrower, REPAYMENT_USDC), maturity, executor);
        vm.prank(borrower);
        orderHash = AQUA.ship(address(router), strategy, tokens, amounts);
    }

    // ---------- Test 2: _notBefore ----------

    function test_NotBefore_RevertsBeforeT_SwapAndQuote() public {
        uint40 maturity = uint40(block.timestamp + 90 days);
        (ISwapVM.Order memory order,) = _shipMaturityLeg(maturity);

        vm.expectRevert(abi.encodeWithSelector(AlbaOpcodes.TooEarly.selector, maturity, block.timestamp));
        vm.prank(executor);
        router.swap(order, address(cbbtc), address(usdc), REPAYMENT_USDC, _pullData(executor));

        // quote (static context) must ALSO revert before maturity
        vm.expectRevert(abi.encodeWithSelector(AlbaOpcodes.TooEarly.selector, maturity, block.timestamp));
        vm.prank(executor);
        router.quote(order, address(cbbtc), address(usdc), REPAYMENT_USDC, _pullData(executor));
    }

    function test_NotBefore_PassesAtT_AndSettlesRepayment() public {
        uint40 maturity = uint40(block.timestamp + 90 days);
        (ISwapVM.Order memory order,) = _shipMaturityLeg(maturity);

        vm.warp(maturity); // exactly at T
        (uint256 aIn, uint256 aOut) = _pullAs(executor, order, REPAYMENT_USDC);

        assertEq(aIn, 0, "pull must be zero-in: no signature, no counter-payment");
        assertEq(aOut, REPAYMENT_USDC);
        assertEq(usdc.balanceOf(executor), REPAYMENT_USDC, "repayment not received");
    }

    // ---------- Test 3: _onlyTaker ----------

    function test_OnlyTaker_RevertsForStranger_PassesForExecutor() public {
        uint40 maturity = uint40(block.timestamp + 1);
        (ISwapVM.Order memory order,) = _shipMaturityLeg(maturity);
        vm.warp(maturity);

        vm.expectRevert(abi.encodeWithSelector(AlbaOpcodes.UnauthorizedTaker.selector, stranger, executor));
        vm.prank(stranger);
        router.swap(order, address(cbbtc), address(usdc), REPAYMENT_USDC, _pullData(stranger));

        (, uint256 aOut) = _pullAs(executor, order, REPAYMENT_USDC);
        assertEq(aOut, REPAYMENT_USDC, "executor settlement failed");
    }

    function test_OnlyTaker_StaticQuoteOpenToAnyone() public {
        uint40 maturity = uint40(block.timestamp + 1);
        (ISwapVM.Order memory order,) = _shipMaturityLeg(maturity);
        vm.warp(maturity);

        vm.prank(stranger);
        (uint256 qIn, uint256 qOut,) =
            router.quote(order, address(cbbtc), address(usdc), REPAYMENT_USDC, _pullData(stranger));
        assertEq(qIn, 0);
        assertEq(qOut, REPAYMENT_USDC, "stranger must be able to quote the settlement");
    }

    function test_MaturityLeg_SecondSettlementReverts() public {
        uint40 maturity = uint40(block.timestamp + 1);
        (ISwapVM.Order memory order, bytes32 orderHash) = _shipMaturityLeg(maturity);
        vm.warp(maturity);

        _pullAs(executor, order, REPAYMENT_USDC);

        vm.expectRevert(abi.encodeWithSelector(AlbaOpcodes.OrderCovered.selector, orderHash));
        vm.prank(executor);
        router.swap(order, address(cbbtc), address(usdc), 1e6, _pullData(executor));
    }

    // ---------- Test 4: _stopWhenCovered ----------

    function test_StopWhenCovered_PartialDrawsSumCorrectly() public {
        (ISwapVM.Order memory order, bytes32 orderHash) = _shipFacilityLeg();

        (uint256 in1, uint256 out1) = _pullAs(borrower, order, 100_000e6);
        (uint256 in2, uint256 out2) = _pullAs(borrower, order, 50_000e6);

        assertEq(out1, 100_000e6);
        assertEq(out2, 50_000e6);
        assertEq(in1 + in2, 0, "draws must be zero-in");
        assertEq(router.coveredAmount(lender, orderHash), 150_000e6, "cumulative fill accounting wrong");
        assertEq(usdc.balanceOf(borrower) - REPAYMENT_USDC, 150_000e6, "borrower USDC mismatch");
    }

    function test_StopWhenCovered_OverdrawRevertsWithRemaining() public {
        (ISwapVM.Order memory order,) = _shipFacilityLeg();

        _pullAs(borrower, order, 250_000e6);

        vm.expectRevert(abi.encodeWithSelector(AlbaOpcodes.StopWhenCoveredExceeded.selector, 100_000e6, 50_000e6));
        vm.prank(borrower);
        router.swap(order, address(cbbtc), address(usdc), 100_000e6, _pullData(borrower));
    }

    function test_StopWhenCovered_LastFillTakesExactRemainder() public {
        (ISwapVM.Order memory order, bytes32 orderHash) = _shipFacilityLeg();

        _pullAs(borrower, order, 250_000e6);

        // filler flow: read remaining from public accounting, take exactly the remainder
        uint256 remaining = FACILITY_USDC - router.coveredAmount(lender, orderHash);
        assertEq(remaining, 50_000e6);
        (, uint256 aOut) = _pullAs(borrower, order, remaining);
        assertEq(aOut, 50_000e6);
        assertEq(router.coveredAmount(lender, orderHash), FACILITY_USDC, "facility should be fully covered");
    }

    function test_StopWhenCovered_CoveredOrderReverts() public {
        (ISwapVM.Order memory order, bytes32 orderHash) = _shipFacilityLeg();

        _pullAs(borrower, order, FACILITY_USDC); // draw everything

        vm.expectRevert(abi.encodeWithSelector(AlbaOpcodes.OrderCovered.selector, orderHash));
        vm.prank(borrower);
        router.swap(order, address(cbbtc), address(usdc), 1e6, _pullData(borrower));
    }

    function test_StopWhenCovered_StaticQuoteNeverMutatesStorage() public {
        (ISwapVM.Order memory order, bytes32 orderHash) = _shipFacilityLeg();

        _pullAs(borrower, order, 100_000e6);
        assertEq(router.coveredAmount(lender, orderHash), 100_000e6);

        // quote repeatedly in static context — fill accounting must not move
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(borrower);
            (, uint256 qOut,) = router.quote(order, address(cbbtc), address(usdc), 50_000e6, _pullData(borrower));
            assertEq(qOut, 50_000e6);
        }
        assertEq(router.coveredAmount(lender, orderHash), 100_000e6, "static quote mutated fill accounting");

        // quote through an explicit staticcall as well (hard guarantee: no state change possible)
        (bool ok,) = address(router).staticcall(
            abi.encodeWithSelector(
                router.quote.selector, order, address(cbbtc), address(usdc), 50_000e6, _pullData(borrower)
            )
        );
        assertTrue(ok, "quote must succeed under staticcall");
        assertEq(router.coveredAmount(lender, orderHash), 100_000e6);
    }
}
