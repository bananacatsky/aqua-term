// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "./token/ERC20.sol";
import {IERC20} from "./interfaces/IERC20.sol";

/// @notice One maturity's portfolio. Shares are created solely against loans
/// originated by AquaTermApp, never when virtual Aqua liquidity is posted.
contract AquaTermVault is ERC20 {
    IERC20 public immutable asset;
    address public immutable app;
    uint40 public immutable maturity;
    uint256 public totalDebt;
    uint256 public badDebt;

    modifier onlyApp() { require(msg.sender == app, "ONLY_APP"); _; }

    constructor(IERC20 asset_, address app_, uint40 maturity_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_, 6)
    { asset = asset_; app = app_; maturity = maturity_; }

    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this)) + totalDebt - badDebt;
    }

    function mintDebtShares(address receiver, uint256 faceAmount) external onlyApp {
        totalDebt += faceAmount;
        _mint(receiver, faceAmount);
    }

    function recordRepayment(uint256 amount) external onlyApp {
        totalDebt -= amount;
    }

    function writeDown(uint256 amount) external onlyApp {
        require(amount <= totalDebt - badDebt, "BAD_DEBT_EXCEEDS_PERFORMING");
        badDebt += amount;
    }

    /// @notice ERC-4626-like redemption at post-maturity NAV. Losses are shared pro rata.
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        require(block.timestamp >= maturity, "NOT_MATURED");
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender];
            require(allowed >= shares, "ERC20: insufficient allowance");
            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }
        uint256 supply = totalSupply;
        require(supply != 0, "NO_SHARES");
        assets = shares * totalAssets() / supply;
        require(asset.balanceOf(address(this)) >= assets, "INSUFFICIENT_CASH");
        _burn(owner, shares);
        require(asset.transfer(receiver, assets), "ASSET_TRANSFER_FAILED");
    }
}
