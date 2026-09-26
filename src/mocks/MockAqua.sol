// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IAqua} from "../interfaces/IAqua.sol";
import {IERC20} from "../interfaces/IERC20.sol";
contract MockAqua is IAqua {
    mapping(address => mapping(address => mapping(bytes32 => mapping(address => uint256)))) public virtualBalance;
    function ship(address app, bytes32 strategy, address token, uint256 amount) external { virtualBalance[msg.sender][app][strategy][token] += amount; }
    function pull(address maker, bytes32 strategy, address token, uint256 amount, address to) external {
        uint256 available = virtualBalance[maker][msg.sender][strategy][token];
        require(available >= amount, "AQUA_INSUFFICIENT_VIRTUAL_BALANCE");
        virtualBalance[maker][msg.sender][strategy][token] = available - amount;
        require(IERC20(token).transferFrom(maker, to, amount), "AQUA_TRANSFER_FAILED");
    }
}
