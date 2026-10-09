"use client";

import Link from "next/link";
import { PAIRS } from "@pairwise/config";
import { useDeployment } from "@/lib/deployment";
import { useVaults } from "@/lib/hooks";
import { SpreadChart } from "@/components/SpreadChart";
import { StateBadge, ZScore, Stat } from "@/components/Bits";
import { ACTION_LABEL, pct, usd, wad } from "@/lib/format";
import { ACTIVE_CHAIN } from "@/lib/config";

export default function Home() {
  const { data: dep, isLoading: depLoading } = useDeployment();
  const { views, isLoading, error } = useVaults(dep);

  return (
    <>
      <section className="hero">
        <h1>Market-neutral pairs vaults for tokenized stocks</h1>
        <p>
          Each vault holds one pair. When the A/B price ratio drifts more than two standard deviations from its rolling
          mean, the vault goes long the cheap leg and short the rich one in equal dollars, then exits when the ratio
          mean-reverts — or at a stop, a correlation breakdown, or the max holding period. Every decision is computed
          on-chain from Chainlink prices and only executes during US market hours.
        </p>
      </section>

      {depLoading && <p className="muted">Loading deployment…</p>}
      {!depLoading && !dep && (
        <div className="card">
          <h3>Not deployed on chain {ACTIVE_CHAIN.id} yet</h3>
          <p className="muted">
            Expected <code>/deployments/{ACTIVE_CHAIN.id}.json</code>, which <code>script/Deploy.s.sol</code> writes on
            broadcast. Launch pairs:
          </p>
          <ul>
            {PAIRS.map((p) => (
              <li key={p.id}>
                <b>
                  {p.a}/{p.b}
                </b>{" "}
                — {p.thesis}
              </li>
            ))}
          </ul>
        </div>
      )}
      {error && <p className="note warn">RPC error: {String(error.message).split("\n")[0]}</p>}
      {dep && isLoading && <p className="muted">Reading vaults…</p>}

      <div className="grid">
        {views.map((v) => {
          const thesis = PAIRS.find((p) => p.a === v.symA && p.b === v.symB)?.thesis;
          return (
            <Link key={v.address} href={`/vault/${v.address}`} className="card pair">
              <div className="pair-head">
                <h2>
                  {v.symA}
                  <span className="vs">/</span>
                  {v.symB}
                </h2>
                <StateBadge state={v.state} />
              </div>
              {v.closes ? (
                <SpreadChart
                  days={v.closes.days}
                  a={v.closes.a}
                  b={v.closes.b}
                  window={30}
                  current={v.currentRatio}
                  height={120}
                  compact
                />
              ) : (
                <div className="chart-empty" style={{ height: 120 }} />
              )}
              <div className="stats">
                <Stat label="z-score" value={<ZScore z={v.z} ok={v.zOk} />} hint="Live ratio vs rolling mean, in σ" />
                <Stat label="TVL" value={usd(v.totalAssets, 6, 0)} />
                <Stat label="Correlation" value={pct(v.corr, 0)} hint="Daily-return correlation over the window" />
                <Stat label="Hedge β" value={wad(v.hedge)} hint="Weekly OLS beta ($B per $A), clamped" />
              </div>
              {thesis && <p className="thesis">{thesis}</p>}
              <div className="row muted small">
                <span>Next keeper action: {v.nextAction !== undefined ? ACTION_LABEL[v.nextAction] : "—"}</span>
                <span>{v.marketOpen ? "Market open" : "Market closed"}</span>
              </div>
            </Link>
          );
        })}
      </div>
    </>
  );
}
