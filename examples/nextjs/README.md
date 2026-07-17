# Next.js sample — `@asseteragmbh/evm-contracts`

A minimal Next.js app that consumes the SDK and resolves the exchange on **Polygon Amoy (80002)** entirely
**by chainId** — no hardcoded addresses or ABIs. It demonstrates the three consumption paths (ADR-0026):

- **`getDeployment(chainId)`** (server component) → addresses + CAIP-2, with block-explorer links.
- **generated wagmi hooks** (`/react`, client component) → live reads with the address auto-resolved per chain.
- (services would use **`createExchangeClient()`** — the viem `getContract` factory — instead of hooks.)

## Run

From the repo root (the SDK is workspace-linked, so build it first):

```bash
npm install
npm run build -w @asseteragmbh/evm-contracts
npm run dev -w evm-contracts-example-nextjs      # http://localhost:3000
```

## Targeting another chain

Change the chain in [`app/providers.tsx`](app/providers.tsx) and the `CHAIN_ID` in [`app/page.tsx`](app/page.tsx).
As long as that chain has a committed deployment (`packages/sdk/src/deployments/<chainId>.json`), the SDK
resolves it — the app code doesn't change. LearningFront will target Sepolia the same way once it's deployed.
