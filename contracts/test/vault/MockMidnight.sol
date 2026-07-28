// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Market, Offer} from "../../src/vault/interfaces/IMidnight.sol";

/// @notice Faithful-subset mock of the Midnight core for unit/invariant tests:
/// internal credit balances, FCFS `withdrawable` pool, lazy lossFactor
/// slashing and pendingFee — the mechanics MidnightSleeve's accounting rides
/// on. Fills execute at a settable price (no ratifier/expiry checks; those are
/// the real contract's job and are covered by the fork tests).
/// Convention: market id == keccak256(abi.encode(market)) — register with
/// {touch} so `toMarket` and the id derivation in `take`/`withdraw` agree.
contract MockMidnight {
    using SafeERC20 for IERC20;

    struct Pos {
        uint128 credit;
        uint128 pendingFee;
        uint128 lastLossWad;
    }

    IERC20 public immutable USDC;
    /// @dev Fill price (WAD per unit) applied to the next take()s.
    uint256 public priceWad = 0.99e18;

    mapping(bytes32 id => Market) internal _markets;
    mapping(bytes32 id => uint128) public withdrawable;
    /// @dev Cumulative socialized-loss fraction (WAD); may only grow.
    mapping(bytes32 id => uint128) public lossWad;
    mapping(bytes32 id => mapping(address user => Pos)) public pos;

    constructor(IERC20 usdc) {
        USDC = usdc;
    }

    // ------------------------------------------------------- test-side knobs
    function touch(Market memory m) external returns (bytes32 id) {
        id = keccak256(abi.encode(m));
        _markets[id] = m;
    }

    function setPrice(uint256 p) external {
        priceWad = p;
    }

    /// @dev Socialize bad debt: every position is lazily scaled at next touch.
    function setLoss(bytes32 id, uint128 lWad) external {
        require(lWad >= lossWad[id], "loss only grows");
        lossWad[id] = lWad;
    }

    function setPendingFee(bytes32 id, address user, uint128 fee) external {
        pos[id][user].pendingFee = fee;
    }

    /// @dev Fund the FCFS pool (test mints the backing USDC to this contract).
    function fund(bytes32 id, uint128 assets) external {
        withdrawable[id] += assets;
    }

    // -------------------------------------------------- IMidnight (lender ops)
    function take(
        Offer memory offer,
        bytes memory,
        uint256 units,
        address taker,
        address receiver,
        address,
        bytes memory
    ) external returns (uint256 buyerAssets, uint256 sellerAssets) {
        bytes32 id = keccak256(abi.encode(offer.market));
        Pos storage p = _sync(id, taker);
        if (!offer.buy) {
            // ask: taker buys units, pays price rounded against them
            buyerAssets = Math.mulDiv(units, priceWad, 1e18, Math.Rounding.Ceil);
            sellerAssets = buyerAssets;
            p.credit += uint128(units);
            USDC.safeTransferFrom(msg.sender, address(this), buyerAssets);
        } else {
            // bid: taker sells units, receives price rounded against them
            sellerAssets = Math.mulDiv(units, priceWad, 1e18);
            buyerAssets = sellerAssets;
            p.credit -= uint128(units);
            USDC.safeTransfer(receiver, sellerAssets);
        }
    }

    function withdraw(Market memory m, uint256 units, address onBehalf, address receiver) external {
        require(onBehalf == msg.sender, "unauthorized");
        bytes32 id = keccak256(abi.encode(m));
        Pos storage p = _sync(id, onBehalf);
        uint256 creditBefore = p.credit;
        p.credit = uint128(creditBefore - units);
        if (p.pendingFee != 0) {
            p.pendingFee = uint128(uint256(p.pendingFee) * (creditBefore - units) / creditBefore);
        }
        withdrawable[id] -= uint128(units); // FCFS pool underflow == real revert
        USDC.safeTransfer(receiver, units);
    }

    function updatePosition(Market memory m, address user) external returns (uint128, uint128, uint128) {
        Pos storage p = _sync(keccak256(abi.encode(m)), user);
        return (p.credit, p.pendingFee, 0);
    }

    // ------------------------------------------------------ IMidnight (views)
    function updatePositionView(Market memory, bytes32 id, address user)
        external
        view
        returns (uint128, uint128, uint128)
    {
        return (_syncedCredit(id, user), pos[id][user].pendingFee, 0);
    }

    function credit(bytes32 id, address user) external view returns (uint128) {
        return _syncedCredit(id, user);
    }

    function toMarket(bytes32 id) external view returns (Market memory) {
        return _markets[id];
    }

    // -------------------------------------------------------------- internals
    function _sync(bytes32 id, address user) internal returns (Pos storage p) {
        p = pos[id][user];
        p.credit = _syncedCredit(id, user);
        p.lastLossWad = lossWad[id];
    }

    function _syncedCredit(bytes32 id, address user) internal view returns (uint128) {
        Pos storage p = pos[id][user];
        uint128 l = lossWad[id];
        if (l == p.lastLossWad) return p.credit;
        return uint128(uint256(p.credit) * (1e18 - l) / (1e18 - p.lastLossWad));
    }
}
