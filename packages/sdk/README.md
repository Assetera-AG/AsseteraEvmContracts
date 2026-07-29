# @asseteragmbh/evm-contracts

TypeScript SDK for the Assetera EVM contracts — **ABIs, per-chain addresses, a viem client, and wagmi hooks**,
generated from the Foundry contracts in [`../../contracts`](../../contracts) (design: **ADR-0026**).

Everything is generated from one source of truth: the Foundry build (ABIs) and the committed per-chain
deployment artifacts in [`src/deployments/*.json`](src/deployments) (addresses, keyed by `chainId` with the
CAIP-2 id). Addresses populate as networks are deployed; until then a chain simply has no entry.

## Install

```bash
npm i @asseteragmbh/evm-contracts viem
# for the React hooks also:
npm i wagmi @tanstack/react-query
```

`viem` is a peer dependency; `wagmi` / `@tanstack/react-query` / `react` are optional peers (only for `/react`).
Published **restricted** (private) on the `@asseteragmbh` scope via release-please + npm OIDC — flips to
public at launch (ADR-0007 / ADR-0016).

## Entry points

| Import | Contents | Runtime deps |
|---|---|---|
| `@asseteragmbh/evm-contracts` | ABIs, address helpers, `createExchangeClient` | viem |
| `@asseteragmbh/evm-contracts/contracts` | ABIs `as const` + address helpers — pure data | **none** |
| `@asseteragmbh/evm-contracts/react` | wagmi hooks (address auto-resolved per chain) | wagmi, react |

The raw `deployments/*.json` are shipped in the package too, for non-TypeScript consumers (e.g. the .NET service).

## Migrating 3.x → 4.0.0 (`AsseteraExchange` → `AsseteraECS`)

The contract was renamed to **AsseteraECS** (Execution, Clearing & Settlement). This is a **source-level
rename only** — the deployed bytecode, the ABI and the on-chain addresses are unchanged, so nothing needs
redeploying. What changed are the generated TypeScript symbols and the deployment-artifact JSON keys:

| 3.x | 4.0.0 |
|---|---|
| `asseteraExchangeAbi` | `asseteraEcsAbi` |
| `asseteraExchangeAddress` / `asseteraExchangeConfig` | `asseteraEcsAddress` / `asseteraEcsConfig` |
| `useReadAsseteraExchange*` / `useWriteAsseteraExchange*` / `useSimulateAsseteraExchange*` / `useWatchAsseteraExchange*` | `useReadAsseteraEcs*` / `useWriteAsseteraEcs*` / `useSimulateAsseteraEcs*` / `useWatchAsseteraEcs*` |
| `getContractAddress(id, "AsseteraExchange")` | `getContractAddress(id, "AsseteraECS")` |
| `deployment.contracts.AsseteraExchange` | `deployment.contracts.AsseteraECS` |
| `deployment.implementations.AsseteraExchange` | `deployment.implementations.AsseteraECS` |
| `getExchangeAddress(id)` | `getEcsAddress(id)` — `getExchangeAddress` still works, now `@deprecated` |

⚠️ Consumers that read the deployment key **raw** (e.g. the Subsquid indexer's
`deployment.contracts.AsseteraExchange`) must change the key in the same PR as the dependency bump — a lone
bump is a runtime break.

The **EIP-712 domain name is still `"AsseteraExchange"`** and is not part of this migration; it is written
into the proxy's storage at initialization and only changes at a future fresh deploy.

## Services (viem)

```ts
import { createPublicClient, http } from "viem";
import { createExchangeClient, getEcsAddress } from "@asseteragmbh/evm-contracts";

const publicClient = createPublicClient({ transport: http(rpcUrl) });
const exchange = createExchangeClient({ chainId: 80002, publicClient }); // address resolved from chainId
const version = await exchange.read.version();
```

## Indexer / non-viem consumers (pure data)

```ts
import { asseteraEcsAbi, getContractAddress } from "@asseteragmbh/evm-contracts/contracts";
// ABIs `as const` for viem `parseEventLogs`, addresses for the Subsquid processor — no viem/wagmi pulled in.
const exchangeAddr = getContractAddress(80002, "AsseteraECS");
```

## React (wagmi)

```tsx
import { useReadAsseteraEcsVersion } from "@asseteragmbh/evm-contracts/react";

function Version() {
  const { data } = useReadAsseteraEcsVersion(); // address auto-resolved from the connected chain
  return <span>{data}</span>;
}
```

## Development

```bash
npm run generate   # forge build → ABIs (wagmi/cli) + inline the deployment artifacts
npm run typecheck
npm run build      # tsup → dist (ESM + CJS + d.ts); `prebuild` runs generate

# to work against local addresses, deploy to anvil first (writes a git-ignored 31337.json), then regenerate:
npm run deploy:local   # from the repo root
```

Generated files (`src/generated/`, `src/deployments/deployments.gen.ts`) are **git-ignored** and produced by
`npm run generate` — they derive from the contracts + committed deployment JSON, so a local deployment never
bakes an address into the committed source or the published package.
