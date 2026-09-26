// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The small Aqua surface used by the MVP. `ship` is virtual accounting;
/// `pull` consumes it and transfers the actual ERC-20 during settlement.
interface IAqua {
    function ship(address app, bytes32 strategy, address token, uint256 amount) external;
    function pull(address maker, bytes32 strategy, address token, uint256 amount, address to) external;
}
