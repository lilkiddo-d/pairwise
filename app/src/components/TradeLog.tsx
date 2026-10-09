"use client";

import type { Address } from "viem";
import { EXPLORER } from "@pairwise/config";
import { useTradeLog } from "@/lib/hooks";
import type { Deployment } from "@/lib/deployment";
import { EXIT_REASON, STATE_LABEL, usd } from "@/lib/format";
import { NETWORK } from "@/lib/config";

function zFmt(z: unknown): string {
  return typeof z === "bigint" ? `${(Number(z) / 1e18).toFixed(2)}σ` : "—";
}

export function TradeLog({ dep, vault }: { dep: Deployment; vault: Address }) {
  const { data, isLoading, error } = useTradeLog(dep, vault);
  if (isLoading) return <p className="muted">Loading trade log…</p>;
  if (error) return <p className="muted">Trade log unavailable: {String(error.message).split("\n")[0]}</p>;
  if (!data?.length) return <p className="muted">No trades yet.</p>;
  return (
    <table className="table">
      <thead>
        <tr>
          <th>Block</th>
          <th>Event</th>
          <th>Details</th>
        </tr>
      </thead>
      <tbody>
        {data.map((e) => {
          const a = e.args;
          let detail = "";
          if (e.kind === "Armed") detail = `${STATE_LABEL[Number(a.direction)]} armed at z ${zFmt(a.z)}`;
          if (e.kind === "Entered")
            detail = `${STATE_LABEL[Number(a.direction)]} · z ${zFmt(a.z)} · long ${usd(a.longValue as bigint)} / short ${usd(a.shortValue as bigint)}`;
          if (e.kind === "Exited")
            detail = `${EXIT_REASON[Number(a.reason)] ?? "Exit"} · z ${zFmt(a.z)} · PnL ${usd(a.pnl as bigint)} · NAV ${usd(a.navAfter as bigint)}`;
          if (e.kind === "Rebalanced")
            detail = `long ${usd(a.longValue as bigint)} / short ${usd(a.shortValue as bigint)} · LTV ${(Number(a.ltv) / 1e16).toFixed(1)}%`;
          return (
            <tr key={`${e.txHash}-${e.kind}`}>
              <td>
                {NETWORK === "mainnet" ? (
                  <a href={`${EXPLORER}/tx/${e.txHash}`} target="_blank" rel="noreferrer">
                    {e.blockNumber.toString()}
                  </a>
                ) : (
                  e.blockNumber.toString()
                )}
              </td>
              <td>
                <span className={`pill ev-${e.kind.toLowerCase()}`}>{e.kind}</span>
              </td>
              <td>{detail}</td>
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}
