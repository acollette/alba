// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Context} from "swap-vm/src/libs/VM.sol";
import {Controls} from "swap-vm/src/instructions/Controls.sol";
import {Balances} from "swap-vm/src/instructions/Balances.sol";
import {Invalidators} from "swap-vm/src/instructions/Invalidators.sol";
import {LimitSwap} from "swap-vm/src/instructions/LimitSwap.sol";
import {DutchAuction} from "swap-vm/src/instructions/DutchAuction.sol";
import {Fee} from "swap-vm/src/instructions/Fee.sol";

import {ChronosOpcodes} from "./ChronosOpcodes.sol";

/// @title ChronosInstructionSet — THE opcode table, defined exactly once
/// @notice Both TermRouter (execution) and ChronosOrderBuilder (order construction) inherit
/// this mixin, so program bytes are always encoded and decoded against the same table.
/// Index layout is IDENTICAL to swap-vm's full `Opcodes` table (46 slots) with the
/// instruction families Chronos doesn't use pointed at `_notInstruction` — same pattern
/// 1inch uses in `AquaOpcodes` — which keeps the router under the EIP-170 size limit.
/// Chronos opcodes sit at indices 46/47/48.
abstract contract ChronosInstructionSet is
    Controls,
    Balances,
    Invalidators,
    LimitSwap,
    DutchAuction,
    Fee,
    ChronosOpcodes
{
    constructor(address aqua) Fee(aqua) {}

    function _notInstruction(Context memory, bytes calldata) internal view {}

    function _chronosInstructions()
        internal
        pure
        returns (function(Context memory, bytes calldata) internal[] memory result)
    {
        function(Context memory, bytes calldata) internal[50] memory instructions = [
            _notInstruction,
            // 0-9: Debug — reserved (placeholders, as upstream)
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            // 10-16: Controls
            Controls._jump,
            Controls._jumpIfTokenIn,
            Controls._jumpIfTokenOut,
            Controls._deadline,
            Controls._onlyTakerTokenBalanceNonZero,
            Controls._onlyTakerTokenBalanceGte,
            Controls._onlyTakerTokenSupplyShareGte,
            // 17-18: Balances
            Balances._staticBalancesXD,
            Balances._dynamicBalancesXD,
            // 19-21: Invalidators
            Invalidators._invalidateBit1D,
            Invalidators._invalidateTokenIn1D,
            Invalidators._invalidateTokenOut1D,
            // 22-24: XYCSwap / XYCConcentrate / Decay — unused by Chronos
            _notInstruction,
            _notInstruction,
            _notInstruction,
            // 25-26: LimitSwap
            LimitSwap._limitSwap1D,
            LimitSwap._limitSwapOnlyFull1D,
            // 27-28: MinRate — unused
            _notInstruction,
            _notInstruction,
            // 29-30: DutchAuction
            DutchAuction._dutchAuctionBalanceIn1D,
            DutchAuction._dutchAuctionBalanceOut1D,
            // 31-33: BaseFeeAdjuster / TWAP / Extruction — unused
            _notInstruction,
            _notInstruction,
            _notInstruction,
            // 34: salt
            Controls._salt,
            // 35: Fee flat-in
            Fee._flatFeeAmountInXD,
            // 36-41: FeeExperimental family + PeggedSwap — unused
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            // 42-45: Fee protocol variants
            Fee._protocolFeeAmountInXD,
            Fee._aquaProtocolFeeAmountInXD,
            Fee._dynamicProtocolFeeAmountInXD,
            Fee._aquaDynamicProtocolFeeAmountInXD,
            // 46-48: Chronos
            _notBefore,
            _onlyTaker,
            _stopWhenCovered
        ];

        // Upstream idiom: alias the static array as dynamic by overwriting slot 0 with length
        uint256 instructionsArrayLength = instructions.length - 1;
        assembly ("memory-safe") {
            result := instructions
            mstore(result, instructionsArrayLength)
        }
    }
}
