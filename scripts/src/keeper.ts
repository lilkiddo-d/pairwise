/**
 * Pairwise keeper.
 *
 *   pnpm keeper status            # table of vaults, z-scores and the next action
 *   pnpm keeper once              # one pass: strategy actions + daily closes + weekly hedge
 *   pnpm keeper run               # loop forever (KEEPER_INTERVAL seconds)
 *   pnpm keeper seed [days=30]    # bootstrap empty ring buffers from verifiable historical Chainlink rounds
 *   pnpm keeper record | hedge | harvest
 *
 * The keeper never sees a private key: every transaction is signed by Foundry
 * (`cast send --account pairwise-keeper`), reads and pre-flight simulations use viem.
 * Keepers can only *trigger*: direction, sizing and timing rules are enforced on-chain by StrategyEngine.
 */
import { spawnSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createPublicClient,
  encodeFunctionData,
  http,
  type Abi,
  type Address,
  type Hex,
  formatUnits,
} from "viem";
import { robinhoodMainnet, localFork, symbolByAddress } from "@pairwise/config";
import {
  PairVaultAbi,
  StrategyEngineAbi,
  SpreadOracleAbi,
  MarketClockAbi,
  OracleAdapterAbi,
  FeeCollectorAbi,
} from "../../app/src/abi/index";

// ---------------------------------------------------------------- config

const here = dirname(fileURLToPath(import.meta.url));
const NETWORK = process.env.KEEPER_NETWORK === "fork" ? "fork" : "mainnet";
const CHAIN = NETWORK === "fork" ? localFork : robinhoodMainnet;
const RPC = process.env.KEEPER_RPC_URL || CHAIN.rpcUrls.default.http[0];
const ACCOUNT = process.env.KEEPER_ACCOUNT || "pairwise-keeper";
const PASSWORD_FILE = process.env.KEEPER_PASSWORD_FILE || "";
const UNLOCKED_FROM = (process.env.KEEPER_UNLOCKED_FROM || "") as Address | "";
const INTERVAL = Number(process.env.KEEPER_INTERVAL || 60);
const HARVEST = process.env.KEEPER_HARVEST === "true";
const DRY_RUN = process.env.KEEPER_DRY_RUN === "true";
const DEADLINE_SECS = 600n;

const ACTIONS = ["NONE", "ARM", "ENTER", "EXIT", "REBALANCE"];
const STATES = ["FLAT", "LONG_SPREAD", "SHORT_SPREAD"];

interface Deployment {
  chainId: number;
  marketClock: Address;
  oracleAdapter: Address;
  spreadOracle: Address;
  strategyEngine: Address;
  feeCollector: Address;
  vaults: Address[];
}

const depPath = process.env.KEEPER_DEPLOYMENT || join(here, "..", "..", "deployments", `${CHAIN.id}.json`);
if (!existsSync(depPath)) {
  console.error(`No deployment at ${depPath}. Run script/Deploy.s.sol first.`);
  process.exit(1);
}
const dep = JSON.parse(readFileSync(depPath, "utf8")) as Deployment;
const client = createPublicClient({ chain: CHAIN, transport: http(RPC, { retryCount: 4, retryDelay: 500 }) });

const log = (...a: unknown[]) => console.log(new Date().toISOString(), ...a);

// ---------------------------------------------------------------- signing (Foundry keystore only)

let keeperAddress: Address | undefined;

function castArgs(): string[] {
  if (UNLOCKED_FROM) return ["--unlocked", "--from", UNLOCKED_FROM];
  const a = ["--account", ACCOUNT];
  if (PASSWORD_FILE) a.push("--password-file", PASSWORD_FILE);
  return a;
}

function resolveKeeperAddress(): Address {
  if (keeperAddress) return keeperAddress;
  if (UNLOCKED_FROM) return (keeperAddress = UNLOCKED_FROM);
  const args = ["wallet", "address", "--account", ACCOUNT];
  if (PASSWORD_FILE) args.push("--password-file", PASSWORD_FILE);
  const r = spawnSync("cast", args, { encoding: "utf8", stdio: ["inherit", "pipe", "inherit"] });
  if (r.status !== 0) throw new Error(`cast wallet address failed for account "${ACCOUNT}"`);
  return (keeperAddress = r.stdout.trim() as Address);
}

