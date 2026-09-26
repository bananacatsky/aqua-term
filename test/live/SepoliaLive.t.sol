// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {AquaTermApp} from "../../src/AquaTermApp.sol";
import {AquaTermVault} from "../../src/AquaTermVault.sol";
import {AquaTermDeployer} from "../../script/AquaTermDeployer.sol";
import {SepoliaConfig} from "../../script/SepoliaConfig.sol";

interface IWETH {
    function deposit() external payable;
}

/// @notice Live Sepolia integration test: deploy AquaTerm and run one matched trade.
/// @dev Skipped unless explicitly enabled. Never run via plain `forge test`.
///
/// Prerequisites on deployer (PRIVATE_KEY in .env):
///   - Sepolia ETH (~0.05) for gas + 0.015 ETH wrapped to WETH
///   - Sepolia USDC (>= 4.8 USDC) from https://faucet.circle.com
///
/// Run (simulation on Sepolia fork):
///   AQUATERM_SEPOLIA_LIVE=1 forge test --match-path test/live/SepoliaLive.t.sol \
///     --fork-url sepolia -vvv
///
/// Real on-chain run (this Foundry build has no `forge test --broadcast`):
///   AQUATERM_SEPOLIA_LIVE=1 forge script script/SepoliaLive.s.sol:SepoliaLive \
///     --rpc-url sepolia --broadcast -vvvv
contract SepoliaLiveTest is Test {
    uint256 internal constant FACE = 5_000_000; // 5 USDC
    uint256 internal constant SPOT = 4_800_000; // 4.8 USDC
    uint256 internal constant WETH_DEPOSIT = 0.015 ether;

    function setUp() public {
        if (_envFlag("AQUATERM_SEPOLIA_LIVE") != 1) {
            vm.skip(true);
        }
        if (block.chainid != SepoliaConfig.CHAIN_ID) {
            revert("SepoliaLiveTest requires --rpc-url sepolia (chain 11155111)");
        }
    }

    function test_deployAndMatchOnLiveSepolia() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        AquaTermDeployer.Deployment memory deployment = AquaTermDeployer.deploy(SepoliaConfig.config());
        AquaTermApp app = deployment.app;
        uint40 maturity = SepoliaConfig.MATURITY_OCT_30_2026;
        AquaTermVault vault = app.vaultForMaturity(maturity);

        assertGt(deployment.oracle.valueInDebtToken(SepoliaConfig.WETH, 1e18), 0, "WETH oracle");
        assertGt(deployment.oracle.valueInDebtToken(SepoliaConfig.WBTC, 1e8), 0, "WBTC oracle");

        IWETH(SepoliaConfig.WETH).deposit{value: WETH_DEPOSIT}();

        IERC20 usdc = IERC20(SepoliaConfig.USDC);
        IERC20 weth = IERC20(SepoliaConfig.WETH);
        require(
            usdc.balanceOf(deployer) >= SPOT,
            "deployer needs >= 4.8 USDC on Sepolia (faucet.circle.com)"
        );

        weth.approve(address(app), type(uint256).max);
        usdc.approve(SepoliaConfig.AQUA, type(uint256).max);
        vault.approve(SepoliaConfig.AQUA, type(uint256).max);

        (uint256 borrowOrderId,) =
            app.createBorrowOrder(maturity, uint128(FACE), uint128(SPOT), 7000, 1, maturity);
        (uint256 supplyOrderId,) =
            app.createSupplyOrder(maturity, uint128(SPOT), uint128(FACE), maturity);

        IAqua aqua = IAqua(SepoliaConfig.AQUA);
        uint256 termShares = vault.previewDebtShares(FACE);
        _ship(aqua, address(app), app.borrowStrategyBytes(borrowOrderId), address(vault), termShares);
        _ship(aqua, address(app), app.supplyStrategyBytes(supplyOrderId), address(usdc), SPOT);

        app.matchOrders(borrowOrderId, supplyOrderId, FACE, SPOT);

        vm.stopBroadcast();

        assertEq(app.totalDebt(deployer), FACE, "borrower debt");
        assertEq(vault.balanceOf(deployer), FACE, "supplier vault shares");
        assertGt(app.depositedCollateral(deployer, 1), 0, "WETH collateral pulled");
        assertEq(vault.totalAssets(), FACE, "vault NAV");

        emit log_named_address("AquaTermApp", address(app));
        emit log_named_address("ChainlinkOracle", address(deployment.oracle));
        emit log_named_uint("AQUATERM_APPS maturity[0]", maturity);
    }

    function _ship(IAqua aqua, address app, bytes memory strategy, address token, uint256 amount) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        aqua.ship(app, strategy, tokens, amounts);
    }

    function _envFlag(string memory name) private view returns (uint256) {
        try vm.envUint(name) returns (uint256 value) {
            return value;
        } catch {
            return 0;
        }
    }
}
