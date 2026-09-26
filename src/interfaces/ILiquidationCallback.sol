// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILiquidationCallback {
    function onAquaTermLiquidation(
        address borrower,
        uint40 maturity,
        uint256 collateralId,
        uint256 debtAmount,
        uint256 collateralAmount,
        bytes calldata data
    ) external;
}