async function send(label: string, to: Address, abi: Abi, functionName: string, args: readonly unknown[]) {
  const data = encodeFunctionData({ abi, functionName, args } as never) as Hex;
  const from = resolveKeeperAddress();
  try {
    await client.call({ account: from, to, data }); // pre-flight: surface revert reasons without spending gas
  } catch (e) {
    log(`skip ${label}: simulation reverted — ${(e as Error).message.split("\n")[0]}`);
    return false;
  }
  if (DRY_RUN) {
    log(`[dry-run] ${label}: cast send ${to} ${data.slice(0, 18)}…`);
    return true;
  }
  const r = spawnSync("cast", ["send", to, data, "--rpc-url", RPC, ...castArgs()], {
    encoding: "utf8",
    stdio: ["inherit", "pipe", "pipe"],
  });
  if (r.status !== 0) {
    log(`FAILED ${label}: ${(r.stderr || r.stdout).trim().split("\n").slice(-2).join(" ")}`);
    return false;
  }
  const tx = /transactionHash\s+(0x[0-9a-fA-F]{64})/.exec(r.stdout)?.[1];
  log(`sent ${label}${tx ? ` tx=${tx}` : ""}`);
  return true;
}

// ---------------------------------------------------------------- reads

const read = <T>(address: Address, abi: Abi, functionName: string, args: readonly unknown[] = []) =>
  client.readContract({ address, abi, functionName, args } as never) as Promise<T>;

async function vaultInfo(v: Address) {
  const [pairId, state, tokenA, tokenB, tvl] = await Promise.all([
    read<bigint>(v, PairVaultAbi, "pairId"),
    read<number>(v, PairVaultAbi, "state"),
    read<Address>(v, PairVaultAbi, "tokenA"),
    read<Address>(v, PairVaultAbi, "tokenB"),
    read<bigint>(v, PairVaultAbi, "totalAssets"),
  ]);
  return { pairId, state, tokenA, tokenB, tvl, name: `${symbolByAddress(tokenA) ?? "A"}/${symbolByAddress(tokenB) ?? "B"}` };
}

// ---------------------------------------------------------------- jobs

async function strategyPass() {
  const now = (await client.getBlock()).timestamp;
  for (const v of dep.vaults) {
    const [action, detail, z] = await read<readonly [number, number, bigint]>(
      dep.strategyEngine,
      StrategyEngineAbi,
      "check",
      [v],
    );
    if (action === 0) continue;
    const info = await vaultInfo(v);
    await send(
      `${ACTIONS[action]}(${detail}) ${info.name} z=${(Number(z) / 1e18).toFixed(2)}`,
      dep.strategyEngine,
      StrategyEngineAbi,
      "execute",
      [v, now + DEADLINE_SECS],
    );
  }
}

async function recordPass() {
  const now = (await client.getBlock()).timestamp;
  const after = await read<boolean>(dep.marketClock, MarketClockAbi, "isAfterCloseOnTradingDay", [now]);
  if (!after) return;
  const today = await read<bigint>(dep.marketClock, MarketClockAbi, "etDay", [now]);
  const due: bigint[] = [];
  for (const v of dep.vaults) {
    const pid = await read<bigint>(v, PairVaultAbi, "pairId");
    const p = await read<{ lastDay: bigint }>(dep.spreadOracle, SpreadOracleAbi, "getPair", [pid]);
    if (p.lastDay < today) due.push(pid);
  }
  if (due.length) await send(`recordCloses(${due.join(",")})`, dep.spreadOracle, SpreadOracleAbi, "recordCloses", [due]);
}

