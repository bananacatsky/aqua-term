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
    MockERC20 internal usdt;
    MockERC20 internal weth;
    MockERC20 internal wbtc;
    MockChainlinkFeed internal ethFeed;
    MockChainlinkFeed internal btcFeed;
    MockChainlinkFeed internal usdtFeed;
    ChainlinkOracle internal oracle;
    Aqua internal aqua;
    AquaTermApp internal app;
    uint40 internal maturity;

    uint256 internal constant FACE = 500e6;
    uint256 internal constant SPOT = 480e6;

    function setUp() public {
        usdt = new MockERC20("USDT", "USDT", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
        ethFeed = new MockChainlinkFeed(8, 1000e8);
        btcFeed = new MockChainlinkFeed(8, 100_000e8);
        usdtFeed = new MockChainlinkFeed(8, 1e8);

        IERC20Metadata[2] memory oracleTokens = [IERC20Metadata(address(weth)), IERC20Metadata(address(wbtc))];
        AggregatorV3Interface[3] memory feeds = [
            AggregatorV3Interface(address(ethFeed)),
            AggregatorV3Interface(address(btcFeed)),
            AggregatorV3Interface(address(usdtFeed))
        ];
        uint32[3] memory maxDelays = [uint32(1 days), uint32(1 days), uint32(1 days)];
        oracle = new ChainlinkOracle(IERC20Metadata(address(usdt)), oracleTokens, feeds, maxDelays);
        aqua = new Aqua();

        maturity = uint40(block.timestamp + 30 days);
        IERC20[2] memory collateral = [IERC20(address(weth)), IERC20(address(wbtc))];
        uint16[2] memory maxLtvs = [uint16(7000), uint16(6500)];
        uint16[2] memory liqLtvs = [uint16(8000), uint16(7500)];
        uint40[] memory maturities = new uint40[](1); maturities[0] = maturity;
        string[] memory names = new string[](1); names[0] = "AquaTerm USDT";
        string[] memory symbols = new string[](1); symbols[0] = "USDT-TERM";
        app = new AquaTermApp(IAqua(address(aqua)), IERC20(address(usdt)), oracle, collateral, maxLtvs, liqLtvs, maturities, names, symbols);

        weth.mint(borrower, 1e18);
        usdt.mint(supplier, 2_000e6);
        vm.prank(borrower); weth.approve(address(app), type(uint256).max);
        vm.prank(supplier); usdt.approve(address(aqua), type(uint256).max);
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

    function _shipAndMatchWithCollateral(uint256 face, uint256 spot, uint16 ltvBps, uint8 collateralId)
        internal returns (AquaTermVault vault)
    {
        vm.prank(borrower); (uint256 bId,) = app.createBorrowOrder(maturity, uint128(face), uint128(spot), ltvBps, collateralId);
        vm.prank(supplier); (uint256 sId,) = app.createSupplyOrder(maturity, uint128(spot), uint128(face));
        vault = app.vaultForMaturity(maturity);
        vm.prank(borrower); vault.approve(address(aqua), type(uint256).max);
        _ship(borrower, app.borrowStrategyBytes(bId), address(vault), face);
        _ship(supplier, app.supplyStrategyBytes(sId), address(usdt), spot);
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
        _assertEq(vault.asset(), address(usdt), "ERC4626 asset");
        _assertEq(vault.balanceOf(supplier), FACE, "supplier receives shares");
        _assertEq(vault.totalAssets(), FACE, "NAV includes receivable");
        _assertEq(vault.maxRedeem(supplier), 0, "locked until maturity");
        _assertEq(usdt.balanceOf(borrower), SPOT, "borrower receives spot USDT");
        usdt.mint(borrower, FACE - SPOT);
        vm.startPrank(borrower); usdt.approve(address(app), FACE); app.repay(maturity, FACE); vm.stopPrank();
        _assertEq(vault.totalAssets(), FACE, "repayment preserves NAV");
        vm.warp(maturity);
        _assertEq(vault.maxRedeem(supplier), FACE, "fully redeemable");
        vm.prank(supplier); vault.redeem(FACE, supplier, supplier);
        _assertEq(usdt.balanceOf(supplier), 2_000e6 + 20e6, "supplier earns discount");
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

    function testOverCapacityFillRevertsAtomically() public {
        _shipAndMatch(FACE, SPOT);
        vm.prank(borrower); (uint256 bId,) = app.createBorrowOrder(maturity, 600e6, 576e6, 6000, 0);
        vm.prank(supplier); (uint256 sId,) = app.createSupplyOrder(maturity, 576e6, 600e6);
        AquaTermVault vault = app.vaultForMaturity(maturity);
        _ship(borrower, app.borrowStrategyBytes(bId), address(vault), 600e6);
        _ship(supplier, app.supplyStrategyBytes(sId), address(usdt), 576e6);
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
        usdtFeed.setAnswer(1e8);
        uint256 lockedCollateral = app.depositedCollateral(borrower, 0);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "UNHEALTHY"));
        app.withdrawCollateral(0, lockedCollateral);
        vm.startPrank(borrower); usdt.approve(address(app), FACE); app.repay(maturity, 200e6); vm.stopPrank();
        _assertEq(vault.totalAssets(), FACE, "late recovery restores NAV");
        _assertEq(vault.badDebt(), 0, "recovered write-down cleared");
    }

    function testChainlinkOracleUsesDecimalsAndUSDTPrice() public {
        _assertEq(oracle.valueInUSDT(address(weth), 1e18), 1000e6, "WETH value");
        _assertEq(oracle.valueInUSDT(address(wbtc), 1e8), 100_000e6, "WBTC value");
        usdtFeed.setAnswer(8e7);
        _assertEq(oracle.valueInUSDT(address(weth), 1e18), 1250e6, "USDT depeg conversion");
    }

    function testChainlinkOracleRejectsStaleAndInvalidAnswers() public {
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "STALE_FEED"));
        oracle.valueInUSDT(address(weth), 1e18);
        ethFeed.setAnswer(-1);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "INVALID_FEED_ANSWER"));
        oracle.valueInUSDT(address(weth), 1e18);
    }

    function _assertEq(uint256 a, uint256 b, string memory reason) internal pure { require(a == b, reason); }
    function _assertEq(address a, address b, string memory reason) internal pure { require(a == b, reason); }
}
