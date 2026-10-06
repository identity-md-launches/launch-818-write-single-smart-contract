# AssetReceiver test coverage

Run `forge build` and `forge test`. No new dependencies, environment variables,
RPC access, or configuration changes are required. The additional suites extend
the existing tests and reuse their offline ERC20 fixture.

- `AssetReceiver.boundaries.t.sol`: four properties run 1,000 cases each. They
  check remaining-cap boundaries after earlier deposits, splitting amounts across
  depositors, partial/full withdrawal through each lifecycle state, and actual
  fee-adjusted receipts and events. Deterministic cases exercise maximum uint256,
  100% fees, gross-versus-net cap boundaries, caller-specific token debits, receive
  failures, and rollback/recovery for every token withdrawal failure mode.
- `AssetReceiver.administration.t.sol`: stale ownership nominees, repeated state
  changes, ownership changes during replacement preparation, competing replacement
  lineages, and privileged callbacks during deposits and withdrawals.
- `AssetReceiver.adversarial.invariant.t.sol`: 256 sequences of 96 calls, three
  depositors, two possible administrators, the fixed withdrawal recipient, and up
  to five receiver generations. Seven targeted operations interleave deposits,
  withdrawals, token donations, pause changes, ownership handoffs, unauthorized
  administration, and upgrades. Inputs include zero, one unit, the remaining cap,
  one unit over it, full balances, and excess withdrawals. Expected reverts are
  handled inside the handler; unexpected handler reverts fail the campaign.

The invariant model records accepted deposits, unsolicited token transfers,
withdrawals, ownership, and pause state separately from the contract. It checks
each receiver's custody, exact conservation across all funded actors and the
recipient, the cumulative priced deposit cap across generations, and the upgrade
lineage. Failure paths must preserve balances, allowances, and administration.
Every sequence ends by draining every nonempty asset balance from every generation
and rechecking the invariants, exercising withdrawal availability after arbitrary
pause, ownership, and upgrade sequences.

The existing implementation interprets the limit as **lifetime accepted deposits**
and upgrades as retirement plus activation at a new address. These tests retain
that established interpretation. Forced ETH and direct ERC20 transfers cannot be
prevented by the receiving contract; the deposit cap is not an absolute bound on
its on-chain balance. Donations are tracked separately in the conservation model.

Integration limits: the suite uses local six-decimal USDT/USDC and eighteen-decimal
IMD stand-ins, including empty ERC20 return data and configurable failure/fee/
callback behavior. It does not verify deployed mainnet bytecode, IMD decimals, or
live token pause, blacklist, and upgrade state. A pinned mainnet fork integration
run against the configured token addresses remains outstanding; none is required
for the default offline suite.
