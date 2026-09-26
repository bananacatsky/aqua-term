# AquaTerm — MVP Specification

Fixed-rate, fixed-term collateralized borrowing built on top of 1inch Aqua.

## 1. Idea

A borrower locks collateral and borrows USDT by selling a fixed-maturity claim.

Example:

```text
Borrower wants:
500 USDT face debt
maturity: Oct 30
LTV: 60%

Market price:
500 USDT-OCT30 = 480 USDT today
```

On fill:

```text
Borrower collateral → AquaTermVault
Supplier 480 USDT → Borrower
Supplier ← 500 USDT-OCT30
```

At maturity:

```text
Borrower 500 USDT → AquaTermVault
Supplier burns 500 USDT-OCT30
AquaTermVault → 500 USDT Supplier
```

The difference between `480 USDT now` and `500 USDT at maturity` is the fixed borrowing rate.

## 2. Main Aqua idea

Collateral and debt are **not created when an order is posted**.

A borrower with enough collateral capacity for only `$1000` can simultaneously quote:

```text
500 USDT-OCT
500 USDT-NOV
500 USDT-DEC
```

Total advertised borrowing:

```text
$1500
```

Actual maximum debt:

```text
$1000
```

This works because Aqua strategies contain **virtual balances**.

`ship()` does not move tokens. Actual token movement happens only during a fill via `pull()` / `push()`.

Therefore debt and collateral are materialized **just in time** when a particular order is filled.

## 3. Architecture

One contract per maturity:

```text
AquaTermFactory
    │
    ├── AquaTermVault USDT-OCT30
    ├── AquaTermVault USDT-NOV30
    └── AquaTermVault USDT-JAN31
```

Each `AquaTermVault` is:

```solidity
contract AquaTermVault is ERC4626, AquaApp
```

Underlying ERC4626 asset:

```text
USDT
```

ERC4626 shares:

```text
USDT-OCT30
```

Shares represent a proportional claim on all performing debt for that maturity.

## 4. External dependencies

Keep the vault itself small.

```solidity
interface IAqua {
    // ship / dock / pull / push
}

interface IERC20 {
    // collateral and USDT
}

interface IOracle {
    function collateralRequired(
        address collateral,
        address debtAsset,
        uint256 debtAmount,
        uint256 ltvBps
    ) external view returns (uint256);
}
```

Optional later:

```solidity
interface ILiquidator {}
interface IRateModel {}
```

For MVP there is no liquidation module.

## 5. Borrower strategy

A strategy describes an offer.

```solidity
struct Strategy {
    address borrower;
    address collateralToken;

    uint16 ltvBps;

    // USDT today per 1 USDT at maturity.
    // 0.96e18 means:
    // 500 future USDT => 480 USDT now.
    uint256 priceWad;

    bytes32 salt;
}
```

Maturity does not need to be inside the strategy if each vault has one immutable maturity.

The vault has:

```solidity
uint40 public immutable maturity;
uint16 public immutable maxBorrowLtvBps;
```

Validation:

```text
strategy.ltvBps <= maxBorrowLtvBps
```

## 6. Posting an order

Borrower does **not** deposit collateral.

Borrower does **not** mint maturity shares.

Borrower only approves:

```text
collateralToken → AquaTermVault
USDT-OCT30      → Aqua
```

and ships a strategy into Aqua:

```text
maker = borrower
app = AquaTermVault
token = USDT-OCT30
virtual amount = 500
```

Aqua stores virtual liquidity under approximately:

```text
borrower
  → AquaTermVault
    → strategyHash
      → USDT-OCT30
        → 500
```

Aqua's virtual balance is accounting only; the real token does not need to move during `ship()`.

Therefore the same collateral capacity can support several unfilled term offers.

## 7. Fill lifecycle

Supplier sees:

```text
Sell:
500 USDT-OCT30

Receive:
minimum 480 USDT now
```

Supplier calls:

```solidity
vault.fill(strategy, 500e6);
```

### Step 1 — calculate current price

```solidity
usdtNow =
    faceAmount * strategy.priceWad / 1e18;
```

Example:

```text
faceAmount = 500
price      = 0.96

usdtNow = 480
```

