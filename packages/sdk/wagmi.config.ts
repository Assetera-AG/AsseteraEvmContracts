import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "@wagmi/cli";
import { foundry, react } from "@wagmi/cli/plugins";

// Codegen for @asseteragmbh/evm-contracts (ADR-0026 D5). Two outputs so the pure-data entry never imports
// wagmi (which CJS bundling would otherwise pull in via a shared module):
//   src/generated/contracts.ts → ABIs `as const` + baked address maps (no React/wagmi)
//   src/generated/react.ts     → the same + wagmi hooks
// The exchange proxy's per-chain address is baked into the hooks (auto-resolved from the connected chain),
// sourced from the committed deployment artifacts — empty until a real network is deployed (local 31337 is
// git-ignored).
const here = dirname(fileURLToPath(import.meta.url));
const deploymentsDir = join(here, "src/deployments");
const include = ["AsseteraECS.json", "FaucetToken.json", "ERC2771Forwarder.json"];

function exchangeAddressesByChain(): Record<number, `0x${string}`> {
  if (!existsSync(deploymentsDir)) return {};
  const byChain: Record<number, `0x${string}`> = {};
  for (const file of readdirSync(deploymentsDir)) {
    if (!file.endsWith(".json")) continue;
    const d = JSON.parse(readFileSync(join(deploymentsDir, file), "utf8"));
    const address = d?.contracts?.AsseteraECS;
    if (d?.chainId && address) byChain[Number(d.chainId)] = address;
  }
  return byChain;
}

const deployments = { AsseteraECS: exchangeAddressesByChain() };

export default defineConfig([
  {
    out: "src/generated/contracts.ts",
    plugins: [foundry({ project: "../../contracts", forge: { build: true }, include, deployments })],
  },
  {
    out: "src/generated/react.ts",
    plugins: [foundry({ project: "../../contracts", forge: { build: false }, include, deployments }), react()],
  },
]);
