// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AquaTermDeployer} from "./AquaTermDeployer.sol";

/// @notice Ethereum Sepolia testnet — the only network with an official 1inch Aqua test deployment.
library SepoliaConfig {
    uint256 internal constant CHAIN_ID = 11_155_111;

    // Same vanity Aqua registry as production; Sepolia is the documented Aqua testnet.
    address internal constant AQUA = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;

    // Circle test USDC on Sepolia.
    address internal constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address internal constant WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
    // Test WBTC used by several Sepolia DeFi demos; not mainnet WBTC.
    address internal constant WBTC = 0xE47dE7c2c4d24198Ff8f3bC3a1d3C529c67925BD;

    // Chainlink USD feeds on Sepolia (8 decimals).
    address internal constant USDC_USD_FEED = 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E;
    address internal constant ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    address internal constant BTC_USD_FEED = 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43;

    uint32 internal constant DEBT_FEED_MAX_DELAY = 86_400;
    uint32 internal constant COLLATERAL_FEED_MAX_DELAY = 3_600;

    uint16 internal constant WBTC_MAX_BORROW_LTV_BPS = 6500;
    uint16 internal constant WBTC_LIQUIDATION_LTV_BPS = 7500;
    uint16 internal constant WBTC_LIQUIDATION_DISCOUNT_BPS = 500;

    uint16 internal constant WETH_MAX_BORROW_LTV_BPS = 7000;
    uint16 internal constant WETH_LIQUIDATION_LTV_BPS = 8000;
    uint16 internal constant WETH_LIQUIDATION_DISCOUNT_BPS = 500;

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