### Step 2 — calculate required collateral

```solidity
collateralAmount =
    oracle.collateralRequired(
        collateralToken,
        USDT,
        faceAmount,
        strategy.ltvBps
    );
```

Example:

```text
debt = $500
LTV = 60%

required collateral value =
500 / 0.60
= $833.33
```

### Step 3 — lock collateral JIT

```text
Borrower
    │
    │ ~$833 WETH
    ▼
AquaTermVault
```

If the borrower no longer has enough collateral:

```text
transferFrom() reverts
→ entire fill reverts
```

### Step 4 — create debt

Vault records:

```solidity
totalDebt += 500e6;
```

and creates a position:

```solidity
Position {
    borrower,
    collateralToken,
    collateralAmount,
    faceDebt: 500e6
}
```

### Step 5 — mint maturity shares JIT

Vault mints:

```text
500 USDT-OCT30 → Borrower
```

These did not exist before the fill.

### Step 6 — Aqua transfers maturity shares

Vault calls:

```solidity
AQUA.pull(
    borrower,
    strategyHash,
    address(vault),
    500e6,
    supplier
);
```

Result:

```text
Borrower
    │
    │ 500 USDT-OCT30
    ▼
Supplier
```

### Step 7 — supplier pays spot USDT

```text
Supplier
    │
    │ 480 USDT
    ▼
Borrower
```

Preferably settlement uses Aqua `push()` so both swap legs are represented in Aqua.

Final state:

```text
Borrower:

+480 USDT
-$833 collateral liquidity
+500 USDT debt due Oct 30


Supplier:

-480 USDT
+500 USDT-OCT30
```

Everything happens atomically.

If any step fails:

```text
collateral lock
debt creation
share mint
Aqua pull
USDT payment
```

all revert.

## 8. ERC4626 accounting

The vault represents a portfolio of loans with the same maturity.

`totalAssets()` should represent economic NAV, not only idle USDT:

```solidity
function totalAssets()
    public
    view
    override
    returns (uint256)
{
    return
        IERC20(asset()).balanceOf(address(this))
        + performingDebt;
}
```

Example immediately after originating a loan:

```text
cash in vault      = 0
performing debt    = 500

totalAssets        = 500
totalSupply        = 500 USDT-OCT

1 USDT-OCT ≈ 1 USDT face value
```

The supplier paid only `480` for those shares.

That discount is their fixed yield.

## 9. Repayment

Borrower calls:

```solidity
repay(positionId)
```

Flow:

```text
Borrower
    │
    │ 500 USDT
    ▼
AquaTermVault
```

Accounting:

```text
performing debt -500
cash             +500
```

Therefore `totalAssets` does not change merely because debt became cash.

Then collateral can be returned:

```text
AquaTermVault
    │
    │ locked WETH
    ▼
Borrower
```

## 10. Redemption

After maturity, a holder can redeem:

```solidity
redeem(shares, receiver, owner)
```

Standard ERC4626 semantics:

```text
Supplier burns:
500 USDT-OCT30

AquaTermVault transfers:
500 USDT
```

If all debt repays:

```text
1 USDT-OCT30
→
1 USDT
```

approximately 1:1 at maturity.

## 11. Bad debt

For MVP, no liquidation.

If a loan reaches maturity without repayment:

```solidity
markBadDebt(positionId)
```

The debt is written down.

Example:

```text
totalSupply = 1000 USDT-OCT

performing debt = 800
bad debt        = 200
cash            = 0
```

Then:

```text
totalAssets = 800
```

ERC4626 share price becomes:

```text
1 USDT-OCT = 0.8 USDT
```

Thus losses are automatically socialized across holders of that maturity vault.

Collateral remains locked.

Recovery / liquidation of that collateral is explicitly outside MVP scope.

## 12. Important invariant

Outstanding debt must never be created merely by `ship()`.

Correct:

```text
ship
→ virtual borrowing capacity only

fill
→ lock collateral
→ create real debt
→ mint shares
```

This is the central Aqua integration.

## 13. Why Aqua matters

Without Aqua, borrower with `$1000` borrowing capacity would have to choose in advance:

