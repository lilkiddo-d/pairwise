"use client";

import { useEffect, useState } from "react";
import { erc20Abi, formatUnits, maxUint256, parseUnits, type Address } from "viem";
import { useAccount, useReadContracts, useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { ProjectTokenHooksAbi } from "@/abi";
import { useDeployment } from "@/lib/deployment";
import { PROJECT_TOKEN } from "@/lib/config";
import { usd } from "@/lib/format";

/** $PAIR features. Rendered only when NEXT_PUBLIC_PROJECT_TOKEN is set (and the token is plugged in on-chain). */
export default function StakePage() {
  const { data: dep } = useDeployment();
  const { address } = useAccount();
  const [amount, setAmount] = useState("");
  const [tokA, setTokA] = useState("");
  const [tokB, setTokB] = useState("");
  const [why, setWhy] = useState("");
  const me = address ?? "0x0000000000000000000000000000000000000000";
  const hooks = dep?.projectTokenHooks;

  const reads = useReadContracts({
    allowFailure: true,
    contracts:
      hooks && PROJECT_TOKEN
        ? [
            { address: hooks, abi: ProjectTokenHooksAbi, functionName: "projectToken" },
            { address: hooks, abi: ProjectTokenHooksAbi, functionName: "staked", args: [me] },
            { address: hooks, abi: ProjectTokenHooksAbi, functionName: "earned", args: [me] },
            { address: hooks, abi: ProjectTokenHooksAbi, functionName: "totalStaked" },
            { address: hooks, abi: ProjectTokenHooksAbi, functionName: "proposalThreshold" },
            { address: PROJECT_TOKEN, abi: erc20Abi, functionName: "balanceOf", args: [me] },
            { address: PROJECT_TOKEN, abi: erc20Abi, functionName: "allowance", args: [me, hooks] },
          ]
        : [],
    query: { enabled: !!hooks && !!PROJECT_TOKEN, refetchInterval: 15_000 },
  });
  const r = <T,>(i: number) => reads.data?.[i]?.result as T | undefined;
  const onchainToken = r<Address>(0);
  const staked = r<bigint>(1);
  const earned = r<bigint>(2);
  const total = r<bigint>(3);
  const threshold = r<bigint>(4);
  const bal = r<bigint>(5);
  const allowance = r<bigint>(6);

  const { writeContract, data: hash, isPending, error } = useWriteContract();
  const receipt = useWaitForTransactionReceipt({ hash });
  const { refetch } = reads;
  useEffect(() => {
    if (receipt.isSuccess) refetch();
  }, [receipt.isSuccess, refetch]);

  if (!PROJECT_TOKEN) return <p className="muted">Token features are disabled.</p>;
  if (!dep || !hooks) return <p className="muted">Loading…</p>;
  const live = onchainToken && onchainToken.toLowerCase() === PROJECT_TOKEN.toLowerCase();
  let parsed = 0n;
  try {
    parsed = amount ? parseUnits(amount, 18) : 0n;
  } catch {}

  return (
    <>
      <h1>Stake $PAIR</h1>
      <p className="muted">
        Stakers receive a share of performance fees in USDG (streamed over 7 days per harvest) and can propose new pairs.
        Listing a pair still requires a 48-hour timelock transaction.
      </p>
      {!live && (
        <p className="note warn">
          The project token has not been plugged into the protocol yet (Timelock <code>setProjectToken</code> pending).
        </p>
      )}
      <div className="layout">
        <div className="card">
          <h3>Your stake</h3>
          <div className="kv">
            <span>Wallet</span>
            <span>{bal !== undefined ? Number(formatUnits(bal, 18)).toLocaleString() : "—"} PAIR</span>
          </div>
          <div className="kv">
            <span>Staked</span>
            <span>{staked !== undefined ? Number(formatUnits(staked, 18)).toLocaleString() : "—"} PAIR</span>
          </div>
          <div className="kv">
            <span>Claimable</span>
            <span>{usd(earned)}</span>
          </div>
          <div className="kv">
            <span>Total staked</span>
            <span>{total !== undefined ? Number(formatUnits(total, 18)).toLocaleString() : "—"} PAIR</span>
          </div>
          <label className="field">
            <span>Amount (PAIR)</span>
            <input value={amount} onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ""))} placeholder="0" />
          </label>
          <div className="row">
            {(allowance ?? 0n) < parsed ? (
              <button
                className="primary"
                disabled={!live || isPending}
                onClick={() =>
                  writeContract({ address: PROJECT_TOKEN!, abi: erc20Abi, functionName: "approve", args: [hooks, maxUint256] })
                }
              >
                Approve
              </button>
            ) : (
              <button
                className="primary"
                disabled={!live || !parsed || isPending}
                onClick={() => writeContract({ address: hooks, abi: ProjectTokenHooksAbi, functionName: "stake", args: [parsed] })}
              >
                Stake
              </button>
            )}
            <button
              className="ghost"
              disabled={!live || !parsed || isPending}
              onClick={() => writeContract({ address: hooks, abi: ProjectTokenHooksAbi, functionName: "unstake", args: [parsed] })}
            >
              Unstake
            </button>
            <button
              className="ghost"
              disabled={!live || !earned || isPending}
              onClick={() => writeContract({ address: hooks, abi: ProjectTokenHooksAbi, functionName: "claim" })}
            >
              Claim
            </button>
          </div>
        </div>
        <div className="card">
          <h3>Propose a pair</h3>
          <p className="muted small">
            Requires {threshold !== undefined ? Number(formatUnits(threshold, 18)).toLocaleString() : "—"} PAIR staked.
            Both tokens need a Chainlink feed, a Morpho borrow market and a swap route to be listable.
          </p>
          <label className="field">
            <span>Token A address</span>
            <input value={tokA} onChange={(e) => setTokA(e.target.value.trim())} placeholder="0x…" />
          </label>
          <label className="field">
            <span>Token B address</span>
            <input value={tokB} onChange={(e) => setTokB(e.target.value.trim())} placeholder="0x…" />
          </label>
          <label className="field">
            <span>Why are they correlated?</span>
            <textarea value={why} maxLength={1024} onChange={(e) => setWhy(e.target.value)} rows={4} />
          </label>
          <button
            className="primary"
            disabled={!live || isPending || !/^0x[0-9a-fA-F]{40}$/.test(tokA) || !/^0x[0-9a-fA-F]{40}$/.test(tokB)}
            onClick={() =>
              writeContract({
                address: hooks,
                abi: ProjectTokenHooksAbi,
                functionName: "proposePair",
                args: [tokA as Address, tokB as Address, why],
              })
            }
          >
            Submit proposal
          </button>
        </div>
      </div>
      {error && <p className="note warn">{error.message.split("\n")[0]}</p>}
      {receipt.isSuccess && <p className="note ok">Confirmed.</p>}
    </>
  );
}