async function hedgePass() {
  const now = (await client.getBlock()).timestamp;
  for (const v of dep.vaults) {
    const pid = await read<bigint>(v, PairVaultAbi, "pairId");
    const p = await read<{ hedgeUpdatedAt: bigint; count: number }>(dep.spreadOracle, SpreadOracleAbi, "getPair", [pid]);
    if (now >= p.hedgeUpdatedAt + 7n * 86400n && p.count >= 10) {
      await send(`updateHedgeRatio(${pid})`, dep.spreadOracle, SpreadOracleAbi, "updateHedgeRatio", [pid]);
    }
  }
}

async function harvestPass() {
  for (const v of dep.vaults) {
    const [m, p] = await Promise.all([
      read<bigint>(dep.feeCollector, FeeCollectorAbi, "pendingManagementShares", [v]),
      read<bigint>(dep.feeCollector, FeeCollectorAbi, "pendingPerformanceShares", [v]),
    ]);
    if (m + p === 0n) continue;
    const preview = await read<bigint>(v, PairVaultAbi, "previewRedeem", [m + p]);
    await send(`harvest(${v})`, dep.feeCollector, FeeCollectorAbi, "harvest", [v, (preview * 99n) / 100n]);
  }
}

async function status() {
  const now = (await client.getBlock()).timestamp;
  const open = await read<boolean>(dep.marketClock, MarketClockAbi, "isMarketOpen");
  console.log(`chain ${CHAIN.id} · block time ${new Date(Number(now) * 1000).toISOString()} · market ${open ? "OPEN" : "closed"}`);
  for (const v of dep.vaults) {
    const info = await vaultInfo(v);
    const [z, ok] = await read<readonly [bigint, boolean]>(dep.spreadOracle, SpreadOracleAbi, "zScore", [info.pairId]);
    const p = await read<{ count: number; lastDay: bigint }>(dep.spreadOracle, SpreadOracleAbi, "getPair", [info.pairId]);
    const [action, detail] = await read<readonly [number, number, bigint]>(dep.strategyEngine, StrategyEngineAbi, "check", [v]);
    console.log(
      [
        info.name.padEnd(10),
        STATES[info.state].padEnd(13),
        `TVL ${Number(formatUnits(info.tvl, 6)).toFixed(2)}`.padEnd(16),
        `z ${ok ? (Number(z) / 1e18).toFixed(2) : "n/a"}`.padEnd(9),
        `closes ${p.count}`.padEnd(10),
        `next ${ACTIONS[action]}${action ? `(${detail})` : ""}`,
        v,
      ].join("  "),
    );
  }
}

// ---------------------------------------------------------------- seeding from Chainlink history

const AggAbi = [
  {
    type: "function",
    name: "latestRoundData",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "roundId", type: "uint80" },
      { name: "answer", type: "int256" },
      { name: "startedAt", type: "uint256" },
      { name: "updatedAt", type: "uint256" },
      { name: "answeredInRound", type: "uint80" },
    ],
  },
  {
    type: "function",
    name: "getRoundData",
    stateMutability: "view",
    inputs: [{ name: "roundId", type: "uint80" }],
    outputs: [
      { name: "roundId", type: "uint80" },
      { name: "answer", type: "int256" },
      { name: "startedAt", type: "uint256" },
      { name: "updatedAt", type: "uint256" },
      { name: "answeredInRound", type: "uint80" },
    ],
  },
] as const;

const roundCache = new Map<string, bigint>();

async function roundUpdatedAt(feed: Address, id: bigint): Promise<bigint | undefined> {
  const key = `${feed}:${id}`;
  if (roundCache.has(key)) return roundCache.get(key);
  try {
    const r = await client.readContract({ address: feed, abi: AggAbi, functionName: "getRoundData", args: [id] });
    roundCache.set(key, r[3]);
    return r[3];
  } catch {
    return undefined;
  }
}