```text
$300 capacity → October
$400 capacity → November
$300 capacity → December
```

With Aqua:

```text
                 same capacity
                     $1000
                       │
          ┌────────────┼────────────┐
          ▼            ▼            ▼
       $500 OCT     $500 NOV     $500 DEC
```

These are only virtual commitments.

Whichever orders fill first consume actual collateral/debt capacity.

Later fills revert if the borrower no longer has sufficient collateral.

This extends Aqua's shared-liquidity model from:

```text
shared token inventory
```

to:

```text
shared borrowing capacity
```

## 14. MVP contract surface

```solidity
contract AquaTermVault is ERC4626, AquaApp {
    IERC20 public immutable USDT;
    IOracle public immutable oracle;

    uint40 public immutable maturity;
    uint16 public immutable maxBorrowLtvBps;

    uint256 public totalDebt;
    uint256 public badDebt;

    function quote(
        Strategy calldata strategy,
        uint256 faceAmount
    ) external view returns (uint256 usdtNow);

    function fill(
        Strategy calldata strategy,
        uint256 faceAmount
    ) external returns (uint256 positionId);

    function repay(
        uint256 positionId
    ) external;

    function markBadDebt(
        uint256 positionId
    ) external;

    function totalAssets()
        public
        view
        override
        returns (uint256);
}
```

Aqua provides:

```text
ship
dock
pull
push
virtual balance accounting
```

`AquaTermVault` provides:

```text
fixed maturity
fixed price/rate
collateral accounting
JIT collateral lock
JIT debt creation
JIT share minting
repayment
bad-debt accounting
```

## 15. Out of scope for MVP

Do not build initially:

```text
liquidations
variable rates
partial collateral top-ups
multiple debt assets per vault
generic credit accounts
leverage loops
secondary AMM
custom SwapVM opcode
governance
insurance
```

Primary demo:

```text
1. Borrower has WETH but locks nothing.

2. Borrower ships:
   500 OCT
   500 NOV
   500 DEC

3. Supplier fills OCT.

4. WETH gets locked JIT.

5. USDT-OCT gets minted JIT.

6. Supplier receives USDT-OCT.

7. Borrower receives discounted USDT.

8. Another maturity can still fill
   while collateral capacity remains.

9. An over-capacity fill reverts.

10. Borrower repays.

11. Supplier redeems at maturity.
```

## 16. One-line pitch

> **AquaTerm lets borrowers quote the same collateral capacity across multiple fixed-rate maturities and only materializes collateral and debt when liquidity actually fills.**

---

## 17. Approximate Solidity implementation

> This is intentionally incomplete and architectural. It shows contract boundaries and accounting, not production-ready code. Exact Aqua method signatures should be adapted to the version used at the hackathon.

Design assumptions:

- `AquaTermApp` has no owner and no admin functions.
- Constructor receives Aqua, USDT, oracle, WETH/WBTC risk parameters, and supported maturities.
- `AquaTermApp` deploys one ERC-4626 vault per maturity.
- Example vaults: `USDT-OCT30`, `USDT-JAN30`, etc.
- Borrowers deposit WETH/WBTC collateral into `AquaTermApp`.
- Borrowers create orders saying how much `USDT-X` they want to sell for spot USDT and at what maximum resulting LTV.
- Suppliers create orders saying how much spot USDT they offer and how much `USDT-X` they require in return.
- Both order types are represented as Aqua strategies / virtual balances.
- Matching happens atomically.
- `USDT-X` is minted only when a match actually fills.
- No liquidation implementation is included below.

Expected external oracle interface:

```solidity
// imported from ./interfaces/IOracle.sol
//
// interface IOracle {
//     function valueInUSDT(
//         address token,
//         uint256 amount
//     ) external view returns (uint256);
// }
```

### 17.1 Contracts

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AquaApp} from "@1inch/aqua/src/AquaApp.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";

