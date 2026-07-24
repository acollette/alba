// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";

import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {TokenCustomDecimalsMock} from "@1inch/solidity-utils/contracts/mocks/TokenCustomDecimalsMock.sol";
import {IERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import {ISwapVM} from "swap-vm/src/interfaces/ISwapVM.sol";
import {TakerTraitsLib} from "swap-vm/src/libs/TakerTraits.sol";

import {TermRouter} from "../src/TermRouter.sol";
import {ChronosOrderBuilder} from "../src/ChronosOrderBuilder.sol";
import {CollateralEscrow} from "../src/CollateralEscrow.sol";
import {AxelarSettlementExecutor} from "../src/AxelarSettlementExecutor.sol";
import {MockV3Aggregator} from "../src/mocks/MockV3Aggregator.sol";
import {ChronosProgramBuilder} from "../src/lib/ProgramBuilder.sol";

/// @notice Live wiring on Base Sepolia: deploy the real stack (router, builder, executor,
/// escrow), publish a facility, lock collateral, draw, arm the maturity leg, and register
/// the settlement package — so the NEXT Hedera-scheduled GMP message settles it for real.
/// One EOA plays lender and borrower on the live leg (gas economy; fork demo has actors).
contract LiveWiring is Script {
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant AXELAR_GATEWAY = 0xe432150cce91c13a887f7D836923d5597adD8E31;

    uint256 constant FACILITY = 300_000e6;
    uint256 constant DRAW1 = 100_000e6;
    uint256 constant COLLAT1 = 1.3e8;
    uint256 constant RATE_BPS = 820;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        IAqua aqua = IAqua(vm.envAddress("AQUA_BS"));
        string memory triggerAddrStr = vm.envString("TRIGGER_ADDR_STR");

        vm.startBroadcast(pk);

        // Honest decimals (USDC 6, cbBTC 8) + collateral/USD oracle (mock: no cbBTC/USD
        // feed exists on Base Sepolia; production wiring = Chainlink on Base mainnet)
        TokenCustomDecimalsMock usdc = new TokenCustomDecimalsMock("Chronos USDC", "USDC", 0, 6);
        TokenCustomDecimalsMock cbbtc = new TokenCustomDecimalsMock("Chronos cbBTC", "CBBTC", 0, 8);
        MockV3Aggregator oracle = new MockV3Aggregator(8, 100_000e8);

        TermRouter router = new TermRouter(address(aqua), WETH, me);
        ChronosOrderBuilder builder = new ChronosOrderBuilder(address(aqua));
        AxelarSettlementExecutor executor =
            new AxelarSettlementExecutor(AXELAR_GATEWAY, router, "hedera", triggerAddrStr);
        CollateralEscrow escrow = new CollateralEscrow(address(executor), router, builder, me);
        executor.setEscrow(escrow);

        // Publish the facility (lender = me): approval + ship, funds stay in wallet
        usdc.mint(me, FACILITY + 50_000e6); // + interest headroom for the repayment pull
        usdc.approve(address(aqua), type(uint256).max);
        (ISwapVM.Order memory facilityOrder, bytes memory strategy, address[] memory tokens, uint256[] memory amounts) =
        builder.buildFacilityLeg(
            ChronosProgramBuilder.PullLegTerms({
                maker: me,
                counterToken: address(cbbtc),
                pullToken: address(usdc),
                amount: FACILITY,
                salt: 1
            }),
            address(escrow)
        );
        aqua.ship(address(router), strategy, tokens, amounts);
        escrow.registerFacility(
            bytes32(uint256(0xFAC)), facilityOrder, me, IERC20(address(usdc)), IERC20(address(cbbtc)), oracle, 13_000
        );

        // Atomic collateralized draw: collateral in, cash out, one tx (borrower = me)
        cbbtc.mint(me, COLLAT1);
        cbbtc.approve(address(escrow), type(uint256).max);
        escrow.draw(bytes32(uint256(0xFAC)), bytes32(uint256(1)), DRAW1);

        // Arm the maturity leg + register the settlement package with the executor
        uint40 maturity = uint40(block.timestamp + 420);
        uint256 repayment = builder.repaymentAmount(DRAW1, RATE_BPS, 90 days);
        (
            ISwapVM.Order memory maturityOrder,
            bytes memory mStrategy,
            address[] memory mTokens,
            uint256[] memory mAmounts
        ) = builder.buildMaturityLeg(
            ChronosProgramBuilder.PullLegTerms({
                maker: me,
                counterToken: address(cbbtc),
                pullToken: address(usdc),
                amount: repayment,
                salt: 1
            }),
            maturity,
            address(executor)
        );
        aqua.ship(address(router), mStrategy, mTokens, mAmounts);
        executor.registerSettlement(
            bytes32(uint256(1)), maturityOrder, address(cbbtc), address(usdc), repayment, me, 3600, 0.99994e18
        );

        vm.stopBroadcast();

        console.log("ROUTER:", address(router));
        console.log("BUILDER:", address(builder));
        console.log("EXECUTOR:", address(executor));
        console.log("ESCROW:", address(escrow));
        console.log("USDC:", address(usdc));
        console.log("CBBTC:", address(cbbtc));
        console.log("ORACLE:", address(oracle));
        console.log("maturity (notBefore):", maturity);
        console.log("repayment:", repayment);
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
}
