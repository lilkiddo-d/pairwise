"use client";

import { useEffect, useState } from "react";
import { erc20Abi, parseUnits, maxUint256, type Address } from "viem";
import { useAccount, useReadContracts, useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { PairVaultAbi } from "@/abi";
import { usd } from "@/lib/format";

export function DepositWithdraw({ vault, usdg, inPosition }: { vault: Address; usdg: Address; inPosition: boolean }) {
  const { address } = useAccount();
  const [tab, setTab] = useState<"deposit" | "withdraw">("deposit");
  const [amount, setAmount] = useState("");
  const parsed = (() => {
    try {
      return amount ? parseUnits(amount, 6) : 0n;
    } catch {
      return 0n;
    }
  })();
  const me = address ?? "0x0000000000000000000000000000000000000000";

  const reads = useReadContracts({
    allowFailure: true,
    contracts: [
      { address: usdg, abi: erc20Abi, functionName: "balanceOf", args: [me] },
      { address: usdg, abi: erc20Abi, functionName: "allowance", args: [me, vault] },
      { address: vault, abi: PairVaultAbi, functionName: "balanceOf", args: [me] },
      { address: vault, abi: PairVaultAbi, functionName: "maxDeposit", args: [me] },
      { address: vault, abi: PairVaultAbi, functionName: "maxRedeem", args: [me] },
      { address: vault, abi: PairVaultAbi, functionName: "previewDeposit", args: [parsed] },
      { address: vault, abi: PairVaultAbi, functionName: "previewWithdraw", args: [parsed] },
      { address: vault, abi: PairVaultAbi, functionName: "maxWithdraw", args: [me] },
    ],
    query: { enabled: !!address, refetchInterval: 15_000 },
  });
  const r = (i: number) => reads.data?.[i]?.result as bigint | undefined;
  const bal = r(0);
  const allowance = r(1);
  const shares = r(2);
  const maxDeposit = r(3);
  const maxRedeem = r(4);
  const sharesForAmount = r(6);
  const maxWithdraw = r(7);

  const { writeContract, data: hash, isPending, error } = useWriteContract();
  const receipt = useWaitForTransactionReceipt({ hash });
  const { refetch } = reads;
  useEffect(() => {
    if (receipt.isSuccess) refetch(); // refresh balances/allowance once mined
  }, [receipt.isSuccess, refetch]);

  const busy = isPending || (hash && receipt.isLoading);
  const needsApproval = tab === "deposit" && parsed > 0n && (allowance ?? 0n) < parsed;

  function submit() {
    if (!address || parsed === 0n) return;
    if (tab === "deposit") {
      if (needsApproval) {
        writeContract({ address: usdg, abi: erc20Abi, functionName: "approve", args: [vault, maxUint256] });
      } else {
        writeContract({ address: vault, abi: PairVaultAbi, functionName: "deposit", args: [parsed, address] });
      }
    } else {
      const all = maxWithdraw !== undefined && parsed >= maxWithdraw;
      const sh = all ? (maxRedeem ?? 0n) : (sharesForAmount ?? 0n);
      if (sh === 0n) return;
      // minAssets: what the user asked for (or the conservative preview when withdrawing everything)
      const minAssets = all ? (maxWithdraw ?? 0n) : parsed;
      writeContract({
        address: vault,
        abi: PairVaultAbi,
        functionName: "redeem",
        args: [sh, address, address, minAssets],
      });
    }
  }

  const blockedReason =
    tab === "deposit"
      ? maxDeposit === 0n
        ? inPosition
          ? "Deposits into an open position are only accepted during US market hours (and when not paused / within cap)."
          : "Deposits are paused, capped, or your address is not allowlisted."
        : undefined
      : maxRedeem === 0n && (shares ?? 0n) > 0n
        ? "This vault holds a position: withdrawals unwind both legs and are only possible during US market hours (and when not paused)."
        : undefined;

  return (
    <div className="card">
      <div className="tabs">
        <button className={tab === "deposit" ? "tab active" : "tab"} onClick={() => setTab("deposit")}>
          Deposit
        </button>
        <button className={tab === "withdraw" ? "tab active" : "tab"} onClick={() => setTab("withdraw")}>
          Withdraw
        </button>
      </div>
      <label className="field">
        <span>Amount (USDG)</span>
        <div className="input-row">
          <input
            inputMode="decimal"
            placeholder="0.00"
            value={amount}
            onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ""))}
          />
          <button
            className="ghost"
            onClick={() => {
              const m = tab === "deposit" ? bal : maxWithdraw;
              if (m !== undefined) setAmount((Number(m) / 1e6).toString());
            }}
          >
            Max
          </button>
        </div>
      </label>
      <div className="kv">
        <span>Wallet</span>
        <span>{usd(bal)}</span>
      </div>
      <div className="kv">
        <span>Your position</span>
        <span>{usd(maxWithdraw)}</span>
      </div>
      {inPosition && tab === "withdraw" && (
        <p className="note">
          The vault is in a trade. Your withdrawal sells your share of both legs in the same transaction; you pay your
          own execution cost so remaining depositors are never diluted. The amount shown is a conservative estimate.
        </p>
      )}
      {blockedReason && <p className="note warn">{blockedReason}</p>}
      <button className="primary" disabled={!address || parsed === 0n || !!busy || !!blockedReason} onClick={submit}>
        {!address
          ? "Connect a wallet"
          : busy
            ? "Confirming…"
            : tab === "deposit"
              ? needsApproval
                ? "Approve USDG"
                : "Deposit"
              : "Withdraw"}
      </button>
      {error && <p className="note warn">{error.message.split("\n")[0]}</p>}
      {receipt.isSuccess && <p className="note ok">Confirmed.</p>}
    </div>
  );
}
