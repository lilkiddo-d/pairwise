// Extracts ABIs from Foundry artifacts into typed `as const` modules (committed, so the app
// builds without Foundry). Re-run after contract changes: `pnpm --filter @pairwise/app abis`.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const out = join(root, "app", "src", "abi");
mkdirSync(out, { recursive: true });
const names = [
  "PairVault",
  "PairVaultFactory",
  "StrategyEngine",
  "SpreadOracle",
  "MarketClock",
  "ShortAdapter",
  "LongAdapter",
  "FeeCollector",
  "ProjectTokenHooks",
  "OracleAdapter",
];
let index = "";
for (const n of names) {
  const art = JSON.parse(readFileSync(join(root, "contracts", "out", `${n}.sol`, `${n}.json`), "utf8"));
  writeFileSync(join(out, `${n}.ts`), `export const ${n}Abi = ${JSON.stringify(art.abi, null, 2)} as const;\n`);
  index += `export { ${n}Abi } from "./${n}";\n`;
}
writeFileSync(join(out, "index.ts"), index);
console.log(`wrote ${names.length} ABIs to app/src/abi`);
