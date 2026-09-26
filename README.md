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

The tests deploy the real `Aqua` contract, ship strategies using its actual `ship(app, strategy, tokens, amounts)` API, and settle with `pull()`. They cover loan origination, ERC-4626 redemption, over-capacity rejection, write-down and late recovery, and Chainlink price validity.

## Contracts

`AquaTermApp` creates one `AquaTermVault` per maturity. A borrower posts an order backed by collateral, a supplier posts a USDT offer, and both ship their corresponding virtual balances into Aqua. An order match checks portfolio LTV, mints the maturity shares, and atomically pulls shares and USDT through Aqua. Posting or shipping alone creates no debt.

`AquaTermVault` inherits OpenZeppelin ERC-4626. Its `totalAssets()` includes cash plus outstanding loans minus write-downs. Shares are minted only when a loan fills, so direct `deposit()` and `mint()` are disabled. `withdraw()` and `redeem()` become available at maturity, limited by the vault's actual USDT cash. A write-down lowers share value but does not forgive the borrower's debt or release collateral; a later repayment restores the written-down value.

`ChainlinkOracle` reads WETH/USD, WBTC/USD and USDT/USD feeds. Its constructor takes the feed addresses and maximum permitted age for each feed. It rejects missing, non-positive, incomplete, future-dated or stale answers, and converts token decimals into USDT's native units. Feed addresses and age limits must be selected for the deployment network.

This MVP has no liquidation or collateral-recovery path. In a real default, collateral therefore remains locked and a write-down represents an accounting loss until recovery is implemented. The contracts and tests have not been audited.
