// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

/// @notice Chainlink-shaped price feed for tests and testnet demos (no cbBTC/USD feed
/// exists on Base Sepolia). Mainnet-fork/production wiring uses the real Chainlink feed.
contract MockV3Aggregator is IAggregatorV3 {
    uint8 public immutable decimals;
    int256 public answer;
    uint256 public updatedAt;
    address public immutable owner;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        answer = answer_;
        updatedAt = block.timestamp;
        owner = msg.sender;
    }

    function setAnswer(int256 answer_) external {
        require(msg.sender == owner, "only owner");
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, answer, updatedAt, updatedAt, 0);
    }
}
