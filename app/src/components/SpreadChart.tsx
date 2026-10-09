"use client";

import { formatUnits } from "viem";
import { dayToDate } from "@/lib/format";

interface Props {
  days: readonly bigint[];
  a: readonly bigint[];
  b: readonly bigint[];
  window: number;
  current?: bigint;
  height?: number;
  compact?: boolean;
}

/** A/B price-ratio closes with the rolling mean and ±1σ / ±2σ bands of the last `window` closes. */
export function SpreadChart({ days, a, b, window, current, height = 220, compact = false }: Props) {
  const ratios = a.map((x, i) => Number(formatUnits((x * 10n ** 18n) / b[i], 18)));
  if (ratios.length < 2) {
    return (
      <div className="chart-empty" style={{ height }}>
        Waiting for daily closes ({ratios.length} recorded)
      </div>
    );
  }
  const tail = ratios.slice(-window);
  const mean = tail.reduce((s, v) => s + v, 0) / tail.length;
  const sd = Math.sqrt(tail.reduce((s, v) => s + (v - mean) ** 2, 0) / Math.max(1, tail.length - 1));
  const cur = current !== undefined ? Number(formatUnits(current, 18)) : undefined;
  const series = cur !== undefined ? [...ratios, cur] : ratios;
  const lo = Math.min(...series, mean - 2.2 * sd);
  const hi = Math.max(...series, mean + 2.2 * sd);
  const W = 640;
  const H = height;
  const pad = compact ? 6 : 28;
  const x = (i: number) => pad + (i / (series.length - 1)) * (W - 2 * pad);
  const y = (v: number) => H - pad - ((v - lo) / (hi - lo || 1)) * (H - 2 * pad);
  const path = series.map((v, i) => `${i ? "L" : "M"}${x(i).toFixed(1)},${y(v).toFixed(1)}`).join(" ");
  const band = (k: number) => ({ y1: y(mean + k * sd), y2: y(mean - k * sd) });
  const b2 = band(2);
  const b1 = band(1);

  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="chart" role="img" aria-label="Price ratio vs rolling mean and bands">
      <rect x={pad} width={W - 2 * pad} y={b2.y1} height={b2.y2 - b2.y1} className="band2" />
      <rect x={pad} width={W - 2 * pad} y={b1.y1} height={b1.y2 - b1.y1} className="band1" />
      <line x1={pad} x2={W - pad} y1={y(mean)} y2={y(mean)} className="mean" />
      <path d={path} className="line" />
      {cur !== undefined && <circle cx={x(series.length - 1)} cy={y(cur)} r={compact ? 3 : 4.5} className="dot" />}
      {!compact && (
        <>
          <text x={pad} y={14} className="axis">
            {hi.toFixed(4)}
          </text>
          <text x={pad} y={H - 8} className="axis">
            {lo.toFixed(4)}
          </text>
          <text x={W - pad} y={H - 8} className="axis" textAnchor="end">
            {dayToDate(days[0])} → {cur !== undefined ? "now" : dayToDate(days[days.length - 1])}
          </text>
          <text x={W - pad} y={y(mean) - 4} className="axis" textAnchor="end">
            mean {mean.toFixed(4)} · ±1σ / ±2σ
          </text>
        </>
      )}
    </svg>
  );
}
