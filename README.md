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
| **Mainnet deploy (4663)** | **live — 13 contracts + 4 vaults, verified, admin = Timelock** |
| Keeper `seed` on fork (real Chainlink history, contract-verified) | all 4 pairs, 30 closes each |
| Frontend production build | success (7 routes + geoblock middleware) |
| Frontend against fork deployment | pair list, live z-scores/correlation, vault pages working |

## Mainnet deployment (Robinhood Chain, 4663)

Deployed 2026-10-09; all contracts source-verified (Sourcify, shown on Blockscout). Admin of every contract is the 48h Timelock; the deployer holds no roles. Full list: [deployments/4663.json](deployments/4663.json).

| Contract | Address |
|---|---|
| Timelock (48h) | [`0x81462dA6f2cd80a6174bE661627f9D1C01530406`](https://robinhoodchain.blockscout.com/address/0x81462dA6f2cd80a6174bE661627f9D1C01530406) |
| PairVaultFactory | [`0x1d859cbc08Ed3031E62aC6797bF513938a1Ee170`](https://robinhoodchain.blockscout.com/address/0x1d859cbc08Ed3031E62aC6797bF513938a1Ee170) |
| StrategyEngine | [`0xB6a24c5516BDa270f1dE6cD9ea80dFb9b44383bD`](https://robinhoodchain.blockscout.com/address/0xB6a24c5516BDa270f1dE6cD9ea80dFb9b44383bD) |
| SpreadOracle | [`0xDc4bdcB6E89b8AB3079E9940f4F48c353d03B01f`](https://robinhoodchain.blockscout.com/address/0xDc4bdcB6E89b8AB3079E9940f4F48c353d03B01f) |
| OracleAdapter | [`0x2F4d0Ad6dDC1dB9182cA983Fb7a1C286E36983A2`](https://robinhoodchain.blockscout.com/address/0x2F4d0Ad6dDC1dB9182cA983Fb7a1C286E36983A2) |
| MarketClock | [`0xf65ADC561B4a15D43DF245BDE2db7A6fCb7d21E5`](https://robinhoodchain.blockscout.com/address/0xf65ADC561B4a15D43DF245BDE2db7A6fCb7d21E5) |
| UniswapV3SwapVenue | [`0x40CF3f86588E64030EC8478dbE76bF4137b03F7d`](https://robinhoodchain.blockscout.com/address/0x40CF3f86588E64030EC8478dbE76bF4137b03F7d) |
| FeeCollector | [`0x618C0528bc19251eC0dfc209A85a4Ccb20ae98C3`](https://robinhoodchain.blockscout.com/address/0x618C0528bc19251eC0dfc209A85a4Ccb20ae98C3) |
| ProjectTokenHooks | [`0x866d7E41b575E7A409eA605B9607DfFFb7D86bB8`](https://robinhoodchain.blockscout.com/address/0x866d7E41b575E7A409eA605B9607DfFFb7D86bB8) |
| ComplianceRegistry | [`0x3AD383658f75AF0dbF3139099e5907E315EA104A`](https://robinhoodchain.blockscout.com/address/0x3AD383658f75AF0dbF3139099e5907E315EA104A) |
| PairVault impl | [`0xB74e995BaF28083e6CDEaBB903087eFe836A8547`](https://robinhoodchain.blockscout.com/address/0xB74e995BaF28083e6CDEaBB903087eFe836A8547) |
| LongAdapter impl | [`0x8A1DA13D604C6Bda22339602e74a3a9Dd4e62f18`](https://robinhoodchain.blockscout.com/address/0x8A1DA13D604C6Bda22339602e74a3a9Dd4e62f18) |
| ShortAdapter impl | [`0x79C6a41871803f155a2DA2893b92B5CD5711D1fD`](https://robinhoodchain.blockscout.com/address/0x79C6a41871803f155a2DA2893b92B5CD5711D1fD) |
| Vault SPY/QQQ | [`0x4ae1f46d102843E3bCB616249F9592352fF5b5d5`](https://robinhoodchain.blockscout.com/address/0x4ae1f46d102843E3bCB616249F9592352fF5b5d5) |
| Vault COIN/MSTR | [`0x7CF99918bcb94B374E6217f16d80356cb6DfA783`](https://robinhoodchain.blockscout.com/address/0x7CF99918bcb94B374E6217f16d80356cb6DfA783) |
| Vault NVDA/QQQ | [`0x272b1D12eEcd8D4e0bDe0AB625E46ffb5838A3A2`](https://robinhoodchain.blockscout.com/address/0x272b1D12eEcd8D4e0bDe0AB625E46ffb5838A3A2) |
| Vault PLTR/NVDA | [`0x6946302BD8CBA228CaA352D790497228E0b20C25`](https://robinhoodchain.blockscout.com/address/0x6946302BD8CBA228CaA352D790497228E0b20C25) |

## Known at launch
- Morpho borrow liquidity for stock tokens is ~$400–1,000 per market, so positions start very small.
- PLTR/NVDA's 30-day return correlation was ~0% at seeding time; the correlation gate (≥50%) keeps it flat until that recovers.

## Deploy

See [DEPLOY.md](DEPLOY.md). Decisions: [DECISIONS.md](DECISIONS.md). Token: [TOKEN_INTEGRATION.md](TOKEN_INTEGRATION.md).
