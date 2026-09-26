# AquaTerm — MVP specification

Fixed-rate, fixed-maturity collateralized borrowing using 1inch Aqua virtual balances. This document describes intended behavior in pseudocode. The Solidity implementation is in `src/`.

## 1. Idea

A borrower sells a claim on future USDT to receive less USDT today. For example, a supplier pays 480 USDT now for 500 USDT of maturity shares. The borrower owes 500 USDT at maturity; the 20 USDT difference is the supplier's fixed yield if the debt is repaid in full.

There is one ERC-4626 vault per maturity. Its underlying asset is USDT, and its shares are the maturity claims. `AquaTermApp` holds borrower collateral, tracks debt across all maturities and settles matches through Aqua.

## 2. Orders and virtual balances

Collateral tokens are configured at deployment; their number is `N_COLLATERAL` and is not hard-coded. For the example deployment, collateral can be WETH or WBTC. The borrower may deposit any configured token into `AquaTermApp` before an order fills, using `depositCollateral(collateralId, amount)`. An advance deposit is optional. `withdrawCollateral` remains available subject to the borrower's portfolio health check.

A borrow order records:

```text
borrower
maturity
face amount of future USDT to sell
minimum spot USDT to receive
maximum portfolio LTV immediately after each fill
collateral token to pull from the wallet if a top-up is needed
amount already filled / cancellation state
```

A supply order records the supplier, maturity, spot USDT offered, minimum maturity shares required, amount already filled and cancellation state.

Each party separately calls Aqua `ship` with the bytes of its app order and a virtual balance: maturity shares for the borrower, USDT for the supplier. `ship` does not transfer tokens. Maturity shares do not exist yet; the app mints them only when a borrow order fills. The borrower approves the chosen collateral token to `AquaTermApp` for any wallet top-up and approves the maturity shares to Aqua. The supplier approves USDT to Aqua.

Several unfilled orders may advertise the same borrowing capacity across maturities. Posting or shipping an order does not create debt or transfer additional collateral. Aqua stores virtual balances; it does not find matching AquaTerm orders. A caller must identify compatible orders and submit the match transaction.

## 3. Collateral and risk

The app values only collateral already held for a borrower; wallet balances do not count until transferred. One Chainlink USD feed per configured collateral token and a USDT/USD feed convert token amounts to USDT's native units. Answers must be positive, complete and fresh. Risk limits are configured for each collateral token at deployment:

```text
token maxBorrowLtvBps < token liquidationLtvBps <= 10,000
```

At a fill, let `newDebt` be the borrower's total face debt across all maturities after the proposed fill. Let `value[i]` be the current USDT value of collateral token `i` already deposited for that borrower. The borrower's order LTV is a ceiling on the resulting portfolio ratio; it is not an instruction to transfer a fixed amount of collateral.

```text
existingValue = sum(value[i])
existingCapacity = sum(value[i] * maxBorrowLtvBps[i])
debtBasis = newDebt * 10,000

valueNeededForOrder = max(0,
    ceil(debtBasis / order.maxResultingLtvBps) - existingValue)

valueNeededForProtocol = ceil(
    max(0, debtBasis - existingCapacity)
    / maxBorrowLtvBps[order.walletTopUpCollateralId])

walletTopUpValue = max(valueNeededForOrder, valueNeededForProtocol)
walletTopUpAmount = round_up_to_token_units(
    walletTopUpValue, current Chainlink price of chosen token)
```

If `walletTopUpValue` is zero, no collateral is taken from the wallet. Otherwise, the app transfers exactly `walletTopUpAmount` of the token chosen in the borrow order from the borrower's wallet and credits that amount to their deposited collateral. An insufficient wallet balance or allowance reverts the entire match. The app rejects fee-on-transfer collateral. After the transfer it checks both the order's resulting LTV ceiling and the token-weighted protocol borrowing limit again.

Example: a 500 USDT debt at a 60% order LTV needs at least 833.333334 USDT of collateral value (rounded up in USDT units). If 500 USDT of collateral value is already deposited, only the remaining value is pulled from the chosen wallet token. If enough collateral is already deposited, nothing is pulled.

