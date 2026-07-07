/**
 * Contract artifacts — the zero-runtime-dependency data entry (`@asseteragmbh/evm-contracts/contracts`).
 *
 * `@wagmi/cli` (foundry plugin) emits ABIs `as const` from the Foundry build output into `./abi/*.ts`,
 * and the per-chain address maps from `../deployments/*.json` (ADR-0026 D5/D6). Consumers that only need
 * ABIs + addresses (the indexer, the Marketplace API, non-viem callers) import from here without pulling
 * in viem.
 *
 * Placeholder until the Phase 3 codegen lands.
 */
export {};
