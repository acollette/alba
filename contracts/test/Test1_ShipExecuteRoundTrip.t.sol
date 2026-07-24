// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {TokenMock} from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import {ISwapVM} from "swap-vm/src/interfaces/ISwapVM.sol";
import {TakerTraitsLib} from "swap-vm/src/libs/TakerTraits.sol";

import {TermRouter} from "../src/TermRouter.sol";
import {ChronosProgramBuilder} from "../src/lib/ProgramBuilder.sol";

/// @notice Test 1 — the strategyHash trap. Ship a strategy to the OFFICIAL Aqua deployment
/// on a pinned Base mainnet fork, then execute the derived order through TermRouter.
/// Green here proves ship() calldata and the executable order are byte-identical.
contract Test1_ShipExecuteRoundTrip is Test {
    IAqua constant AQUA = IAqua(0x499943E74FB0cE105688beeE8Ef2ABec5D936d31);
    address constant WETH = 0x4200000000000000000000000000000000000006;
    uint256 constant FORK_BLOCK = 49_062_000;

    uint256 constant LENDER_USDC = 300_000e6; // maker side: committed facility-style liquidity
    uint256 constant PRICE_REF_CBBTC = 3e8; // taker side pricing reference (100k USDC per cbBTC)

    TermRouter router;
    TokenMock usdc; // mock loan token (official Aqua, mock assets)
    TokenMock cbbtc; // mock collateral-ish counter token

    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_MAINNET_RPC", string("https://mainnet.base.org")), FORK_BLOCK);

        router = new TermRouter(address(AQUA), WETH, address(this));
        usdc = new TokenMock("Mock USDC", "USDC");
        cbbtc = new TokenMock("Mock cbBTC", "CBBTC");

        usdc.mint(lender, LENDER_USDC);
        vm.prank(lender);
        usdc.approve(address(AQUA), type(uint256).max);
    }

    function _leg() internal view returns (ChronosProgramBuilder.AquaLegTerms memory) {
        return ChronosProgramBuilder.AquaLegTerms({
            maker: lender,
            takerToken: address(cbbtc),
            makerToken: address(usdc),
            takerTokenBalance: PRICE_REF_CBBTC,
            makerTokenBalance: LENDER_USDC,
            salt: 1
        });
    }

    function _takerData() internal view returns (bytes memory) {
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: borrower,
                isExactIn: true,
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: false,
                useTransferFromAndAquaPush: true,
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

    function test_ShipThenExecute_RoundTrip() public {
        (ISwapVM.Order memory order, bytes memory strategy, address[] memory tokens, uint256[] memory amounts) =
            router.buildAquaLimitLeg(_leg());

        // Ship: strategyHash must equal the router's orderHash — THE round-trip assertion
        vm.prank(lender);
        bytes32 strategyHash = AQUA.ship(address(router), strategy, tokens, amounts);
        assertEq(strategyHash, router.hash(order), "strategyHash != orderHash: round trip broken");

        // Execute: borrower swaps 1 cbBTC-mock for USDC at the shipped ratio, no signature anywhere
        uint256 amountIn = 1e8;
        cbbtc.mint(borrower, amountIn);
        vm.prank(borrower);
        cbbtc.approve(address(router), amountIn);

        vm.prank(borrower);
        (uint256 aIn, uint256 aOut,) = router.swap(order, address(cbbtc), address(usdc), amountIn, _takerData());

        assertEq(aIn, amountIn, "amountIn mismatch");
        assertEq(aOut, amountIn * LENDER_USDC / PRICE_REF_CBBTC, "amountOut != shipped-ratio price");
        assertEq(usdc.balanceOf(borrower), aOut, "borrower did not receive USDC");

        // Maker-side Aqua accounting: USDC drawn down, cbBTC pushed in
        (uint248 usdcLeft,) = AQUA.rawBalances(lender, address(router), strategyHash, address(usdc));
        (uint248 cbbtcIn,) = AQUA.rawBalances(lender, address(router), strategyHash, address(cbbtc));
        assertEq(uint256(usdcLeft), LENDER_USDC - aOut, "Aqua USDC balance not decremented");
        assertEq(uint256(cbbtcIn), PRICE_REF_CBBTC + aIn, "Aqua cbBTC balance not incremented");
    }

    function test_Quote_MatchesSwap_AndIsStatic() public {
        (ISwapVM.Order memory order, bytes memory strategy, address[] memory tokens, uint256[] memory amounts) =
            router.buildAquaLimitLeg(_leg());
        vm.prank(lender);
        AQUA.ship(address(router), strategy, tokens, amounts);

        uint256 amountIn = 5e7; // 0.5
        vm.prank(borrower);
        (uint256 qIn, uint256 qOut,) = router.quote(order, address(cbbtc), address(usdc), amountIn, _takerData());
        assertEq(qIn, amountIn);
        assertEq(qOut, amountIn * LENDER_USDC / PRICE_REF_CBBTC, "quote price mismatch");
    }

    function test_UnshippedOrder_Reverts() public {
        (ISwapVM.Order memory order,,,) = router.buildAquaLimitLeg(_leg());
        cbbtc.mint(borrower, 1e8);
        vm.prank(borrower);
        cbbtc.approve(address(router), 1e8);
        vm.prank(borrower);
        vm.expectRevert(); // safeBalances: token not in active strategy
        router.swap(order, address(cbbtc), address(usdc), 1e8, _takerData());
    }
}
