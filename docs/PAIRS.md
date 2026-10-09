# Launch pairs

A pairs vault can be long *or* short either leg, so each token must have all three on chain 4663:
a Chainlink feed, a Morpho Blue market that **lends** it (with real supply), and a Uniswap v3 route to USDG.
As of 2026-10-09 that set is NVDA, QQQ, SPY, COIN, MSTR, PLTR, TSLA (plus meme names). Market IDs, feeds and routes are in
`config/robinhood-mainnet.json`.

| Pair | Why the legs co-move | What the spread captures |
|---|---|---|
| **SPY / QQQ** | ~80% of QQQ's weight is inside the S&P 500; both are cap-weighted US large-cap baskets. Daily-return correlation is typically > 0.9. | Growth/tech tilt vs the broad market — historically mean-reverting over weeks. |
| **COIN / MSTR** | Both trade as listed bitcoin proxies: COIN's revenue tracks crypto volumes and prices; MSTR's equity is levered to its BTC treasury. | Operating-business beta vs balance-sheet (BTC NAV premium) beta. |
| **NVDA / QQQ** | NVDA is QQQ's largest constituent and drives much of its daily move. The weekly OLS beta (clamped) sizes the hedge on rebalance. | NVDA-specific news vs the index — the idiosyncratic component. |
| **PLTR / NVDA** | Both are priced off the same AI capex / adoption narrative (software vs silicon). Correlation is the weakest of the four, so the correlation gate matters most here. | Relative momentum between AI software and AI hardware leaders. |

## Not yet listable
- **NVDA / AMD** (classic chipmaker pair): AMD has a feed and a Uniswap pool, but no Morpho market lends AMD.
- **MU / SNDK, TSM / ASML, META / GOOGL**: feeds exist, borrow markets don't (or have zero supply).

Anyone can create a Morpho Blue market permissionlessly; once lenders supply the stock token, the Timelock can list the
pair with `PairVaultFactory.createVault` (and $PAIR stakers can propose it).

## Capacity
Borrowable supply per stock is currently ~$400–1,000. Each vault caps a new position at 90% of the short leg's available
liquidity, so early positions are small. Capacity grows automatically as Morpho supply grows.
