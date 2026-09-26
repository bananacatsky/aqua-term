// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {Aqua} from "@1inch/aqua/src/Aqua.sol";
import {AquaTermApp} from "../src/AquaTermApp.sol";
import {AquaTermVault} from "../src/AquaTermVault.sol";
import {ChainlinkOracle} from "../src/ChainlinkOracle.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockChainlinkFeed} from "../src/mocks/MockChainlinkFeed.sol";

interface Vm {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function warp(uint256) external;
    function expectRevert(bytes calldata) external;
}

contract AquaTermAppTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal borrower = address(0xB0B);
    address internal supplier = address(0x5A11);
    MockERC20 internal debtToken;
    MockERC20 internal weth;
    MockERC20 internal wbtc;
    MockERC20 internal alt;
    MockChainlinkFeed internal ethFeed;
    MockChainlinkFeed internal btcFeed;
    MockChainlinkFeed internal altFeed;
    MockChainlinkFeed internal debtTokenFeed;
    ChainlinkOracle internal oracle;
    Aqua internal aqua;
    AquaTermApp internal app;
    uint40 internal maturity;

    uint256 internal constant FACE = 500e6;
    uint256 internal constant SPOT = 480e6;

    function setUp() public {
        debtToken = new MockERC20("USDT", "USDT", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
        alt = new MockERC20("Alternative Collateral", "ALT", 18);
        ethFeed = new MockChainlinkFeed(8, 1000e8);
        btcFeed = new MockChainlinkFeed(8, 100_000e8);
        altFeed = new MockChainlinkFeed(8, 2e8);
        debtTokenFeed = new MockChainlinkFeed(8, 1e8);

        IERC20Metadata[] memory oracleTokens = new IERC20Metadata[](3);
        oracleTokens[0] = IERC20Metadata(address(weth)); oracleTokens[1] = IERC20Metadata(address(wbtc));
        oracleTokens[2] = IERC20Metadata(address(alt));
        AggregatorV3Interface[] memory collateralFeeds = new AggregatorV3Interface[](3);
        collateralFeeds[0] = AggregatorV3Interface(address(ethFeed));
        collateralFeeds[1] = AggregatorV3Interface(address(btcFeed));
        collateralFeeds[2] = AggregatorV3Interface(address(altFeed));
        uint32[] memory collateralMaxDelays = new uint32[](3);
        collateralMaxDelays[0] = 1 days; collateralMaxDelays[1] = 1 days; collateralMaxDelays[2] = 1 days;
        oracle = new ChainlinkOracle(
            IERC20Metadata(address(debtToken)), oracleTokens, collateralFeeds, collateralMaxDelays,
            AggregatorV3Interface(address(debtTokenFeed)), 1 days
        );
        aqua = new Aqua();

        maturity = uint40(block.timestamp + 30 days);
        IERC20[] memory collateral = new IERC20[](3);
        collateral[0] = IERC20(address(weth)); collateral[1] = IERC20(address(wbtc)); collateral[2] = IERC20(address(alt));
        uint16[] memory maxLtvs = new uint16[](3); maxLtvs[0] = 7000; maxLtvs[1] = 6500; maxLtvs[2] = 5000;
        uint16[] memory liqLtvs = new uint16[](3); liqLtvs[0] = 8000; liqLtvs[1] = 7500; liqLtvs[2] = 6000;
        uint40[] memory maturities = new uint40[](1); maturities[0] = maturity;
        string[] memory names = new string[](1); names[0] = "AquaTerm USDT";
        string[] memory symbols = new string[](1); symbols[0] = "USDT-TERM";
        app = new AquaTermApp(IAqua(address(aqua)), IERC20(address(debtToken)), oracle, collateral, maxLtvs, liqLtvs, maturities, names, symbols);

        weth.mint(borrower, 1e18);
        alt.mint(borrower, 1e18);
        debtToken.mint(supplier, 2_000e6);
        vm.prank(borrower); weth.approve(address(app), type(uint256).max);
        vm.prank(borrower); alt.approve(address(app), type(uint256).max);
        vm.prank(supplier); debtToken.approve(address(aqua), type(uint256).max);
    }

    function _ship(address maker, bytes memory strategy, address token, uint256 amount) internal {
        address[] memory tokens = new address[](1); tokens[0] = token;
        uint256[] memory amounts = new uint256[](1); amounts[0] = amount;
        vm.prank(maker);
        aqua.ship(address(app), strategy, tokens, amounts);
    }

    function _shipAndMatch(uint256 face, uint256 spot) internal returns (AquaTermVault vault) {
        return _shipAndMatchWithCollateral(face, spot, 6000, 0);
    }

    function _shipAndMatchWithCollateral(uint256 face, uint256 spot, uint16 ltvBps, uint256 collateralId)
        internal returns (AquaTermVault vault)
    {
        vm.prank(borrower); (uint256 bId,) = app.createBorrowOrder(maturity, uint128(face), uint128(spot), ltvBps, collateralId);
        vm.prank(supplier); (uint256 sId,) = app.createSupplyOrder(maturity, uint128(spot), uint128(face));
        vault = app.vaultForMaturity(maturity);
        vm.prank(borrower); vault.approve(address(aqua), type(uint256).max);
        _ship(borrower, app.borrowStrategyBytes(bId), address(vault), vault.previewDebtShares(face));
        _ship(supplier, app.supplyStrategyBytes(sId), address(debtToken), spot);
        app.matchOrders(bId, sId, face, spot);
    }

    function testMatchUsesRealAquaAndRedeemsThroughERC4626() public {
        AquaTermVault vault = app.vaultForMaturity(maturity);
        _assertEq(vault.totalSupply(), 0, "shares before fill");
        _assertEq(app.totalDebt(borrower), 0, "debt before fill");
        _assertEq(app.depositedCollateral(borrower, 0), 0, "no collateral at order time");
        _assertEq(vault.maxDeposit(supplier), 0, "direct deposits closed");
        vault = _shipAndMatch(FACE, SPOT);
        _assertEq(app.depositedCollateral(borrower, 0), 833_333_334_000_000_000, "collateral pulled JIT");
        _assertEq(weth.balanceOf(borrower), 166_666_666_000_000_000, "only required collateral taken");
        _assertEq(vault.asset(), address(debtToken), "ERC4626 asset");
        _assertEq(vault.balanceOf(supplier), FACE, "supplier receives shares");
        _assertEq(vault.totalAssets(), FACE, "NAV includes receivable");
        _assertEq(vault.maxRedeem(supplier), 0, "locked until maturity");
        _assertEq(debtToken.balanceOf(borrower), SPOT, "borrower receives debt token");
        debtToken.mint(borrower, FACE - SPOT);
        vm.startPrank(borrower); debtToken.approve(address(app), FACE); app.repay(maturity, FACE); vm.stopPrank();
        _assertEq(vault.totalAssets(), FACE, "repayment preserves NAV");
        vm.warp(maturity);
        _assertEq(vault.maxRedeem(supplier), FACE, "fully redeemable");
        vm.prank(supplier); vault.redeem(FACE, supplier, supplier);
        _assertEq(debtToken.balanceOf(supplier), 2_000e6 + 20e6, "supplier earns discount");
    }

    function testFullOrdersPayTermShareSpreadToMatcher() public {
        address matcher = address(0xA11CE);
        uint256 face = 110e6;
        uint256 debtTokenIn = 100e6;
        uint256 supplierMinTerm = 105e6;
        vm.prank(borrower); (uint256 bId,) = app.createBorrowOrder(maturity, uint128(face), uint128(debtTokenIn), 6000, 0);
        vm.prank(supplier); (uint256 sId,) = app.createSupplyOrder(maturity, uint128(debtTokenIn), uint128(supplierMinTerm));
        AquaTermVault vault = app.vaultForMaturity(maturity);
        vm.prank(borrower); vault.approve(address(aqua), type(uint256).max);
        _ship(borrower, app.borrowStrategyBytes(bId), address(vault), vault.previewDebtShares(face));
        _ship(supplier, app.supplyStrategyBytes(sId), address(debtToken), debtTokenIn);

        vm.prank(matcher); app.matchOrders(bId, sId, face, debtTokenIn);

        (,,,,,, uint128 filledFace,) = app.borrowOrders(bId);
        (,,,, uint128 filledDebtToken,) = app.supplyOrders(sId);
        _assertEq(filledFace, face, "borrow order fully closed");
        _assertEq(filledDebtToken, debtTokenIn, "supply order fully closed");
        _assertEq(debtToken.balanceOf(borrower), debtTokenIn, "borrower receives its limit");
        _assertEq(vault.balanceOf(supplier), supplierMinTerm, "supplier receives its limit");
        _assertEq(vault.balanceOf(matcher), face - supplierMinTerm, "matcher receives term-share spread");
    }

    function testFullOrdersPayDebtTokenSpreadToMatcher() public {
        address matcher = address(0xA11CE);
        uint256 face = 105e6;
        uint256 borrowerMinDebtToken = 95e6;
        uint256 debtTokenIn = 100e6;
        vm.prank(borrower); (uint256 bId,) = app.createBorrowOrder(maturity, uint128(face), uint128(borrowerMinDebtToken), 6000, 0);
        vm.prank(supplier); (uint256 sId,) = app.createSupplyOrder(maturity, uint128(debtTokenIn), uint128(face));
        AquaTermVault vault = app.vaultForMaturity(maturity);
        vm.prank(borrower); vault.approve(address(aqua), type(uint256).max);
        _ship(borrower, app.borrowStrategyBytes(bId), address(vault), vault.previewDebtShares(face));
        _ship(supplier, app.supplyStrategyBytes(sId), address(debtToken), debtTokenIn);

        vm.prank(matcher); app.matchOrders(bId, sId, face, debtTokenIn);

        (,,,,,, uint128 filledFace,) = app.borrowOrders(bId);
        (,,,, uint128 filledDebtToken,) = app.supplyOrders(sId);
        _assertEq(filledFace, face, "borrow order fully closed");
        _assertEq(filledDebtToken, debtTokenIn, "supply order fully closed");
        _assertEq(debtToken.balanceOf(borrower), borrowerMinDebtToken, "borrower receives its limit");
        _assertEq(vault.balanceOf(supplier), face, "supplier receives its limit");
        _assertEq(debtToken.balanceOf(matcher), debtTokenIn - borrowerMinDebtToken, "matcher receives debt-token spread");
    }

    function testExistingCollateralNeedsNoAdditionalWalletTransfer() public {
        vm.prank(borrower); app.depositCollateral(0, 1e18);
        _assertEq(weth.balanceOf(borrower), 0, "collateral deposited in advance");
        _shipAndMatch(FACE, SPOT);
        _assertEq(app.depositedCollateral(borrower, 0), 1e18, "existing deposit is enough");
        _assertEq(weth.balanceOf(borrower), 0, "no additional wallet transfer");
    }

    function testPartialDepositPullsOnlyShortfall() public {
        vm.prank(borrower); app.depositCollateral(0, 5e17);
        _shipAndMatch(FACE, SPOT);
        _assertEq(app.depositedCollateral(borrower, 0), 833_333_334_000_000_000, "old and new collateral combined");
        _assertEq(weth.balanceOf(borrower), 166_666_666_000_000_000, "only shortfall taken");
    }

    function testChosenTokenAndProtocolLtvLimit() public {
        wbtc.mint(borrower, 1e6);
        vm.prank(borrower); wbtc.approve(address(app), type(uint256).max);
        _shipAndMatchWithCollateral(FACE, SPOT, 7000, 1);
        _assertEq(app.depositedCollateral(borrower, 0), 0, "WETH left untouched");
        _assertEq(app.depositedCollateral(borrower, 1), 769_231, "WBTC pulled to protocol limit");
        require(app.currentLtv(borrower) <= 6500, "protocol LTV breached");
    }

    function testManualDepositAndWithdrawalStillWork() public {
        vm.startPrank(borrower);
        app.depositCollateral(0, 5e17);
        app.withdrawCollateral(0, 5e17);
        vm.stopPrank();
        _assertEq(app.depositedCollateral(borrower, 0), 0, "manual deposit withdrawn");
        _assertEq(weth.balanceOf(borrower), 1e18, "wallet restored");
    }

    function testCollateralCountIsConfigurable() public {
        _assertEq(app.N_COLLATERAL(), 3, "three configured collateral types");
        vm.startPrank(borrower);
        app.depositCollateral(2, 1e18);
        _assertEq(app.collateralValue(borrower), 2e6, "third collateral is valued");
        app.withdrawCollateral(2, 1e18);
        vm.stopPrank();
        _assertEq(app.depositedCollateral(borrower, 2), 0, "third collateral can be withdrawn");
    }

    function testOverCapacityFillRevertsAtomically() public {
        _shipAndMatch(FACE, SPOT);
        vm.prank(borrower); (uint256 bId,) = app.createBorrowOrder(maturity, 600e6, 576e6, 6000, 0);
        vm.prank(supplier); (uint256 sId,) = app.createSupplyOrder(maturity, 576e6, 600e6);
        AquaTermVault vault = app.vaultForMaturity(maturity);
        _ship(borrower, app.borrowStrategyBytes(bId), address(vault), vault.previewDebtShares(600e6));
        _ship(supplier, app.supplyStrategyBytes(sId), address(debtToken), 576e6);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "INSUFFICIENT_WALLET_COLLATERAL"));
        app.matchOrders(bId, sId, 600e6, 576e6);
        _assertEq(app.totalDebt(borrower), FACE, "failed fill changes no debt");
    }

    function testWriteDownKeepsBorrowerDebtAndRecoveryRestoresNAV() public {
        AquaTermVault vault = _shipAndMatch(FACE, SPOT);
        vm.warp(maturity);
        app.markBadDebt(borrower, maturity, 200e6);
        _assertEq(vault.totalAssets(), 300e6, "write-down lowers NAV");
        _assertEq(vault.badDebt(), 200e6, "loss recorded");
        _assertEq(app.totalDebt(borrower), FACE, "borrower still owes full debt");
        _assertEq(vault.maxRedeem(supplier), 0, "no cash to redeem");
        ethFeed.setAnswer(1000e8);
        btcFeed.setAnswer(100_000e8);
        altFeed.setAnswer(2e8);
        debtTokenFeed.setAnswer(1e8);
        uint256 lockedCollateral = app.depositedCollateral(borrower, 0);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "UNHEALTHY"));
        app.withdrawCollateral(0, lockedCollateral);
        vm.startPrank(borrower); debtToken.approve(address(app), FACE); app.repay(maturity, 200e6); vm.stopPrank();
        _assertEq(vault.totalAssets(), FACE, "late recovery restores NAV");
        _assertEq(vault.badDebt(), 0, "recovered write-down cleared");
    }

    function testHealthyLiquidationRepaysDebtAndTransfersDiscountedCollateral() public {
        AquaTermVault vault = _shipAndMatch(FACE, SPOT);
        ethFeed.setAnswer(400e8);
        address liquidator = address(0x11A);
        uint256 repayAmount = 100e6;
        debtToken.mint(liquidator, repayAmount);
        vm.prank(liquidator); debtToken.approve(address(app), repayAmount);

        uint256 liquidatorWethBefore = weth.balanceOf(liquidator);
        uint256 borrowerCollateralBefore = app.depositedCollateral(borrower, 0);
        vm.prank(liquidator);
        uint256 seized = app.liquidate(borrower, maturity, 0, repayAmount, "");

        _assertEq(app.totalDebt(borrower), FACE - repayAmount, "liquidation reduces borrower debt");
        _assertEq(app.debtByVault(borrower, address(vault)), FACE - repayAmount, "maturity debt reduced");
        _assertEq(vault.totalAssets(), FACE, "cash replaces repaid receivable");
        _assertEq(app.depositedCollateral(borrower, 0), borrowerCollateralBefore - seized, "collateral accounting reduced");
        require(seized != 0 && weth.balanceOf(liquidator) == liquidatorWethBefore + seized, "liquidator receives WETH");
        _assertEq(debtToken.balanceOf(liquidator), 0, "liquidator funds repayment");
    }

    function testBadDebtLossStaysWithLegacySupplierCohort() public {
        uint256 oldFace = 100e6;
        uint256 oldSpot = 98e6;
        AquaTermVault vault = _shipAndMatchWithCollateral(oldFace, oldSpot, 6000, 0);

        // The collateral falls below the amount needed to cover the liquidation at the maximum discount.
        ethFeed.setAnswer(600e8);
        address liquidator = address(0x11A);
        uint256 recovered = 98e6;
        debtToken.mint(liquidator, recovered);
        vm.prank(liquidator); debtToken.approve(address(app), recovered);
        vm.prank(liquidator); app.liquidate(borrower, maturity, 0, recovered, "");

        _assertEq(app.debtByVault(borrower, address(vault)), 2e6, "uncovered residual borrower debt remains");
        _assertEq(app.depositedCollateral(borrower, 0), 0, "liquidation exhausted borrower collateral");
        _assertEq(vault.badDebt(), 2e6, "uncovered debt is written down once");
        _assertEq(vault.totalAssets(), 98e6, "legacy NAV reflects loss");
        _assertEq(vault.balanceOf(supplier), oldFace, "legacy cohort keeps original shares");

        // A later loan is capitalized at the then-current NAV, so its supplier does not inherit the old loss.
        ethFeed.setAnswer(1000e8);
        address laterBorrower = address(0xB022);
        address laterSupplier = address(0x5A112);
        weth.mint(laterBorrower, 1e18);
        debtToken.mint(laterSupplier, 2_000e6);
        vm.prank(laterBorrower); weth.approve(address(app), type(uint256).max);
        vm.prank(laterSupplier); debtToken.approve(address(aqua), type(uint256).max);
        uint256 newFace = 100e6;
        uint256 newSpot = 98e6;
        vm.prank(laterBorrower);
        (uint256 bId,) = app.createBorrowOrder(maturity, uint128(newFace), uint128(newSpot), 6000, 0);
        uint256 newShares = vault.previewDebtShares(newFace);
        vm.prank(laterSupplier);
        (uint256 sId,) = app.createSupplyOrder(maturity, uint128(newSpot), uint128(newShares));
        vm.prank(laterBorrower); vault.approve(address(aqua), type(uint256).max);
        _ship(laterBorrower, app.borrowStrategyBytes(bId), address(vault), newShares);
        _ship(laterSupplier, app.supplyStrategyBytes(sId), address(debtToken), newSpot);
        app.matchOrders(bId, sId, newFace, newSpot);
        _assertEq(vault.balanceOf(laterSupplier), newShares, "late supplier receives NAV-priced shares");
        require(newShares > newFace, "shares account for the prior loss");

        // Repay the performing loan. At maturity each cohort exits against its own share price.
        debtToken.mint(laterBorrower, newFace - newSpot);
        vm.startPrank(laterBorrower);
        debtToken.approve(address(app), newFace);
        app.repay(maturity, newFace);
        vm.stopPrank();
        vm.warp(maturity);
        uint256 oldBalanceBefore = debtToken.balanceOf(supplier);
        vm.prank(supplier);
        vault.redeem(oldFace, supplier, supplier);
        uint256 oldPayout = debtToken.balanceOf(supplier) - oldBalanceBefore;
        uint256 lateBalanceBefore = debtToken.balanceOf(laterSupplier);
        vm.prank(laterSupplier);
        vault.redeem(newShares, laterSupplier, laterSupplier);
        uint256 latePayout = debtToken.balanceOf(laterSupplier) - lateBalanceBefore;
        require(oldPayout >= 98e6 - 2 && oldPayout <= 98e6 + 2, "legacy cohort absorbs bad debt");
        require(latePayout >= 100e6 - 2 && latePayout <= 100e6 + 2, "late cohort exits at par");
    }

    function testChainlinkOracleUsesDecimalsAndUSDTPrice() public {
        _assertEq(oracle.valueInDebtToken(address(weth), 1e18), 1000e6, "WETH value");
        _assertEq(oracle.valueInDebtToken(address(wbtc), 1e8), 100_000e6, "WBTC value");
        debtTokenFeed.setAnswer(8e7);
        _assertEq(oracle.valueInDebtToken(address(weth), 1e18), 1250e6, "USDT depeg conversion");
    }

    function testChainlinkOracleRejectsStaleAndInvalidAnswers() public {
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "STALE_FEED"));
        oracle.valueInDebtToken(address(weth), 1e18);
        ethFeed.setAnswer(-1);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "INVALID_FEED_ANSWER"));
        oracle.valueInDebtToken(address(weth), 1e18);
    }

    function _assertEq(uint256 a, uint256 b, string memory reason) internal pure { require(a == b, reason); }
    function _assertEq(address a, address b, string memory reason) internal pure { require(a == b, reason); }
}
