import { formatUnits } from "viem";

export const STATE_LABEL = ["Flat", "Long spread", "Short spread"] as const;
export const STATE_HINT = [
  "100% USDG, waiting for a signal",
  "Long A / short B — betting the A/B ratio rises back to its mean",
  "Short A / long B — betting the A/B ratio falls back to its mean",
] as const;

export const ACTION_LABEL = ["None", "Arm entry", "Enter", "Exit", "Rebalance"] as const;
export const EXIT_REASON: Record<number, string> = {
  1: "Mean reversion",
  2: "Stop loss",
  3: "Max holding period",
  4: "Correlation breakdown",
  5: "Borrow cost",
  7: "Guardian emergency exit",
  8: "Full redemption",
};

export function usd(v: bigint | undefined, decimals = 6, digits = 2): string {
  if (v === undefined) return "—";
  const n = Number(formatUnits(v, decimals));
  return n.toLocaleString(undefined, { style: "currency", currency: "USD", maximumFractionDigits: digits });
}

export function wad(v: bigint | undefined, digits = 2): string {
  if (v === undefined) return "—";
  return Number(formatUnits(v, 18)).toFixed(digits);
}

export function pct(vWad: bigint | undefined, digits = 1): string {
  if (vWad === undefined) return "—";
  return `${(Number(formatUnits(vWad, 18)) * 100).toFixed(digits)}%`;
}

export function short(addr: string | undefined): string {
  return addr ? `${addr.slice(0, 6)}…${addr.slice(-4)}` : "—";
}

export function dayToDate(day: bigint | number): string {
  return new Date(Number(day) * 86_400_000).toISOString().slice(0, 10);
}
