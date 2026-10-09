"use client";

import { useQuery } from "@tanstack/react-query";
import type { Address } from "viem";
import { ACTIVE_CHAIN } from "./config";

/** Shape written by contracts/script/Deploy.s.sol to app/public/deployments/<chainId>.json */
export interface Deployment {
  chainId: number;
  deployedAtBlock: number;
  timelock: Address;
  marketClock: Address;
  oracleAdapter: Address;
  spreadOracle: Address;
  swapVenue: Address;
  strategyEngine: Address;
  feeCollector: Address;
  projectTokenHooks: Address;
  complianceRegistry: Address;
  factory: Address;
  usdg: Address;
  vaults: Address[];
}

export function useDeployment() {
  return useQuery({
    queryKey: ["deployment", ACTIVE_CHAIN.id],
    queryFn: async (): Promise<Deployment | null> => {
      const res = await fetch(`/deployments/${ACTIVE_CHAIN.id}.json`, { cache: "no-store" });
      if (!res.ok) return null;
      return (await res.json()) as Deployment;
    },
    staleTime: 60_000,
  });
}
