// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {ISwapVM} from "swap-vm/src/interfaces/ISwapVM.sol";

import {AlbaOrderBuilder} from "../src/AlbaOrderBuilder.sol";
import {CollateralEscrow} from "../src/CollateralEscrow.sol";
import {AxelarSettlementExecutor} from "../src/AxelarSettlementExecutor.sol";
import {AlbaProgramBuilder} from "../src/lib/ProgramBuilder.sol";

/// @notice Arm an existing draw for scheduled settlement: ship the borrower's maturity
/// leg and register the settlement package. Recovery tool for draws whose UI flow was
/// interrupted mid-ceremony. Usage:
///   DRAW_ID=<uint> ESCROW=.. BUILDER_ADDR=.. EXECUTOR_ADDR=.. USDC=.. CBBTC=.. AQUA_BS=.. \
///   forge script script/ArmDraw.s.sol --rpc-url $BASE_SEPOLIA_RPC --broadcast
contract ArmDraw is Script {
    function run() external {
        uint256 borrowerPk = vm.envUint("BORROWER_PK");
        address borrower = vm.addr(borrowerPk);
        bytes32 drawId = bytes32(vm.envUint("DRAW_ID"));
        CollateralEscrow escrow = CollateralEscrow(vm.envAddress("ESCROW"));
        AlbaOrderBuilder builder = AlbaOrderBuilder(vm.envAddress("BUILDER_ADDR"));
        AxelarSettlementExecutor executor = AxelarSettlementExecutor(vm.envAddress("EXECUTOR_ADDR"));
        IAqua aqua = IAqua(vm.envAddress("AQUA_BS"));

        (,,,,,,, uint40 maturity,) = escrow.draws(drawId);
        uint256 repayment = escrow.repaymentOf(drawId);

        vm.startBroadcast(borrowerPk);
        (ISwapVM.Order memory order, bytes memory strategy, address[] memory tokens, uint256[] memory amounts) =
        builder.buildMaturityLeg(
            AlbaProgramBuilder.PullLegTerms({
                maker: borrower,
                counterToken: vm.envAddress("CBBTC"),
                pullToken: vm.envAddress("USDC"),
                amount: repayment,
                salt: uint256(drawId)
            }),
            maturity,
            address(executor)
        );
        // Idempotent: a re-run after a partial broadcast must skip what already landed
        (, uint8 shipped) = aqua.rawBalances(
            borrower, vm.envAddress("ROUTER_ADDR"), keccak256(strategy), vm.envAddress("USDC")
        );
        if (shipped == 0) {
            aqua.ship(vm.envAddress("ROUTER_ADDR"), strategy, tokens, amounts);
        } else {
            console.log("maturity leg already shipped, skipping");
        }
        (,,, bool exists,) = executor.settlements(drawId);
        if (!exists) {
            executor.registerSettlement(drawId, order, vm.envAddress("CBBTC"), vm.envAddress("USDC"));
        } else {
            console.log("settlement already registered, skipping");
        }
        vm.stopBroadcast();

        console.log("armed draw", uint256(drawId));
        console.log("maturity:", maturity);
        console.log("repayment:", repayment);
    }
}