import {IOracle} from "./interfaces/IOracle.sol";
```

### 17.2 One ERC-4626 vault per maturity

```solidity
contract AquaTermVault is ERC4626 {
    using SafeERC20 for IERC20;

    address public immutable APP;
    uint40 public immutable MATURITY;

    // Face value of all outstanding loans for this maturity.
    uint256 public totalDebt;

    // Portion of totalDebt that has been written down.
    uint256 public badDebt;

    modifier onlyApp() {
        require(msg.sender == APP, "ONLY_APP");
        _;
    }

    constructor(
        IERC20 usdt,
        address app,
        uint40 maturity_,
        string memory name_,
        string memory symbol_
    )
        ERC20(name_, symbol_)
        ERC4626(usdt)
    {
        APP = app;
        MATURITY = maturity_;
    }

    function totalAssets()
        public
        view
        override
        returns (uint256)
    {
        uint256 cash =
            IERC20(asset()).balanceOf(address(this));

        return cash + totalDebt - badDebt;
    }

    // Called only when a real borrow order fills.
    //
    // This deliberately mints ERC-4626 shares against a new
    // receivable instead of against an ERC-20 deposit.
    function mintDebtShares(
        address receiver,
        uint256 faceAmount
    )
        external
        onlyApp
    {
        totalDebt += faceAmount;
        _mint(receiver, faceAmount);
    }

    // App transfers real USDT into this vault before calling this.
    function recordRepayment(
        uint256 faceAmount
    )
        external
        onlyApp
    {
        totalDebt -= faceAmount;
    }

    function writeDown(
        uint256 amount
    )
        external
        onlyApp
    {
        badDebt += amount;
    }
}
```

### 17.3 AquaTermApp

```solidity
contract AquaTermApp is AquaApp {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    IERC20 public immutable USDT;
    IOracle public immutable ORACLE;

    struct CollateralConfig {
        IERC20 token;
        uint16 maxBorrowLtvBps;
        uint16 liquidationLtvBps;
    }

    // Exactly two collateral assets for MVP:
    // [0] WETH
    // [1] WBTC
    CollateralConfig[2] public collateralConfigs;

    // maturity => ERC4626 maturity vault
    mapping(uint40 => AquaTermVault) public vaultForMaturity;

    uint40[] public maturities;

    // borrower => collateralId => deposited amount
    mapping(address => mapping(uint8 => uint256))
        public depositedCollateral;

    // borrower => maturity vault => face debt
    mapping(address => mapping(address => uint256))
        public debtByVault;

    // borrower => aggregate face debt in USDT terms
    mapping(address => uint256)
        public totalDebt;

    uint256 public nextBorrowOrderId;
    uint256 public nextSupplyOrderId;

    struct BorrowOrder {
        address borrower;
        uint40 maturity;

        // Total future USDT the borrower is willing to mint/sell.
        uint128 faceAmount;

        // Minimum real USDT borrower wants for the full faceAmount.
        uint128 minUsdtOut;

        // Borrower chooses how far they are willing to lever.
        //
        // Resulting portfolio LTV after fill must be <= this value.
        // Also must be <= portfolioWeightedMaxBorrowLtv().
        uint16 ltvBps;

        uint128 filledFace;
        bool cancelled;
    }

    struct SupplyOrder {
        address supplier;
        uint40 maturity;

        // Real USDT supplier is willing to spend.
        uint128 usdtIn;

        // Minimum USDT-X supplier wants for full usdtIn.
        uint128 minTermOut;

        uint128 filledUsdt;
        bool cancelled;
    }

    mapping(uint256 => BorrowOrder)
        public borrowOrders;

    mapping(uint256 => SupplyOrder)
        public supplyOrders;

    event BorrowOrderCreated(
        uint256 indexed orderId,
        address indexed borrower,
        uint40 maturity,
        uint256 faceAmount,
        uint256 minUsdtOut,
        uint256 ltvBps
    );

    event SupplyOrderCreated(
        uint256 indexed orderId,
        address indexed supplier,
        uint40 maturity,
        uint256 usdtIn,
        uint256 minTermOut
    );

    event OrdersMatched(
        uint256 indexed borrowOrderId,
        uint256 indexed supplyOrderId,
        uint256 faceAmount,
        uint256 usdtAmount
    );

    constructor(
        IAqua aqua,
        IERC20 usdt,
        IOracle oracle,

        // [WETH, WBTC]
        IERC20[2] memory collateralTokens,

        // per-token risk config
        uint16[2] memory maxBorrowLtvs,
        uint16[2] memory liquidationLtvs,

        // one vault will be deployed for each maturity
        uint40[] memory maturities_,

        // e.g. ["AquaTerm USDT Oct30", "AquaTerm USDT Jan30"]
        string[] memory vaultNames,

        // e.g. ["USDT-OCT30", "USDT-JAN30"]
        string[] memory vaultSymbols
    )
        AquaApp(aqua)
    {
        require(
            maturities_.length == vaultNames.length &&
            maturities_.length == vaultSymbols.length,
            "BAD_MATURITY_CONFIG"
        );

        USDT = usdt;
        ORACLE = oracle;

        for (uint256 i; i < 2; ++i) {
            require(
                maxBorrowLtvs[i] < liquidationLtvs[i],
                "BAD_LTV_CONFIG"
            );

            require(
                liquidationLtvs[i] <= BPS,
                "BAD_LLTV"
            );

            collateralConfigs[i] = CollateralConfig({
                token: collateralTokens[i],
                maxBorrowLtvBps: maxBorrowLtvs[i],
                liquidationLtvBps: liquidationLtvs[i]
            });
        }

        for (uint256 i; i < maturities_.length; ++i) {
            uint40 maturity = maturities_[i];

            require(
                address(vaultForMaturity[maturity]) == address(0),
                "DUPLICATE_MATURITY"
            );

            AquaTermVault vault =
                new AquaTermVault(
                    usdt,
                    address(this),
                    maturity,
                    vaultNames[i],
                    vaultSymbols[i]
                );

            vaultForMaturity[maturity] = vault;
            maturities.push(maturity);
        }
    }

    // ------------------------------------------------------------
    // Collateral
    // ------------------------------------------------------------

    function depositCollateral(
        uint8 collateralId,
        uint256 amount
    )
        external
    {
        CollateralConfig memory c =
            collateralConfigs[collateralId];

        c.token.safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );

        depositedCollateral[msg.sender][collateralId]
            += amount;
    }

    function withdrawCollateral(
        uint8 collateralId,
        uint256 amount
    )
        external
    {
        depositedCollateral[msg.sender][collateralId]
            -= amount;

        require(
            healthFactor(msg.sender) >= WAD,
            "UNHEALTHY"
        );

        collateralConfigs[collateralId]
            .token
            .safeTransfer(msg.sender, amount);
    }

    // ------------------------------------------------------------
    // Portfolio risk
    // ------------------------------------------------------------

    function collateralValue(
        address borrower
    )
        public
        view
        returns (uint256 totalValue)
    {
        for (uint8 i; i < 2; ++i) {
            uint256 amount =
                depositedCollateral[borrower][i];

            totalValue += ORACLE.valueInUSDT(
                address(collateralConfigs[i].token),
                amount
            );
        }
    }

    // Weighted average of token-specific maxBorrowLTVs.
    //
    // Example:
    //
    // $700 WETH @ 70%
    // $300 WBTC @ 60%
    //
    // weighted max borrow LTV =
    // (700*70% + 300*60%) / 1000
    // = 67%
    function portfolioWeightedMaxBorrowLtv(
        address borrower
    )
        public
        view
        returns (uint256)
    {
        uint256 totalValue;
        uint256 weighted;

        for (uint8 i; i < 2; ++i) {
            uint256 value = ORACLE.valueInUSDT(
                address(collateralConfigs[i].token),
                depositedCollateral[borrower][i]
            );

            totalValue += value;

            weighted +=
                value *
                collateralConfigs[i].maxBorrowLtvBps;
        }

        if (totalValue == 0) {
            return 0;
        }

        return weighted / totalValue;
    }

    // This is the "average LLTV" of the borrower's portfolio,
    // weighted by deposited collateral USD value.
    function portfolioWeightedLiquidationLtv(
        address borrower
    )
        public
        view
        returns (uint256)
    {
        uint256 totalValue;
        uint256 weighted;

        for (uint8 i; i < 2; ++i) {
            uint256 value = ORACLE.valueInUSDT(
                address(collateralConfigs[i].token),
                depositedCollateral[borrower][i]
            );

            totalValue += value;

            weighted +=
                value *
                collateralConfigs[i].liquidationLtvBps;
        }

        if (totalValue == 0) {
            return 0;
        }

        return weighted / totalValue;
    }

    // HF = liquidation-adjusted collateral / debt.
    //
    // HF > 1  => healthy
    // HF = 1  => liquidation boundary
    // HF < 1  => liquidatable
    //
    // Since there is no liquidation implementation in MVP,
    // this is currently informational + used for withdrawals.
    function healthFactor(
        address borrower
    )
        public
        view
        returns (uint256)
    {
        uint256 debt = totalDebt[borrower];

        if (debt == 0) {
            return type(uint256).max;
        }

        uint256 totalValue =
            collateralValue(borrower);

        uint256 weightedLltv =
            portfolioWeightedLiquidationLtv(borrower);

        uint256 liquidationAdjustedCollateral =
            Math.mulDiv(
                totalValue,
                weightedLltv,
                BPS
            );

        return Math.mulDiv(
            liquidationAdjustedCollateral,
            WAD,
            debt
        );
    }

    function currentLtv(
        address borrower
    )
        public
        view
        returns (uint256)
    {
        uint256 value =
            collateralValue(borrower);

        if (value == 0) {
            return totalDebt[borrower] == 0
                ? 0
                : type(uint256).max;
        }

        return Math.mulDiv(
            totalDebt[borrower],
            BPS,
            value
        );
    }

    // ------------------------------------------------------------
    // Borrower orders
    // ------------------------------------------------------------

    function createBorrowOrder(
        uint40 maturity,
        uint128 faceAmount,
        uint128 minUsdtOut,
        uint16 ltvBps
    )
        external
        returns (
            uint256 orderId,
            bytes32 strategyHash
        )
    {
        require(
            address(vaultForMaturity[maturity]) != address(0),
            "UNSUPPORTED_MATURITY"
        );

        require(
            ltvBps <= portfolioWeightedMaxBorrowLtv(msg.sender),
            "ORDER_LTV_TOO_HIGH"
        );

        orderId = nextBorrowOrderId++;

        borrowOrders[orderId] = BorrowOrder({
            borrower: msg.sender,
            maturity: maturity,
            faceAmount: faceAmount,
            minUsdtOut: minUsdtOut,
            ltvBps: ltvBps,
            filledFace: 0,
            cancelled: false
        });

        strategyHash =
            borrowStrategyHash(orderId);

        emit BorrowOrderCreated(
            orderId,
            msg.sender,
            maturity,
            faceAmount,
            minUsdtOut,
            ltvBps
        );

        // IMPORTANT:
        //
        // createBorrowOrder() only creates the app-level order.
        //
        // The borrower must also ship the corresponding
        // virtual USDT-X balance into Aqua for this app:
        //
        // maker     = borrower
        // app       = address(this)
        // strategy  = borrowStrategyBytes(orderId)
        // token     = address(vaultForMaturity[maturity])
        // amount    = faceAmount
        //
        // USDT-X does NOT exist yet.
        // It is minted JIT when a fill happens.
    }

    // ------------------------------------------------------------
    // Supplier orders
    // ------------------------------------------------------------

    function createSupplyOrder(
        uint40 maturity,
        uint128 usdtIn,
        uint128 minTermOut
    )
        external
        returns (
            uint256 orderId,
            bytes32 strategyHash
        )
    {
        require(
            address(vaultForMaturity[maturity]) != address(0),
            "UNSUPPORTED_MATURITY"
        );

        orderId = nextSupplyOrderId++;

        supplyOrders[orderId] = SupplyOrder({
            supplier: msg.sender,
            maturity: maturity,
            usdtIn: usdtIn,
            minTermOut: minTermOut,
            filledUsdt: 0,
            cancelled: false
        });

        strategyHash =
            supplyStrategyHash(orderId);

        emit SupplyOrderCreated(
            orderId,
            msg.sender,
            maturity,
            usdtIn,
            minTermOut
        );

        // Supplier then ships real USDT virtual liquidity into Aqua:
        //
        // maker     = supplier
        // app       = address(this)
        // strategy  = supplyStrategyBytes(orderId)
        // token     = USDT
        // amount    = usdtIn
    }

    // ------------------------------------------------------------
    // Matching
    // ------------------------------------------------------------

    function matchOrders(
        uint256 borrowOrderId,
        uint256 supplyOrderId,
        uint256 faceAmount,
        uint256 usdtAmount
    )
        external
    {
        BorrowOrder storage b =
            borrowOrders[borrowOrderId];

        SupplyOrder storage s =
            supplyOrders[supplyOrderId];

        require(!b.cancelled, "BORROW_CANCELLED");
        require(!s.cancelled, "SUPPLY_CANCELLED");

        require(
            b.maturity == s.maturity,
            "MATURITY_MISMATCH"
        );

        require(
            block.timestamp < b.maturity,
            "MATURED"
        );

        require(
            faceAmount <=
                uint256(b.faceAmount) -
                uint256(b.filledFace),
            "BORROW_OVERFILL"
        );

        require(
            usdtAmount <=
                uint256(s.usdtIn) -
                uint256(s.filledUsdt),
            "SUPPLY_OVERFILL"
        );

        // Borrower price constraint:
        //
        // for a proportional fill, borrower must receive at least
        // minUsdtOut * faceAmount / originalFaceAmount.
        uint256 borrowerMinUsdt =
            Math.mulDiv(
                b.minUsdtOut,
                faceAmount,
                b.faceAmount
            );

        require(
            usdtAmount >= borrowerMinUsdt,
            "BORROW_PRICE"
        );

        // Supplier price constraint:
        //
        // for a proportional fill, supplier must receive at least
        // minTermOut * usdtAmount / originalUsdtIn.
        uint256 supplierMinTerm =
            Math.mulDiv(
                s.minTermOut,
                usdtAmount,
                s.usdtIn
            );

        require(
            faceAmount >= supplierMinTerm,
            "SUPPLY_PRICE"
        );

        // Borrower's chosen order LTV must still be allowed
        // by the current collateral composition.
        require(
            b.ltvBps <=
                portfolioWeightedMaxBorrowLtv(b.borrower),
            "RISK_CHANGED"
        );

        uint256 value =
            collateralValue(b.borrower);

        uint256 newDebt =
            totalDebt[b.borrower] +
            faceAmount;

        uint256 resultingLtv =
            Math.mulDiv(
                newDebt,
                BPS,
                value
            );

        require(
            resultingLtv <= b.ltvBps,
            "BORROWER_LTV"
        );

        AquaTermVault vault =
            vaultForMaturity[b.maturity];

        // --------------------------------------------------------
        // 1. Materialize debt.
        // --------------------------------------------------------

        totalDebt[b.borrower] =
            newDebt;

        debtByVault[b.borrower][address(vault)]
            += faceAmount;

        // JIT mint USDT-X only now.
        vault.mintDebtShares(
            b.borrower,
            faceAmount
        );

        // --------------------------------------------------------
        // 2. Future USDT:
        //
        // borrower -> supplier
        //
        // Aqua consumes the borrower's virtual USDT-X offer.
        // --------------------------------------------------------

        AQUA.pull(
            b.borrower,
            borrowStrategyHash(borrowOrderId),
            address(vault),
            faceAmount,
            s.supplier
        );

        // --------------------------------------------------------
        // 3. Present USDT:
        //
        // supplier -> borrower
        //
        // Aqua consumes supplier's virtual USDT offer.
        // --------------------------------------------------------

        AQUA.pull(
            s.supplier,
            supplyStrategyHash(supplyOrderId),
            address(USDT),
            usdtAmount,
            b.borrower
        );

        b.filledFace += uint128(faceAmount);
        s.filledUsdt += uint128(usdtAmount);

        emit OrdersMatched(
            borrowOrderId,
            supplyOrderId,
            faceAmount,
            usdtAmount
        );
    }

    // ------------------------------------------------------------
    // Repayment
    // ------------------------------------------------------------

    function repay(
        uint40 maturity,
        uint256 amount
    )
        external
    {
        AquaTermVault vault =
            vaultForMaturity[maturity];

        require(
            address(vault) != address(0),
            "UNSUPPORTED_MATURITY"
        );

        uint256 debt =
            debtByVault[msg.sender][address(vault)];

        require(
            amount <= debt,
            "TOO_MUCH"
        );

        debtByVault[msg.sender][address(vault)]
            = debt - amount;

        totalDebt[msg.sender] -= amount;

        // Borrower repays real USDT directly into the maturity vault.
        USDT.safeTransferFrom(
            msg.sender,
            address(vault),
            amount
        );

        vault.recordRepayment(amount);
    }

    // ------------------------------------------------------------
    // Aqua strategy encoding
    // ------------------------------------------------------------

    function borrowStrategyBytes(
        uint256 orderId
    )
        public
        view
        returns (bytes memory)
    {
        BorrowOrder memory b =
            borrowOrders[orderId];

        return abi.encode(
            bytes32("AQUATERM_BORROW"),
            address(this),
            orderId,
            b.borrower,
            b.maturity
        );
    }

    function borrowStrategyHash(
        uint256 orderId
    )
        public
        view
        returns (bytes32)
    {
        return keccak256(
            borrowStrategyBytes(orderId)
        );
    }

    function supplyStrategyBytes(
        uint256 orderId
    )
        public
        view
        returns (bytes memory)
    {
        SupplyOrder memory s =
            supplyOrders[orderId];

        return abi.encode(
            bytes32("AQUATERM_SUPPLY"),
            address(this),
            orderId,
            s.supplier,
            s.maturity
        );
    }

    function supplyStrategyHash(
        uint256 orderId
    )
        public
        view
        returns (bytes32)
    {
        return keccak256(
            supplyStrategyBytes(orderId)
        );
    }
}
```

### 17.4 Risk model

For MVP there are exactly two collateral assets:

```text
WETH:
  maxBorrowLTV
  liquidationLTV

