// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AxelarExecutable} from "axelar-gmp-sdk-solidity/contracts/executable/AxelarExecutable.sol";
import {IERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import {ISwapVM} from "swap-vm/src/interfaces/ISwapVM.sol";
import {TakerTraitsLib} from "swap-vm/src/libs/TakerTraits.sol";

import {TermRouter} from "./TermRouter.sol";
import {CollateralEscrow} from "./CollateralEscrow.sol";

/// @title AxelarSettlementExecutor — the destination end of the keeper-free trigger loop
/// @notice Hedera Schedule Service fires → DealRegistry dispatches a GMP message → Axelar
/// delivers it here → this contract settles the maturity leg via `TermRouter.swap()` in
/// Aqua mode (no signature exists or is needed). If the repayment pull reverts, the SAME
/// transaction arms the pre-registered Dutch-auction liquidation.
contract AxelarSettlementExecutor is AxelarExecutable {
    error InvalidSource(string sourceChain, string sourceAddress);
    error SettlementUnknown(bytes32 drawId);
    error SettlementAlreadyRegistered(bytes32 drawId);
    error OnlyOrderMaker(address caller, address maker);
    error EscrowAlreadySet();

    event SettlementRegistered(bytes32 indexed drawId, address indexed borrower, uint256 repayment);
    event Settled(bytes32 indexed drawId, uint256 repayment, address lender);
    event Defaulted(bytes32 indexed drawId, bytes32 auctionOrderHash);

    /// @dev Auction sizing registered up front so the default path needs no live inputs
    struct Settlement {
        ISwapVM.Order order; // the borrower's shipped maturity leg (Aqua mode)
        address counterToken;
        address pullToken;
        uint256 repayment;
        address lender;
        uint256 startBidRef;
        uint16 auctionDuration;
        uint64 auctionDecay;
        bool exists;
        bool executed;
    }

    TermRouter public immutable ROUTER;
    bytes32 public immutable SOURCE_CHAIN_HASH; // e.g. keccak("hedera")
    bytes32 public immutable SOURCE_ADDRESS_HASH; // DealRegistry address string on Hedera

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

    /// @notice Borrower registers the settlement package for a draw: the maturity order they
    /// shipped plus auction sizing for the default path. Restricted to the order's maker so
    /// nobody can plant a broken order and force a spurious liquidation.
    function registerSettlement(
        bytes32 drawId,
        ISwapVM.Order calldata order,
        address counterToken,
        address pullToken,
        uint256 repayment,
        address lender,
        uint256 startBidRef,
        uint16 auctionDuration,
        uint64 auctionDecay
    ) external {
        require(!settlements[drawId].exists, SettlementAlreadyRegistered(drawId));
        require(msg.sender == order.maker, OnlyOrderMaker(msg.sender, order.maker));
        settlements[drawId] = Settlement({
            order: order,
            counterToken: counterToken,
            pullToken: pullToken,
            repayment: repayment,
            lender: lender,
            startBidRef: startBidRef,
            auctionDuration: auctionDuration,
            auctionDecay: auctionDecay,
            exists: true,
            executed: false
        });
        emit SettlementRegistered(drawId, order.maker, repayment);
    }

    /// @notice External self-call target so the settlement attempt can be try/caught.
    function attemptSettle(bytes32 drawId) external {
        require(msg.sender == address(this), OnlyOrderMaker(msg.sender, address(this)));
        Settlement storage s = settlements[drawId];
        ROUTER.swap(s.order, s.counterToken, s.pullToken, s.repayment, _takerData(s.lender));
    }

    /// @dev GMP payload: abi.encode(facilityId, drawId, epoch, action) with action "SETTLE"
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
        require(keccak256(bytes(action)) == keccak256("SETTLE"), SettlementUnknown(drawId));

        Settlement storage s = settlements[drawId];
        require(s.exists && !s.executed, SettlementUnknown(drawId));
        s.executed = true;

        try this.attemptSettle(drawId) {
            escrow.release(drawId);
            emit Settled(drawId, s.repayment, s.lender);
        } catch {
            bytes32 auctionHash = escrow.armAuction(
                drawId, s.lender, IERC20(s.pullToken), s.repayment, s.startBidRef, s.auctionDuration, s.auctionDecay
            );
            emit Defaulted(drawId, auctionHash);
        }
    }

    function _takerData(address lender) private view returns (bytes memory) {
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: address(this),
                isExactIn: false, // exact-out pull of the repayment
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: false,
                useTransferFromAndAquaPush: false,
                threshold: "",
                to: lender, // repayment lands straight with the lender
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
