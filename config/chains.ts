/**
 * Pairwise chain configuration — single source of truth for TypeScript (app + keeper).
 * Solidity (script/Deploy.s.sol) reads the same data from ./robinhood-mainnet.json.
 *
 * Every address was taken from an official source and re-verified on-chain (see `SOURCES`):
 *  - Network params ............ https://docs.robinhood.com/chain/deploy-smart-contracts/
 *  - USDG / WETH ............... https://docs.robinhood.com/chain/contracts/
 *  - Stock tokens .............. https://api.robinhood.com/rhj/assets  (the official registry that renders
 *                                https://docs.robinhood.com/chain/contracts/ "Stock Tokens & Tokenized ETFs")
 *  - Chainlink feeds ........... https://docs.chain.link/data-feeds/price-feeds/addresses?network=robinhood
 *  - Uniswap v3 ................ https://developers.uniswap.org/docs/protocols/v3/deployments/v3-robinhood-chain-deployments
 *  - Morpho Blue + markets ..... https://api.morpho.org/graphql (chainId 4663), params re-read via idToMarketParams
 *  - L2 sequencer uptime feed .. https://docs.chain.link/data-feeds/l2-sequencer-feeds — NOT published for this chain
 */
import { defineChain, type Address, type Hex } from "viem";
import raw from "./robinhood-mainnet.json";

export const SOURCES = raw.sources;

export const robinhoodMainnet = defineChain({
  id: raw.chainId,
  name: raw.name, // network name as published by its operator (factual, not product branding)
  nativeCurrency: raw.nativeCurrency,
  rpcUrls: { default: { http: raw.rpcUrls } },
  blockExplorers: { default: { name: "Blockscout", url: raw.explorer } },
  contracts: { multicall3: { address: raw.multicall3.address as Address } },
});

/** Local anvil fork of mainnet (`anvil --fork-url ... --chain-id 31337`). Same contracts, local RPC. */
export const localFork = defineChain({
  id: 31337,
  name: "Local fork (4663)",
  nativeCurrency: raw.nativeCurrency,
  rpcUrls: { default: { http: ["http://127.0.0.1:8545"] } },
  contracts: { multicall3: { address: raw.multicall3.address as Address } },
});

export const SUPPORTED_CHAINS = [robinhoodMainnet, localFork] as const;

export const TOKENS = {
  USDG: { address: raw.tokens.USDG.address as Address, decimals: raw.tokens.USDG.decimals },
  WETH: { address: raw.tokens.WETH.address as Address, decimals: raw.tokens.WETH.decimals },
  steakUSDG: { address: raw.tokens.steakUSDG.address as Address, decimals: raw.tokens.steakUSDG.decimals },
} as const;

export const CHAINLINK = {
  sequencerUptimeFeed: raw.chainlink.sequencerUptimeFeed as Address,
  USDG: raw.chainlink.USDG.feed as Address,
} as const;

export const UNISWAP_V3 = {
  factory: raw.uniswapV3.factory as Address,
  swapRouter02: raw.uniswapV3.swapRouter02 as Address,
  quoterV2: raw.uniswapV3.quoterV2 as Address,
} as const;

export const MORPHO = {
  blue: raw.morpho.blue as Address,
  adaptiveCurveIrm: raw.morpho.adaptiveCurveIrm as Address,
} as const;

export type StockSymbol = keyof typeof raw.stocks;

export interface StockConfig {
  symbol: StockSymbol;
  address: Address;
  decimals: number;
  feed: Address;
  morphoMarketId: Hex;
  lltv: string;
  route: { tokens: string[]; fees: number[] };
}

export const STOCKS: Record<StockSymbol, StockConfig> = Object.fromEntries(
  Object.entries(raw.stocks).map(([symbol, s]) => [
    symbol,
    {
      symbol: symbol as StockSymbol,
      address: s.address as Address,
      decimals: s.decimals,
      feed: s.feed as Address,
      morphoMarketId: s.morphoMarketId as Hex,
      lltv: s.lltv,
      route: s.route,
    },
  ]),
) as Record<StockSymbol, StockConfig>;

export interface PairInfo {
  id: string;
  a: StockSymbol;
  b: StockSymbol;
  thesis: string;
}

/** Launch pairs and why each leg pair co-moves. See docs/PAIRS.md for the full rationale. */
export const PAIRS: PairInfo[] = raw.pairs.map((p) => ({
  id: p.id,
  a: p.a as StockSymbol,
  b: p.b as StockSymbol,
  thesis:
    {
      "SPY-QQQ": "US large-cap index vs Nasdaq-100: ~80% of QQQ's weight sits inside the S&P 500; spread = growth vs broad-market tilt.",
      "COIN-MSTR": "Both trade as listed bitcoin proxies (exchange revenue vs BTC treasury); spread = business vs balance-sheet beta.",
      "NVDA-QQQ": "Largest single QQQ constituent vs its own benchmark; weekly OLS beta sizes the hedge, spread = idiosyncratic NVDA.",
      "PLTR-NVDA": "AI-cycle leaders (software vs silicon) driven by the same capex/adoption narrative; widest, most volatile spread.",
    }[p.id] ?? "",
}));

export function stockBySymbol(symbol: string): StockConfig | undefined {
  return (STOCKS as Record<string, StockConfig>)[symbol];
}

export function symbolByAddress(address: string): string | undefined {
  const a = address.toLowerCase();
  for (const s of Object.values(STOCKS)) if (s.address.toLowerCase() === a) return s.symbol;
  if (TOKENS.USDG.address.toLowerCase() === a) return "USDG";
  return undefined;
}

export const EXPLORER = raw.explorer;
export const VERIFIER = raw.verifier;
