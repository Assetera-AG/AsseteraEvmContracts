# AsseteraExchange — Audit Scope & Handover

This document is the entry point for an external security review of the AsseteraExchange smart contracts.
It defines exactly what is in scope, how to build and test it, the trust model, and the known assumptions.
Everything an auditor needs to reproduce our results should be reachable from here.

- **Project:** AsseteraExchange — the on-chain exchange for a regulated real-world-asset (RWA) venue (MiFID).
- **Foundry root:** `contracts/` (point `forge`, `slither`, and coverage here).
- **Functional specification:** [`docs/FUNCTIONAL_SPEC.md`](docs/FUNCTIONAL_SPEC.md).
- **Event schema (for indexers):** [`docs/INDEXER_EVENT_SCHEMA.md`](docs/INDEXER_EVENT_SCHEMA.md).
- **Internal pre-audit review:** [`docs/SECURITY-REVIEW-2026-07-14.md`](docs/SECURITY-REVIEW-2026-07-14.md) — read this
  for the known findings (M-1, L-1…L-3, I-1…I-4) we have already triaged.

## Audit target (frozen commit)

Please audit a **single frozen commit**. We tag a dedicated release for the engagement
(e.g. `audit-v1`); confirm the exact commit hash with us before starting rather than tracking a moving
branch. `main` is protected, linear-history, and squash-merged, so the tag is stable.

## In scope

The production contract surface under `contracts/src/` — 12 files, ~1,500 LoC:

| File | LoC | Role |
|---|---:|---|
| `src/AsseteraExchange.sol` | 106 | UUPS proxy entrypoint; assembles the modules; `initialize` |
| `src/core/OrderBook.sol` | 292 | Order lifecycle: place / cancel / fill / sweep; pooled escrow |
| `src/core/OfferBook.sol` | 330 | Offer lifecycle: make / replace / accept (atomic settle) / cancel / sweep |
| `src/gates/KycGate.sol` | 62 | EIP-712 KYC attestation verification + nonce burn |
| `src/gates/FeeGate.sol` | 97 | EIP-712 fee attestation verification + fee bounds/collector allowlist |
| `src/admin/ExchangeAdmin.sol` | 100 | Admin surface: pause, compliance toggles, collector allowlist, force-cancel |
| `src/storage/ExchangeStorage.sol` | 78 | Single storage struct behind `__gap` (UUPS layout) |
| `src/types/ExchangeTypes.sol` | 120 | Structs, enums (`Action`), attestation types |
| `src/libs/FeeMath.sol` | 23 | Fee arithmetic (floor division) |
| `src/interfaces/IAsseteraExchange.sol` | 239 | External interface |
| `src/interfaces/IKycGate.sol` | 29 | Interface |
| `src/interfaces/IFeeGate.sol` | 27 | Interface |

## Out of scope

| Path | Why |
|---|---|
| `test/**` — unit tests, the `test/invariants/` escrow-conservation suite, and mocks (`test/mocks/FaucetToken.sol`, `ReentrantToken.sol`, `FeeOnTransferToken.sol`, `RebasingToken.sol`, `AsseteraExchangeV2.sol`) | Tests and mocks. `FaucetToken` is an **open-mint testnet faucet**, deployed only on Amoy/Sepolia/local anvil — never mainnet (enforced in `Deploy.s.sol` via `_isTestnet`). Not part of the production surface. |
| `script/**` (`Deploy.s.sol`, `DeployBase.sol`, `Verify.s.sol`, `UpgradeCalldata.s.sol`) | Deployment / verification tooling, not deployed bytecode. Reviewing the deploy story is welcome but it is not the contract under custody. |
| `docs/parked/OperatorFunctions.sol` | **Parked, not compiled, not deployed.** A commented reference implementation of `settle`/`refund` (`OPERATOR_ROLE`), kept outside `src/` so it is not on the attack surface. See `docs/FUNCTIONAL_SPEC.md §11` for the re-enable path. |
| `lib/**` | Pinned dependencies (see below). |
| `packages/sdk/**`, `examples/**` | TypeScript SDK and consumer examples (in the monorepo, not the Foundry project). |

## Build & test

