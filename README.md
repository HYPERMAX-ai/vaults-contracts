# Steps

1.	Deploy contracts (`deploy.js`)
2.	Deposit assets into the vault (`1_deposit.js`)
3.	Withdraw assets *after the vault deposit lock-up period* (`2_withdraw.js`)
4.	Bridge assets and finalize *after the vault withdrawal lock-up period* (`3_finalize.js`)

---

# Memo

- To activate your account on Core, after deploying the contract,
send funds from Core to the `contract address` to receive them.
- Since precompiled calls never fail, you need to separately verify their success on L1.
