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

Copy [`.env.sample`](.env.sample) → `.env` and fill in the RPC URLs, deployer key, and role addresses.
**Never commit `.env`.** Deployment state per network is written to `deployments/<chainId>.json`; the
deploy script is idempotent — re-running **upgrades the exchange proxy in place** and reuses
already-deployed tokens/forwarder.

```bash
# Local (anvil)
anvil &
forge script script/Deploy.s.sol --rpc-url local --broadcast

# Polygon Amoy testnet
forge script script/Deploy.s.sol --rpc-url amoy --broadcast --verify
```

Supported RPC aliases (`foundry.toml`): `local`, `sepolia`, `amoy`. Target network is Polygon Amoy
(testnet) → Polygon mainnet.

| Script | Purpose |
|---|---|
| [`script/Deploy.s.sol`](script/Deploy.s.sol) | Deploy tokens + ERC-2771 forwarder + exchange impl + proxy, or upgrade the proxy in place. |
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
