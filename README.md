# AssetReceiver

A single constructor-configured Ethereum mainnet custody contract for ETH, USDT,
USDC and IMD. It accepts a combined **$10,000 of lifetime deposits** at the fixed
prices below. Only `0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7` can withdraw,
and all withdrawals go to that same address.

**Upgrade model:** the supplied launch check forbids `DELEGATECALL`, `CALLCODE`
and `SELFDESTRUCT`. Consequently, this project implements owner-controlled
**replacement upgrades at a new address**, not same-address proxy/code upgrades.
An upgrade permanently closes deposits on the old receiver, activates a reviewed
replacement and carries the lifetime cap forward. Existing assets stay at their
original address until the fixed withdrawal address withdraws them.

## Assets and accounting

| Asset | Mainnet address | Decimals | Fixed USD price |
| --- | --- | ---: | ---: |
| ETH | Native currency; `address(0)` in the withdrawal API | 18 | 2,600 |
| USDT | `0xdAC17F958D2ee523a2206206994597C13D831ec7` | 6 | 1 |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | 6 | 1 |
| IMD | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` | 18 | 9 |

The lifetime interpretation is an explicit assumption: partial or full withdrawals
**do not** reopen capacity. The cap is global across all depositors and assets,
including prior versions linked through replacement upgrades. There are no donor
balances, shares, refund rights or yield promises.

`totalAcceptedUsd` and `remainingCapacityUsd()` use 18 USD decimals. Each ETH wei
costs 2,600 accounting units; each USDT/USDC base unit costs 10^12; each IMD base
unit costs 9. This is exact integer arithmetic, including dust. Amounts above the
remaining cap revert completely; there is no partial acceptance. No oracle, swap,
market price, stablecoin depeg adjustment or administrative price setter is used.

Token deposits measure the actual balance increase. Transfer fees reduce the
recorded receipt; a transfer returning success without increasing the balance is
rejected. OpenZeppelin SafeERC20 supports USDT's empty return data and rejects
false returns. Rebasing tokens and malicious token balance reports are not supported.

ERC20 `transfer(receiver, amount)` does not execute the receiver, and ETH can be
forced into a contract. Such unsolicited transfers cannot be blocked by a cap or
pause. They are **not accepted/accounted deposits**, can make actual holdings
exceed $10,000, and can be recovered only by the fixed withdrawal address.
Never send tokens directly when a recorded deposit is intended.

## Calls and permissions

- `depositETH()` or an empty-calldata ETH call: accepts ETH while active and
  unpaused. Send enough gas to execute accounting; a 2,300-gas `transfer` is unsuitable.
- `depositToken(asset, amount)`: approve this receiver for the exact raw amount
  first, then call as the token holder. Only the three listed ERC20s are accepted.
- `withdraw(asset, amount)` / `withdrawAll(asset)`: fixed withdrawal address only;
  always pays that address. Any positive amount up to the actual balance is allowed,
  including the full balance, during a pause and after retirement. Other ERC20s
  can also be recovered through this same restricted API. Empty withdrawals revert.
- `pause()` / `unpause()`: owner only; affect deposits. Retired receivers cannot
  reopen deposits. A pending replacement cannot accept deposits before activation.
- `transferOwnership(newOwner)` then `acceptOwnership()`: two-step administration
  transfer. A new nomination replaces the old nomination. Zero and the receiver
  itself are invalid owners. Ownership does not grant withdrawal rights. There is
  no renounce function and no ability to change the withdrawal address.
- `upgradeTo(replacement)`: owner only, with the current receiver paused and active
  in its lineage. Publishes the successor once and permanently retires deposits here.

All financial operations and administration changes are guarded against reentrancy.
Deposits, withdrawals, pause changes, ownership handovers and upgrades emit events.
Unknown calldata reverts.

## Deployment and replacement procedure

Deploy `src/AssetReceiver.sol:AssetReceiver` with zero ETH and two static arguments:

1. `initialOwner`: the actual launch administrator (`$owner` in `launch.json`).
   This may differ from the fixed withdrawal address. The deploying factory is
   never implicitly assigned ownership.
2. `previousReceiver`: `0x0000000000000000000000000000000000000000` for the initial
   deployment; the old receiver address for a replacement.

There is no initializer, proxy, linked library deployment or post-deployment setup.
The contract is intended for Ethereum mainnet (chain ID 1). Token addresses are
fixed; there is no chain-ID guard, so deploying it on another chain does not make
those chains' token contracts supported.

To replace a running receiver:

1. The owner pauses deposits on the old receiver.
2. Review and deploy the replacement with the same owner and the old address as
   `previousReceiver`. Construction snapshots the accepted total. It must expose
   the compatible getters used by `upgradeTo` and enforce the same activation/cap
   semantics. The new contract cannot accept deposits yet.
3. The owner calls `old.upgradeTo(new)`. This checks the owner, withdrawal address,
   cap, predecessor, unchanged accepted total and absence of a successor. If old
   deposits resumed and changed the total meanwhile, deploy a fresh candidate.
4. Update clients to the new address and obtain new token approvals. Existing
   approvals do not migrate. Revoke old approvals where practical.
5. The fixed withdrawal address can independently withdraw old balances whenever
   desired. There is no automatic asset or donor-state migration. Redeploying a
   fresh unrelated root is a new collection, outside the old lineage's cap.

Already collected assets should not be redeposited into a successor: their value
has already consumed the carried lifetime cap, and another deposit counts again.
Getter checks cannot prove a replacement is honest. Owners and reviewers are
responsible for its bytecode and accounting. A replacement is a new deployment
that needs its own launch approval and review; this repository does not broadcast.

## Build and validation

Solidity is pinned to **0.8.26**, Cancun, optimizer 200 runs, with
`bytecode_hash = "none"`. FFI and filesystem permissions are disabled. All Solidity
dependencies are ordinary files in `lib/`; no installation or RPC is needed by tests.
An offline runner needs Foundry and the pinned compiler already installed.

```sh
forge build
forge test
forge fmt --check
```

Tests use local token doubles at the mainnet addresses. They cover mixed-asset cap
boundaries, dust, failed transfers and rollback, permissions, pause, partial/full
withdrawals, callbacks, forced balances, constructor/factory behavior, replacement
handoffs, and the protected runtime opcode/size rules. Fuzz and stateful invariant
tests check exact valuation, conservation and the lifetime cap across deposits,
withdrawals, pauses and multiple replacements. Tests do not read environment
variables, fork a network or broadcast transactions.

## Operational responsibilities and evidence

Token addresses match [Circle's USDC documentation](https://developers.circle.com/stablecoins/usdc-contract-addresses)
and [Tether's supported protocols](https://tether.to/en/supported-protocols/); the IMD
address is specified by the assignment. A read-only Ethereum mainnet RPC check at
block **26,134,580**, chain ID 1, found nonempty bytecode and confirmed symbols and
decimals for all three tokens (USDT/6, USDC/6, IMD/18). This check is not a live-token
integration test or a guarantee about later token upgrades.

The deployer must confirm chain, addresses, constructor arguments, runtime and
control of the designated accounts. The owner maintains clients and pause/upgrade
operations. The withdrawal address must safeguard its signing authority: loss of
that authority cannot be repaired by the owner. Token issuer pauses, blocklists,
fees or changed implementations can delay or prevent token withdrawals. An ETH
recipient that reverts also prevents that payout; the failed transaction leaves
funds in the receiver. "Any time" means this receiver adds no time lock or pause
restriction to withdrawals; it cannot override external token or recipient failures.

The tests and local review are not an independent security audit. A separate
adversarial review is required before holding real funds. Slither/Mythril and a
mainnet fork integration suite were not run.
