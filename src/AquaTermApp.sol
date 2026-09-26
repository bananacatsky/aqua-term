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
import {ILiquidationCallback} from "./interfaces/ILiquidationCallback.sol";

/// @notice Fixed-maturity borrowing app backed by Aqua virtual balances.
/// Aqua holds virtual order capacity; this contract only creates debt on a match.
contract AquaTermApp is AquaApp, ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    IERC20 public immutable debtToken;
    IOracle public immutable oracle;

    struct CollateralConfig {
        IERC20 token;
        uint16 maxBorrowLtvBps;
        uint16 liquidationLtvBps;
        uint16 liquidationDiscountBps;
    }
    CollateralConfig[] public collateralConfigs;
    uint256 public immutable N_COLLATERAL;
    mapping(uint40 => AquaTermVault) public vaultForMaturity;
    mapping(address => mapping(uint256 => uint256)) public depositedCollateral;
    mapping(address => mapping(address => uint256)) public debtByVault;
    mapping(address => mapping(address => uint256)) public writtenDownByVault;
    mapping(address => uint256) public totalDebt;
    uint40[] internal supportedMaturities;

    struct BorrowOrder {
        address borrower; uint40 maturity; uint40 deadline; uint128 faceAmount; uint128 minDebtTokenOut;
        uint16 ltvBps; uint256 collateralId; uint128 filledFace; bool cancelled;
    }
    struct SupplyOrder {
        address supplier; uint40 maturity; uint40 deadline; uint128 debtTokenIn; uint128 minTermOut;
        uint128 filledDebtToken; bool cancelled;
    }
    struct MatchSettlement {
        uint256 borrowerDebtTokenOut;
        uint256 supplierTermShares;
        uint256 matcherTermShares;
        uint256 matcherDebtToken;
    }
    uint256 public nextBorrowOrderId;
    uint256 public nextSupplyOrderId;
    mapping(uint256 => BorrowOrder) public borrowOrders;
    mapping(uint256 => SupplyOrder) public supplyOrders;

    event BorrowOrderCreated(uint256 indexed orderId, address indexed borrower, uint40 maturity, uint40 deadline, uint256 faceAmount, uint256 minDebtTokenOut, uint256 ltvBps, uint256 collateralId);
    event CollateralPulled(address indexed borrower, uint256 indexed collateralId, uint256 amount);
    event SupplyOrderCreated(uint256 indexed orderId, address indexed supplier, uint40 maturity, uint40 deadline, uint256 debtTokenIn, uint256 minTermOut);
    event OrdersMatched(
        uint256 indexed borrowOrderId,
        uint256 indexed supplyOrderId,
        address indexed matcher,
        uint256 faceAmount,
        uint256 supplierTermShares,
        uint256 borrowerDebtTokenOut,
        uint256 matcherTermShares,
        uint256 matcherDebtToken
    );
    event BadDebtMarked(address indexed borrower, uint40 indexed maturity, uint256 amount);
    event Liquidated(
        address indexed liquidator,
        address indexed borrower,
        uint40 indexed maturity,
        uint256 collateralId,
        uint256 debtRepaid,
        uint256 collateralSeized,
        uint256 badDebtAdded
    );

    constructor(
        IAqua aqua_, IERC20 debtToken_, IOracle oracle_, IERC20[] memory collateralTokens,
        uint16[] memory maxBorrowLtvs, uint16[] memory liquidationLtvs, uint16[] memory liquidationDiscountBps,
        uint40[] memory maturities, string[] memory names, string[] memory symbols
    ) AquaApp(aqua_) {
        require(maturities.length == names.length && maturities.length == symbols.length, "BAD_MATURITY_CONFIG");
        require(
            collateralTokens.length != 0 && collateralTokens.length == maxBorrowLtvs.length
                && collateralTokens.length == liquidationLtvs.length
                && collateralTokens.length == liquidationDiscountBps.length,
            "BAD_COLLATERAL_CONFIG"
        );
        debtToken = debtToken_; oracle = oracle_;
        N_COLLATERAL = collateralTokens.length;
        for (uint256 i; i < N_COLLATERAL; ++i) {
            require(maxBorrowLtvs[i] != 0 && maxBorrowLtvs[i] < liquidationLtvs[i] && liquidationLtvs[i] <= BPS, "BAD_LTV_CONFIG");
            require(liquidationDiscountBps[i] != 0 && liquidationDiscountBps[i] < BPS, "BAD_LIQUIDATION_DISCOUNT");
            require(address(collateralTokens[i]) != address(0), "ZERO_COLLATERAL");
            for (uint256 j; j < i; ++j) require(address(collateralTokens[j]) != address(collateralTokens[i]), "DUPLICATE_COLLATERAL");
            collateralConfigs.push(
                CollateralConfig(collateralTokens[i], maxBorrowLtvs[i], liquidationLtvs[i], liquidationDiscountBps[i])
            );
        }
        for (uint256 i; i < maturities.length; ++i) {
            require(address(vaultForMaturity[maturities[i]]) == address(0), "DUPLICATE_MATURITY");
            vaultForMaturity[maturities[i]] = new AquaTermVault(debtToken_, address(this), maturities[i], names[i], symbols[i]);
            supportedMaturities.push(maturities[i]);
        }
    }

    function depositCollateral(uint256 collateralId, uint256 amount) external nonReentrant {
        require(collateralId < N_COLLATERAL, "BAD_COLLATERAL");
        IERC20 token = collateralConfigs[collateralId].token;
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        require(token.balanceOf(address(this)) - beforeBalance == amount, "FEE_ON_TRANSFER_COLLATERAL");
        depositedCollateral[msg.sender][collateralId] += amount;
    }

    function withdrawCollateral(uint256 collateralId, uint256 amount) external nonReentrant {
        require(collateralId < N_COLLATERAL && depositedCollateral[msg.sender][collateralId] >= amount, "INSUFFICIENT_COLLATERAL");
        depositedCollateral[msg.sender][collateralId] -= amount;
        require(healthFactor(msg.sender) >= WAD, "UNHEALTHY");
        collateralConfigs[collateralId].token.safeTransfer(msg.sender, amount);
    }

    function collateralValue(address borrower) public view returns (uint256 value) {
        for (uint256 i; i < N_COLLATERAL; ++i) value += oracle.valueInDebtToken(address(collateralConfigs[i].token), depositedCollateral[borrower][i]);
    }

    function portfolioWeightedMaxBorrowLtv(address borrower) public view returns (uint256) {
        uint256 value; uint256 weighted;
        for (uint256 i; i < N_COLLATERAL; ++i) { uint256 v = oracle.valueInDebtToken(address(collateralConfigs[i].token), depositedCollateral[borrower][i]); value += v; weighted += v * collateralConfigs[i].maxBorrowLtvBps; }
        return value == 0 ? 0 : weighted / value;
    }

    function portfolioWeightedLiquidationLtv(address borrower) public view returns (uint256) {
        uint256 value; uint256 weighted;
        for (uint256 i; i < N_COLLATERAL; ++i) { uint256 v = oracle.valueInDebtToken(address(collateralConfigs[i].token), depositedCollateral[borrower][i]); value += v; weighted += v * collateralConfigs[i].liquidationLtvBps; }
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

    function createBorrowOrder(
        uint40 maturity, uint128 faceAmount, uint128 minDebtTokenOut, uint16 ltvBps, uint256 collateralId, uint40 deadline
    ) external returns (uint256 orderId, bytes32 strategyHash) {
        require(address(vaultForMaturity[maturity]) != address(0), "UNSUPPORTED_MATURITY");
        require(faceAmount != 0 && minDebtTokenOut != 0, "ZERO_ORDER");
        require(ltvBps != 0 && ltvBps <= BPS, "BAD_ORDER_LTV");
        require(collateralId < N_COLLATERAL, "BAD_COLLATERAL");
        orderId = nextBorrowOrderId++;
        borrowOrders[orderId] = BorrowOrder(msg.sender, maturity, deadline, faceAmount, minDebtTokenOut, ltvBps, collateralId, 0, false);
        strategyHash = borrowStrategyHash(orderId);
        emit BorrowOrderCreated(orderId, msg.sender, maturity, deadline, faceAmount, minDebtTokenOut, ltvBps, collateralId);
    }

    function createSupplyOrder(uint40 maturity, uint128 debtTokenIn, uint128 minTermOut, uint40 deadline) external returns (uint256 orderId, bytes32 strategyHash) {
        require(address(vaultForMaturity[maturity]) != address(0), "UNSUPPORTED_MATURITY");
        require(debtTokenIn != 0 && minTermOut != 0, "ZERO_ORDER");
        orderId = nextSupplyOrderId++;
        supplyOrders[orderId] = SupplyOrder(msg.sender, maturity, deadline, debtTokenIn, minTermOut, 0, false);
        strategyHash = supplyStrategyHash(orderId);
        emit SupplyOrderCreated(orderId, msg.sender, maturity, deadline, debtTokenIn, minTermOut);
    }

    function cancelBorrowOrder(uint256 id) external { require(borrowOrders[id].borrower == msg.sender, "NOT_BORROWER"); borrowOrders[id].cancelled = true; }
    function cancelSupplyOrder(uint256 id) external { require(supplyOrders[id].supplier == msg.sender, "NOT_SUPPLIER"); supplyOrders[id].cancelled = true; }

    function matchOrders(uint256 borrowOrderId, uint256 supplyOrderId, uint256 faceAmount, uint256 debtTokenAmount) external nonReentrant {
        BorrowOrder storage b = borrowOrders[borrowOrderId]; SupplyOrder storage s = supplyOrders[supplyOrderId];
        require(!b.cancelled && !s.cancelled, "CANCELLED");
        require(b.maturity == s.maturity && block.timestamp < b.maturity, "BAD_MATURITY");
        require(block.timestamp <= b.deadline && block.timestamp <= s.deadline, "ORDER_EXPIRED");
        require(faceAmount != 0 && debtTokenAmount != 0, "ZERO_FILL");
        require(faceAmount <= uint256(b.faceAmount) - b.filledFace, "BORROW_OVERFILL");
        require(debtTokenAmount <= uint256(s.debtTokenIn) - s.filledDebtToken, "SUPPLY_OVERFILL");
        MatchSettlement memory settlement;
        settlement.borrowerDebtTokenOut = Math.ceilDiv(uint256(b.minDebtTokenOut) * faceAmount, b.faceAmount);
        require(debtTokenAmount >= settlement.borrowerDebtTokenOut, "BORROW_PRICE");
        uint256 newDebt = totalDebt[b.borrower] + faceAmount;
        _topUpCollateral(b.borrower, b.collateralId, b.ltvBps, newDebt);
        AquaTermVault vault = vaultForMaturity[b.maturity];
        totalDebt[b.borrower] = newDebt;
        debtByVault[b.borrower][address(vault)] += faceAmount;
        uint256 termShares = vault.mintDebtShares(b.borrower, faceAmount);
        settlement.supplierTermShares = Math.ceilDiv(uint256(s.minTermOut) * debtTokenAmount, s.debtTokenIn);
        require(termShares >= settlement.supplierTermShares, "SUPPLY_PRICE");
        settlement.matcherTermShares = termShares - settlement.supplierTermShares;
        settlement.matcherDebtToken = debtTokenAmount - settlement.borrowerDebtTokenOut;
        _settleAqua(b, s, borrowOrderId, supplyOrderId, address(vault), settlement);
        b.filledFace += uint128(faceAmount); s.filledDebtToken += uint128(debtTokenAmount);
        emit OrdersMatched(
            borrowOrderId, supplyOrderId, msg.sender, faceAmount, settlement.supplierTermShares, settlement.borrowerDebtTokenOut,
            settlement.matcherTermShares, settlement.matcherDebtToken
        );
    }

    function _settleAqua(
        BorrowOrder storage b,
        SupplyOrder storage s,
        uint256 borrowOrderId,
        uint256 supplyOrderId,
        address vault,
        MatchSettlement memory settlement
    ) internal {
        AQUA.pull(b.borrower, borrowStrategyHash(borrowOrderId), vault, settlement.supplierTermShares, s.supplier);
        if (settlement.matcherTermShares != 0) {
            AQUA.pull(b.borrower, borrowStrategyHash(borrowOrderId), vault, settlement.matcherTermShares, msg.sender);
        }
        AQUA.pull(s.supplier, supplyStrategyHash(supplyOrderId), address(debtToken), settlement.borrowerDebtTokenOut, b.borrower);
        if (settlement.matcherDebtToken != 0) {
            AQUA.pull(s.supplier, supplyStrategyHash(supplyOrderId), address(debtToken), settlement.matcherDebtToken, msg.sender);
        }
    }

    /// @dev Use existing deposited collateral first; pull only the shortfall from the chosen wallet token.
    function _topUpCollateral(address borrower, uint256 collateralId, uint16 orderLtvBps, uint256 newDebt) internal {
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
        for (uint256 i; i < N_COLLATERAL; ++i) {
            uint256 tokenValue = oracle.valueInDebtToken(address(collateralConfigs[i].token), depositedCollateral[borrower][i]);
            value += tokenValue;
            weightedCapacity += tokenValue * collateralConfigs[i].maxBorrowLtvBps;
        }
    }

    function _pullCollateral(address borrower, uint256 collateralId, uint256 valueNeeded) internal {
        IERC20 token = collateralConfigs[collateralId].token;
        uint8 decimals = IERC20Metadata(address(token)).decimals();
        require(decimals <= 18, "COLLATERAL_DECIMALS");
        uint256 unit = 10 ** decimals;
        uint256 unitValue = oracle.valueInDebtToken(address(token), unit);
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
        debtToken.safeTransferFrom(msg.sender, address(vault), amount);
        vault.recordRepayment(amount, recovered);
    }

    /// @notice Repays one maturity debt and seizes discounted collateral from an unhealthy or matured borrower.
    /// @dev The callback may swap seized collateral and approve the debt token back to this app for repayment.
    function liquidate(
        address borrower,
        uint40 maturity,
        uint256 collateralId,
        uint256 debtAmount,
        bytes calldata callbackData
    ) external nonReentrant returns (uint256 collateralSeized) {
        require(collateralId < N_COLLATERAL, "BAD_COLLATERAL");
        AquaTermVault vault = vaultForMaturity[maturity];
        require(address(vault) != address(0), "UNSUPPORTED_MATURITY");
        uint256 health = healthFactor(borrower);
        require(block.timestamp >= maturity || health < WAD, "NOT_LIQUIDATABLE");

        uint256 borrowerDebt = debtByVault[borrower][address(vault)];
        require(debtAmount != 0 && debtAmount <= borrowerDebt, "TOO_MUCH");
        uint256 availableCollateral = depositedCollateral[borrower][collateralId];
        collateralSeized = _liquidationCollateralAmount(collateralId, debtAmount, availableCollateral);
        require(collateralSeized != 0, "NO_COLLATERAL_TO_SEIZE");

        debtByVault[borrower][address(vault)] = borrowerDebt - debtAmount;
        totalDebt[borrower] -= debtAmount;
        depositedCollateral[borrower][collateralId] = availableCollateral - collateralSeized;
        uint256 writtenDown = writtenDownByVault[borrower][address(vault)];
        uint256 recoveredBadDebt = debtAmount < writtenDown ? debtAmount : writtenDown;
        writtenDownByVault[borrower][address(vault)] = writtenDown - recoveredBadDebt;

        collateralConfigs[collateralId].token.safeTransfer(msg.sender, collateralSeized);
        if (callbackData.length != 0) {
            ILiquidationCallback(msg.sender).onAquaTermLiquidation(
                borrower, maturity, collateralId, debtAmount, collateralSeized, callbackData
            );
        }
        debtToken.safeTransferFrom(msg.sender, address(vault), debtAmount);
        vault.recordRepayment(debtAmount, recoveredBadDebt);

        uint256 badDebtAdded;
        if (_hasNoCollateral(borrower)) badDebtAdded = _recognizeBadDebt(borrower);
        emit Liquidated(msg.sender, borrower, maturity, collateralId, debtAmount, collateralSeized, badDebtAdded);
    }

    function _liquidationCollateralAmount(uint256 collateralId, uint256 debtAmount, uint256 available)
        internal view returns (uint256)
    {
        uint256 discountBps = collateralConfigs[collateralId].liquidationDiscountBps;
        uint256 collateralValueNeeded = Math.mulDiv(debtAmount, BPS, BPS - discountBps, Math.Rounding.Ceil);
        IERC20 token = collateralConfigs[collateralId].token;
        uint8 decimals = IERC20Metadata(address(token)).decimals();
        require(decimals <= 18, "COLLATERAL_DECIMALS");
        uint256 unit = 10 ** decimals;
        uint256 unitValue = oracle.valueInDebtToken(address(token), unit);
        require(unitValue != 0, "COLLATERAL_VALUE_ZERO");
        uint256 amount = Math.mulDiv(collateralValueNeeded, unit, unitValue, Math.Rounding.Ceil);
        return Math.min(amount, available);
    }

    function _hasNoCollateral(address borrower) internal view returns (bool) {
        for (uint256 i; i < N_COLLATERAL; ++i) {
            if (depositedCollateral[borrower][i] != 0) return false;
        }
        return true;
    }

    /// @dev Write off each remaining performing maturity debt after all borrower collateral is exhausted.
    function _recognizeBadDebt(address borrower) internal returns (uint256 badDebtAdded) {
        for (uint256 i; i < supportedMaturities.length; ++i) {
            uint40 maturity = supportedMaturities[i];
            AquaTermVault vault = vaultForMaturity[maturity];
            address vaultAddress = address(vault);
            uint256 debt = debtByVault[borrower][vaultAddress];
            uint256 alreadyWrittenDown = writtenDownByVault[borrower][vaultAddress];
            uint256 performingDebt = debt - alreadyWrittenDown;
            if (performingDebt != 0) {
                writtenDownByVault[borrower][vaultAddress] = debt;
                vault.writeDown(performingDebt);
                badDebtAdded += performingDebt;
                emit BadDebtMarked(borrower, maturity, performingDebt);
            }
        }
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

    function borrowStrategyBytes(uint256 id) public view returns (bytes memory) { BorrowOrder memory b = borrowOrders[id]; return abi.encode(bytes32("AQUATERM_BORROW"), address(this), id, b.borrower, b.maturity, b.deadline, b.collateralId); }
    function borrowStrategyHash(uint256 id) public view returns (bytes32) { return keccak256(borrowStrategyBytes(id)); }
    function supplyStrategyBytes(uint256 id) public view returns (bytes memory) { SupplyOrder memory s = supplyOrders[id]; return abi.encode(bytes32("AQUATERM_SUPPLY"), address(this), id, s.supplier, s.maturity, s.deadline); }
    function supplyStrategyHash(uint256 id) public view returns (bytes32) { return keccak256(supplyStrategyBytes(id)); }
}
