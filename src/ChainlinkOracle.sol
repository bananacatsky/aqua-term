// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IOracle} from "./interfaces/IOracle.sol";

/// @notice Values configured collateral tokens in USDT using Chainlink USD feeds.
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
        IERC20Metadata[] memory collateralTokens_,
        AggregatorV3Interface[] memory collateralFeeds_,
        uint32[] memory collateralMaxDelays_,
        AggregatorV3Interface debtFeed_,
        uint32 debtMaxDelay_
    ) {
        require(address(debtToken_) != address(0), "ZERO_DEBT_TOKEN");
        require(collateralTokens_.length != 0, "NO_COLLATERAL");
        require(
            collateralTokens_.length == collateralFeeds_.length && collateralTokens_.length == collateralMaxDelays_.length,
            "BAD_COLLATERAL_CONFIG"
        );
        require(address(debtFeed_) != address(0) && debtMaxDelay_ != 0, "BAD_FEED_CONFIG");
        debtToken = debtToken_;
        uint8 debtFeedDecimals = debtFeed_.decimals();
        require(debtFeedDecimals <= 18, "FEED_DECIMALS");
        require(debtToken_.decimals() <= 18, "TOKEN_DECIMALS");
        debtFeed = FeedConfig(debtFeed_, debtToken_.decimals(), debtFeedDecimals, debtMaxDelay_);
        for (uint256 i; i < collateralTokens_.length; ++i) {
            require(address(collateralTokens_[i]) != address(0), "ZERO_COLLATERAL");
            require(address(collateralFeeds_[i]) != address(0) && collateralMaxDelays_[i] != 0, "BAD_FEED_CONFIG");
            require(address(collateralFeed[address(collateralTokens_[i])].feed) == address(0), "DUPLICATE_COLLATERAL");
            uint8 feedDecimals = collateralFeeds_[i].decimals();
            require(feedDecimals <= 18, "FEED_DECIMALS");
            uint8 tokenDecimals = collateralTokens_[i].decimals();
            require(tokenDecimals <= 18, "TOKEN_DECIMALS");
            collateralFeed[address(collateralTokens_[i])] =
                FeedConfig(collateralFeeds_[i], tokenDecimals, feedDecimals, collateralMaxDelays_[i]);
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
