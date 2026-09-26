// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOracle {
    /// @return USDT value in the debt asset's native units (six decimals for the demo USDT).
    function valueInUSDT(address token, uint256 amount) external view returns (uint256);
}
