// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AquaTermDeployer} from "./AquaTermDeployer.sol";

/// @notice Base mainnet addresses and deployment parameters for AquaTerm.
library BaseConfig {
    uint256 internal constant CHAIN_ID = 8453;

    // 1inch Aqua registry (same vanity address on all supported chains).
    address internal constant AQUA = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;

    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant WBTC = 0x1ceA84203673764244E05693e42E6Ace62bE9BA5;

    // Chainlink USD feeds on Base (8 decimals).
    address internal constant USDC_USD_FEED = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address internal constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant BTC_USD_FEED = 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F;

    // Max Chainlink staleness (seconds). USDC feed heartbeat is 24h on Base.
    uint32 internal constant DEBT_FEED_MAX_DELAY = 86_400;
    uint32 internal constant COLLATERAL_FEED_MAX_DELAY = 3_600;

    // collateralId 0 = WBTC, collateralId 1 = WETH.
    uint16 internal constant WBTC_MAX_BORROW_LTV_BPS = 6500;
    uint16 internal constant WBTC_LIQUIDATION_LTV_BPS = 7500;
    uint16 internal constant WBTC_LIQUIDATION_DISCOUNT_BPS = 500;

    uint16 internal constant WETH_MAX_BORROW_LTV_BPS = 7000;
    uint16 internal constant WETH_LIQUIDATION_LTV_BPS = 8000;
    uint16 internal constant WETH_LIQUIDATION_DISCOUNT_BPS = 500;

    // Maturity timestamps (UTC midnight), aligned with frontend/web3-config.js.
    uint40 internal constant MATURITY_OCT_30_2026 = 1_793_318_400;
    uint40 internal constant MATURITY_NOV_30_2026 = 1_795_996_800;
    uint40 internal constant MATURITY_DEC_31_2026 = 1_798_675_200;
    uint40 internal constant MATURITY_JAN_31_2027 = 1_801_353_600;

    function config() internal pure returns (AquaTermDeployer.Config memory cfg) {
        cfg.aqua = AQUA;
        cfg.usdc = USDC;
        cfg.wbtc = WBTC;
        cfg.weth = WETH;
        cfg.usdcUsdFeed = USDC_USD_FEED;
        cfg.ethUsdFeed = ETH_USD_FEED;
        cfg.btcUsdFeed = BTC_USD_FEED;
        cfg.debtFeedMaxDelay = DEBT_FEED_MAX_DELAY;
        cfg.collateralFeedMaxDelay = COLLATERAL_FEED_MAX_DELAY;
        cfg.wbtcMaxBorrowLtvBps = WBTC_MAX_BORROW_LTV_BPS;
        cfg.wbtcLiquidationLtvBps = WBTC_LIQUIDATION_LTV_BPS;
        cfg.wbtcLiquidationDiscountBps = WBTC_LIQUIDATION_DISCOUNT_BPS;
        cfg.wethMaxBorrowLtvBps = WETH_MAX_BORROW_LTV_BPS;
        cfg.wethLiquidationLtvBps = WETH_LIQUIDATION_LTV_BPS;
        cfg.wethLiquidationDiscountBps = WETH_LIQUIDATION_DISCOUNT_BPS;
        cfg.maturityOct30 = MATURITY_OCT_30_2026;
        cfg.maturityNov30 = MATURITY_NOV_30_2026;
        cfg.maturityDec31 = MATURITY_DEC_31_2026;
        cfg.maturityJan31 = MATURITY_JAN_31_2027;
    }
}
