// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {IAqua} from "./interfaces/IAqua.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {AquaTermVault} from "./AquaTermVault.sol";

/// @notice Dependency-light MVP of AquaTerm's fixed-maturity borrowing app.
/// Aqua holds virtual order capacity; this contract only creates debt on a match.
contract AquaTermApp {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    IAqua public immutable aqua;
    IERC20 public immutable usdt;
    IOracle public immutable oracle;

    struct CollateralConfig { IERC20 token; uint16 maxBorrowLtvBps; uint16 liquidationLtvBps; }
    CollateralConfig[2] public collateralConfigs;
    mapping(uint40 => AquaTermVault) public vaultForMaturity;
    mapping(address => mapping(uint8 => uint256)) public depositedCollateral;
    mapping(address => mapping(address => uint256)) public debtByVault;
    mapping(address => uint256) public totalDebt;

    struct BorrowOrder {
        address borrower; uint40 maturity; uint128 faceAmount; uint128 minUsdtOut;
        uint16 ltvBps; uint128 filledFace; bool cancelled;
    }
    struct SupplyOrder {
        address supplier; uint40 maturity; uint128 usdtIn; uint128 minTermOut;
        uint128 filledUsdt; bool cancelled;
    }
    uint256 public nextBorrowOrderId;
    uint256 public nextSupplyOrderId;
    mapping(uint256 => BorrowOrder) public borrowOrders;
    mapping(uint256 => SupplyOrder) public supplyOrders;

    event BorrowOrderCreated(uint256 indexed orderId, address indexed borrower, uint40 maturity, uint256 faceAmount, uint256 minUsdtOut, uint256 ltvBps);
    event SupplyOrderCreated(uint256 indexed orderId, address indexed supplier, uint40 maturity, uint256 usdtIn, uint256 minTermOut);
    event OrdersMatched(uint256 indexed borrowOrderId, uint256 indexed supplyOrderId, uint256 faceAmount, uint256 usdtAmount);
    event BadDebtMarked(address indexed borrower, uint40 indexed maturity, uint256 amount);

    constructor(
        IAqua aqua_, IERC20 usdt_, IOracle oracle_, IERC20[2] memory collateralTokens,
        uint16[2] memory maxBorrowLtvs, uint16[2] memory liquidationLtvs,
        uint40[] memory maturities, string[] memory names, string[] memory symbols
    ) {
        require(maturities.length == names.length && maturities.length == symbols.length, "BAD_MATURITY_CONFIG");
        aqua = aqua_; usdt = usdt_; oracle = oracle_;
        for (uint256 i; i < 2; ++i) {
            require(maxBorrowLtvs[i] < liquidationLtvs[i] && liquidationLtvs[i] <= BPS, "BAD_LTV_CONFIG");
            collateralConfigs[i] = CollateralConfig(collateralTokens[i], maxBorrowLtvs[i], liquidationLtvs[i]);
        }
        for (uint256 i; i < maturities.length; ++i) {
            require(address(vaultForMaturity[maturities[i]]) == address(0), "DUPLICATE_MATURITY");
            vaultForMaturity[maturities[i]] = new AquaTermVault(usdt_, address(this), maturities[i], names[i], symbols[i]);
        }
    }

    function depositCollateral(uint8 collateralId, uint256 amount) external {
        require(collateralId < 2, "BAD_COLLATERAL");
        depositedCollateral[msg.sender][collateralId] += amount;
        require(collateralConfigs[collateralId].token.transferFrom(msg.sender, address(this), amount), "COLLATERAL_TRANSFER_FAILED");
    }

    function withdrawCollateral(uint8 collateralId, uint256 amount) external {
        require(collateralId < 2 && depositedCollateral[msg.sender][collateralId] >= amount, "INSUFFICIENT_COLLATERAL");
        depositedCollateral[msg.sender][collateralId] -= amount;
        require(healthFactor(msg.sender) >= WAD, "UNHEALTHY");
        require(collateralConfigs[collateralId].token.transfer(msg.sender, amount), "COLLATERAL_TRANSFER_FAILED");
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

    function createBorrowOrder(uint40 maturity, uint128 faceAmount, uint128 minUsdtOut, uint16 ltvBps) external returns (uint256 orderId, bytes32 strategyHash) {
        require(address(vaultForMaturity[maturity]) != address(0), "UNSUPPORTED_MATURITY");
        require(faceAmount != 0 && minUsdtOut != 0, "ZERO_ORDER");
        require(ltvBps <= portfolioWeightedMaxBorrowLtv(msg.sender), "ORDER_LTV_TOO_HIGH");
        orderId = nextBorrowOrderId++;
        borrowOrders[orderId] = BorrowOrder(msg.sender, maturity, faceAmount, minUsdtOut, ltvBps, 0, false);
        strategyHash = borrowStrategyHash(orderId);
        emit BorrowOrderCreated(orderId, msg.sender, maturity, faceAmount, minUsdtOut, ltvBps);
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

    function matchOrders(uint256 borrowOrderId, uint256 supplyOrderId, uint256 faceAmount, uint256 usdtAmount) external {
        BorrowOrder storage b = borrowOrders[borrowOrderId]; SupplyOrder storage s = supplyOrders[supplyOrderId];
        require(!b.cancelled && !s.cancelled, "CANCELLED");
        require(b.maturity == s.maturity && block.timestamp < b.maturity, "BAD_MATURITY");
        require(faceAmount != 0 && usdtAmount != 0, "ZERO_FILL");
        require(faceAmount <= uint256(b.faceAmount) - b.filledFace, "BORROW_OVERFILL");
        require(usdtAmount <= uint256(s.usdtIn) - s.filledUsdt, "SUPPLY_OVERFILL");
        require(usdtAmount >= uint256(b.minUsdtOut) * faceAmount / b.faceAmount, "BORROW_PRICE");
        require(faceAmount >= uint256(s.minTermOut) * usdtAmount / s.usdtIn, "SUPPLY_PRICE");
        require(b.ltvBps <= portfolioWeightedMaxBorrowLtv(b.borrower), "RISK_CHANGED");
        uint256 newDebt = totalDebt[b.borrower] + faceAmount;
        require(collateralValue(b.borrower) != 0 && newDebt * BPS / collateralValue(b.borrower) <= b.ltvBps, "BORROWER_LTV");
        AquaTermVault vault = vaultForMaturity[b.maturity];
        totalDebt[b.borrower] = newDebt;
        debtByVault[b.borrower][address(vault)] += faceAmount;
        vault.mintDebtShares(b.borrower, faceAmount);
        aqua.pull(b.borrower, borrowStrategyHash(borrowOrderId), address(vault), faceAmount, s.supplier);
        aqua.pull(s.supplier, supplyStrategyHash(supplyOrderId), address(usdt), usdtAmount, b.borrower);
        b.filledFace += uint128(faceAmount); s.filledUsdt += uint128(usdtAmount);
        emit OrdersMatched(borrowOrderId, supplyOrderId, faceAmount, usdtAmount);
    }

    function repay(uint40 maturity, uint256 amount) external {
        AquaTermVault vault = vaultForMaturity[maturity]; require(address(vault) != address(0), "UNSUPPORTED_MATURITY");
        uint256 debt = debtByVault[msg.sender][address(vault)]; require(amount != 0 && amount <= debt, "TOO_MUCH");
        debtByVault[msg.sender][address(vault)] = debt - amount; totalDebt[msg.sender] -= amount;
        require(usdt.transferFrom(msg.sender, address(vault), amount), "REPAYMENT_TRANSFER_FAILED"); vault.recordRepayment(amount);
    }

    /// @notice Permissionless maturity write-down; collateral recovery is intentionally outside MVP scope.
    function markBadDebt(address borrower, uint40 maturity, uint256 amount) external {
        AquaTermVault vault = vaultForMaturity[maturity]; require(address(vault) != address(0), "UNSUPPORTED_MATURITY");
        require(block.timestamp >= maturity, "NOT_MATURED");
        uint256 debt = debtByVault[borrower][address(vault)]; require(amount != 0 && amount <= debt, "TOO_MUCH");
        debtByVault[borrower][address(vault)] = debt - amount; totalDebt[borrower] -= amount; vault.writeDown(amount);
        emit BadDebtMarked(borrower, maturity, amount);
    }

    function borrowStrategyBytes(uint256 id) public view returns (bytes memory) { BorrowOrder memory b = borrowOrders[id]; return abi.encode(bytes32("AQUATERM_BORROW"), address(this), id, b.borrower, b.maturity); }
    function borrowStrategyHash(uint256 id) public view returns (bytes32) { return keccak256(borrowStrategyBytes(id)); }
    function supplyStrategyBytes(uint256 id) public view returns (bytes memory) { SupplyOrder memory s = supplyOrders[id]; return abi.encode(bytes32("AQUATERM_SUPPLY"), address(this), id, s.supplier, s.maturity); }
    function supplyStrategyHash(uint256 id) public view returns (bytes32) { return keccak256(supplyStrategyBytes(id)); }
}
