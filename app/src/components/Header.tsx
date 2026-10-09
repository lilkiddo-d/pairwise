"use client";

import Link from "next/link";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { PROJECT_TOKEN, NETWORK } from "@/lib/config";

export function Header() {
  return (
    <header className="header">
      <Link href="/" className="brand" aria-label="Pairwise home">
        <svg width="26" height="26" viewBox="0 0 26 26" aria-hidden="true">
          <circle cx="9" cy="13" r="7" fill="none" stroke="currentColor" strokeWidth="2" />
          <circle cx="17" cy="13" r="7" fill="none" stroke="var(--accent)" strokeWidth="2" />
        </svg>
        <span>Pairwise</span>
        {NETWORK === "fork" && <span className="pill warn">local fork</span>}
      </Link>
      <nav className="nav">
        <Link href="/">Pairs</Link>
        {PROJECT_TOKEN && <Link href="/stake">Stake</Link>}
        <Link href="/risk">Risks</Link>
      </nav>
      <ConnectButton chainStatus="icon" showBalance={false} accountStatus="address" />
    </header>
  );
}
