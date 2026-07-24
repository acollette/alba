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
    CollateralEscrow escrow;
    AxelarSettlementExecutor executor;
    MockAxelarGateway gateway;
    TokenMock usdc;
    TokenMock cbbtc;

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
        gateway = new MockAxelarGateway();
        executor = new AxelarSettlementExecutor(address(gateway), router, SOURCE_CHAIN, SOURCE_ADDR);
        escrow = new CollateralEscrow(address(executor), router, feeSink);
        executor.setEscrow(escrow);

        usdc = new TokenMock("Mock USDC", "USDC");
        cbbtc = new TokenMock("Mock cbBTC", "CBBTC");

        // Publish facility
        usdc.mint(lender, FACILITY);
        vm.startPrank(lender);
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
        AQUA.ship(address(router), strategy, tokens, amounts);
        vm.stopPrank();

        // Draw + arm maturity leg + register settlement package with the executor
        cbbtc.mint(borrower, COLLAT1);
        maturity = uint40(block.timestamp + TERM);
        repayment = router.repaymentAmount(DRAW1, RATE_BPS, TERM);
        usdc.mint(borrower, repayment - DRAW1); // interest portion; principal comes from the draw

        vm.startPrank(borrower);
        cbbtc.approve(address(escrow), type(uint256).max);
        usdc.approve(address(AQUA), type(uint256).max);
        escrow.lockFor(DRAW_ID, IERC20(address(cbbtc)), COLLAT1);
        router.swap(facilityOrder, address(cbbtc), address(usdc), DRAW1, _pullData(borrower));
        (maturityOrder, strategy, tokens, amounts) = router.buildMaturityLeg(
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
            DRAW_ID, maturityOrder, address(cbbtc), address(usdc), repayment, lender, 136_500e6, 3600, 0.99994e18
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
            bytes32(uint256(2)), maturityOrder, address(cbbtc), address(usdc), repayment, lender, 1, 1, 1
        );
    }

    function _draw(bytes32 drawId)
        internal
        view
        returns (address borrower_, IERC20 token, uint256 amount, uint256 unused, CollateralEscrow.DrawState state)
    {
        (borrower_, token, amount, state) = escrow.draws(drawId);
        unused = 0;
    }
}
