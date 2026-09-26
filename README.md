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


How it's made
-------------

The on-chain core is Solidity on Foundry: `AquaTermApp` extends 1inch Aqua’s `AquaApp`, settles matches with `Aqua.pull()`, and mints one OpenZeppelin ERC-4626 `AquaTermVault` per maturity. Chainlink feeds price collateral; bad-debt write-downs flow through a custom `totalAssets()` that tracks cash plus performing receivables minus losses. Tests deploy the real Aqua contract and exercise full `ship` → `matchOrders` → repay/redeem flows.

The hacky part is leaning on Aqua virtual balances: borrowers `ship` maturity shares that do not exist yet, suppliers `ship` spot USDT from wallet, and nothing moves until a permissionless matcher fills compatible orders — at which point collateral is pulled just-in-time, shares are minted, and both legs settle atomically. The matcher keeps any spread.

Off-chain, a Flask API indexes chain events into a DB and exposes an order book, portfolio views, and match suggestions. The frontend is static HTML/CSS/JS with ethers v6 for wallet connect, `create*Order`, `ship`, and `matchOrders`. No separate frontend build step — the demo is meant to plug into Aqua’s existing strategy UX.
