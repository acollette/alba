// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ISwapVM} from "swap-vm/src/interfaces/ISwapVM.sol";
import {MakerTraitsLib} from "swap-vm/src/libs/MakerTraits.sol";
import {LimitSwapArgsBuilder} from "swap-vm/src/instructions/LimitSwap.sol";
import {DutchAuctionArgsBuilder} from "swap-vm/src/instructions/DutchAuction.sol";
import {BalancesArgsBuilder} from "swap-vm/src/instructions/Balances.sol";
import {Program, ProgramBuilder} from "swap-vm/test/utils/ProgramBuilder.sol";

import {NotBeforeArgsBuilder, OnlyTakerArgsBuilder, StopWhenCoveredArgsBuilder} from "../opcodes/AlbaOpcodes.sol";
import {AlbaInstructionSet} from "../opcodes/AlbaInstructionSet.sol";

/// @title AlbaProgramBuilder — single source of truth for order construction
/// @notice Every Alba order is built here and ONLY here. `aqua.ship()` calldata and the
/// executable order derive from the same `ISwapVM.Order`: the shipped strategy bytes are
/// `abi.encode(order)`, so `keccak256(strategy) == SwapVM.hash(order)` by construction
/// (Aqua-mode orderHash is `keccak256(abi.encode(order))`). Never hand-assemble programs.
///
/// @dev DESIGN NOTE — one-way pulls, not swaps. Aqua balances are LIVE: every fill moves
/// them, so balance-ratio pricing (`_limitSwap1D` over Aqua balances) drifts like an AMM
/// and cannot express a fixed rate across partial fills. Alba legs therefore avoid VM
/// pricing entirely: draw and repayment legs are zero-amountIn exact-out pulls
/// (`allowZeroAmountIn` + no pricing instruction — `SwapVM._transferIn` skips the taker
/// transfer when amountIn == 0). All economics (zero-coupon repayment = drawn × (1 + r·t))
/// are computed HERE when sizing the shipped amounts. Collateral never touches the VM;
/// it locks in CollateralEscrow.
abstract contract AlbaProgramBuilder is AlbaInstructionSet {
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
    /// committed pullToken. `_onlyTaker(taker)` makes the escrow the ONLY doorway to the
    /// facility: collateral in and cash out are one atomic motion via `CollateralEscrow.draw`
    /// (quotes stay open — the check skips in static context).
    ///
    /// @dev Deliberately NO `_stopWhenCovered` here: that counter is monotonic, while a
    /// revolver's capacity must refill on `recycle()`. Commitment metering lives in the
    /// escrow (`outstandingOf + amount <= commitment`), and the live Aqua balance — which
    /// `push` replenishes — is the hard outer bound on what can ever be pulled.
    function buildFacilityLeg(PullLegTerms memory t, address taker)
        public
        pure
        returns (
            ISwapVM.Order memory order,
            bytes memory shipStrategy,
            address[] memory tokens,
            uint256[] memory amounts
        )
    {
        Program memory p = ProgramBuilder.init(_albaInstructions());
        bytes memory bytecode = bytes.concat(
            p.build(_onlyTaker, OnlyTakerArgsBuilder.build(taker)), p.build(_salt, abi.encodePacked(t.salt))
        );
        (order, shipStrategy) = _wrapAquaOrder(t.maker, bytecode, true);
        (tokens, amounts) = _shipArrays(t);
    }

    /// @notice Cure leg (per draw, opt-in): zero-in pull rights over the borrower's loan-token
    /// balance with NO maturity gate — the liquidation path's gentle tier. Gated by
    /// `_onlyTaker(escrow)` (the escrow only pulls on an oracle-verified breach) and capped
    /// at the full repayment by `_stopWhenCovered`.
    ///
    /// @dev Unlike the facility leg, the cap MUST stay: the borrower is the maker here and
    /// the escrow operates the pull, so the in-program cap is the borrower's own term sheet —
    /// cumulative cure pulls can never exceed what is owed, whatever the taker does.
    function buildCureLeg(PullLegTerms memory t, address taker)
        public
        pure
        returns (
            ISwapVM.Order memory order,
            bytes memory shipStrategy,
            address[] memory tokens,
            uint256[] memory amounts
        )
    {
        Program memory p = ProgramBuilder.init(_albaInstructions());
        bytes memory bytecode = bytes.concat(
            p.build(_onlyTaker, OnlyTakerArgsBuilder.build(taker)),
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
        Program memory p = ProgramBuilder.init(_albaInstructions());
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
        Program memory p = ProgramBuilder.init(_albaInstructions());
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

    /// @param maker The escrow (auction Aqua maker)
    /// @param bidToken Filler's tokenIn (loan token, USDC); raised amount counts toward target
    /// @param collateralToken tokenOut sold to fillers (cbBTC)
    /// @param collateralAmount Collateral shipped for sale (this draw's lock only)
    /// @param startBidRef Bid-side reference balance: collateralAmount × startPrice. Price per
    ///        collateral unit starts at startBidRef/collateralAmount and decays exponentially.
    /// @param target USDC to raise (debt + liquidation fee) — auction halts here
    /// @param startTime Decay clock start; execution before startTime reverts (underflow gate)
    /// @param duration Auction lifetime in seconds (max 65535); expiry = price floor
    /// @param decayFactor Per-second decay ×1e18 (e.g. 0.99994e18); floor = start·decay^duration
    struct AuctionTerms {
        address maker;
        address bidToken;
        address collateralToken;
        uint256 collateralAmount;
        uint256 startBidRef;
        uint256 target;
        uint40 startTime;
        uint16 duration;
        uint64 decayFactor;
        uint256 salt;
    }

    /// @notice Dutch-auction liquidation leg: unit price decays from startBidRef/collateral
    /// toward the floor (reached at expiry); `_stopWhenCovered` halts sales the moment
    /// `target` USDC is raised. Partial fills welcome — every SwapVM filler is a liquidator.
    ///
    /// @dev SIGNATURE mode (ERC-1271 by the escrow), NOT Aqua mode: Aqua fillers must push
    /// tokenIn into the strategy, which inflates the bid-side pricing balance and breaks the
    /// decay curve after the first partial fill. `_staticBalancesXD` re-seeds pricing from
    /// program bytes on every fill, so the price is purely time-decayed. Collateral custody
    /// stays capped by the escrow's bounded router allowance.
    function buildAuctionLeg(AuctionTerms memory t) public pure returns (ISwapVM.Order memory order) {
        Program memory p = ProgramBuilder.init(_albaInstructions());
        address[] memory tokens = new address[](2);
        uint256[] memory balances = new uint256[](2);
        tokens[0] = t.bidToken;
        tokens[1] = t.collateralToken;
        balances[0] = t.startBidRef;
        balances[1] = t.collateralAmount;
        bytes memory bytecode = bytes.concat(
            p.build(_salt, abi.encodePacked(t.salt)),
            p.build(_staticBalancesXD, BalancesArgsBuilder.build(tokens, balances)),
            p.build(_dutchAuctionBalanceIn1D, DutchAuctionArgsBuilder.build(t.startTime, t.duration, t.decayFactor)),
            p.build(_limitSwap1D, LimitSwapArgsBuilder.build(t.bidToken, t.collateralToken)),
            p.build(_stopWhenCovered, StopWhenCoveredArgsBuilder.build(true, t.target))
        );
        (order,) = _wrapOrder(t.maker, bytecode, false, false);
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
        return _wrapOrder(maker, bytecode, allowZeroAmountIn, true);
    }

    function _wrapOrder(address maker, bytes memory bytecode, bool allowZeroAmountIn, bool useAqua)
        internal
        pure
        returns (ISwapVM.Order memory order, bytes memory shipStrategy)
    {
        order = MakerTraitsLib.build(
            MakerTraitsLib.Args({
                maker: maker,
                receiver: address(0),
                shouldUnwrapWeth: false,
                useAquaInsteadOfSignature: useAqua,
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
}
