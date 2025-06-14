# Vault

A collection of Solidity contracts for asset management.
Includes an ERC4626 vault with cross-chain bridging, a multisignature wallet, and a timelock controller.

```mermaid
graph LR
  MS[MultiSigWallet]
  TL[TimeLock]
  LV[L1Vault]
  MS -- "owner of" --> TL
  TL -- "owner of" --> LV
```

### `L1Vault.sol`

An ERC4626 vault for USDC that supports:
- cross-chain bridging to an L1 vault via precompile and custom writer
- management fee accrual and spread adjustments
- emergency pause and buffered withdrawals

### `MultiSig.sol`

A 2-of-3 multisignature wallet that lets a predefined set of three owners:
- submit transactions
- confirm and execute once at least two approvals are gathered

### `TimeLock.sol`

A simple timelock controller where the owner can:
- queue calls with a minimum delay
- cancel queued calls
- execute after the timelock has passed


---


# Steps

1. Deploy contracts (`deploy.js`)
2. Send *1 HYPE* to the `contract address` on HypeCore to activate L1 account.
3. Deposit assets into the vault (`1_deposit.js`)
4. Withdraw assets *after the vault deposit lock-up period* (`2_withdraw.js`)
5. Bridge assets and finalize *after the vault withdrawal lock-up period* (`3_finalize.js`)


---


# Memo

<!-- - To activate your account on HypeCore, after deploying the contract, send funds to the `contract address` to receive them. -->
- Since precompiled calls never fail, you need to separately verify their success on L1.
