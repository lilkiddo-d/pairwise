"use client";

import { useReadContracts, usePublicClient } from "wagmi";
import { useQuery } from "@tanstack/react-query";
import type { Abi, Address } from "viem";
import { PairVaultAbi, SpreadOracleAbi, StrategyEngineAbi, MarketClockAbi } from "@/abi";
import { symbolByAddress } from "@pairwise/config";
import type { Deployment } from "./deployment";

export interface VaultView {
  address: Address;
  name?: string;
  symbol?: string;
  state?: number;
  totalAssets?: bigint;
  totalSupply?: bigint;
  pairId?: bigint;
  tokenA?: Address;
  tokenB?: Address;
  symA: string;
  symB: string;
  legs?: readonly [bigint, bigint, bigint, bigint];
  entryTime?: bigint;
  paused?: boolean;
  pricePerShare?: bigint;
  z?: bigint;
  zOk?: boolean;
  corr?: bigint;
  hedge?: bigint;
  mean?: bigint;
  std?: bigint;
  samples?: bigint;
  currentRatio?: bigint;
  closes?: { days: readonly bigint[]; a: readonly bigint[]; b: readonly bigint[] };
  nextAction?: number;
  nextDetail?: number;
  marketOpen?: boolean;
}

const REFRESH = 30_000;

/** Widened call type: keeps wagmi from deep-instantiating generics over dynamic multicall arrays. */
type Call = { address: Address; abi: Abi; functionName: string; args?: readonly unknown[] };

/** Phase 1: vault fields. Phase 2: pair statistics keyed by pairId. */
export function useVaults(dep: Deployment | null | undefined) {
  const vaults = dep?.vaults ?? [];
  const baseCalls: Call[] = vaults.flatMap((v) => [
      { address: v, abi: PairVaultAbi, functionName: "name" },
      { address: v, abi: PairVaultAbi, functionName: "symbol" },
      { address: v, abi: PairVaultAbi, functionName: "state" },
      { address: v, abi: PairVaultAbi, functionName: "totalAssets" },
      { address: v, abi: PairVaultAbi, functionName: "totalSupply" },
      { address: v, abi: PairVaultAbi, functionName: "pairId" },
      { address: v, abi: PairVaultAbi, functionName: "tokenA" },
      { address: v, abi: PairVaultAbi, functionName: "tokenB" },
      { address: v, abi: PairVaultAbi, functionName: "legs" },
      { address: v, abi: PairVaultAbi, functionName: "entryTime" },
      { address: v, abi: PairVaultAbi, functionName: "paused" },
      { address: v, abi: PairVaultAbi, functionName: "pricePerShare" },
    ]);
  const base = useReadContracts({
    allowFailure: true,
    contracts: baseCalls,
    query: { enabled: vaults.length > 0, refetchInterval: REFRESH },
  });
  const N = 12;
  const pairIds = vaults.map((_, i) => base.data?.[i * N + 5]?.result as bigint | undefined);

  const statCalls: Call[] = dep
      ? vaults.flatMap((v, i) => {
          const pid = pairIds[i] ?? 0n;
          return [
            { address: dep.spreadOracle, abi: SpreadOracleAbi, functionName: "zScore", args: [pid] },
            { address: dep.spreadOracle, abi: SpreadOracleAbi, functionName: "correlation", args: [pid] },
            { address: dep.spreadOracle, abi: SpreadOracleAbi, functionName: "hedgeRatio", args: [pid] },
            { address: dep.spreadOracle, abi: SpreadOracleAbi, functionName: "ratioStats", args: [pid] },
            { address: dep.spreadOracle, abi: SpreadOracleAbi, functionName: "currentRatio", args: [pid] },
            { address: dep.spreadOracle, abi: SpreadOracleAbi, functionName: "getCloses", args: [pid] },
            { address: dep.strategyEngine, abi: StrategyEngineAbi, functionName: "check", args: [v] },
          ];
        })
      : [];
  const stats = useReadContracts({
    allowFailure: true,
    contracts: statCalls,
    query: { enabled: !!dep && pairIds.every((p) => p !== undefined), refetchInterval: REFRESH },
  });
  const clock = useReadContracts({
    contracts: dep ? [{ address: dep.marketClock, abi: MarketClockAbi, functionName: "isMarketOpen" }] : [],
    query: { enabled: !!dep, refetchInterval: REFRESH },
  });
  const S = 7;

  const views: VaultView[] = vaults.map((address, i) => {
    const r = (k: number) => base.data?.[i * N + k]?.result;
    const s = (k: number) => stats.data?.[i * S + k]?.result;
    const tokenA = r(6) as Address | undefined;
    const tokenB = r(7) as Address | undefined;
    const z = s(0) as readonly [bigint, boolean] | undefined;
    const corr = s(1) as readonly [bigint, boolean] | undefined;
    const rs = s(3) as readonly [bigint, bigint, bigint] | undefined;
    const closes = s(5) as readonly [readonly bigint[], readonly bigint[], readonly bigint[]] | undefined;
    const check = s(6) as readonly [number, number, bigint] | undefined;
    return {
      address,
      name: r(0) as string | undefined,
      symbol: r(1) as string | undefined,
      state: r(2) as number | undefined,
      totalAssets: r(3) as bigint | undefined,
      totalSupply: r(4) as bigint | undefined,
      pairId: r(5) as bigint | undefined,
      tokenA,
      tokenB,
      symA: (tokenA && symbolByAddress(tokenA)) || "A",
      symB: (tokenB && symbolByAddress(tokenB)) || "B",
      legs: r(8) as readonly [bigint, bigint, bigint, bigint] | undefined,
      entryTime: r(9) as bigint | undefined,
      paused: r(10) as boolean | undefined,
      pricePerShare: r(11) as bigint | undefined,
      z: z?.[0],
      zOk: z?.[1],
      corr: corr?.[1] ? corr[0] : undefined,
      hedge: s(2) as bigint | undefined,
      mean: rs?.[0],
      std: rs?.[1],
      samples: rs?.[2],
      currentRatio: s(4) as bigint | undefined,
      closes: closes ? { days: closes[0], a: closes[1], b: closes[2] } : undefined,
      nextAction: check?.[0],
      nextDetail: check?.[1],
      marketOpen: clock.data?.[0]?.result as boolean | undefined,
    };
  });
  return { views, isLoading: base.isLoading || stats.isLoading, error: base.error ?? stats.error };
}

