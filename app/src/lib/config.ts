import { http, createConfig, fallback } from "wagmi";
import { connectorsForWallets } from "@rainbow-me/rainbowkit";
import {
  injectedWallet,
  metaMaskWallet,
  rainbowWallet,
  coinbaseWallet,
  walletConnectWallet,
} from "@rainbow-me/rainbowkit/wallets";
import { robinhoodMainnet, localFork } from "@pairwise/config";
import type { Address } from "viem";

export const NETWORK = process.env.NEXT_PUBLIC_NETWORK === "fork" ? "fork" : "mainnet";
export const ACTIVE_CHAIN = NETWORK === "fork" ? localFork : robinhoodMainnet;

const rpc = process.env.NEXT_PUBLIC_RPC_URL || ACTIVE_CHAIN.rpcUrls.default.http[0];

/** $PAIR token address. Empty => all token features are hidden. */
export const PROJECT_TOKEN: Address | undefined = (() => {
  const v = (process.env.NEXT_PUBLIC_PROJECT_TOKEN || "").trim();
  return /^0x[0-9a-fA-F]{40}$/.test(v) ? (v as Address) : undefined;
})();

const projectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID || "";

const connectors = connectorsForWallets(
  [
    {
      groupName: "Wallets",
      wallets: projectId
        ? [injectedWallet, metaMaskWallet, rainbowWallet, coinbaseWallet, walletConnectWallet]
        : [injectedWallet],
    },
  ],
  { appName: "Pairwise", projectId: projectId || "unused" },
);

export const wagmiConfig = createConfig({
  chains: [ACTIVE_CHAIN],
  connectors,
  transports: { [ACTIVE_CHAIN.id]: fallback([http(rpc)]) },
  ssr: true,
});
