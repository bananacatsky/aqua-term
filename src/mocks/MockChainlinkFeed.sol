// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract MockChainlinkFeed is AggregatorV3Interface {
    uint8 public immutable override decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId = 1;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        setAnswer(answer_);
    }

    function setAnswer(int256 answer_) public {
        answer = answer_;
        updatedAt = block.timestamp;
        roundId++;
    }

    function setUpdatedAt(uint256 updatedAt_) external { updatedAt = updatedAt_; }
    function description() external pure returns (string memory) { return "mock feed"; }
    function version() external pure returns (uint256) { return 1; }

    function getRoundData(uint80 requestedRoundId)
        external view returns (uint80, int256, uint256, uint256, uint80)
    {
        require(requestedRoundId == roundId, "ROUND_NOT_FOUND");
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}
