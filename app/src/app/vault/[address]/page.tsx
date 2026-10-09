"use client";

import { use } from "react";
import Link from "next/link";
import { useReadContracts } from "wagmi";
import type { Address } from "viem";
import { EXPLORER, PAIRS } from "@pairwise/config";
import { PairVaultAbi, StrategyEngineAbi } from "@/abi";
import { useDeployment } from "@/lib/deployment";
import { useVaults } from "@/lib/hooks";
import { SpreadChart } from "@/components/SpreadChart";
import { StateBadge, Stat, ZScore } from "@/components/Bits";
import { DepositWithdraw } from "@/components/DepositWithdraw";
import { TradeLog } from "@/components/TradeLog";
import { ACTION_LABEL, EXIT_REASON, STATE_HINT, STATE_LABEL, pct, usd, wad } from "@/lib/format";
import { NETWORK } from "@/lib/config";

export default function VaultPage({ params }: { params: Promise<{ address: string }> }) {
  const { address } = use(params);
  const vaultAddr = address as Address;
  const { data: dep } = useDeployment();
  const { views } = useVaults(dep);
  const v = views.find((x) => x.address.toLowerCase() === vaultAddr.toLowerCase());

  const extra = useReadContracts({
    allowFailure: true,
    contracts: dep
      ? [
          { address: dep.strategyEngine, abi: StrategyEngineAbi, functionName: "params", args: [vaultAddr] },
          { address: vaultAddr, abi: PairVaultAbi, functionName: "config" },
          { address: vaultAddr, abi: PairVaultAbi, functionName: "managementFeeBps" },
          { address: vaultAddr, abi: PairVaultAbi, functionName: "performanceFeeBps" },
          { address: vaultAddr, abi: PairVaultAbi, functionName: "highWaterMark" },
        ]
      : [],
    query: { enabled: !!dep },
  });
  const params_ = extra.data?.[0]?.result as
    | {
        entryZ: bigint;
        exitZ: bigint;
        stopZ: bigint;
        maxHolding: bigint;
        minCorrelation: bigint;
        exitCorrelation: bigint;
        maxBorrowApr: bigint;
        confirmDelay: bigint;
      }
    | undefined;
  const cfg = extra.data?.[1]?.result as readonly [number, number, number, number, number, number, number, number, bigint, bigint] | undefined;
  const mgmt = extra.data?.[2]?.result as number | undefined;
  const perf = extra.data?.[3]?.result as number | undefined;

  if (!dep) return <p className="muted">Loading…</p>;
  if (!v) return <p className="muted">Vault not found in this deployment.</p>;
  const thesis = PAIRS.find((p) => p.a === v.symA && p.b === v.symB)?.thesis;
  const inPosition = (v.state ?? 0) !== 0;
  const legs = v.legs;
  const longSym = v.state === 1 ? v.symA : v.symB;
  const shortSym = v.state === 1 ? v.symB : v.symA;

  return (
    <>
      <p className="crumbs">
        <Link href="/">Pairs</Link> / {v.symA}/{v.symB}
      </p>
      <div className="vault-head">
        <h1>
          {v.symA}
          <span className="vs">/</span>
          {v.symB}
        </h1>
        <StateBadge state={v.state} />
        {v.paused && <span className="pill warn">paused</span>}
      </div>
      {thesis && <p className="thesis">{thesis}</p>}

      <div className="layout">
        <div>
          <div className="card">
            <h3>Spread (price ratio {v.symA}/{v.symB})</h3>
            {v.closes ? (
              <SpreadChart days={v.closes.days} a={v.closes.a} b={v.closes.b} window={30} current={v.currentRatio} />
            ) : (
              <div className="chart-empty" style={{ height: 220 }} />
            )}
            <div className="stats">
              <Stat label="z-score" value={<ZScore z={v.z} ok={v.zOk} />} />
              <Stat label="Mean ratio" value={wad(v.mean, 4)} />
              <Stat label="σ" value={wad(v.std, 4)} />
              <Stat label="Closes" value={v.samples?.toString() ?? "—"} hint="Samples in the rolling window" />
              <Stat label="Correlation" value={pct(v.corr, 0)} />
              <Stat label="Hedge β" value={wad(v.hedge)} />
            </div>
          </div>

          <div className="card">
            <h3>Vault state: {v.state !== undefined ? STATE_LABEL[v.state] : "…"}</h3>
            <p className="muted">{v.state !== undefined && STATE_HINT[v.state]}</p>
            <div className="stats">
              <Stat label="TVL" value={usd(v.totalAssets)} />
              <Stat label="Share price" value={v.pricePerShare !== undefined ? (Number(v.pricePerShare) / 1e6).toFixed(6) : "—"} />
              {inPosition && legs && (
                <>
                  <Stat label={`Long ${longSym}`} value={usd(legs[0])} />
                  <Stat label={`Short ${shortSym}`} value={usd(legs[1])} />
                  <Stat label="Short LTV / cap" value={`${pct(legs[2])} / ${pct(legs[3])}`} />
                  <Stat
                    label="Opened"
                    value={v.entryTime ? new Date(Number(v.entryTime) * 1000).toLocaleString() : "—"}
                  />
                </>
              )}
              <Stat
                label="Next keeper action"
                value={
                  v.nextAction !== undefined
                    ? `${ACTION_LABEL[v.nextAction]}${v.nextAction === 3 && v.nextDetail ? ` (${EXIT_REASON[v.nextDetail]})` : ""}`
                    : "—"
                }
              />
              <Stat label="US market" value={v.marketOpen ? "Open" : "Closed"} />
            </div>
          </div>

          <div className="card">
            <h3>Trade log</h3>
            <TradeLog dep={dep} vault={vaultAddr} />
          </div>
        </div>

        <aside>
          <DepositWithdraw vault={vaultAddr} usdg={dep.usdg} inPosition={inPosition} />
          <div className="card">
            <h3>Rules</h3>
            {params_ ? (
              <ul className="rules">
                <li>
                  Enter when {wad(params_.entryZ, 1)} ≤ |z| &lt; {wad(params_.stopZ, 1)} and correlation ≥{" "}
                  {pct(params_.minCorrelation, 0)}, after a {Number(params_.confirmDelay) / 60}-min confirmation
                </li>
                <li>Exit at |z| ≤ {wad(params_.exitZ, 1)} (mean reversion)</li>
                <li>Stop at |z| ≥ {wad(params_.stopZ, 1)} against the trade</li>
                <li>Max holding {Number(params_.maxHolding) / 86400} days</li>
                <li>Exit if correlation &lt; {pct(params_.exitCorrelation, 0)} or borrow APR &gt; {pct(params_.maxBorrowApr, 0)}</li>
                {cfg && (
                  <>
                    <li>Dollar-neutral band ±{cfg[5] / 100}% · max slippage {cfg[0] / 100}% per swap</li>
                    <li>
                      Short-leg LTV target {cfg[2] / 100}% of LLTV, hard cap {cfg[4] / 100}% of LLTV
                    </li>
                  </>
                )}
                {mgmt !== undefined && perf !== undefined && (
                  <li>
                    Fees: {mgmt / 100}%/yr management + {perf / 100}% performance over high-water mark (hard-capped at
                    1% / 15%)
                  </li>
                )}
                <li>Actions only during US regular market hours</li>
              </ul>
            ) : (
              <p className="muted">Loading…</p>
            )}
            {NETWORK === "mainnet" && (
              <p className="small">
                <a href={`${EXPLORER}/address/${vaultAddr}`} target="_blank" rel="noreferrer">
                  View contract on explorer ↗
                </a>
              </p>
            )}
          </div>
        </aside>
      </div>
    </>
  );
}
