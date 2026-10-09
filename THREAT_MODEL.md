# Threat model

Scope: `contracts/src/*` as deployed by `script/Deploy.s.sol` on Robinhood Chain (4663), plus the keeper and frontend.
Status: **unaudited**. Slither: 0 High / 0 Medium. Tests: 129 unit/fuzz/invariant + 5 mainnet-fork, 97.5% line coverage.

## Assets and actors

| Asset | Where |
|---|---|
| Depositor USDG | idle in `PairVault`; long leg in `LongAdapter`; collateral (steakUSDG) in Morpho under `ShortAdapter` |
| Fee shares / treasury USDG | `FeeCollector` |
| Staked $PAIR + USDG rewards | `ProjectTokenHooks` |

| Actor | Can | Cannot |
|---|---|---|
| Depositor | deposit, redeem (always when flat; in market hours when in a trade) | move positions |
| Keeper (`KEEPER_ROLE`) | trigger `execute` when `check()` says so; seed history | choose direction, size, timing, slippage |
| Guardian | pause vaults/engine/staking; `emergencyExit` (≤5% slippage); edit holiday calendar | unpause, change parameters, move funds |
| Timelock (48h) | all admin: parameters (within hard caps), oracle/venue swaps, listings, `setProjectToken`, treasury | raise fees above 1% / 15%; bypass the 48h delay |
| Anyone | `recordClose` after the close, `updateHedgeRatio` weekly, `harvest` fees | anything else |

## Top risks (as required)

### 1. Short-leg recall or liquidation
*Threat.* Morpho lenders can't recall an open borrow, but they can withdraw idle supply, pushing utilization to 100% and the
adaptive IRM's rate up sharply; a rally in the shorted stock pushes LTV towards LLTV and liquidation (with a penalty).
*Mitigations.*
- Entry LTV = 65% of LLTV; keeper rebalances above 75%; every position-changing action reverts if LTV > 80% of LLTV
  (invariant `invariant_shortLegUnderSafeLtv`).
- Rebalance first tops up collateral from the 10% reserve, otherwise cuts both legs by the same fraction while *keeping*
  collateral (`deleverage`), restoring LTV and neutrality together.
- Engine exits when borrow APR > 50% (`EXIT_BORROW_COST`); entries are capped at 90% of available borrow liquidity.
- Guardian `emergencyExit` works outside market hours and while paused.
- A liquidated position is handled: equity reads zero debt/collateral and exits still settle (tested).
*Residual.* Liquidity is thin today (~$400–1,000 per market); a fast gap overnight can still liquidate.

### 2. Correlation breakdown
*Threat.* An idiosyncratic event decouples the legs; the spread trends instead of reverting.
*Mitigations.* Entry requires return correlation ≥ 0.5; correlation < 0.2 forces an exit; stop at |z| ≥ 3.5; never
enters beyond the stop; max holding 20 days; per-pair isolation (one vault per pair, separate adapters).
*Residual.* Stops on daily-close statistics can be hit late on gaps; losses up to the stop distance plus gap are expected.

### 3. Keeper front-running / manipulating entries
*Threat.* A keeper (or MEV searcher) times entries against a manipulated pool or oracle, or sandwiches vault swaps.
*Mitigations.*
- Keepers cannot pass direction, size or prices; `StrategyEngine.check()` derives everything from Chainlink.
- Signals must persist through a 15-minute arm → confirm window.
- Every swap is bounded by an oracle-derived `minOut` / `maxIn` (≤0.5% default) and a deadline (≤1h); the venue
  re-measures delivered balances. A skewed pool makes the transaction revert rather than fill badly (tested).
- Post-entry dollar-neutral band check (±10%) and LTV check.
- Robinhood Chain is an Arbitrum Orbit chain with a first-come-first-served sequencer and no public mempool.
*Residual.* A malicious keeper can only delay actions (liveness), which the guardian/Timelock can address by granting the role elsewhere.

## Other threats

| Threat | Mitigation |
|---|---|
| Stale / bad oracle | positive answer, `answeredInRound`, non-future timestamp, 26h staleness; optional secondary-source deviation check; optional sequencer feed; whole adapter swappable via Timelock |
| NAV manipulation via oracle lag | in-position deposits/withdrawals only in market hours; withdrawers realize their own execution |
| Share-price inflation (first depositor) | ERC-4626 virtual shares, decimals offset 6 (tested) |
| Dilution on deposit/withdraw | pro-rata in-kind unwind, rounding against the user; fuzz + invariant `invariant_noDilution` |
| Reentrancy | `nonReentrant` on every state-changing entry point; CEI in fee accrual; callbacks gated by sender + expected-callback flag |
| Malicious Morpho callback | `onMorphoFlashLoan` / `onMorphoSupplyCollateral` require `msg.sender == morpho` and an armed callback mode |
| Admin key compromise | 48h Timelock on all admin; hard-coded fee caps; guardian powers are defensive only |
| Upgrade risk | none: vaults/adapters are immutable clones; implementations disable initializers |
| Unbounded loops / gas DoS | ring buffer fixed at 64; batch functions capped (16–200); no iteration over user sets |
| Stock-token corporate actions | Chainlink prices include the issuer's `uiMultiplier`; raw-balance debt therefore tracks dividends/splits automatically |
| Collateral vault illiquidity | steakUSDG redemptions depend on its own liquidity; documented; adapter supports plain-USDG markets as an alternative |
| USDG depeg / freeze | USDG priced via its own Chainlink feed; systemic, disclosed |
| Market-hours lockout | flat vaults always withdrawable; guardian emergency exit anytime |
| Compliance misuse | ComplianceRegistry off by default; never gates withdrawals or unstaking |

## Slither triage

All High/Medium findings resolved. Fixed in code: `reentrancy-no-eth` (fee accrual split into effects then
notification; factory duplicate guard written before external calls + `ReentrancyGuard`), `uninitialized-local`
(explicit init). Suppressed with an inline reason (`// slither: …` above each block):

| Detector | Where | Why it is a false positive |
|---|---|---|
| `weak-prng` | MarketClock weekday/DST/minute | `% 7` and `% 86400` are calendar arithmetic, not randomness |
| `divide-before-multiply` | MarketClock civil-date conversion | Hinnant's algorithm depends on floor division |
| `reentrancy-balance` | swap venue, `PairVault.withdraw`, `FeeCollector.harvest` | balance deltas are the *measurement*; functions are `nonReentrant`; callees are trusted immutable protocol contracts |
| `incorrect-equality` | zero checks in views/early returns | equality on empty positions/supply, not attacker-steered balances |
| `unused-return` | adapter/oracle tuple returns | values re-measured via balances/positions or not needed |

Remaining Low/Informational: `timestamp` (intended — market hours), `calls-loop` (bounded batches), `reentrancy-benign/events`, `missing-zero-check` (zero fee collector intentionally disables fees).

## Operational checklist before raising caps
1. External audit. 2. Use Safes for `TIMELOCK_ADMIN` and `GUARDIAN_ADDRESS`. 3. Dedicated RPC + monitored keeper.
4. Keep `depositCap` (1M USDG default) and `maxNotionalUsdg` (250k default) conservative until borrow liquidity grows.
5. Update the holiday calendar each December (guardian `setHolidays`).
