# Pairwise

Market-neutral pairs-trading vaults for tokenized stocks on Robinhood Chain (4663). Each vault holds one pair: when the
A/B price ratio moves more than 2σ from its rolling mean, it buys the cheap leg and borrows-and-sells the rich one in
equal dollars, then exits on mean reversion, a stop, a correlation breakdown, high borrow cost, or a max holding period.
All decisions are computed on-chain from Chainlink prices and execute only during US market hours.

> Unaudited, experimental software. See [THREAT_MODEL.md](THREAT_MODEL.md) and the in-app risk disclosure.

## Layout

| Path | What |
|---|---|
| `contracts/` | Foundry project (Solidity 0.8.28, OpenZeppelin v5) — protocol, tests, `script/Deploy.s.sol` |
| `app/` | Next.js + wagmi/viem + RainbowKit frontend |
| `scripts/` | strategy keeper (TypeScript, signs via Foundry keystore) |
| `config/` | `robinhood-mainnet.json` (all addresses, sourced) + `chains.ts` |
| `deployments/` | written by the deploy script |
| `docs/` | [PAIRS.md](docs/PAIRS.md) |

## Contracts

| Contract | Role |
|---|---|
| `PairVaultFactory` | lists pairs: deploys immutable clones of vault + adapters, registers them (Timelock-only) |
| `PairVault` | ERC-4626 over USDG; FLAT / LONG_SPREAD / SHORT_SPREAD; fees; pro-rata in-position withdrawals |
| `LongAdapter` | holds the long stock leg (Uniswap v3 via `UniswapV3SwapVenue`) |
| `ShortAdapter` | Morpho Blue short: steakUSDG collateral, borrow + sell, flash-loan unwinds |
| `SpreadOracle` | 64-slot ring buffer of daily closes; z-score, correlation, weekly beta; verifiable Chainlink seeding |
| `StrategyEngine` | entry/exit/rebalance rules; keepers only trigger |
| `MarketClock` | NYSE hours with US DST and holiday calendar |
| `OracleAdapter` | Chainlink with staleness / round / sequencer / deviation checks (swappable) |
| `FeeCollector` | 1%/yr mgmt + 15% perf over HWM (hard caps); splits perf fees with $PAIR stakers |
| `ProjectTokenHooks` | $PAIR staking + pair proposals, inert until `setProjectToken` |
| `ComplianceRegistry` | optional allowlist hook (off by default) |
| `PairwiseTimelock` | 48h TimelockController holding every admin role |

Launch pairs: **SPY/QQQ, COIN/MSTR, NVDA/QQQ, PLTR/NVDA** ([why](docs/PAIRS.md)).

## Develop

```bash
pnpm install
```
```bash
cd contracts && forge test --no-match-path "test/fork/*"
```
```bash
cd contracts && RUN_FORK_TESTS=true forge test --match-path "test/fork/*" -vv
```
```bash
cd contracts && forge coverage --code-size-limit 300000 --no-match-path "test/fork/*" --report summary
```
```bash
cd contracts && slither . --filter-paths "lib/|test/|script/" --exclude-dependencies
```
```bash
pnpm app:dev
```

## Status

| Check | Result |
|---|---|
| Unit + fuzz + invariant tests | 131 passing |
| Mainnet-fork tests (real tokens, Chainlink, Uniswap, Morpho) | 5 passing |
| Line coverage, core contracts | 97.5% (each ≥ 96.8%) |
| Slither | 0 High, 0 Medium |
| Deploy to local mainnet fork | success |
| Mainnet dry run (`Deploy.s.sol`, no broadcast) | success — ~34.1M gas ≈ 0.0014 ETH |
| Keeper `seed` on fork (real Chainlink history, contract-verified) | all 4 pairs, 30 closes each |
| Frontend production build | success (7 routes + geoblock middleware) |
| Frontend against fork deployment | pair list, live z-scores/correlation, vault pages working |

## Known at launch
- Morpho borrow liquidity for stock tokens is ~$400–1,000 per market, so positions start very small.
- PLTR/NVDA's 30-day return correlation was ~0% at seeding time; the correlation gate (≥50%) keeps it flat until that recovers.

## Deploy

See [DEPLOY.md](DEPLOY.md). Decisions: [DECISIONS.md](DECISIONS.md). Token: [TOKEN_INTEGRATION.md](TOKEN_INTEGRATION.md).
