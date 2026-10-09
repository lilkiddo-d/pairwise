# Deploying Pairwise to Robinhood Chain mainnet

Everything below is what **you** run. Nothing in this repo creates, stores or prints a private key: the deploy script
signs only through the Foundry keystore account `pairwise-deployer`, the keeper only through `pairwise-keeper`.

| | |
|---|---|
| Chain | Robinhood Chain mainnet, chain ID **4663**, gas token **ETH** |
| RPC | `https://rpc.mainnet.chain.robinhood.com` (public, rate-limited — a dedicated provider is better for the keeper) |
| Explorer / verifier | Blockscout `https://robinhoodchain.blockscout.com`; verify via **Sourcify** (Blockscout's API is behind a Cloudflare challenge that blocks CLI tools) |
| Cost | dry run estimate: ~34.1M gas ≈ **0.0014 ETH** at 0.04 gwei → fund the deployer with **0.01 ETH** for headroom |

Prerequisites: Foundry (`foundryup`), Node 20+, pnpm 10, and in `contracts/`: `forge build` succeeds.

---

## 0. (Recommended) decide your roles

The script reads three optional environment variables. Anything unset defaults to the deployer address.

| Variable | Role | Recommendation |
|---|---|---|
| `TIMELOCK_ADMIN` | proposer + executor of the 48h Timelock (i.e. governance) | a Safe multisig |
| `GUARDIAN_ADDRESS` | can pause vaults/engine/staking and force an emergency exit; maintains the holiday calendar | a Safe (fast signers) |
| `KEEPER_ADDRESS` | the only address allowed to trigger strategy actions and seed price history | the `pairwise-keeper` keystore |

## 1. Import the deployer key into an encrypted Foundry keystore

```bash
cast wallet import pairwise-deployer --interactive
```

(Paste the key when prompted; it is encrypted to `~/.foundry/keystores/pairwise-deployer`.) Do the same for the keeper:

```bash
cast wallet import pairwise-keeper --interactive
```

Fund `cast wallet address --account pairwise-deployer` with ~0.01 ETH on chain 4663, and the keeper with ~0.01 ETH.

Optional rehearsal (simulation only, sends nothing):

```bash
cd contracts && forge script script/Deploy.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --account pairwise-deployer
```

## 2. Deploy + verify (one command)

From `contracts/` (set `TIMELOCK_ADMIN` / `GUARDIAN_ADDRESS` first if you use Safes):

```bash
KEEPER_ADDRESS=$(cast wallet address --account pairwise-keeper) forge script script/Deploy.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --account pairwise-deployer --broadcast --slow --verify --verifier sourcify
```

What it does, in order: deploys the 48h Timelock, MarketClock (+ 2026–2027 NYSE holidays), OracleAdapter (Chainlink
feeds), Uniswap v3 swap venue (routes), SpreadOracle, StrategyEngine, FeeCollector, ProjectTokenHooks, ComplianceRegistry
(disabled), vault/adapter implementations and the factory; wires all roles; lists the 4 launch pairs; grants every admin
role to the Timelock and **renounces every deployer role**, then asserts the deployer holds nothing. On success it writes
`deployments/4663.json` and `app/public/deployments/4663.json` (the frontend config).

If verification didn't run or failed, the deployment itself is unaffected. Verify every contract on Sourcify (no keys
needed; Blockscout shows Sourcify-verified sources automatically). From `contracts/`, for each created contract listed in
`broadcast/Deploy.s.sol/4663/run-latest.json`:

```bash
forge verify-contract <address> src/<Name>.sol:<Name> --chain 4663 --verifier sourcify --rpc-url https://rpc.mainnet.chain.robinhood.com --watch
```

Do **not** use `--verifier blockscout`: its API answers CLI requests with a Cloudflare 403 challenge.

Vaults and adapters are EIP-1167 clones of verified implementations; Blockscout shows them as minimal proxies.

## 3. Seed history and start the keeper

Vaults trade only once their ring buffer holds ≥10 daily closes. Seed the last 30 trading days from verifiable
Chainlink history (the contract checks each round was the last update before that day's close):

```bash
pnpm install
```
```bash
pnpm keeper seed 30
```

Start the keeper (signs via `cast send --account pairwise-keeper`):

```bash
pnpm keeper run
```

For unattended operation put the keystore password in a file only you can read and set `KEEPER_PASSWORD_FILE=/path/to/file`
(see `scripts/.env.example`). `pnpm keeper status` prints every vault, its z-score and the next action. Run it under a
process supervisor (systemd, pm2, Docker restart policy) on an always-on host.

## 4. Deploy the frontend to Vercel

1. Commit `app/public/deployments/4663.json` (written by step 2).
2. Vercel → New Project → import the repo, **Root Directory: `app`**, framework Next.js. Vercel detects pnpm from the
   lockfile; install command `pnpm install`, build command `pnpm build`.
3. Environment variables (see `app/.env.example`):
   - `NEXT_PUBLIC_NETWORK=mainnet`
   - `NEXT_PUBLIC_RPC_URL=` (optional dedicated RPC)
   - `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID=` (optional; without it only injected wallets show)
   - `NEXT_PUBLIC_PROJECT_TOKEN=` (leave **empty** until $PAIR is plugged in)
   - `NEXT_PUBLIC_GEOBLOCK_COUNTRIES=` (optional, e.g. `US,CU,IR,KP,SY`)
4. Deploy. CLI alternative: `cd app && npx vercel --prod`.

## 5. Later: plug in the $PAIR token (`setProjectToken`)

Only once, only via the Timelock (48h). Replace `<PAIR>` with the launched token address; addresses come from
`deployments/4663.json`. Sign with the `TIMELOCK_ADMIN` account (if that's a Safe, submit the same two calls through the
Safe UI's transaction builder).

```bash
TL=$(jq -r .timelock deployments/4663.json); HOOKS=$(jq -r .projectTokenHooks deployments/4663.json); DATA=$(cast calldata "setProjectToken(address)" <PAIR>)
```
```bash
cast send $TL "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" $HOOKS 0 $DATA 0x0000000000000000000000000000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000000000000000000000000000 172800 --rpc-url https://rpc.mainnet.chain.robinhood.com --account pairwise-deployer
```

…wait 48 hours, then:

```bash
cast send $TL "execute(address,uint256,bytes,bytes32,bytes32)" $HOOKS 0 $DATA 0x0000000000000000000000000000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000000000000000000000000000 --rpc-url https://rpc.mainnet.chain.robinhood.com --account pairwise-deployer
```

Then set `NEXT_PUBLIC_PROJECT_TOKEN=<PAIR>` in Vercel and redeploy. See TOKEN_INTEGRATION.md.

---

## Rehearsing locally (what was run to validate this)

```bash
anvil --fork-url https://rpc.mainnet.chain.robinhood.com --chain-id 31337 --port 47123
```
```bash
cd contracts && forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:47123 --broadcast --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
```

(`0xf39F…2266` is anvil's pre-funded, pre-unlocked dev account; no key is handled.) Then
`NEXT_PUBLIC_NETWORK=fork NEXT_PUBLIC_RPC_URL=http://127.0.0.1:47123 pnpm app:dev` and
`KEEPER_NETWORK=fork KEEPER_RPC_URL=http://127.0.0.1:47123 KEEPER_UNLOCKED_FROM=0x70997970C51812dc3A010C7d01b50e0d17dc79C8 pnpm keeper status`.
