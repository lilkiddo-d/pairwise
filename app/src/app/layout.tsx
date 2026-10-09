import type { Metadata } from "next";
import Link from "next/link";
import "./globals.css";
import { Providers } from "@/components/Providers";
import { Header } from "@/components/Header";

export const metadata: Metadata = {
  title: "Pairwise — market-neutral pairs vaults",
  description: "Long one stock token, short another, earn the spread. Rules-based, on-chain, non-custodial.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>
          <Header />
          <main className="main">{children}</main>
          <footer className="footer">
            <span>
              Pairwise is experimental, unaudited software. Pairs trading can lose money, including through short-leg
              liquidation. Not investment advice. <Link href="/risk">Read the risk disclosure</Link>.
            </span>
          </footer>
        </Providers>
      </body>
    </html>
  );
}