WBTC:
  maxBorrowLTV
  liquidationLTV
```

Example:

```text
WETH
maxBorrowLTV = 70%
liquidationLTV = 80%

WBTC
maxBorrowLTV = 65%
liquidationLTV = 75%
```

If borrower deposited:

```text
$700 WETH
$300 WBTC
```

their weighted liquidation LTV is:

```text
($700 × 80% + $300 × 75%) / $1000
= 78.5%
```

Liquidation-adjusted collateral:

```text
$1000 × 78.5%
= $785
```

If debt is:

```text
$500
```

then:

```text
healthFactor = 785 / 500
             = 1.57
```

The same weighted-average approach is used for `maxBorrowLTV`.

### 17.5 Order example

Borrower has:

```text
$1000 collateral
```

and creates:

```text
Borrow order:
500 USDT-OCT30
minimum 480 USDT now
max resulting LTV 60%
```

Supplier creates:

```text
Supply order:
480 USDT now
minimum 500 USDT-OCT30
```

Before match:

```text
Borrower collateral is already deposited.

No USDT-OCT30 has been minted.

Supplier still holds real USDT.

Aqua only stores virtual order capacity.
```

On match:

```text
1. App checks borrower portfolio LTV.

2. App calls:
   USDT-OCT30.mintDebtShares(
       borrower,
       500
   )

3. Aqua pulls:
   500 USDT-OCT30
   borrower -> supplier

4. Aqua pulls:
   480 USDT
   supplier -> borrower

5. App records:
   borrower debt += 500
```

Result:

```text
Borrower:
+480 real USDT
+500 face debt

Supplier:
-480 real USDT
+500 USDT-OCT30
```

The fixed rate is implied by the market price:

```text
480 USDT today
↔
500 USDT at maturity
```

### 17.6 No owner

The MVP app intentionally has no owner.

All permanent configuration is supplied at deployment:

```text
Aqua address
USDT address
Oracle address

WETH:
  maxBorrowLTV
  liquidationLTV

WBTC:
  maxBorrowLTV
  liquidationLTV

supported maturities
vault names
vault symbols
```

After deployment there are no admin setters.

This keeps the hackathon implementation deterministic and removes governance/admin logic from scope.
