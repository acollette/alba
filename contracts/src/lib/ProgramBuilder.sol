// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ISwapVM} from "swap-vm/src/interfaces/ISwapVM.sol";
import {Context} from "swap-vm/src/libs/VM.sol";
import {MakerTraitsLib} from "swap-vm/src/libs/MakerTraits.sol";
import {Opcodes} from "swap-vm/src/opcodes/Opcodes.sol";
import {LimitSwapArgsBuilder} from "swap-vm/src/instructions/LimitSwap.sol";
import {Program, ProgramBuilder} from "swap-vm/test/utils/ProgramBuilder.sol";

import {ChronosOpcodes} from "../opcodes/ChronosOpcodes.sol";

/// @title ChronosProgramBuilder — single source of truth for order construction
/// @notice Every Chronos order is built here and ONLY here. `aqua.ship()` calldata and the
/// executable order derive from the same `ISwapVM.Order`: the shipped strategy bytes are
/// `abi.encode(order)`, so `keccak256(strategy) == SwapVM.hash(order)` by construction
/// (Aqua-mode orderHash is `keccak256(abi.encode(order))`). Never hand-assemble programs.
/// @dev In Aqua mode the shipped balances ARE the pricing balances (`AQUA.safeBalances`
/// pre-loads registers, ratio = price), so programs need no balances instruction.
abstract contract ChronosProgramBuilder is Opcodes, ChronosOpcodes {
    using ProgramBuilder for Program;

    /// @param maker Liquidity owner (lender for draw legs, borrower for maturity legs)
    /// @param takerToken tokenIn from the taker's perspective
    /// @param makerToken tokenOut pulled from maker's Aqua balance
    /// @param takerTokenBalance Pricing reference for the taker side (never pulled from maker)
    /// @param makerTokenBalance Committed maker-side amount (facility size / repayment)
    /// @param salt Uniqueness (facility/draw id) so identical terms produce distinct orderHashes
    struct AquaLegTerms {
        address maker;
        address takerToken;
        address makerToken;
        uint256 takerTokenBalance;
        uint256 makerTokenBalance;
        uint256 salt;
    }

    /// @notice Plain fixed-rate, partially-fillable Aqua leg (no gates). Base of Test 1.
    function buildAquaLimitLeg(AquaLegTerms memory t)
        public
        pure
        returns (
            ISwapVM.Order memory order,
            bytes memory shipStrategy,
            address[] memory tokens,
            uint256[] memory amounts
        )
    {
        Program memory p = ProgramBuilder.init(_instructions());
        bytes memory bytecode = bytes.concat(
            p.build(_salt, abi.encodePacked(t.salt)),
            p.build(_limitSwap1D, LimitSwapArgsBuilder.build(t.takerToken, t.makerToken))
        );
        (order, shipStrategy) = _wrapAquaOrder(t.maker, bytecode);
        (tokens, amounts) = _shipArrays(t);
    }

    function _wrapAquaOrder(address maker, bytes memory bytecode)
        internal
        pure
        returns (ISwapVM.Order memory order, bytes memory shipStrategy)
    {
        order = MakerTraitsLib.build(
            MakerTraitsLib.Args({
                maker: maker,
                receiver: address(0),
                shouldUnwrapWeth: false,
                useAquaInsteadOfSignature: true,
                allowZeroAmountIn: false,
                hasPreTransferInHook: false,
                hasPostTransferInHook: false,
                hasPreTransferOutHook: false,
                hasPostTransferOutHook: false,
                preTransferInTarget: address(0),
                preTransferInData: "",
                postTransferInTarget: address(0),
                postTransferInData: "",
                preTransferOutTarget: address(0),
                preTransferOutData: "",
                postTransferOutTarget: address(0),
                postTransferOutData: "",
                program: bytecode
            })
        );
        shipStrategy = abi.encode(order);
    }

    function _shipArrays(AquaLegTerms memory t)
        private
        pure
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        tokens = new address[](2);
        amounts = new uint256[](2);
        tokens[0] = t.takerToken;
        tokens[1] = t.makerToken;
        amounts[0] = t.takerTokenBalance;
        amounts[1] = t.makerTokenBalance;
    }

    /// @dev Resolved by TermRouter with the composed opcode table (built-ins + Chronos)
    function _instructions()
        internal
        pure
        virtual
        returns (function(Context memory, bytes calldata) internal[] memory);
}
