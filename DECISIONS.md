# Decisions

One line of reasoning per decision. Newest concerns at the bottom of each section.

## Chain & data sources
- **Target: Robinhood Chain mainnet, chain ID 4663, ETH gas, Blockscout verification** — from docs.robinhood.com/chain/deploy-smart-contracts, confirmed via `eth_chainId`.
- **Stock-token addresses from `api.robinhood.com/rhj/assets`** — the docs' contract table is rendered client-side from this official registry; scraping the page would have returned nothing.
- **Chainlink is the only oracle** — Robinhood's docs name it the sole provider; feed addresses come from Chainlink's official directory JSON, not hardcoded guesses.
- **No L2 sequencer-uptime feed** — Chainlink doesn't publish one for this chain; `OracleAdapter.setSequencerUptimeFeed` exists and is off (address 0) until one does.
- **Multicall3 at the canonical address** — bytecode verified on-chain; used for batched frontend reads.
- **Config in JSON (`config/robinhood-mainnet.json`) + typed `config/chains.ts`** — Solidity can't read TypeScript, so JSON is the single source both read.

## Venues
- **Short leg: Morpho Blue (borrow stock token against USDG/steakUSDG, sell it)** — the only on-chain venue where stock tokens are lendable; verified by opening and closing a real NVDA short on a fork.
- **Perps rejected for now** — Lighter is an off-chain orderbook with no composable contract entry point; `IShortAdapter` allows a perps adapter later.
- **Collateral = steakUSDG (Morpho Vault V2 over USDG)** — the stock-loan markets with actual supply all use it; Vault V2's `maxDeposit` returns 0 by design, real deposits work (fork-tested). Plain-USDG markets are also supported by the adapter.
- **Atomic leverage via Morpho's `supplyCollateral` callback** — borrowing the full notional against margin alone would exceed LLTV for an instant; the callback credits collateral first, exactly like Morpho's own leverage bundlers.
- **Unwinds: vault USDG first, Morpho flash loan (fee-free) for any shortfall** — closes never depend on long-leg proceeds; Morpho holds ~43M idle USDG.
- **Long leg + swaps: Uniswap v3 SwapRouter02 with per-token multi-hop routes** — deep, documented, simple to call; COIN routes via WETH (only deep pool). Uniswap v4 has more liquidity for some names; `ISwapVenue` lets a v4/aggregator venue be swapped in by the Timelock.
- **SPY routes direct SPY/USDG 0.05%** rather than via WETH — one hop, adequate depth.

## Pairs
- **Launch: SPY/QQQ, COIN/MSTR, NVDA/QQQ, PLTR/NVDA** — a pairs vault shorts either leg, so *both* legs need a Chainlink feed, a funded Morpho borrow market and a swap route; only NVDA, QQQ, SPY, COIN, MSTR, PLTR, TSLA (and meme names) qualify. Rationale in docs/PAIRS.md.
- **NVDA/AMD not launched** — AMD has a feed and a pool but no Morpho market lends AMD; listable by Timelock the day one exists.
- **Capacity is tiny at launch (~$400–1,000 borrowable per stock)** — entries are capped at 90% of venue liquidity; documented as the main scaling constraint.

## Strategy
- **Signal = z-score of the price ratio A/B vs rolling mean/stdev of daily closes** — exactly as specified; ring buffer of 64, window 30.
- **Entry only when entryZ ≤ |z| < stopZ** — entering beyond the stop would stop out immediately (found while writing fork tests).
- **Dollar-neutral at entry; weekly OLS beta used on rebalances, clamped to 1±5% tilt** — honours both "dollar-neutral at entry" and "hedge ratio updated weekly" while staying inside the ±10% neutrality band invariant.
- **Correlation gate (≥0.5 to enter, <0.2 forces exit)** — direct mitigation of correlation breakdown.
- **Borrow-cost exit (APR > 50%)** — Morpho rates spike when lenders withdraw; this is the practical form of "short recall".
- **Arm → confirm (15 min) before entry** — the signal must persist, defeating single-update oracle spikes and keeper timing games.
- **Keeper can only trigger** — direction, size and timing are computed on-chain from Chainlink, never passed in.
- **History bootstrap via `seedFromRounds`** — trust-minimised: the contract verifies each Chainlink round was the last one before that day's official close.
- **Price feeds' 26h staleness limit** — Chainlink heartbeat is 24h; actions only happen in market hours when feeds are fresh.

## Vault mechanics
- **Withdrawals during a trade unwind pro-rata in the same tx; the redeemer bears execution cost** — guarantees no dilution of remaining holders (fuzzed + invariant-tested).
- **In-position deposits/withdrawals only during market hours; flat vaults are always open** — NAV uses oracle prices that are fresh only in session.
- **Previews apply a 2×slippage haircut while in position** — ERC-4626 requires previews ≤ actual.
- **Fees minted as shares; caps 1%/yr and 15% are compile-time constants** — governance can lower, never raise.
- **Decimals offset 6** — first-depositor inflation attack mitigation (tested).
- **Withdrawals are never paused when flat and never compliance-gated** — users can always exit.
- **Guardian can pause and `emergencyExit` (bounded ≤5% slippage) at any hour; only the Timelock can unpause** — fast defence, slow recovery.

## Architecture & governance
- **Vaults/adapters are immutable EIP-1167 clones** — no proxy upgrade risk; the factory fits under the size limit.
- **Timelock: OZ TimelockController, 48h minimum enforced in the constructor, self-administered** — every admin role ends up there; the deploy script asserts the deployer keeps none.
- **Per-vault adapters** — positions are segregated; a bug or liquidation in one vault cannot touch another's collateral.
- **No `via_ir`** — stack issues were fixed by refactoring so coverage stays accurate.

## Project token ($PAIR)
- **No token is written or deployed** — `ProjectTokenHooks.setProjectToken` is one-shot and Timelock-only; tests use a MockERC20.
- **Staker rewards streamed over 7 days** — stops just-in-time stakers from sniping a harvest.
- **Default staker share 50% of performance fees, capped at 50%** — rest goes to treasury, Timelock-controlled.
- **Proposals are on-chain signals; listing still needs the Timelock** — as specified.

## Tooling, compliance, frontend
- **Slither: all High/Medium cleared** — real fixes where the finding was real (CEI in fee setters, explicit init, factory guard), scoped `slither-disable` with a written reason for false positives (calendar `% 7` flagged as "weak PRNG", Hinnant date math, balance-delta checks inside `nonReentrant`). See THREAT_MODEL.md.
- **LF line endings enforced (`.gitattributes`)** — CRLF shifted Slither's line mapping on Windows.
- **Frontend: Next 15 + React 19 + wagmi 2 + viem 2 + RainbowKit 2** — the known-compatible set; wagmi 3's API changes weren't worth the risk.
- **Deployment config fetched at runtime from `/deployments/<chainId>.json`** — redeploys don't require code changes.
- **ABIs generated from Foundry artifacts and committed** — Vercel builds without Foundry.
- **No Robinhood name/logo in branding** — UI says "chain 4663"; the network's official name appears only where wallets need it.
- **Geoblock via Vercel's `x-vercel-ip-country`, off unless configured** — a courtesy control; the on-chain hook is ComplianceRegistry (off by default).
- **Local fork uses chain ID 31337** — so fork deployments never overwrite `deployments/4663.json`.
- **Deployment files are only written on broadcast** — a dry run can't produce fake addresses.