/** Round prevailing at closeTs: updatedAt <= closeTs < next.updatedAt, at most 26h old (what SpreadOracle verifies). */
async function closeRound(feed: Address, closeTs: bigint): Promise<bigint | undefined> {
  const latest = await client.readContract({ address: feed, abi: AggAbi, functionName: "latestRoundData" });
  const phase = latest[0] >> 64n;
  const base = phase << 64n;
  let lo = 1n;
  let hi = latest[0] - base;
  const first = await roundUpdatedAt(feed, base + lo);
  if (first === undefined || first > closeTs) return undefined; // before this phase started
  while (lo < hi) {
    const mid = (lo + hi + 1n) / 2n;
    const t = await roundUpdatedAt(feed, base + mid);
    if (t !== undefined && t <= closeTs) lo = mid;
    else hi = mid - 1n;
  }
  const t = await roundUpdatedAt(feed, base + lo);
  const next = await roundUpdatedAt(feed, base + lo + 1n);
  if (t === undefined || next === undefined || next <= closeTs || closeTs - t > 26n * 3600n) return undefined;
  return base + lo;
}

async function seed(days: number) {
  const now = (await client.getBlock()).timestamp;
  const today = await read<bigint>(dep.marketClock, MarketClockAbi, "etDay", [now]);
  for (const v of dep.vaults) {
    const info = await vaultInfo(v);
    const p = await read<{ count: number }>(dep.spreadOracle, SpreadOracleAbi, "getPair", [info.pairId]);
    if (p.count > 0) {
      log(`${info.name}: already has ${p.count} closes, skipping`);
      continue;
    }
    const feedA = (await read<readonly [Address]>(dep.oracleAdapter, OracleAdapterAbi, "feeds", [info.tokenA]))[0];
    const feedB = (await read<readonly [Address]>(dep.oracleAdapter, OracleAdapterAbi, "feeds", [info.tokenB]))[0];
    const ds: bigint[] = [];
    const ra: bigint[] = [];
    const rb: bigint[] = [];
    for (let d = today - 1n; d > today - 120n && ra.length < days; d--) {
      if (!(await read<boolean>(dep.marketClock, MarketClockAbi, "isTradingDay", [d]))) continue;
      const closeTs = await read<bigint>(dep.marketClock, MarketClockAbi, "closeTimestamp", [d]);
      const [a, b] = await Promise.all([closeRound(feedA, closeTs), closeRound(feedB, closeTs)]);
      if (a === undefined || b === undefined) continue;
      ds.unshift(d);
      ra.unshift(a);
      rb.unshift(b);
    }
    log(`${info.name}: found ${ra.length} verifiable closes`);
    if (ra.length >= 10) {
      await send(`seedFromRounds(${info.pairId})`, dep.spreadOracle, SpreadOracleAbi, "seedFromRounds", [info.pairId, ds, ra, rb]);
    }
  }
}

// ---------------------------------------------------------------- main

async function once() {
  for (const [name, job] of [
    ["strategy", strategyPass],
    ["closes", recordPass],
    ["hedge", hedgePass],
  ] as const) {
    try {
      await job();
    } catch (e) {
      log(`${name} pass error: ${(e as Error).message.split("\n")[0]}`);
    }
  }
}

async function main() {
  const [cmd = "status", arg] = process.argv.slice(2);
  log(`keeper · network ${NETWORK} (chain ${CHAIN.id}) · rpc ${RPC} · ${dep.vaults.length} vaults`);
  switch (cmd) {
    case "status":
      return status();
    case "once":
      return once();
    case "record":
      return recordPass();
    case "hedge":
      return hedgePass();
    case "harvest":
      return harvestPass();
    case "seed":
      return seed(Number(arg || 30));
    case "run": {
      log(`signing as ${resolveKeeperAddress()}${DRY_RUN ? " (dry run)" : ""}`);
      let lastHarvestDay = -1;
      for (;;) {
        await once();
        const day = Math.floor(Date.now() / 86_400_000);
        if (HARVEST && day !== lastHarvestDay) {
          await harvestPass().catch((e) => log(`harvest error: ${(e as Error).message.split("\n")[0]}`));
          lastHarvestDay = day;
        }
        await new Promise((r) => setTimeout(r, INTERVAL * 1000));
      }
    }
    default:
      console.error(`unknown command "${cmd}"`);
      process.exit(1);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
