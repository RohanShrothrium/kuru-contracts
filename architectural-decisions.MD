# Architectural Decisions

## 2026-09-03: Owner balance override

Status: accepted

`MarginAccount.overrideBalance(userAddress, tokenAddress, newBalance)` sets an account's absolute internal balance and is restricted to the contract owner. It emits both the previous and new balances for auditability.

The function intentionally remains available while the protocol is paused so the owner can perform recovery or reconciliation before resuming operations. It does not move tokens, so the owner is responsible for ensuring the resulting aggregate internal balances remain backed by assets held by the margin account.
