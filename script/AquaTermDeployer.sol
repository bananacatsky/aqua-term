// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {AquaTermApp} from "../src/AquaTermApp.sol";
import {AquaTermVault} from "../src/AquaTermVault.sol";
import {ChainlinkOracle} from "../src/ChainlinkOracle.sol";

/// @notice Shared AquaTerm deployment logic for network-specific scripts.
library AquaTermDeployer {
    struct Config {
        address aqua;
        address usdc;
        address wbtc;
        address weth;
        address usdcUsdFeed;
        address ethUsdFeed;
        address btcUsdFeed;
        uint32 debtFeedMaxDelay;
        uint32 collateralFeedMaxDelay;
        uint16 wbtcMaxBorrowLtvBps;
        uint16 wbtcLiquidationLtvBps;
        uint16 wbtcLiquidationDiscountBps;
        uint16 wethMaxBorrowLtvBps;
        uint16 wethLiquidationLtvBps;
        uint16 wethLiquidationDiscountBps;
        uint40 maturityOct30;
        uint40 maturityNov30;
        uint40 maturityDec31;
        uint40 maturityJan31;
    }

    struct Deployment {
        ChainlinkOracle oracle;
        AquaTermApp app;
        AquaTermVault vaultOct30;
        AquaTermVault vaultNov30;
        AquaTermVault vaultDec31;
        AquaTermVault vaultJan31;
    }

    function deploy(Config memory cfg) internal returns (Deployment memory deployment) {
        IERC20Metadata[] memory collateralTokens = new IERC20Metadata[](2);
        collateralTokens[0] = IERC20Metadata(cfg.wbtc);
        collateralTokens[1] = IERC20Metadata(cfg.weth);

        AggregatorV3Interface[] memory collateralFeeds = new AggregatorV3Interface[](2);
        collateralFeeds[0] = AggregatorV3Interface(cfg.btcUsdFeed);
        collateralFeeds[1] = AggregatorV3Interface(cfg.ethUsdFeed);

        uint32[] memory collateralMaxDelays = new uint32[](2);
        collateralMaxDelays[0] = cfg.collateralFeedMaxDelay;
        collateralMaxDelays[1] = cfg.collateralFeedMaxDelay;

        deployment.oracle = new ChainlinkOracle(
            IERC20Metadata(cfg.usdc),
            collateralTokens,
            collateralFeeds,
            collateralMaxDelays,
            AggregatorV3Interface(cfg.usdcUsdFeed),
            cfg.debtFeedMaxDelay
        );

        IERC20[] memory collateral = new IERC20[](2);
        collateral[0] = IERC20(cfg.wbtc);
        collateral[1] = IERC20(cfg.weth);

        uint16[] memory maxBorrowLtvs = new uint16[](2);
        maxBorrowLtvs[0] = cfg.wbtcMaxBorrowLtvBps;
        maxBorrowLtvs[1] = cfg.wethMaxBorrowLtvBps;

        uint16[] memory liquidationLtvs = new uint16[](2);
        liquidationLtvs[0] = cfg.wbtcLiquidationLtvBps;
        liquidationLtvs[1] = cfg.wethLiquidationLtvBps;

        uint16[] memory liquidationDiscounts = new uint16[](2);
        liquidationDiscounts[0] = cfg.wbtcLiquidationDiscountBps;
        liquidationDiscounts[1] = cfg.wethLiquidationDiscountBps;

        uint40[] memory maturities = new uint40[](4);
        maturities[0] = cfg.maturityOct30;
        maturities[1] = cfg.maturityNov30;
        maturities[2] = cfg.maturityDec31;
        maturities[3] = cfg.maturityJan31;

        string[] memory names = new string[](4);
        names[0] = "AquaTerm USDC OCT30";
        names[1] = "AquaTerm USDC NOV30";
        names[2] = "AquaTerm USDC DEC31";
        names[3] = "AquaTerm USDC JAN31";

        string[] memory symbols = new string[](4);
        symbols[0] = "USDC-OCT30";
        symbols[1] = "USDC-NOV30";
        symbols[2] = "USDC-DEC31";
        symbols[3] = "USDC-JAN31";

        deployment.app = new AquaTermApp(
            IAqua(cfg.aqua),
            IERC20(cfg.usdc),
            deployment.oracle,
            collateral,
            maxBorrowLtvs,
            liquidationLtvs,
            liquidationDiscounts,
            maturities,
            names,
            symbols
        );

        deployment.vaultOct30 = deployment.app.vaultForMaturity(cfg.maturityOct30);
        deployment.vaultNov30 = deployment.app.vaultForMaturity(cfg.maturityNov30);
        deployment.vaultDec31 = deployment.app.vaultForMaturity(cfg.maturityDec31);
        deployment.vaultJan31 = deployment.app.vaultForMaturity(cfg.maturityJan31);
    }
}
