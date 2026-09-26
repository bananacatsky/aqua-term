# AquaTerm MVP

Dependency-free Foundry implementation of the fixed-term Aqua borrowing MVP in `aquaterm_mvp_spec.md`.

`AquaTermApp` deploys one `AquaTermVault` per maturity. Orders are merely app records plus `MockAqua.ship()` virtual balances; a match atomically checks portfolio LTV, mints term shares, and uses Aqua `pull()` for both legs. No debt or term shares are created by posting an order.

Run when Foundry is available:

```bash
forge test
```

The test suite covers JIT origination, the shared-capacity overfill revert, repayment/redemption, and maturity write-down accounting. `MockAqua` is intentionally a small stand-in for the version-specific 1inch Aqua API; replace only the `IAqua` adapter when integrating the deployed protocol.
