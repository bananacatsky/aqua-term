// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AquaTermApp} from "../src/AquaTermApp.sol";
import {AquaTermVault} from "../src/AquaTermVault.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";
import {MockAqua} from "../src/mocks/MockAqua.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IAqua} from "../src/interfaces/IAqua.sol";

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
    MockOracle internal oracle;
    MockAqua internal aqua;
    AquaTermApp internal app;
    uint40 internal maturity;

    uint256 internal constant FACE = 500e6;
    uint256 internal constant SPOT = 480e6;

    function setUp() public {
        usdt = new MockERC20("USDT", "USDT", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
        oracle = new MockOracle(); aqua = new MockAqua();
        oracle.setPrice(address(weth), 18, 1000e6 * 1e18);
        oracle.setPrice(address(wbtc), 8, 100_000e6 * 1e18);
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
        vm.startPrank(borrower); weth.approve(address(app), type(uint256).max); app.depositCollateral(0, 1e18); vm.stopPrank();
        vm.prank(supplier); usdt.approve(address(aqua), type(uint256).max);
    }

    function _shipAndMatch(uint256 face, uint256 spot) internal returns (AquaTermVault vault) {
        vm.prank(borrower); (uint256 bId,) = app.createBorrowOrder(maturity, uint128(face), uint128(spot), 6000);
        vm.prank(supplier); (uint256 sId,) = app.createSupplyOrder(maturity, uint128(spot), uint128(face));
        vault = app.vaultForMaturity(maturity);
        vm.startPrank(borrower);
        vault.approve(address(aqua), type(uint256).max);
        aqua.ship(address(app), app.borrowStrategyHash(bId), address(vault), face);
        vm.stopPrank();
        vm.prank(supplier); aqua.ship(address(app), app.supplyStrategyHash(sId), address(usdt), spot);
        app.matchOrders(bId, sId, face, spot);
    }

    function testMatchMaterializesDebtOnlyOnFillAndRepaysAtPar() public {
        AquaTermVault vault = app.vaultForMaturity(maturity);
        _assertEq(vault.totalSupply(), 0, "shares before fill");
        _assertEq(app.totalDebt(borrower), 0, "debt before fill");
        vault = _shipAndMatch(FACE, SPOT);
        _assertEq(vault.balanceOf(supplier), FACE, "supplier gets term shares");
        _assertEq(usdt.balanceOf(borrower), SPOT, "borrower gets discounted spot");
        _assertEq(app.totalDebt(borrower), FACE, "face debt recorded");
        _assertEq(vault.totalAssets(), FACE, "NAV includes performing receivable");
        usdt.mint(borrower, FACE - SPOT);
        vm.startPrank(borrower); usdt.approve(address(app), FACE); app.repay(maturity, FACE); vm.stopPrank();
        _assertEq(vault.totalAssets(), FACE, "repayment changes debt into cash without NAV change");
        vm.warp(maturity);
        vm.prank(supplier); vault.redeem(FACE, supplier, supplier);
        _assertEq(usdt.balanceOf(supplier), 2_000e6 + 20e6, "supplier earns fixed discount");
    }

    function testMultipleVirtualQuotesShareCapacityAndOverCapacityFillReverts() public {
        _shipAndMatch(FACE, SPOT);
        vm.prank(borrower); (uint256 bId,) = app.createBorrowOrder(maturity, 600e6, 576e6, 6000);
        vm.prank(supplier); (uint256 sId,) = app.createSupplyOrder(maturity, 576e6, 600e6);
        AquaTermVault vault = app.vaultForMaturity(maturity);
        vm.startPrank(borrower); aqua.ship(address(app), app.borrowStrategyHash(bId), address(vault), 600e6); vm.stopPrank();
        vm.prank(supplier); aqua.ship(address(app), app.supplyStrategyHash(sId), address(usdt), 576e6);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "BORROWER_LTV"));
        app.matchOrders(bId, sId, 600e6, 576e6);
        _assertEq(app.totalDebt(borrower), FACE, "failed second fill changes no debt");
    }

    function testMaturedBadDebtLowersShareNAV() public {
        AquaTermVault vault = _shipAndMatch(FACE, SPOT);
        vm.warp(maturity);
        app.markBadDebt(borrower, maturity, 200e6);
        _assertEq(vault.totalAssets(), 300e6, "loss lowers NAV");
        _assertEq(vault.badDebt(), 200e6, "write-down tracked");
    }

    function _assertEq(uint256 a, uint256 b, string memory reason) internal pure {
        require(a == b, reason);
    }
}