export interface TradeEvent {
  kind: "Entered" | "Exited" | "Rebalanced" | "Armed";
  blockNumber: bigint;
  txHash: string;
  args: Record<string, unknown>;
}

/** Trade log from vault + engine events, scanned in bounded chunks from the deployment block. */
export function useTradeLog(dep: Deployment | null | undefined, vault: Address | undefined) {
  const client = usePublicClient();
  return useQuery({
    queryKey: ["tradelog", vault, dep?.deployedAtBlock],
    enabled: !!client && !!dep && !!vault,
    refetchInterval: 60_000,
    queryFn: async (): Promise<TradeEvent[]> => {
      if (!client || !dep || !vault) return [];
      const latest = await client.getBlockNumber();
      const from = BigInt(dep.deployedAtBlock);
      const CHUNK = 500_000n;
      const MAX_CHUNKS = 40n;
      const out: TradeEvent[] = [];
      let hi = latest;
      for (let n = 0n; n < MAX_CHUNKS && hi >= from; n++) {
        const lo = hi - CHUNK + 1n > from ? hi - CHUNK + 1n : from;
        const [vaultLogs, armed] = await Promise.all([
          client.getContractEvents({ address: vault, abi: PairVaultAbi, fromBlock: lo, toBlock: hi }),
          client.getContractEvents({
            address: dep.strategyEngine,
            abi: StrategyEngineAbi,
            eventName: "Armed",
            args: { vault },
            fromBlock: lo,
            toBlock: hi,
          }),
        ]);
        for (const l of [...vaultLogs, ...armed]) {
          if (!["Entered", "Exited", "Rebalanced", "Armed"].includes(l.eventName)) continue;
          out.push({
            kind: l.eventName as TradeEvent["kind"],
            blockNumber: l.blockNumber,
            txHash: l.transactionHash,
            args: (l.args ?? {}) as Record<string, unknown>,
          });
        }
        hi = lo - 1n;
      }
      return out.sort((x, y) => Number(y.blockNumber - x.blockNumber));
    },
  });
}
