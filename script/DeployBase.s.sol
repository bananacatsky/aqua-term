// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {AquaTermDeployer} from "./AquaTermDeployer.sol";
import {BaseConfig} from "./BaseConfig.sol";

/// @notice Deploy AquaTerm on Base with USDC debt and WBTC + WETH collateral.
/// @dev Usage:
///   export BASE_RPC_URL=https://mainnet.base.org
///   export PRIVATE_KEY=0x...
///   forge script script/DeployBase.s.sol:DeployBase --rpc-url base --broadcast -vvvv
contract DeployBase is Script {
    function run() external returns (AquaTermDeployer.Deployment memory deployment) {
        require(block.chainid == BaseConfig.CHAIN_ID, "WRONG_CHAIN");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        deployment = AquaTermDeployer.deploy(BaseConfig.config());
        _log(deployment);

        vm.stopBroadcast();
    }

    function _log(AquaTermDeployer.Deployment memory deployment) internal view {
        console2.log("chainId", block.chainid);
        console2.log("network", "base");
        console2.log("aqua", BaseConfig.AQUA);
        console2.log("usdc", BaseConfig.USDC);
        console2.log("wbtc", BaseConfig.WBTC);
        console2.log("weth", BaseConfig.WETH);
        console2.log("oracle", address(deployment.oracle));
        console2.log("app", address(deployment.app));
        console2.log("vaultOct30", address(deployment.vaultOct30));
        console2.log("vaultNov30", address(deployment.vaultNov30));
        console2.log("vaultDec31", address(deployment.vaultDec31));
        console2.log("vaultJan31", address(deployment.vaultJan31));
        console2.log("");
        console2.log("AQUATERM_APPS env (fill deployment block after broadcast):");
        console2.log(
            string.concat(
                vm.toString(address(deployment.app)),
                ":base:<DEPLOYMENT_BLOCK>:",
                vm.toString(BaseConfig.MATURITY_OCT_30_2026),
                ",",
                vm.toString(BaseConfig.MATURITY_NOV_30_2026),
                ",",
                vm.toString(BaseConfig.MATURITY_DEC_31_2026),
                ",",
                vm.toString(BaseConfig.MATURITY_JAN_31_2027)
            )
        );
    }
}
