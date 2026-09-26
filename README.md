AquaTerm
========

Fixed-rate term JIT lending with shared collateral across maturities, powered by 1inch Aqua

Description
-----------

AquaTerm is a fixed-rate, fixed-maturity just-in-time lending protocol built on 1inch Aqua. Borrowers can quote debt across multiple maturities without pre-locking separate collateral for every open order, while suppliers can quote the same liquidity across multiple term markets. Because Aqua orders use virtual balances rather than custodial escrow, uncommitted balances remain available until a match executes. That means both borrowers and suppliers can keep the same collateral and liquidity active in other Aqua strategies and continue earning yield on them.

Collateral in the borrower's wallet remains free to use in Aqua strategies until it is actually pulled at fill time. AquaTerm only counts collateral already deposited in the app toward LTV; wallet balances enter the portfolio only when a match requires a top-up. The borrower specifies a maximum resulting portfolio LTV — an execution bound on leverage: the match reverts if, after the fill, total debt across all maturities would exceed this fraction of collateral value for that borrower. In practice, it works like slippage protection for leverage: if oracle prices move, multiple orders fill in sequence, or the required wallet top-up would leave the borrower more leveraged than they agreed to, the trade simply does not execute. It does not force a fixed collateral transfer — the app pulls only the shortfall from the chosen wallet token, using any collateral already deposited first.

The loan asset, such as USDT, stays in the supplier's wallet while the order is open and can likewise participate in other Aqua strategies. On execution, USDT is pulled from the supplier to the borrower via Aqua; only then does the borrower receive spot liquidity. Simultaneously, maturity shares are minted just in time — ERC-4626 vault tokens representing fixed-maturity claims such as USDT-OCT30, USDT-NOV30, or USDT-JAN30. These shares are pulled from the borrower to the supplier as payment for the spot USDT. They are standard transferable ERC-20 tokens, tradable on a secondary market, and can be shipped into Aqua strategies like any other token. After maturity, each share redeems pro-rata against the vault's USDT cash via ERC-4626 `redeem` or `withdraw`. If all receivables are repaid in full, maturity shares redeem 1:1 against USDT.

Each maturity is represented by an ERC-4626 vault whose shares are tradable maturity claims. For example, a supplier may exchange 480 USDT today for 500 USDT-OCT30, which becomes redeemable against the vault at maturity. The discount between spot USDT and the maturity claim determines the fixed rate. If bad debt occurs — for example, a borrower is fully liquidated and the remaining collateral is insufficient to cover the receivable — the vault writes down the unpaid portion. This reduces total debt and therefore the NAV of the maturity shares, causing current holders of that maturity to absorb the loss proportionally. A later repayment by the borrower can still restore vault value for the remaining holders.

AquaTerm uses Aqua virtual balances to keep orders non-custodial until execution. Posting an order creates neither debt nor an additional collateral lock. When compatible borrower and supplier orders are matched, collateral is pulled only if required, maturity shares are minted just in time, and both sides of the trade settle atomically through Aqua.

Borrower collateral is shared across debts of different maturities under a single portfolio health factor. Maturity claims are transferable and can be traded on the secondary market before expiry.

An unhealthy borrower can be liquidated against one maturity's debt and one collateral token. After maturity, outstanding debt can also be liquidated when the borrower is healthy. The liquidator receives collateral at the configured per-token liquidation discount, pays the debt token into that maturity vault, and may use a callback to exchange collateral and fund repayment atomically. If all of the borrower's collateral is exhausted, remaining performing debt across maturities is written down, while the borrower still owes it and later repayment restores vault value. The contracts and tests have not been audited.


How it's made
-------------

AquaTerm is built around 1inch Aqua as its execution and liquidity layer. The core Solidity contract, AquaTermApp, uses Aqua virtual balances so borrowers and suppliers can post term orders without locking assets upfront. Their collateral and USDT remain available to other Aqua strategies while the orders are open, and real token transfers happen only when two compatible orders are matched.

The most unusual part is how we handle fixed-maturity debt. Every maturity has its own ERC-4626 vault, such as USDT-OCT30 or USDT-JAN31. These derivative tokens are designed to redeem approximately 1:1 for USDT at maturity, assuming the underlying loans are fully repaid. Borrowers can advertise these maturity shares through Aqua before the shares actually exist. When a match executes, AquaTerm checks the borrower's portfolio LTV, pulls only the additional collateral required, mints the maturity shares just in time, and immediately settles the trade through Aqua: the supplier's USDT goes to the borrower, while the freshly minted maturity shares go to the supplier. This all happens atomically in a single transaction.

The derivative tokens are implemented as ERC-4626 vault shares so that, in the event of bad debt, losses can be socialized across the current holders of the maturity claims. The maturity vaults track both cash and outstanding loans in their NAV, allowing the maturity tokens to behave as transferable fixed-income claims that can be traded before expiry.

Risk is managed at the borrower portfolio level across multiple maturities and collateral types, with Chainlink price feeds used for collateral valuation, LTV checks, and liquidations. The contracts have no owner or admin setters; protocol parameters are fixed at deployment.

We built a lightweight Python indexer using Flask, web3.py, and SQLite. It watches the AquaTerm contracts for borrower and supplier orders, reconstructs the live orderbook, and exposes it to the frontend.

Matching is permissionless and incentivized: anyone can execute crossed orders, and the spread between the borrower's minimum price and the supplier's maximum price becomes the executor's reward.

The frontend is a lightweight static app built with vanilla JavaScript and ethers v6. It talks directly to the contracts for transactions and uses the indexer only for market discovery and orderbook data. The whole stack is intentionally simple and hackathon-friendly: Solidity and Foundry onchain, a small Python service for indexing, and a static frontend with no build pipeline.

## Mock API and frontend

For local frontend development, run the deterministic Python mock API:

```bash
python3 server/mock_app.py
```

It listens on `http://127.0.0.1:5002` and exposes the same read endpoints as the chain-backed API: `/api/health`, `/api/market`, `/api/portfolio`, `/api/orders` and `/api/orderbook`. The static frontend requests this API automatically. To use another API URL, define `window.AQUA_API_BASE` before loading `api.js`.
