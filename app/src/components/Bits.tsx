import { STATE_LABEL } from "@/lib/format";

export function StateBadge({ state }: { state?: number }) {
  if (state === undefined) return <span className="pill">…</span>;
  const cls = state === 0 ? "pill" : state === 1 ? "pill long" : "pill shortp";
  return <span className={cls}>{STATE_LABEL[state]}</span>;
}

export function ZScore({ z, ok }: { z?: bigint; ok?: boolean }) {
  if (z === undefined || !ok) return <span className="muted">n/a</span>;
  const v = Number(z) / 1e18;
  const cls = Math.abs(v) >= 2 ? "z hot" : Math.abs(v) >= 1 ? "z warm" : "z";
  return (
    <span className={cls}>
      {v >= 0 ? "+" : ""}
      {v.toFixed(2)}σ
    </span>
  );
}

export function Stat({ label, value, hint }: { label: string; value: React.ReactNode; hint?: string }) {
  return (
    <div className="stat" title={hint}>
      <div className="stat-label">{label}</div>
      <div className="stat-value">{value}</div>
    </div>
  );
}
