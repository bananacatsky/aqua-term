// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice A fixed-maturity claim on cash and performing loans.
/// @dev Shares originate only when the app fills a loan; ordinary deposits are disabled.
contract AquaTermVault is ERC4626 {
    address public immutable app;
    uint40 public immutable maturity;
    uint256 public totalDebt;
    uint256 public badDebt;

    modifier onlyApp() {
        require(msg.sender == app, "ONLY_APP");
        _;
    }

    constructor(IERC20 asset_, address app_, uint40 maturity_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(asset_)
    {
        require(app_ != address(0), "ZERO_APP");
        app = app_;
        maturity = maturity_;
    }

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + totalDebt - badDebt;
    }

    function maxDeposit(address) public pure override returns (uint256) { return 0; }
    function maxMint(address) public pure override returns (uint256) { return 0; }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(owner), IERC20(asset()).balanceOf(address(this)));
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 ownerShares = balanceOf(owner);
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        if (previewRedeem(ownerShares) <= cash) return ownerShares;
        return convertToShares(cash);
    }

    /// @notice Preview the number of shares representing a new performing debt receivable at current NAV.
    function previewDebtShares(uint256 faceAmount) public view returns (uint256) {
        return convertToShares(faceAmount);
    }

    function mintDebtShares(address receiver, uint256 faceAmount) external onlyApp returns (uint256 shares) {
        require(block.timestamp < maturity, "MATURED");
        shares = previewDebtShares(faceAmount);
        require(shares != 0, "ZERO_DEBT_SHARES");
        totalDebt += faceAmount;
        _mint(receiver, shares);
    }

    function recordRepayment(uint256 amount, uint256 recoveredBadDebt) external onlyApp {
        require(recoveredBadDebt <= amount && recoveredBadDebt <= badDebt, "BAD_RECOVERY");
        totalDebt -= amount;
        badDebt -= recoveredBadDebt;
    }

    function writeDown(uint256 amount) external onlyApp {
        require(amount <= totalDebt - badDebt, "BAD_DEBT_EXCEEDS_PERFORMING");
        badDebt += amount;
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal override
    {
        require(assets <= IERC20(asset()).balanceOf(address(this)), "INSUFFICIENT_CASH");
        super._withdraw(caller, receiver, owner, assets, shares);
    }
}
