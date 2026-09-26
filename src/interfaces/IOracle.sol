// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOracle {
    /// @return Value in the debt token's native units.
    function valueInDebtToken(address token, uint256 amount) external view returns (uint256);
}
