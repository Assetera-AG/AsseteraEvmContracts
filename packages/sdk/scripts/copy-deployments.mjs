#!/usr/bin/env node
// Ship the raw REAL-network deployment artifacts inside the package (ADR-0026 D6) for non-TypeScript
// consumers (e.g. the .NET service). Local-chain artifacts (anvil 31337 / 1337) are ephemeral and
// deployer-specific — never published. Runs postbuild, copying into dist/ (which is what `files` ships).
import { copyFileSync, existsSync, mkdirSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const srcDir = join(here, "..", "src", "deployments");
const outDir = join(here, "..", "dist", "deployments");
const LOCAL_CHAINS = new Set(["31337", "1337"]);

if (!existsSync(srcDir)) process.exit(0);
mkdirSync(outDir, { recursive: true });

let copied = 0;
for (const file of readdirSync(srcDir)) {
  const chainId = file.replace(/\.json$/, "");
  if (!file.endsWith(".json") || LOCAL_CHAINS.has(chainId)) continue;
  copyFileSync(join(srcDir, file), join(outDir, file));
  copied++;
}
console.log(`Copied ${copied} real-network deployment artifact${copied === 1 ? "" : "s"} to dist/deployments/`);
