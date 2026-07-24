// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {TokenCustomDecimalsMock} from "@1inch/solidity-utils/contracts/mocks/TokenCustomDecimalsMock.sol";
import {IERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import {ISwapVM} from "swap-vm/src/interfaces/ISwapVM.sol";
import {SwapVM} from "swap-vm/src/SwapVM.sol";
import {TakerTraitsLib} from "swap-vm/src/libs/TakerTraits.sol";

import {TermRouter} from "../src/TermRouter.sol";
import {AlbaOrderBuilder} from "../src/AlbaOrderBuilder.sol";
import {MockV3Aggregator} from "../src/mocks/MockV3Aggregator.sol";
import {CollateralEscrow} from "../src/CollateralEscrow.sol";
import {AlbaOpcodes} from "../src/opcodes/AlbaOpcodes.sol";
import {AlbaProgramBuilder} from "../src/lib/ProgramBuilder.sol";

/// @notice Test 6 — the default path: borrower drained → repayment pull reverts → auction
/// armed → two partial fills at a decaying price → auction halts the moment the lender-side
/// target is covered → waterfall exact (lender debt, fee, borrower surplus collateral).
contract Test6_DefaultPath is Test {
    IAqua constant AQUA = IAqua(0x499943E74FB0cE105688beeE8Ef2ABec5D936d31);
    address constant WETH = 0x4200000000000000000000000000000000000006;
    uint256 constant FORK_BLOCK = 49_062_000;

    uint256 constant FACILITY = 300_000e6;
    uint256 constant RATE_BPS = 820;
    uint256 constant TERM = 90 days;

    uint256 constant DRAW1 = 100_000e6;
    uint256 constant COLLAT1 = 1.3e8; // 130% at 100k USDC per unit

    // Auction params: start 105% of the 100k oracle price, floor ~85% at expiry
    uint256 constant START_BID_REF = 136_500e6; // 1.3 × 105_000e6
    uint16 constant DURATION = 3600;
    uint64 constant DECAY = 0.99994e18; // ≈80.6% of start after 3600s

    TermRouter router;
    AlbaOrderBuilder builder;
    MockV3Aggregator oracle;
    CollateralEscrow escrow;
    TokenCustomDecimalsMock usdc;
    TokenCustomDecimalsMock cbbtc;

    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");
    address executor = makeAddr("executor");
    address feeSink = makeAddr("feeSink");
    address filler1 = makeAddr("filler1");
    address filler2 = makeAddr("filler2");

    ISwapVM.Order facilityOrder;
    ISwapVM.Order maturityOrder;
    uint256 repayment;
    uint40 maturity;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_MAINNET_RPC", string("https://mainnet.base.org")), FORK_BLOCK);
        router = new TermRouter(address(AQUA), WETH, address(this));
        builder = new AlbaOrderBuilder(address(AQUA));
        oracle = new MockV3Aggregator(8, 100_000e8);
        escrow = new CollateralEscrow(executor, router, builder, feeSink);
        usdc = new TokenCustomDecimalsMock("Mock USDC", "USDC", 0, 6);
        cbbtc = new TokenCustomDecimalsMock("Mock cbBTC", "CBBTC", 0, 8);

        // Publish facility, lock collateral, draw 100k, arm maturity leg
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
                amount: FACILITY,
                salt: 1
            }),
            address(escrow)
        );
        AQUA.ship(address(router), strategy, tokens, amounts);
        escrow.registerFacility(
            bytes32(uint256(0xFAC)),
            facilityOrder,
            borrower,
            IERC20(address(usdc)),
            IERC20(address(cbbtc)),
            oracle,
            13_000
        );
        vm.stopPrank();

        cbbtc.mint(borrower, COLLAT1);
        maturity = uint40(block.timestamp + TERM);
        repayment = builder.repaymentAmount(DRAW1, RATE_BPS, TERM);

        vm.startPrank(borrower);
        cbbtc.approve(address(escrow), type(uint256).max);
        usdc.approve(address(AQUA), type(uint256).max);
        escrow.draw(bytes32(uint256(0xFAC)), bytes32(uint256(1)), DRAW1);
        (maturityOrder, strategy, tokens, amounts) = builder.buildMaturityLeg(
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
        AQUA.ship(address(router), strategy, tokens, amounts);
        vm.stopPrank();
    }

    function _pullData(address taker) internal pure returns (bytes memory) {
        return _takerData(taker, false, false);
    }

    function _fillData(address taker) internal pure returns (bytes memory) {
        return _takerData(taker, true, false);
    }

    function _takerData(address taker, bool isExactIn, bool aquaPush) internal pure returns (bytes memory) {
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: taker,
                isExactIn: isExactIn,
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: false,
                useTransferFromAndAquaPush: aquaPush,
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

    function _fill(address filler, ISwapVM.Order memory order, uint256 usdcIn)
        internal
        returns (uint256 aIn, uint256 aOut)
    {
        usdc.mint(filler, usdcIn);
        vm.prank(filler);
        usdc.approve(address(router), usdcIn);
        vm.prank(filler);
        (aIn, aOut,) = router.swap(order, address(usdc), address(cbbtc), usdcIn, _fillData(filler));
    }

    function test_DefaultPath_AuctionWaterfallExact() public {
        bytes32 drawId = bytes32(uint256(1));

        // Borrower defaults: drains the wallet backing the Aqua repayment rights
        address gone = makeAddr("gone");
        uint256 borrowerBal = usdc.balanceOf(borrower);
        vm.prank(borrower);
        usdc.transfer(gone, borrowerBal);

        vm.warp(maturity);
        oracle.setAnswer(100_000e8); // fresh mark post-warp (staleness guard is live)

        // Settlement attempt reverts — same trigger arms the auction (manual executor here)
        vm.prank(executor);
        vm.expectRevert();
        router.swap(maturityOrder, address(cbbtc), address(usdc), repayment, _pullData(executor));

        vm.prank(executor);
        bytes32 auctionHash = escrow.armAuction(drawId, repayment, DURATION, DECAY);

        uint256 fee = (repayment * escrow.LIQ_FEE_BPS()) / 10_000;
        uint256 target = repayment + fee;

        // Rebuild the auction order via the same single source of truth
        ISwapVM.Order memory auctionOrder = builder.buildAuctionLeg(
            AlbaProgramBuilder.AuctionTerms({
                maker: address(escrow),
                bidToken: address(usdc),
                collateralToken: address(cbbtc),
                collateralAmount: COLLAT1,
                startBidRef: START_BID_REF,
                target: target,
                startTime: uint40(block.timestamp),
                duration: DURATION,
                decayFactor: DECAY,
                salt: uint256(drawId)
            })
        );
        assertEq(router.hash(auctionOrder), auctionHash, "auction order hash mismatch");

        // Fill 1 at t+600
        vm.warp(maturity + 600);
        (, uint256 c1) = _fill(filler1, auctionOrder, 60_000e6);
        uint256 unitPrice1 = (60_000e6 * 1e8) / c1;

        // Fill 2 at t+1200 takes exactly the remainder — decayed (cheaper) price
        vm.warp(maturity + 1200);
        uint256 remainder = target - router.coveredAmount(address(escrow), auctionHash);
        (, uint256 c2) = _fill(filler2, auctionOrder, remainder);
        uint256 unitPrice2 = (remainder * 1e8) / c2;

        assertLt(unitPrice2, unitPrice1, "price must decay between fills");
        assertLt(unitPrice1, 105_000e6, "fill 1 must be below start price");
        assertGt(unitPrice2, 85_000e6, "price must stay above the floor");

        // Halt: the lender is whole, further sales revert
        usdc.mint(filler1, 1e6);
        vm.prank(filler1);
        usdc.approve(address(router), 1e6);
        vm.expectRevert(abi.encodeWithSelector(AlbaOpcodes.OrderCovered.selector, auctionHash));
        vm.prank(filler1);
        router.swap(auctionOrder, address(usdc), address(cbbtc), 1e6, _fillData(filler1));

        // Waterfall: lender made whole up to debt, fee to sink, surplus collateral home
        escrow.sweepAuction(drawId);

        assertEq(usdc.balanceOf(lender), FACILITY - DRAW1 + repayment, "lender not made whole");
        assertEq(usdc.balanceOf(feeSink), fee, "liquidation fee wrong");
        assertEq(usdc.balanceOf(address(escrow)), 0, "escrow must hold no USDC after sweep");
        assertEq(cbbtc.balanceOf(borrower), COLLAT1 - c1 - c2, "surplus collateral not returned");
        assertEq(cbbtc.balanceOf(address(escrow)), 0, "escrow must hold no collateral after sweep");
        assertEq(cbbtc.allowance(address(escrow), address(router)), 0, "auction path must be closed");

        // Disarm is explicit: the ERC-1271 flag is cleared, so any fill after sweep dies at
        // the signature layer (checked before the program even runs) — no stale fillable order
        assertFalse(escrow.armedOrders(auctionHash), "armed flag must be cleared after sweep");
        usdc.mint(filler2, 1e6);
        vm.prank(filler2);
        usdc.approve(address(router), 1e6);
        vm.expectRevert(abi.encodeWithSelector(SwapVM.BadSignature.selector, address(escrow), auctionHash, bytes("")));
        vm.prank(filler2);
        router.swap(auctionOrder, address(usdc), address(cbbtc), 1e6, _fillData(filler2));
    }

    function test_ArmAuction_OnlyExecutor_AndOnlyOnce() public {
        bytes32 drawId = bytes32(uint256(1));

        vm.expectRevert(abi.encodeWithSelector(CollateralEscrow.OnlyExecutor.selector, borrower));
        vm.prank(borrower);
        escrow.armAuction(drawId, repayment, DURATION, DECAY);

        vm.prank(executor);
        escrow.armAuction(drawId, repayment, DURATION, DECAY);

        // Second arm (or release) on the same draw must fail — single-claim collateral
        vm.expectRevert(abi.encodeWithSelector(CollateralEscrow.DrawNotLocked.selector, drawId));
        vm.prank(executor);
        escrow.armAuction(drawId, repayment, DURATION, DECAY);

        vm.expectRevert(abi.encodeWithSelector(CollateralEscrow.DrawNotLocked.selector, drawId));
        vm.prank(executor);
        escrow.release(drawId);
    }
}
