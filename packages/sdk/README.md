# @asseteragmbh/evm-contracts

TypeScript SDK for the Assetera EVM contracts — **ABIs, per-chain addresses, and a typed viem client**,
generated from the Foundry contracts in [`../../contracts`](../../contracts) (design: **ADR-0026**).

> **Status: scaffold.** The generated ABIs/addresses, the `createExchangeClient` factory, and the wagmi
> React hooks land in Phase 3 of AC-249. The package structure, exports, and build are in place now.

## Install

```bash
npm i @asseteragmbh/evm-contracts viem
```

`viem` is a peer dependency. The package is published **restricted** (private) to the `@asseteragmbh`
scope via release-please + npm OIDC trusted publishing (ADR-0007 / ADR-0016).

## Entry points

| Import | Contents |
|---|---|
| `@asseteragmbh/evm-contracts` | client factory + re-exports (viem) |
| `@asseteragmbh/evm-contracts/contracts` | pure data — ABIs `as const` + per-chain address maps (no runtime deps) |
| `@asseteragmbh/evm-contracts/react` | wagmi hooks (added in Phase 3) |

Raw `abi/*.json` and `deployments/*.json` are shipped in the package for non-TypeScript consumers
(e.g. the .NET compliance service).
