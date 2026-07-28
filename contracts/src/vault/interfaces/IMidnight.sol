// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev Types copied verbatim from the verified Midnight source
/// (`lib/midnight/src/interfaces/IMidnight.sol`, Base mainnet
/// 0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A). See md-files/MIDNIGHT_INTEGRATION.md.
struct CollateralParams {
    address token;
    uint256 lltv;
    uint256 liquidationCursor;
    address oracle;
}

struct Market {
    uint256 chainId;
    address midnight;
    address loanToken;
    CollateralParams[] collateralParams;
    uint256 maturity;
    uint256 rcfThreshold;
    address enterGate;
    address liquidatorGate;
}

struct Offer {
    Market market;
    bool buy;
    address maker;
    uint256 start;
    uint256 expiry;
    uint256 tick;
    bytes32 group;
    address callback;
    bytes callbackData;
    address receiverIfMakerIsSeller;
    address ratifier;
    bool reduceOnly;
    uint128 maxUnits;
    uint128 maxAssets;
    uint256 continuousFeeCap;
}

/// @title IMidnight — the lender-side surface of the Midnight core contract
interface IMidnight {
    function take(
        Offer memory offer,
        bytes memory ratifierData,
        uint256 units,
        address taker,
        address receiverIfTakerIsSeller,
        address takerCallback,
        bytes memory takerCallbackData
    ) external returns (uint256 buyerAssets, uint256 sellerAssets);

    function withdraw(Market memory market, uint256 units, address onBehalf, address receiver) external;

    function repay(Market memory market, uint256 units, address onBehalf, address callback, bytes memory data) external;

    function updatePosition(Market memory market, address user)
        external
        returns (uint128 newCredit, uint128 newPendingFee, uint128 accruedFee);

    function updatePositionView(Market memory market, bytes32 id, address user)
        external
        view
        returns (uint128 newCredit, uint128 newPendingFee, uint128 accruedFee);

    function withdrawable(bytes32 id) external view returns (uint128);

    function credit(bytes32 id, address user) external view returns (uint128);

    function toMarket(bytes32 id) external view returns (Market memory);
}
