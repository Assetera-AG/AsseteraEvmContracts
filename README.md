# AsseteraEvmContracts

The Assetera **EVM smart contracts** and the TypeScript **SDK** generated from them — one npm-workspaces
monorepo. The contracts are the exchange, distribution, and supporting tokens for the regulated real-world-asset
(RWA) platform; the SDK (`@asseteragmbh/evm-contracts`) is the single source of truth for ABIs, per-chain
addresses, and a typed client that every front-end, the indexer, and the Marketplace API consume.

Design: **ADR-0026** (deploy pipeline + publishable SDK, per-VM split). Solana, when it lands, gets its own
repo (`AsseteraSolanaContracts` → `@asseteragmbh/solana-contracts`) — this repo stays EVM-only.

## Layout

```
contracts/     self-contained Foundry project — the audit scope
               (foundry.toml, src/{exchange,distribution,token,interfaces,libraries}, test/, script/, lib/)
packages/
  sdk/         @asseteragmbh/evm-contracts — the published TypeScript SDK (generated from contracts/)
examples/      consumer apps that import the SDK (examples/nextjs — resolves Amoy by chainId)
```

- **Contracts / auditors:** work in [`contracts/`](contracts/) — see its [README](contracts/README.md).
  `forge build` / `forge test` run from there.
- **SDK consumers:** `npm i @asseteragmbh/evm-contracts` — see [`packages/sdk/`](packages/sdk/).

## Develop

```bash
# Contracts (from contracts/)
cd contracts && forge build && forge test

# SDK (from repo root — npm workspaces)
npm install
npm run build            # builds packages/sdk
```

## Conventions

Branch naming, Conventional Commit scopes, and Solidity/TypeScript style live in [`AGENTS.md`](AGENTS.md).
`main` is protected and squash-merged; work on `feat/AC-###-slug` branches (ADR-0004).
