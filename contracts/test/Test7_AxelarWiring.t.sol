// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {TokenCustomDecimalsMock} from "@1inch/solidity-utils/contracts/mocks/TokenCustomDecimalsMock.sol";
import {IERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import {ISwapVM} from "swap-vm/src/interfaces/ISwapVM.sol";
import {TakerTraitsLib} from "swap-vm/src/libs/TakerTraits.sol";

import {TermRouter} from "../src/TermRouter.sol";
import {ChronosOrderBuilder} from "../src/ChronosOrderBuilder.sol";
import {MockV3Aggregator} from "../src/mocks/MockV3Aggregator.sol";
import {CollateralEscrow} from "../src/CollateralEscrow.sol";
import {AxelarSettlementExecutor} from "../src/AxelarSettlementExecutor.sol";
import {ChronosProgramBuilder} from "../src/lib/ProgramBuilder.sol";

/// @dev Stand-in for the Axelar gateway on the fork: approves every command so the executor's
/// _execute path (source validation, settle, default fallback) can be driven end-to-end.
/// The real gateway leg is proven on Hedera/Base Sepolia by the trigger-leg spike.
contract MockAxelarGateway {
    function validateContractCall(bytes32, string calldata, string calldata, bytes32) external pure returns (bool) {
        return true;
    }
}

/// @notice Item 10 — real wiring: a GMP message (mock-approved gateway) drives
/// AxelarSettlementExecutor.execute → TermRouter.swap. Happy path settles the repayment to
/// the lender and releases collateral; drained borrower arms the auction in the SAME tx.
contract Test7_AxelarWiring is Test {
    IAqua constant AQUA = IAqua(0x499943E74FB0cE105688beeE8Ef2ABec5D936d31);
    address constant WETH = 0x4200000000000000000000000000000000000006;
    uint256 constant FORK_BLOCK = 49_062_000;

    uint256 constant FACILITY = 300_000e6;
    uint256 constant RATE_BPS = 820;
    uint256 constant TERM = 90 days;
    uint256 constant DRAW1 = 100_000e6;
    uint256 constant COLLAT1 = 1.3e8;

    string constant SOURCE_CHAIN = "hedera";
    string constant SOURCE_ADDR = "0xDEA1Re915";

    TermRouter router;
    ChronosOrderBuilder builder;
    MockV3Aggregator oracle;
    CollateralEscrow escrow;
    AxelarSettlementExecutor executor;
    MockAxelarGateway gateway;
    TokenCustomDecimalsMock usdc;
    TokenCustomDecimalsMock cbbtc;

    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");
    address feeSink = makeAddr("feeSink");

    ISwapVM.Order facilityOrder;
    ISwapVM.Order maturityOrder;
    uint256 repayment;
    uint40 maturity;
    bytes32 constant DRAW_ID = bytes32(uint256(1));

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_MAINNET_RPC", string("https://mainnet.base.org")), FORK_BLOCK);
        router = new TermRouter(address(AQUA), WETH, address(this));
        builder = new ChronosOrderBuilder(address(AQUA));
        oracle = new MockV3Aggregator(8, 100_000e8);
        gateway = new MockAxelarGateway();
        executor = new AxelarSettlementExecutor(address(gateway), router, SOURCE_CHAIN, SOURCE_ADDR);
        escrow = new CollateralEscrow(address(executor), router, builder, feeSink);
        executor.setEscrow(escrow);

        usdc = new TokenCustomDecimalsMock("Mock USDC", "USDC", 0, 6);
        cbbtc = new TokenCustomDecimalsMock("Mock cbBTC", "CBBTC", 0, 8);

        // Publish facility
        usdc.mint(lender, FACILITY);
        vm.startPrank(lender);
        usdc.approve(address(AQUA), type(uint256).max);
        bytes memory strategy;
        address[] memory tokens;
        uint256[] memory amounts;
        (facilityOrder, strategy, tokens, amounts) = builder.buildFacilityLeg(
            ChronosProgramBuilder.PullLegTerms({
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
            bytes32(uint256(0xFAC)), facilityOrder, IERC20(address(usdc)), IERC20(address(cbbtc)), oracle, 13_000
        );
        vm.stopPrank();

        // Draw + arm maturity leg + register settlement package with the executor
        cbbtc.mint(borrower, COLLAT1);
        maturity = uint40(block.timestamp + TERM);
        repayment = builder.repaymentAmount(DRAW1, RATE_BPS, TERM);
        usdc.mint(borrower, repayment - DRAW1); // interest portion; principal comes from the draw

        vm.startPrank(borrower);
        cbbtc.approve(address(escrow), type(uint256).max);
        usdc.approve(address(AQUA), type(uint256).max);
        escrow.draw(bytes32(uint256(0xFAC)), DRAW_ID, DRAW1);
        (maturityOrder, strategy, tokens, amounts) = builder.buildMaturityLeg(
            ChronosProgramBuilder.PullLegTerms({
                maker: borrower,
                counterToken: address(cbbtc),
                pullToken: address(usdc),
                amount: repayment,
                salt: 1
            }),
            maturity,
            address(executor)
        );
        AQUA.ship(address(router), strategy, tokens, amounts);
        executor.registerSettlement(
            DRAW_ID, maturityOrder, address(cbbtc), address(usdc), repayment, lender, 3600, 0.99994e18
        );
        vm.stopPrank();
    }

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

    function _payload() internal pure returns (bytes memory) {
        return abi.encode(uint256(1), uint256(uint256(DRAW_ID)), uint256(0), "SETTLE");
    }

    function test_GMPMessage_SettlesRepayment_ReleasesCollateral() public {
        vm.warp(maturity);
        executor.execute(bytes32("cmd1"), SOURCE_CHAIN, SOURCE_ADDR, _payload());

        assertEq(usdc.balanceOf(lender), FACILITY - DRAW1 + repayment, "repayment did not reach lender");
        assertEq(cbbtc.balanceOf(borrower), COLLAT1, "collateral not released");
        assertEq(cbbtc.balanceOf(address(escrow)), 0);
    }

    function test_GMPMessage_DrainedBorrower_ArmsAuction_SameTx() public {
        address gone = makeAddr("gone");
        uint256 bal = usdc.balanceOf(borrower);
        vm.prank(borrower);
        usdc.transfer(gone, bal);

        vm.warp(maturity);
        oracle.setAnswer(100_000e8); // fresh mark post-warp (staleness guard is live)
        executor.execute(bytes32("cmd2"), SOURCE_CHAIN, SOURCE_ADDR, _payload());

        // Settlement failed → auction armed in the same tx; collateral still in escrow
        (,,,, CollateralEscrow.DrawState state) = _draw(DRAW_ID);
        assertEq(uint8(state), uint8(CollateralEscrow.DrawState.AUCTIONING), "auction not armed");
        assertEq(cbbtc.balanceOf(address(escrow)), COLLAT1, "collateral must remain in escrow");
        assertEq(usdc.balanceOf(lender), FACILITY - DRAW1, "no repayment should have moved");
    }

    function test_WrongSource_Reverts() public {
        vm.warp(maturity);
        vm.expectRevert(
            abi.encodeWithSelector(AxelarSettlementExecutor.InvalidSource.selector, "ethereum", SOURCE_ADDR)
        );
        executor.execute(bytes32("cmd3"), "ethereum", SOURCE_ADDR, _payload());
    }

    function test_RegisterSettlement_OnlyMaker() public {
        vm.expectRevert(abi.encodeWithSelector(AxelarSettlementExecutor.OnlyOrderMaker.selector, lender, borrower));
        vm.prank(lender);
        executor.registerSettlement(
            bytes32(uint256(2)), maturityOrder, address(cbbtc), address(usdc), repayment, lender, 1, 1
        );
    }

    function _draw(bytes32 drawId)
        internal
        view
        returns (address borrower_, IERC20 token, uint256 amount, uint256 unused, CollateralEscrow.DrawState state)
    {
        (, borrower_, token, amount, state) = escrow.draws(drawId);
        unused = 0;
    }
}
