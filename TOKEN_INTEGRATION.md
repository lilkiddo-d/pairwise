# $PAIR token integration

**Pairwise does not write or deploy any ERC-20.** $PAIR launches separately on a launchpad. The protocol runs fully
without it; every token feature is inert until the token address is plugged in.

## Where the token is used

`ProjectTokenHooks` (deployed by `Deploy.s.sol`, admin = 48h Timelock) is the only contract that knows about $PAIR.

| Feature | Before `setProjectToken` | After |
|---|---|---|
| Staking (`stake` / `unstake`) | reverts `TokenNotSet` | stake $PAIR; unstake any time (never paused, never compliance-gated) |
| Fee share | `FeeCollector.harvest` sends 100% to treasury (`rewardsActive()` = false) | `stakerShareBps` (default **50%**, max 50%) of *performance* fees goes to stakers in USDG, streamed over 7 days |
| Pair proposals (`proposePair`) | reverts `TokenNotSet` | stakers with ≥ `proposalThreshold` (default 10,000 PAIR) propose `tokenA/tokenB + rationale`; 1-day cooldown per proposer |
| Listing | Timelock calls `PairVaultFactory.createVault` | unchanged: proposals are signals; listing still needs a 48h Timelock tx, after which the Timelock marks the proposal `LISTED`/`REJECTED` |

## `setProjectToken(address)`

- Callable **once**, only by `DEFAULT_ADMIN_ROLE` (the Timelock ⇒ 48h public delay).
- Rejects the zero address, EOAs (no code) and the reward token (USDG).
- The exact `schedule` / `execute` commands are in DEPLOY.md §5.

Before scheduling, check the token: standard ERC-20, no transfer hooks that can block `unstake`, sensible decimals
(rewards math is decimal-agnostic). Fee-on-transfer tokens are handled (staking credits the amount actually received).

## Frontend

`NEXT_PUBLIC_PROJECT_TOKEN` (Vercel env):
- **empty** → the Stake nav item and `/stake` page are hidden; nothing token-related renders.
- **set** → `/stake` shows wallet/staked/claimable balances, stake/unstake/claim and the proposal form. If the on-chain
  `projectToken()` doesn't match yet (Timelock still pending), the page says so and disables actions.

Set it only after the Timelock `execute` has landed, then redeploy the app.

## Tests

`test/TokenAndFees.t.sol` uses a `MockERC20` stand-in to cover: disabled-by-default behaviour (fees → treasury),
one-shot Timelock-only setter, pro-rata streamed rewards and anti-sniping, carry-over when nobody stakes, proposals and
thresholds, compliance gating, and the 48h Timelock path for `setProjectToken`.
