// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {AquaApp} from "@1inch/aqua/src/AquaApp.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {AquaTermVault} from "./AquaTermVault.sol";

/// @notice Fixed-maturity borrowing app backed by Aqua virtual balances.
/// Aqua holds virtual order capacity; this contract only creates debt on a match.
contract AquaTermApp is AquaApp, ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    IERC20 public immutable usdt;
    IOracle public immutable oracle;

    struct CollateralConfig { IERC20 token; uint16 maxBorrowLtvBps; uint16 liquidationLtvBps; }
    CollateralConfig[2] public collateralConfigs;
    mapping(uint40 => AquaTermVault) public vaultForMaturity;
    mapping(address => mapping(uint8 => uint256)) public depositedCollateral;
    mapping(address => mapping(address => uint256)) public debtByVault;
    mapping(address => mapping(address => uint256)) public writtenDownByVault;
    mapping(address => uint256) public totalDebt;

    struct BorrowOrder {
        address borrower; uint40 maturity; uint128 faceAmount; uint128 minUsdtOut;
        uint16 ltvBps; uint8 collateralId; uint128 filledFace; bool cancelled;
    }
    struct SupplyOrder {
        address supplier; uint40 maturity; uint128 usdtIn; uint128 minTermOut;
        uint128 filledUsdt; bool cancelled;
    }
    uint256 public nextBorrowOrderId;
    uint256 public nextSupplyOrderId;
    mapping(uint256 => BorrowOrder) public borrowOrders;
    mapping(uint256 => SupplyOrder) public supplyOrders;

    event BorrowOrderCreated(uint256 indexed orderId, address indexed borrower, uint40 maturity, uint256 faceAmount, uint256 minUsdtOut, uint256 ltvBps, uint8 collateralId);
    event CollateralPulled(address indexed borrower, uint8 indexed collateralId, uint256 amount);
    event SupplyOrderCreated(uint256 indexed orderId, address indexed supplier, uint40 maturity, uint256 usdtIn, uint256 minTermOut);
    event OrdersMatched(uint256 indexed borrowOrderId, uint256 indexed supplyOrderId, uint256 faceAmount, uint256 usdtAmount);
    event BadDebtMarked(address indexed borrower, uint40 indexed maturity, uint256 amount);

    constructor(
        IAqua aqua_, IERC20 usdt_, IOracle oracle_, IERC20[2] memory collateralTokens,
        uint16[2] memory maxBorrowLtvs, uint16[2] memory liquidationLtvs,
        uint40[] memory maturities, string[] memory names, string[] memory symbols
    ) AquaApp(aqua_) {
        require(maturities.length == names.length && maturities.length == symbols.length, "BAD_MATURITY_CONFIG");
        usdt = usdt_; oracle = oracle_;
        for (uint256 i; i < 2; ++i) {
            require(maxBorrowLtvs[i] != 0 && maxBorrowLtvs[i] < liquidationLtvs[i] && liquidationLtvs[i] <= BPS, "BAD_LTV_CONFIG");
            collateralConfigs[i] = CollateralConfig(collateralTokens[i], maxBorrowLtvs[i], liquidationLtvs[i]);
        }
        for (uint256 i; i < maturities.length; ++i) {
            require(address(vaultForMaturity[maturities[i]]) == address(0), "DUPLICATE_MATURITY");
            vaultForMaturity[maturities[i]] = new AquaTermVault(usdt_, address(this), maturities[i], names[i], symbols[i]);
        }
    }

    function depositCollateral(uint8 collateralId, uint256 amount) external nonReentrant {
        require(collateralId < 2, "BAD_COLLATERAL");
        IERC20 token = collateralConfigs[collateralId].token;
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        require(token.balanceOf(address(this)) - beforeBalance == amount, "FEE_ON_TRANSFER_COLLATERAL");
        depositedCollateral[msg.sender][collateralId] += amount;
    }

    function withdrawCollateral(uint8 collateralId, uint256 amount) external nonReentrant {
        require(collateralId < 2 && depositedCollateral[msg.sender][collateralId] >= amount, "INSUFFICIENT_COLLATERAL");
        depositedCollateral[msg.sender][collateralId] -= amount;
        require(healthFactor(msg.sender) >= WAD, "UNHEALTHY");
        collateralConfigs[collateralId].token.safeTransfer(msg.sender, amount);
    }

    function collateralValue(address borrower) public view returns (uint256 value) {
        for (uint8 i; i < 2; ++i) value += oracle.valueInUSDT(address(collateralConfigs[i].token), depositedCollateral[borrower][i]);
    }

    function portfolioWeightedMaxBorrowLtv(address borrower) public view returns (uint256) {
        uint256 value; uint256 weighted;
        for (uint8 i; i < 2; ++i) { uint256 v = oracle.valueInUSDT(address(collateralConfigs[i].token), depositedCollateral[borrower][i]); value += v; weighted += v * collateralConfigs[i].maxBorrowLtvBps; }
        return value == 0 ? 0 : weighted / value;
    }

    function portfolioWeightedLiquidationLtv(address borrower) public view returns (uint256) {
        uint256 value; uint256 weighted;
        for (uint8 i; i < 2; ++i) { uint256 v = oracle.valueInUSDT(address(collateralConfigs[i].token), depositedCollateral[borrower][i]); value += v; weighted += v * collateralConfigs[i].liquidationLtvBps; }
        return value == 0 ? 0 : weighted / value;
    }

    function healthFactor(address borrower) public view returns (uint256) {
        uint256 debt = totalDebt[borrower];
        if (debt == 0) return type(uint256).max;
        return collateralValue(borrower) * portfolioWeightedLiquidationLtv(borrower) * WAD / BPS / debt;
    }

    function currentLtv(address borrower) public view returns (uint256) {
        uint256 value = collateralValue(borrower);
        return value == 0 ? (totalDebt[borrower] == 0 ? 0 : type(uint256).max) : totalDebt[borrower] * BPS / value;
    }

    function createBorrowOrder(uint40 maturity, uint128 faceAmount, uint128 minUsdtOut, uint16 ltvBps, uint8 collateralId) external returns (uint256 orderId, bytes32 strategyHash) {
        require(address(vaultForMaturity[maturity]) != address(0), "UNSUPPORTED_MATURITY");
        require(faceAmount != 0 && minUsdtOut != 0, "ZERO_ORDER");
        require(ltvBps != 0 && ltvBps <= BPS, "BAD_ORDER_LTV");
        require(collateralId < 2, "BAD_COLLATERAL");
        orderId = nextBorrowOrderId++;
        borrowOrders[orderId] = BorrowOrder(msg.sender, maturity, faceAmount, minUsdtOut, ltvBps, collateralId, 0, false);
        strategyHash = borrowStrategyHash(orderId);
        emit BorrowOrderCreated(orderId, msg.sender, maturity, faceAmount, minUsdtOut, ltvBps, collateralId);
    }

    function createSupplyOrder(uint40 maturity, uint128 usdtIn, uint128 minTermOut) external returns (uint256 orderId, bytes32 strategyHash) {
        require(address(vaultForMaturity[maturity]) != address(0), "UNSUPPORTED_MATURITY");
        require(usdtIn != 0 && minTermOut != 0, "ZERO_ORDER");
        orderId = nextSupplyOrderId++;
        supplyOrders[orderId] = SupplyOrder(msg.sender, maturity, usdtIn, minTermOut, 0, false);
        strategyHash = supplyStrategyHash(orderId);
        emit SupplyOrderCreated(orderId, msg.sender, maturity, usdtIn, minTermOut);
    }

    function cancelBorrowOrder(uint256 id) external { require(borrowOrders[id].borrower == msg.sender, "NOT_BORROWER"); borrowOrders[id].cancelled = true; }
    function cancelSupplyOrder(uint256 id) external { require(supplyOrders[id].supplier == msg.sender, "NOT_SUPPLIER"); supplyOrders[id].cancelled = true; }

    function matchOrders(uint256 borrowOrderId, uint256 supplyOrderId, uint256 faceAmount, uint256 usdtAmount) external nonReentrant {
        BorrowOrder storage b = borrowOrders[borrowOrderId]; SupplyOrder storage s = supplyOrders[supplyOrderId];
        require(!b.cancelled && !s.cancelled, "CANCELLED");
        require(b.maturity == s.maturity && block.timestamp < b.maturity, "BAD_MATURITY");
        require(faceAmount != 0 && usdtAmount != 0, "ZERO_FILL");
        require(faceAmount <= uint256(b.faceAmount) - b.filledFace, "BORROW_OVERFILL");
        require(usdtAmount <= uint256(s.usdtIn) - s.filledUsdt, "SUPPLY_OVERFILL");
        require(usdtAmount >= uint256(b.minUsdtOut) * faceAmount / b.faceAmount, "BORROW_PRICE");
        require(faceAmount >= uint256(s.minTermOut) * usdtAmount / s.usdtIn, "SUPPLY_PRICE");
        uint256 newDebt = totalDebt[b.borrower] + faceAmount;
        _topUpCollateral(b.borrower, b.collateralId, b.ltvBps, newDebt);
        AquaTermVault vault = vaultForMaturity[b.maturity];
        totalDebt[b.borrower] = newDebt;
        debtByVault[b.borrower][address(vault)] += faceAmount;
        vault.mintDebtShares(b.borrower, faceAmount);
        AQUA.pull(b.borrower, borrowStrategyHash(borrowOrderId), address(vault), faceAmount, s.supplier);
        AQUA.pull(s.supplier, supplyStrategyHash(supplyOrderId), address(usdt), usdtAmount, b.borrower);
        b.filledFace += uint128(faceAmount); s.filledUsdt += uint128(usdtAmount);
        emit OrdersMatched(borrowOrderId, supplyOrderId, faceAmount, usdtAmount);
    }

    /// @dev Use existing deposited collateral first; pull only the shortfall from the chosen wallet token.
    function _topUpCollateral(address borrower, uint8 collateralId, uint16 orderLtvBps, uint256 newDebt) internal {
        (uint256 value, uint256 weightedCapacity) = _collateralState(borrower);
        uint256 debtBps = newDebt * BPS;
        uint256 minTotalValue = Math.ceilDiv(debtBps, orderLtvBps);
        uint256 valueNeededForOrder = minTotalValue > value ? minTotalValue - value : 0;
        uint256 valueNeededForProtocol = debtBps > weightedCapacity
            ? Math.ceilDiv(debtBps - weightedCapacity, collateralConfigs[collateralId].maxBorrowLtvBps)
            : 0;
        uint256 valueNeeded = Math.max(valueNeededForOrder, valueNeededForProtocol);
        if (valueNeeded != 0) _pullCollateral(borrower, collateralId, valueNeeded);

        (uint256 finalValue, uint256 finalCapacity) = _collateralState(borrower);
        require(debtBps <= finalValue * orderLtvBps, "BORROWER_LTV");
        require(debtBps <= finalCapacity, "PROTOCOL_LTV");
    }

    function _collateralState(address borrower) internal view returns (uint256 value, uint256 weightedCapacity) {
        for (uint8 i; i < 2; ++i) {
            uint256 tokenValue = oracle.valueInUSDT(address(collateralConfigs[i].token), depositedCollateral[borrower][i]);
            value += tokenValue;
            weightedCapacity += tokenValue * collateralConfigs[i].maxBorrowLtvBps;
        }
    }

    function _pullCollateral(address borrower, uint8 collateralId, uint256 valueNeeded) internal {
        IERC20 token = collateralConfigs[collateralId].token;
        uint8 decimals = IERC20Metadata(address(token)).decimals();
        require(decimals <= 18, "COLLATERAL_DECIMALS");
        uint256 unit = 10 ** decimals;
        uint256 unitValue = oracle.valueInUSDT(address(token), unit);
        require(unitValue != 0, "COLLATERAL_VALUE_ZERO");
        uint256 amount = Math.mulDiv(valueNeeded, unit, unitValue, Math.Rounding.Ceil);
        require(token.balanceOf(borrower) >= amount, "INSUFFICIENT_WALLET_COLLATERAL");
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(borrower, address(this), amount);
        require(token.balanceOf(address(this)) - beforeBalance == amount, "FEE_ON_TRANSFER_COLLATERAL");
        depositedCollateral[borrower][collateralId] += amount;
        emit CollateralPulled(borrower, collateralId, amount);
    }

    function repay(uint40 maturity, uint256 amount) external nonReentrant {
        AquaTermVault vault = vaultForMaturity[maturity]; require(address(vault) != address(0), "UNSUPPORTED_MATURITY");
        uint256 debt = debtByVault[msg.sender][address(vault)]; require(amount != 0 && amount <= debt, "TOO_MUCH");
        debtByVault[msg.sender][address(vault)] = debt - amount; totalDebt[msg.sender] -= amount;
        uint256 writtenDown = writtenDownByVault[msg.sender][address(vault)];
        uint256 recovered = amount < writtenDown ? amount : writtenDown;
        writtenDownByVault[msg.sender][address(vault)] = writtenDown - recovered;
        usdt.safeTransferFrom(msg.sender, address(vault), amount);
        vault.recordRepayment(amount, recovered);
    }

    /// @notice Permissionless maturity write-down. The borrower still owes the debt and collateral stays locked.
    function markBadDebt(address borrower, uint40 maturity, uint256 amount) external nonReentrant {
        AquaTermVault vault = vaultForMaturity[maturity]; require(address(vault) != address(0), "UNSUPPORTED_MATURITY");
        require(block.timestamp >= maturity, "NOT_MATURED");
        uint256 debt = debtByVault[borrower][address(vault)];
        uint256 writtenDown = writtenDownByVault[borrower][address(vault)];
        require(amount != 0 && amount <= debt - writtenDown, "TOO_MUCH");
        writtenDownByVault[borrower][address(vault)] = writtenDown + amount;
        vault.writeDown(amount);
        emit BadDebtMarked(borrower, maturity, amount);
    }

    function borrowStrategyBytes(uint256 id) public view returns (bytes memory) { BorrowOrder memory b = borrowOrders[id]; return abi.encode(bytes32("AQUATERM_BORROW"), address(this), id, b.borrower, b.maturity, b.collateralId); }
    function borrowStrategyHash(uint256 id) public view returns (bytes32) { return keccak256(borrowStrategyBytes(id)); }
    function supplyStrategyBytes(uint256 id) public view returns (bytes memory) { SupplyOrder memory s = supplyOrders[id]; return abi.encode(bytes32("AQUATERM_SUPPLY"), address(this), id, s.supplier, s.maturity); }
    function supplyStrategyHash(uint256 id) public view returns (bytes32) { return keccak256(supplyStrategyBytes(id)); }
}