The health factor for withdrawals and liquidations uses the portfolio's token-weighted liquidation limits. With outstanding debt, `withdrawCollateral` must leave the health factor at least 1. Repayment does not automatically return collateral; the borrower uses `withdrawCollateral` after the debt falls sufficiently.

## 4. Atomic match

Any caller may propose two order IDs and fill amounts. The app performs the following steps as one transaction:

```text
require both orders active and for the same unexpired maturity
require positive amounts within both orders' unfilled balances
require both parties' minimum exchange rates are satisfied

newDebt = borrower.totalDebt + faceAmount
count the borrower's existing deposits across all configured collateral tokens
pull only a required wallet collateral shortfall, if any
recheck order LTV and protocol borrowing limit

record the new borrower debt, globally and for this maturity vault
shares = vault.previewDebtShares(faceAmount) // current NAV before this loan is added
mint shares to the borrower against the new faceAmount receivable
Aqua.pull shares from borrower to supplier
Aqua.pull spot USDT from supplier to borrower
record the filled amounts and emit the match event
```

The app mints the shares before Aqua transfers them. The real tokens move only during the match. If any check, collateral transfer or Aqua pull fails, the whole transaction reverts, including the collateral top-up and debt creation. Later fills recompute risk against the updated aggregate debt and current prices.

## 5. Vault accounting, repayment and redemption

The ERC-4626 vault's `totalAssets` reflects economic net asset value:

```text
vault USDT cash + total outstanding face debt - debt written down
```

Shares originate only from filled loans. Direct ERC-4626 `deposit` and `mint` are disabled. New debt shares are minted at the vault's current NAV (`convertToShares(faceAmount)`, before adding the new receivable). Therefore a loan originated after a write-down does not give its supplier exposure to losses already borne by earlier shares. A borrower repays USDT to the relevant vault through the app; face debt falls as vault cash rises, so a normal repayment does not change net asset value. A late recovery of previously written-down debt increases net asset value.

After maturity, holders may use ERC-4626 `withdraw` or `redeem`, limited by actual vault USDT cash. Full repayment should make one maturity share worth approximately one USDT unit. If some debt remains unpaid, a holder may have to wait for more cash before redeeming all shares.

## 6. Liquidation and bad debt

Any account may liquidate a borrower whose portfolio health factor is below 1. A liquidation targets one maturity's debt and one of the borrower's collateral tokens:

```text
require healthFactor(borrower) < 1
require 0 < debtAmount <= borrower's debt for the chosen maturity

discount = min(15%, 5% + (1 - healthFactor))
collateralValueToSeize = debtAmount / (1 - discount)
collateralToSeize = min(
    collateral token amount worth collateralValueToSeize,
    borrower's deposited amount of that token)

reduce the borrower's chosen-maturity debt by debtAmount
transfer collateralToSeize to the liquidator
optionally call the liquidator callback
pull debtAmount USDT from the liquidator into the maturity vault
record repayment; clear previously written-down debt first

if the borrower has no collateral remaining across all configured collateral tokens:
    write down all remaining performing debt across their maturity vaults
```

All operations are atomic. The optional callback lets a liquidator exchange seized collateral and approve USDT in the same transaction. If the callback, payment or any accounting operation fails, the entire liquidation reverts.

Bad debt reduces vault net asset value and shares the loss across that maturity's holders. A write-down does not forgive the borrower's debt. If the borrower later repays, the recovered amount restores vault value. Collateral is not automatically returned after repayment; the borrower withdraws it through `withdrawCollateral` while healthy.

The MVP still has no matching service, variable rates, second debt asset, governance or insurance. Aqua supplies virtual balance accounting and token transfer operations; AquaTerm supplies the loan, collateral, price, maturity and liquidation rules.

All permanent configuration is set at deployment: Aqua, USDT, oracle, supported maturities, collateral tokens and their borrow/liquidation LTV limits. The app has no owner or admin setters.
