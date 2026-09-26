# AquaTerm MVP

Foundry implementation of the fixed-maturity Aqua borrowing example in [aquaterm_mvp_spec.md](aquaterm_mvp_spec.md). It compiles against the published 1inch Aqua contract and interfaces, OpenZeppelin ERC-4626, and Chainlink's data-feed interface.

## Dependencies and tests

Install the pinned Solidity dependencies (once per checkout):

```bash
forge install --no-git --shallow \
  OpenZeppelin/openzeppelin-contracts@v5.5.0 \
  1inch/aqua@v1.0.0 \
  1inch/solidity-utils@6.9.7 \
  smartcontractkit/chainlink-evm@contracts-v1.4.0
forge test
```

The `lib/` directory contains downloaded dependencies and is ignored by Git. `remappings.txt` pins the import paths. Foundry needs Solidity 0.8.30 because the published Aqua implementation uses that exact compiler version. The target EVM is Cancun, which supports Aqua's transient-storage reentrancy locks.

The tests deploy the real `Aqua` contract, ship strategies using its actual `ship(app, strategy, tokens, amounts)` API, and settle with `pull()`. They cover loan origination, just-in-time collateral pulls, existing and partial collateral deposits, insufficient wallet collateral, ERC-4626 redemption, write-down and late recovery, normal liquidation, bad-debt cohort accounting, and Chainlink price validity.

## Contracts

`AquaTermApp` creates one `AquaTermVault` per maturity. The configured `debtToken` is the asset issued to borrowers and repaid to the vault. The number of supported collateral tokens is configured at deployment (`N_COLLATERAL`) along with each token's risk limits. A borrower posts an order with a maximum resulting LTV and chooses a collateral index for any wallet top-up; a supplier posts a debt-token offer. Both ship their corresponding virtual balances into Aqua. At a match, the app counts the borrower's existing collateral deposits and transfers only the shortfall from the chosen wallet token. It checks the order LTV and token-weighted protocol limits, mints maturity shares, and atomically pulls shares and debt tokens through Aqua. Each party receives its quoted minimum; any remaining debt tokens or maturity shares are paid to the caller that submitted the match. Posting or shipping alone creates no debt or collateral transfer. Borrowers can still use `depositCollateral()` and `withdrawCollateral()` independently.

`AquaTermVault` inherits OpenZeppelin ERC-4626. Its `totalAssets()` includes cash plus outstanding loans minus write-downs. Shares are minted only when a loan fills, at the vault's current NAV (`previewDebtShares(faceAmount)`), so a later loan does not inherit losses recorded before it originated; direct `deposit()` and `mint()` are disabled. `withdraw()` and `redeem()` become available at maturity, limited by the vault's actual USDT cash. A write-down lowers the value of existing shares but does not forgive the borrower's debt; a later repayment restores the written-down value.

`ChainlinkOracle` reads one configured USD feed per collateral token and one for USDT. Its constructor takes the token/feed arrays and maximum permitted age for each feed. It rejects missing, non-positive, incomplete, future-dated or stale answers, and converts token decimals into USDT's native units. Feed addresses and age limits must be selected for the deployment network.

An unhealthy borrower can be liquidated against one maturity's debt and one collateral token. The liquidator receives discounted collateral, pays USDT into that maturity vault, and may use a callback to exchange collateral and fund repayment atomically. If all of the borrower's collateral is exhausted, remaining performing debt across maturities is written down, while the borrower still owes it and later repayment restores vault value. Liquidation uses a fixed 5% minimum discount that grows with the health-factor shortfall up to 15%. The contracts and tests have not been audited.
