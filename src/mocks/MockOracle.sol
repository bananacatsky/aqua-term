// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IOracle} from "../interfaces/IOracle.sol";
contract MockOracle is IOracle {
    mapping(address => uint256) public priceWad; // USDT-native units per whole token, scaled 1e18
    mapping(address => uint8) public decimals;
    function setPrice(address token, uint8 tokenDecimals, uint256 priceWad_) external { decimals[token] = tokenDecimals; priceWad[token] = priceWad_; }
    function valueInUSDT(address token, uint256 amount) external view returns (uint256) { return amount * priceWad[token] / (10 ** decimals[token]) / 1e18; }
}
