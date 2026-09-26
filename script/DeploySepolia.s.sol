// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {AquaTermDeployer} from "./AquaTermDeployer.sol";
import {SepoliaConfig} from "./SepoliaConfig.sol";

/// @notice Deploy AquaTerm on Ethereum Sepolia (official 1inch Aqua testnet).
/// @dev Usage:
///   export SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com
///   export PRIVATE_KEY=0x...
///   forge script script/DeploySepolia.s.sol:DeploySepolia --rpc-url sepolia --broadcast -vvvv
contract DeploySepolia is Script {
    function run() external returns (AquaTermDeployer.Deployment memory deployment) {
        require(block.chainid == SepoliaConfig.CHAIN_ID, "WRONG_CHAIN");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        deployment = AquaTermDeployer.deploy(SepoliaConfig.config());
        _log(deployment);

        vm.stopBroadcast();
    }

    function _log(AquaTermDeployer.Deployment memory deployment) internal view {
        console2.log("chainId", block.chainid);
        console2.log("network", "sepolia");
        console2.log("aqua", SepoliaConfig.AQUA);
        console2.log("usdc", SepoliaConfig.USDC);
        console2.log("wbtc", SepoliaConfig.WBTC);
        console2.log("weth", SepoliaConfig.WETH);
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
                ":sepolia:<DEPLOYMENT_BLOCK>:",
                vm.toString(SepoliaConfig.MATURITY_OCT_30_2026),
                ",",
                vm.toString(SepoliaConfig.MATURITY_NOV_30_2026),
                ",",
                vm.toString(SepoliaConfig.MATURITY_DEC_31_2026),
                ",",
                vm.toString(SepoliaConfig.MATURITY_JAN_31_2027)
            )
        );
    }
}
