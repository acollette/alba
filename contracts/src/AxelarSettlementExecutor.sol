// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AxelarExecutable} from "axelar-gmp-sdk-solidity/contracts/executable/AxelarExecutable.sol";

import {ISwapVM} from "swap-vm/src/interfaces/ISwapVM.sol";
import {TakerTraitsLib} from "swap-vm/src/libs/TakerTraits.sol";

import {TermRouter} from "./TermRouter.sol";
import {CollateralEscrow} from "./CollateralEscrow.sol";

/// @title AxelarSettlementExecutor — the destination end of the keeper-free loops
/// @notice Two message kinds arrive from the Hedera schedule via Axelar GMP:
///  - "SETTLE" (once, at maturity): settle the maturity leg via `TermRouter.swap()` in Aqua
///    mode (no signature exists or is needed); a failed pull arms the Dutch auction in the
///    SAME transaction. Amounts derive from the escrow at execution time (cures reconcile).
///  - "CHECK" (recurring — the sentinel): run the escrow's permissionless continuous-margining
///    check. Healthy → no-op; breached → the escrow's cure→auction waterfall runs. Anyone can
///    also race this call directly on the escrow; the schedule just guarantees it happens.
contract AxelarSettlementExecutor is AxelarExecutable {
    error InvalidSource(string sourceChain, string sourceAddress);
    error SettlementUnknown(bytes32 drawId);
    error SettlementAlreadyRegistered(bytes32 drawId);
    error OnlyOrderMaker(address caller, address maker);
    error EscrowAlreadySet();
    error UnknownAction(string action);
    error InsufficientCheckGas(uint256 provided, uint256 required);

    event SettlementRegistered(bytes32 indexed drawId, address indexed borrower);
    event Settled(bytes32 indexed drawId, uint256 amountPulled, address lender);
    event SettlementSkipped(bytes32 indexed drawId, CollateralEscrow.DrawState state);
    event Defaulted(bytes32 indexed drawId, bytes32 auctionOrderHash);
    event HealthChecked(bytes32 indexed drawId, bool intervened);

    struct Settlement {
        ISwapVM.Order order; // the borrower's shipped maturity leg (Aqua mode)
        address counterToken;
        address pullToken;
        bool exists;
        bool executed;
    }

    /// @notice Floor for the CHECK path: full-cure = liquidate + Aqua pull + transfers
    uint256 public constant MIN_CHECK_GAS = 900_000;

    TermRouter public immutable ROUTER;
    bytes32 public immutable SOURCE_CHAIN_HASH; // e.g. keccak("hedera")
    bytes32 public immutable SOURCE_ADDRESS_HASH; // trigger/registry address string on Hedera

    CollateralEscrow public escrow; // set once post-deploy (circular constructor dependency)

    mapping(bytes32 drawId => Settlement) public settlements;

    constructor(address gateway_, TermRouter router, string memory sourceChain_, string memory sourceAddress_)
        AxelarExecutable(gateway_)
    {
        ROUTER = router;
        SOURCE_CHAIN_HASH = keccak256(bytes(sourceChain_));
        SOURCE_ADDRESS_HASH = keccak256(bytes(sourceAddress_));
    }

    /// @notice One-shot escrow wiring (escrow's constructor needs this contract's address).
    function setEscrow(CollateralEscrow escrow_) external {
        require(address(escrow) == address(0), EscrowAlreadySet());
        escrow = escrow_;
    }

    /// @notice Borrower registers the maturity leg they shipped for a draw. Restricted to the
    /// order's maker so nobody can plant a broken order and force a spurious liquidation.
    /// Amounts are NOT stored: the executor asks the escrow at execution time, so mid-term
    /// cures reconcile automatically.
    function registerSettlement(bytes32 drawId, ISwapVM.Order calldata order, address counterToken, address pullToken)
        external
    {
        require(!settlements[drawId].exists, SettlementAlreadyRegistered(drawId));
        require(msg.sender == order.maker, OnlyOrderMaker(msg.sender, order.maker));
        settlements[drawId] =
            Settlement({order: order, counterToken: counterToken, pullToken: pullToken, exists: true, executed: false});
        emit SettlementRegistered(drawId, order.maker);
    }

    /// @notice External self-call target so the settlement attempt can be try/caught.
    function attemptSettle(bytes32 drawId) external returns (uint256 amount) {
        require(msg.sender == address(this), OnlyOrderMaker(msg.sender, address(this)));
        Settlement storage s = settlements[drawId];
        amount = escrow.maturityOutstanding(drawId);
        // Pull lands at the ESCROW, which recycles it into the lender's facility strategy:
        // the lender is paid AND the revolving capacity refills, in one motion.
        ROUTER.swap(s.order, s.counterToken, s.pullToken, amount, _takerData(address(escrow)));
    }

    /// @notice External self-call target so the sentinel check can be try/caught.
    function attemptLiquidate(bytes32 drawId) external {
        require(msg.sender == address(this), OnlyOrderMaker(msg.sender, address(this)));
        escrow.liquidate(drawId);
    }

    /// @dev GMP payload: abi.encode(facilityId, drawId, epoch, action); action SETTLE | CHECK
    function _execute(bytes32, string calldata sourceChain, string calldata sourceAddress, bytes calldata payload)
        internal
        override
    {
        require(
            keccak256(bytes(sourceChain)) == SOURCE_CHAIN_HASH && keccak256(bytes(sourceAddress)) == SOURCE_ADDRESS_HASH,
            InvalidSource(sourceChain, sourceAddress)
        );

        (, uint256 drawIdRaw,, string memory action) = abi.decode(payload, (uint256, uint256, uint256, string));
        bytes32 drawId = bytes32(drawIdRaw);
        bytes32 actionHash = keccak256(bytes(action));

        if (actionHash == keccak256("SETTLE")) {
            _settle(drawId);
        } else if (actionHash == keccak256("CHECK")) {
            // The cure path needs real gas. A relayer that under-allocates must fail LOUDLY
            // (retryable) — otherwise the try/catch swallows the inner out-of-gas and a
            // breached position reads as "healthy". Discovered live; see STATUS.md.
            require(gasleft() >= MIN_CHECK_GAS, InsufficientCheckGas(gasleft(), MIN_CHECK_GAS));
            // Sentinel tick: intervene only on a real breach; healthy checks are no-ops
            try this.attemptLiquidate(drawId) {
                emit HealthChecked(drawId, true);
            } catch {
                emit HealthChecked(drawId, false);
            }
        } else {
            revert UnknownAction(action);
        }
    }

    function _settle(bytes32 drawId) private {
        Settlement storage s = settlements[drawId];
        require(s.exists && !s.executed, SettlementUnknown(drawId));
        s.executed = true;

        CollateralEscrow.DrawState state = escrow.stateOf(drawId);
        if (state != CollateralEscrow.DrawState.LOCKED) {
            // Already cured/auctioned/settled before maturity — nothing to pull
            emit SettlementSkipped(drawId, state);
            return;
        }

        try this.attemptSettle(drawId) returns (uint256 amount) {
            escrow.recycle(drawId, amount);
            escrow.release(drawId);
            emit Settled(drawId, amount, escrow.lenderOf(drawId));
        } catch {
            bytes32 auctionHash = escrow.armAuction(drawId);
            emit Defaulted(drawId, auctionHash);
        }
    }

    function _takerData(address to) private view returns (bytes memory) {
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: address(this),
                isExactIn: false, // exact-out pull of the outstanding repayment
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: false,
                useTransferFromAndAquaPush: false,
                threshold: "",
                to: to, // escrow first — it recycles into the facility strategy, paying the lender
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
