# AsseteraEvmContracts

Solidity (Foundry) smart contracts for the **Assetera** regulated real-world-asset (RWA) exchange.

`AsseteraECS` — **E**xecution, **C**learing and **S**ettlement — is an **escrow-based, off-chain-matched
limit-order venue** with a MiFID-style compliance model: every user-initiated trade action requires a fresh,
single-use **EIP-712 KYC attestation** signed by the platform's compliance backend, and trades are
**gasless** for end users via ERC-2771 meta-transactions. The contract is **UUPS-upgradeable** (ERC-1967)
and role-gated.

> **Renamed from `AsseteraExchange`** (AC-836/AC-837). The rename is source-level only: the compiled
> `deployedBytecode`, the ABI and the storage layout are byte-identical, so the live Amoy/Sepolia proxies
> and implementations are untouched — **no redeploy, no upgrade**. Two string literals deliberately keep
> the old name because they are addresses/domains rather than branding: the **EIP-712 domain**
> (`src/AsseteraECS.sol:initialize`) and the **CREATE2/CREATE3 salt labels** (`script/Deploy.s.sol`).
> Both move to `AsseteraECS` only at the planned production fresh deploy.

> Full behaviour is specified in [`docs/FUNCTIONAL_SPEC.md`](docs/FUNCTIONAL_SPEC.md). The event surface
> consumed by the indexer is in [`docs/INDEXER_EVENT_SCHEMA.md`](docs/INDEXER_EVENT_SCHEMA.md).

## Contracts

| Contract | Path | What it is |
|---|---|---|
| `AsseteraECS` | [`src/AsseteraECS.sol`](src/AsseteraECS.sol) | The exchange. UUPS proxy; escrow limit orders + counter-offer negotiation; KYC-attestation gated; ERC-2771 gasless; per-pair maker/taker fees. |
| `FaucetToken` | [`test/mocks/FaucetToken.sol`](test/mocks/FaucetToken.sol) | Minimal ERC20 + EIP-2612 permit with an open faucet — the mock `mUSDC` (6 dp) and `mRWA` (18 dp) test tokens. **Testnet only, not part of the production `src/` surface.** |

### Roles

- `DEFAULT_ADMIN_ROLE` — upgrade the proxy, manage roles, force-cancel positions. **Safe multisig in prod.**
- `OPERATOR_ROLE` — settle matched orders/offers, refund, pause.
- `KYC_OPERATOR_ROLE` — the address whose signature authorises KYC-gated actions (the compliance backend).
- `FEE_OPERATOR_ROLE` — the address whose signature authorises per-pair fee terms on `placeOrder`/`placeOrderWithPermit`/`makeOffer` (a separate fee service, not the KYC backend).

## Layout

```
src/       production contract surface (AsseteraECS)
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
is idempotent — it reuses existing contracts and, when the layout allows it, **upgrades the proxy in place**
(address unchanged). Local-chain records (anvil `31337`) are **git-ignored** — they're deterministic and
deployer-specific, so just regenerate them with `npm run deploy:local`; only **real-network** deployments
(Amoy/mainnet/…) are committed.

> ⚠️ **The deployer address is an input to every salt.** "Idempotent" holds only for the SAME deployer key.
> Run the script with a different key and it computes a different address for every contract, finds no code
> there, and deploys a second forwarder and a second pair of mock tokens alongside the live ones — it forks
> the deployment set rather than reporting an error. The deployer is therefore a durable artifact: it has no
> role and cannot upgrade anything, but losing it means this environment can never be re-deployed into.

**Sign from an encrypted keystore, not from a key in `.env`.** One passphrase prompt per deploy, and no
plaintext key in a dotfile, in shell history, or in a backup:

```bash
cast wallet import assetera-deployer --interactive   # once
```

```bash
# Local (anvil) — one command; auto-etches CreateX onto the node, then broadcasts
npm run anvil          # in another terminal
npm run deploy:local

# Live networks. DRY RUN FIRST — it prints every address without sending anything
# and without touching the committed deployment record.
npm run dryrun:amoy
npm run deploy:amoy

npm run verify:amoy    # governance invariants of what is now on chain
```

Compare the dry run's addresses against the ones you expect **before** broadcasting. They are permanent, and
a wrong deployer or a renamed salt label is invisible in every other way.

Copy [`.env.sample`](.env.sample) → `.env` for RPC URLs, `DEPLOYER_ADDRESS`, and the role addresses.
**Every role address silently defaults to the deployer when unset**, so setting them is not optional on a
deploy you intend to keep. `ADMIN_ADDRESS` is the Safe multisig in prod. **Never commit `.env`.** Supported
RPC aliases (`foundry.toml`): `local`, `sepolia`, `amoy`. Use a **server-side** RPC key: a domain-restricted
browser key is matched on `Origin` and returns 403 from a terminal.

| Script | Purpose |
|---|---|
| [`script/Deploy.s.sol`](script/Deploy.s.sol) | Deterministic deploy of forwarder + tokens + exchange impl + CREATE3 proxy (atomic init), or upgrade the proxy in place. |
| [`script/UpgradeCalldata.s.sol`](script/UpgradeCalldata.s.sol) | Print the `upgradeToAndCall` calldata for a Safe multisig to propose (prod upgrades). |
| [`script/Verify.s.sol`](script/Verify.s.sol) | Post-deploy **governance** check: proxy wiring, who holds which role, whether the deployer still holds admin, compliance gating, pause state, and whether the router's settlement caps are still closed. Not source verification — that is `forge verify-contract`. |
| [`script/AdminCalldata.s.sol`](script/AdminCalldata.s.sol) | Print the post-deploy admin transactions (`setSettlementCap`, `setAllowedCollector`) as multisig fields and as `cast send` lines. The router deploys **closed**, so it settles nothing until these are sent. |
| [`script/DeploymentFile.sol`](script/DeploymentFile.sol) | The single definition of where a chain's deployment record lives, shared by the three scripts above so they cannot drift apart. |

## Conventions & contributing

See [`AGENTS.md`](../AGENTS.md) for Conventional Commit scopes, branch naming, and Solidity style. In short:
work on a `feat/AC-###-slug` branch, open a PR, get CI green + one code-owner review; `main` is protected
and squash-merged.

## References

- [`docs/FUNCTIONAL_SPEC.md`](docs/FUNCTIONAL_SPEC.md) — contract functional specification.
- [`docs/INDEXER_EVENT_SCHEMA.md`](docs/INDEXER_EVENT_SCHEMA.md) — event schema for the off-chain indexer.
- Architecture decisions live in the **AsseteraADRs** repo (engineering workflow: ADR-0004;
  github-config-as-code: ADR-0013).
