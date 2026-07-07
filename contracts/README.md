# AsseteraEvmContracts

Solidity (Foundry) smart contracts for the **Assetera** regulated real-world-asset (RWA) exchange.

`AsseteraExchange` is an **escrow-based, off-chain-matched limit-order venue** with a MiFID-style
compliance model: every user-initiated trade action requires a fresh, single-use **EIP-712 KYC
attestation** signed by the platform's compliance backend, and trades are **gasless** for end users via
ERC-2771 meta-transactions. The contract is **UUPS-upgradeable** (ERC-1967) and role-gated.

> Full behaviour is specified in [`docs/FUNCTIONAL_SPEC.md`](docs/FUNCTIONAL_SPEC.md). The event surface
> consumed by the indexer is in [`docs/INDEXER_EVENT_SCHEMA.md`](docs/INDEXER_EVENT_SCHEMA.md).

## Contracts

| Contract | Path | What it is |
|---|---|---|
| `AsseteraExchange` | [`src/AsseteraExchange.sol`](src/AsseteraExchange.sol) | The exchange. UUPS proxy; escrow limit orders + counter-offer negotiation; KYC-attestation gated; ERC-2771 gasless; per-pair maker/taker fees. |
| `FaucetToken` | [`src/FaucetToken.sol`](src/FaucetToken.sol) | Minimal ERC20 + EIP-2612 permit with an open faucet — the mock `mUSDC` (6 dp) and `mRWA` (18 dp) test tokens. **Testnet only.** |

### Roles

- `DEFAULT_ADMIN_ROLE` — upgrade the proxy, manage roles, force-cancel positions. **Safe multisig in prod.**
- `OPERATOR_ROLE` — settle matched orders/offers, refund, pause.
- `KYC_OPERATOR_ROLE` — the address whose signature authorises KYC-gated actions (the compliance backend).
- `FEE_OPERATOR_ROLE` — the address whose signature authorises per-pair fee terms on `placeOrder`/`placeOrderWithPermit`/`makeOffer` (a separate fee service, not the KYC backend).

## Layout

```
src/       contracts (AsseteraExchange, FaucetToken)
script/    Foundry deploy/verify/upgrade scripts
test/      forge tests (+ test/mocks/)
docs/      FUNCTIONAL_SPEC.md, INDEXER_EVENT_SCHEMA.md
lib/       dependencies as pinned git submodules (see below)
```

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`, `anvil`)
- Node.js (only for `solhint`, invoked via `npx`)

## Build & test

Dependencies are tracked as **git submodules** pinned in [`foundry.lock`](foundry.lock). Clone with
submodules (or restore them after cloning):

```bash
git clone --recurse-submodules <repo-url>
# or, in an existing clone:
git submodule update --init --recursive
```

Then:

```bash
forge build            # compile (Solidity 0.8.28, via-IR, optimizer 200)
forge test -vvv        # run the test suite
forge fmt --check      # formatting gate (CI enforces this)
npx --yes solhint 'src/**/*.sol' 'script/**/*.sol' 'test/**/*.sol'   # lint gate
```

These four commands are exactly what CI runs on every PR — see
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml).

## Deploy

Deployment is **deterministic** (ADR-0026): contracts are deployed through the **CreateX** factory, and the
exchange proxy + forwarder use **CREATE3** — so they get the **same address on every chain** for a given
deployer, an address that survives implementation upgrades. The per-network record is written to
[`../packages/sdk/src/deployments/<chainId>.json`](../packages/sdk/src/deployments) (the SDK's source of
truth), keyed by numeric `chainId` and carrying the `caip2` id + `namespace` for the indexer/API. Re-running
is idempotent — it reuses existing contracts and **upgrades the proxy in place** (address unchanged).
Local-chain records (anvil `31337`) are **git-ignored** — they're deterministic and deployer-specific, so
just regenerate them with `npm run deploy:local`; only **real-network** deployments (Amoy/mainnet/…) are
committed.

```bash
# Local (anvil) — one command; auto-etches CreateX onto the node, then broadcasts
npm run anvil          # in another terminal
npm run deploy:local

# Polygon Amoy testnet (CreateX is already deployed there)
npm run deploy:amoy    # reads RPC + PRIVATE_KEY from .env / the environment
```

Copy [`.env.sample`](.env.sample) → `.env` for testnet RPC URLs, the deployer key, and role addresses
(`ADMIN_ADDRESS` = the Safe multisig in prod). **Never commit `.env`.** Supported RPC aliases
(`foundry.toml`): `local`, `sepolia`, `amoy`. Target network is Polygon Amoy (testnet) → Polygon mainnet.

| Script | Purpose |
|---|---|
| [`script/Deploy.s.sol`](script/Deploy.s.sol) | Deterministic deploy of forwarder + tokens + exchange impl + CREATE3 proxy (atomic init), or upgrade the proxy in place. |
| [`script/UpgradeCalldata.s.sol`](script/UpgradeCalldata.s.sol) | Print the `upgradeToAndCall` calldata for a Safe multisig to propose (prod upgrades). |
| [`script/Verify.s.sol`](script/Verify.s.sol) | Verify deployed bytecode against a block explorer. |

## Conventions & contributing

See [`AGENTS.md`](../AGENTS.md) for Conventional Commit scopes, branch naming, and Solidity style. In short:
work on a `feat/AC-###-slug` branch, open a PR, get CI green + one code-owner review; `main` is protected
and squash-merged.

## References

- [`docs/FUNCTIONAL_SPEC.md`](docs/FUNCTIONAL_SPEC.md) — contract functional specification.
- [`docs/INDEXER_EVENT_SCHEMA.md`](docs/INDEXER_EVENT_SCHEMA.md) — event schema for the off-chain indexer.
- Architecture decisions live in the **AsseteraADRs** repo (engineering workflow: ADR-0004;
  github-config-as-code: ADR-0013).
