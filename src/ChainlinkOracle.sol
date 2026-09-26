// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IOracle} from "./interfaces/IOracle.sol";

/// @notice Values WETH and WBTC collateral in USDT using three Chainlink USD feeds.
/// @dev Feed addresses and freshness limits are fixed at deployment; select them for the target chain.
contract ChainlinkOracle is IOracle {
    struct FeedConfig {
        AggregatorV3Interface feed;
        uint8 tokenDecimals;
        uint8 feedDecimals;
        uint32 maxDelay;
    }

    IERC20Metadata public immutable debtToken;
    FeedConfig public debtFeed;
    mapping(address => FeedConfig) public collateralFeed;

    constructor(
        IERC20Metadata debtToken_,
        IERC20Metadata[2] memory collateralTokens_,
        AggregatorV3Interface[3] memory feeds_,
        uint32[3] memory maxDelays_
    ) {
        require(address(debtToken_) != address(0), "ZERO_DEBT_TOKEN");
        require(address(collateralTokens_[0]) != address(collateralTokens_[1]), "DUPLICATE_COLLATERAL");
        debtToken = debtToken_;
        for (uint256 i; i < 3; ++i) {
            require(address(feeds_[i]) != address(0) && maxDelays_[i] != 0, "BAD_FEED_CONFIG");
            uint8 feedDecimals = feeds_[i].decimals();
            require(feedDecimals <= 18, "FEED_DECIMALS");
            uint8 tokenDecimals = i == 2 ? debtToken_.decimals() : collateralTokens_[i].decimals();
            require(tokenDecimals <= 18, "TOKEN_DECIMALS");
            FeedConfig memory config = FeedConfig(feeds_[i], tokenDecimals, feedDecimals, maxDelays_[i]);
            if (i == 2) debtFeed = config;
            else collateralFeed[address(collateralTokens_[i])] = config;
        }
    }

    function valueInUSDT(address token, uint256 amount) external view returns (uint256) {
        FeedConfig memory config = collateralFeed[token];
        require(address(config.feed) != address(0), "UNSUPPORTED_COLLATERAL");
        uint256 collateralPrice = _priceWad(config);
        uint256 debtPrice = _priceWad(debtFeed);
        uint256 usdWad = Math.mulDiv(amount, collateralPrice, 10 ** config.tokenDecimals);
        return Math.mulDiv(usdWad, 10 ** debtFeed.tokenDecimals, debtPrice);
    }

    function _priceWad(FeedConfig memory config) internal view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = config.feed.latestRoundData();
        require(answer > 0 && updatedAt != 0 && updatedAt <= block.timestamp, "INVALID_FEED_ANSWER");
        require(roundId != 0 && answeredInRound >= roundId, "INCOMPLETE_FEED_ROUND");
        require(block.timestamp - updatedAt <= config.maxDelay, "STALE_FEED");
        return uint256(answer) * 10 ** (18 - config.feedDecimals);
    }
}