```bash
cd contracts
forge build          # Solidity 0.8.28, via-IR, optimizer 200 runs
forge test           # 146 tests, expected: all passing
forge coverage       # line coverage ~95–100% on core
```

- `forge build` is clean; the only lint output is `block-timestamp` warnings on expiry comparisons (benign —
  the expiry windows dwarf validator drift; see the Slither triage).
- **Testing (internal finding I-2, resolved):** in addition to the unit suite, the review's coverage gap was
  closed with a handler-driven **escrow-conservation invariant** suite (`test/invariants/`, asserting
  `Σ escrowed == contract balanceOf` per token across every order/offer action), **fee-on-transfer / rebasing
  mock-token** tests that directly exercise the M-1 pool-insolvency mechanism, and **reentrancy-guard coverage
  on all 12 funds-custody entry points** (via a `ReentrantToken` armed with arbitrary calldata).

## Toolchain & compiler settings (`foundry.toml`)

| Setting | Value |
|---|---|
| `solc` | `0.8.28` |
| `optimizer` / `optimizer_runs` | on / `200` |
| `via_ir` | `true` |
| `bytecode_hash` | `none` (deterministic bytecode) |

## Dependencies (pinned — `foundry.lock`, git submodules under `lib/`)

| Dependency | Version |
|---|---|
| `openzeppelin-contracts` | v5.1.0 |
| `openzeppelin-contracts-upgradeable` | v5.1.0 |
| `forge-std` | v1.16.1 |
| `createx-forge` | (deploy tooling only, out of scope) |

## Static analysis (Slither)

Config: [`slither.config.json`](slither.config.json) (filters `lib/`, `test/`, `script/`). Run: `slither .`
from `contracts/`. All current findings are **triaged benign** (details in the internal review, I-4):

| Detector | Location | Verdict |
|---|---|---|
| `arbitrary-send-erc20` | `OfferBook.acceptOffer` | **False positive** — `from` is always the verified caller (maker or taker); you can only pull tokens from yourself. |
| `reentrancy-benign` | `OrderBook.placeOrderWithPermit` | Guarded by `nonReentrant`; state writes after the `permit` external call are harmless. |
| `timestamp` | expiry / TTL comparisons | Benign — validator drift (seconds) is immaterial to the expiry/TTL windows. |
| `dead-code` (`_msgData`) | `AsseteraExchange` | OZ-required ERC-2771 override. |
| `naming-convention` | interface getters, `__gap` | Getters mirror public constants; `__gap` is the OZ storage-gap idiom. |

## Trust model & centralization (by design — regulated venue)

- `DEFAULT_ADMIN_ROLE` is effectively full custody: it can `upgradeToAndCall` to arbitrary logic and
  force-cancel/route any escrow. **Mainnet requirement:** a Safe multisig, plus a timelock on upgrades.
- `KYC_OPERATOR_ROLE` signs KYC attestations (off-chain signer). Compromise cannot move escrow beyond
  normal trading and **cannot set/redirect fees**.
- `FEE_OPERATOR_ROLE` signs fee attestations (a distinct signer). Bounded by `MAX_FEE_BPS` and the
  `allowedCollectors` allowlist.
- Order/offer **matching happens off-chain**; the chain enforces settlement, escrow, attestation, and fees.
- This centralization is intentional and mandated by the regulatory model. See L-3 in the internal review.

## Known security assumptions & findings

Fully described in the internal review; the load-bearing ones:

1. **M-1 — standard-ERC-20-only.** The pooled escrow assumes tokens transfer exactly the requested amount.
   **Only standard, non-rebasing, non-fee-on-transfer ERC-20 tokens may trade.** Enforced off-chain today
   (attestation-gated token addresses); no on-chain tradable-token allowlist. See `FUNCTIONAL_SPEC.md §9`.
2. **L-1 — freezable tokens** (e.g. USDC) can strand escrow if a party or the exchange is blacklisted.
3. **L-3 — centralized signer/upgrade authority** — operationalize with multisig + timelock on mainnet.

## Contact

Code owner: `@tomw1808` (see `CODEOWNERS`). Please route questions and preliminary findings through the
agreed engagement channel.
