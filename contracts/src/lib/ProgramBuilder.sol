// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ISwapVM} from "swap-vm/src/interfaces/ISwapVM.sol";
import {Context} from "swap-vm/src/libs/VM.sol";
import {MakerTraitsLib} from "swap-vm/src/libs/MakerTraits.sol";
import {Opcodes} from "swap-vm/src/opcodes/Opcodes.sol";
import {LimitSwapArgsBuilder} from "swap-vm/src/instructions/LimitSwap.sol";
import {Program, ProgramBuilder} from "swap-vm/test/utils/ProgramBuilder.sol";

import {
    ChronosOpcodes,
    NotBeforeArgsBuilder,
    OnlyTakerArgsBuilder,
    StopWhenCoveredArgsBuilder
} from "../opcodes/ChronosOpcodes.sol";

/// @title ChronosProgramBuilder — single source of truth for order construction
/// @notice Every Chronos order is built here and ONLY here. `aqua.ship()` calldata and the
/// executable order derive from the same `ISwapVM.Order`: the shipped strategy bytes are
/// `abi.encode(order)`, so `keccak256(strategy) == SwapVM.hash(order)` by construction
/// (Aqua-mode orderHash is `keccak256(abi.encode(order))`). Never hand-assemble programs.
///
/// @dev DESIGN NOTE — one-way pulls, not swaps. Aqua balances are LIVE: every fill moves
/// them, so balance-ratio pricing (`_limitSwap1D` over Aqua balances) drifts like an AMM
/// and cannot express a fixed rate across partial fills. Chronos legs therefore avoid VM
/// pricing entirely: draw and repayment legs are zero-amountIn exact-out pulls
/// (`allowZeroAmountIn` + no pricing instruction — `SwapVM._transferIn` skips the taker
/// transfer when amountIn == 0). All economics (zero-coupon repayment = drawn × (1 + r·t))
/// are computed HERE when sizing the shipped amounts. Collateral never touches the VM;
/// it locks in CollateralEscrow.
abstract contract ChronosProgramBuilder is Opcodes, ChronosOpcodes {
    using ProgramBuilder for Program;

    /// @param maker Liquidity owner: lender (facility leg) or borrower (maturity leg)
    /// @param counterToken Symbolic tokenIn (SwapVM needs a distinct pair); never transferred
    /// @param pullToken Token pulled from maker's Aqua balance (loan token, USDC)
    /// @param amount Committed size (facility) or repayment owed (maturity) — the
    ///        `_stopWhenCovered` target, denominated in pullToken OUT
    /// @param salt Uniqueness (facility/draw id) so identical terms yield distinct orderHashes
    struct PullLegTerms {
        address maker;
        address counterToken;
        address pullToken;
        uint256 amount;
        uint256 salt;
    }

    /// @notice Facility open/draw leg: each draw is a zero-in exact-out partial fill of the
    /// committed pullToken; `_stopWhenCovered` caps cumulative draws at the facility size.
    function buildFacilityLeg(PullLegTerms memory t)
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
            p.build(_stopWhenCovered, StopWhenCoveredArgsBuilder.build(false, t.amount))
        );
        (order, shipStrategy) = _wrapAquaOrder(t.maker, bytecode, true);
        (tokens, amounts) = _shipArrays(t);
    }

    /// @notice Maturity leg (per draw): zero-in pull of the repayment from the borrower's
    /// Aqua balance, gated by maturity time and the settlement executor. `_stopWhenCovered`
    /// doubles as double-settlement protection (a second pull hits OrderCovered).
    function buildMaturityLeg(PullLegTerms memory t, uint40 maturity, address executor)
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
            p.build(_notBefore, NotBeforeArgsBuilder.build(maturity)),
            p.build(_onlyTaker, OnlyTakerArgsBuilder.build(executor)),
            p.build(_salt, abi.encodePacked(t.salt)),
            p.build(_stopWhenCovered, StopWhenCoveredArgsBuilder.build(false, t.amount))
        );
        (order, shipStrategy) = _wrapAquaOrder(t.maker, bytecode, true);
        (tokens, amounts) = _shipArrays(t);
    }

    /// @notice Generic two-token Aqua limit leg (balance-ratio priced, drifts with fills).
    /// Kept for the Test 1 round trip and as the base of the auction leg.
    function buildAquaLimitLeg(
        address maker,
        address takerToken,
        address makerToken,
        uint256 takerTokenBalance,
        uint256 makerTokenBalance,
        uint256 salt
    )
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
            p.build(_salt, abi.encodePacked(salt)),
            p.build(_limitSwap1D, LimitSwapArgsBuilder.build(takerToken, makerToken))
        );
        (order, shipStrategy) = _wrapAquaOrder(maker, bytecode, false);
        tokens = new address[](2);
        amounts = new uint256[](2);
        tokens[0] = takerToken;
        tokens[1] = makerToken;
        amounts[0] = takerTokenBalance;
        amounts[1] = makerTokenBalance;
    }

    /// @notice Zero-coupon repayment for a draw: principal × (1 + rateBps · term / 365d)
    /// @param rateBps annual simple-interest rate in basis points (e.g. 820 = 8.20%)
    function repaymentAmount(uint256 principal, uint256 rateBps, uint256 termSeconds) public pure returns (uint256) {
        return principal + (principal * rateBps * termSeconds) / (10_000 * 365 days);
    }

    function _wrapAquaOrder(address maker, bytes memory bytecode, bool allowZeroAmountIn)
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
                allowZeroAmountIn: allowZeroAmountIn,
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

    function _shipArrays(PullLegTerms memory t)
        private
        pure
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        tokens = new address[](2);
        amounts = new uint256[](2);
        tokens[0] = t.counterToken; // shipped at 0: activates the pair, never priced or pulled
        tokens[1] = t.pullToken;
        amounts[0] = 0;
        amounts[1] = t.amount;
    }

    /// @dev Resolved by TermRouter with the composed opcode table (built-ins + Chronos)
    function _instructions()
        internal
        pure
        virtual
        returns (function(Context memory, bytes calldata) internal[] memory);
}
