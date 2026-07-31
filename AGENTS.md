# AGENTS.md — AsseteraEvmContracts

Local conventions for this repo. Cross-repo rules live in the workspace `CLAUDE.md`; engineering
workflow is **ADR-0004** and github-config-as-code is **ADR-0013** (AsseteraADRs repo). The deploy
pipeline + published SDK design is **ADR-0026**. The `AsseteraExchange` → `AsseteraECS` rename and the
decision to keep the EIP-712 domain name unchanged is **ADR-0041**
(`adr/0041-assetera-ecs-rename/README.md`).

## Layout (npm-workspaces monorepo)

```
contracts/        self-contained Foundry project — the audit scope (foundry.toml, src/, test/, script/, lib/)
packages/sdk/     @asseteragmbh/evm-contracts — the published TypeScript SDK (generated from the contracts)
examples/         consumer apps that import the SDK (proof + living docs)
```

Point Foundry/Slither/reviewers at `contracts/`. Everything TypeScript lives under `packages/` and
`examples/`. `contracts/src/` is grouped by domain (`exchange/`, `distribution/`, `token/`, `interfaces/`,
`libraries/`).

## Frozen identifiers — never rename ⚠️

The `AsseteraECS` rename (**ADR-0041**) left three string literals that read like leftovers but are **live
on-chain state**. Renaming any of them is silent and irreversible — not a refactor. Each carries an inline
comment; this list exists so you see the hazard *before* you grep.

| Identifier | Where | Why it is frozen |
|---|---|---|
| `"AsseteraExchange"` | `contracts/src/AsseteraECS.sol` — `__EIP712_init("AsseteraExchange", "1")` | The EIP-712 domain name is baked into the deployed proxies' ERC-7201 namespaced storage. Changing it invalidates **every** KYC/fee attestation (the signer service pins the same string). |
| `"AsseteraExchange.impl"` / `"AsseteraExchange.proxy"` | `contracts/script/Deploy.s.sol` | CREATE3 **salt labels** — `DeployBase._salt()` hashes the string into the salt, so the label *determines the deployed address*. A rename misses the live proxy (`0x58c3Fb1B69ca985A5461CcEfFd0Fe590b653F213` on Amoy + Sepolia) and deploys a **second, empty venue**. |

The same class of hazard exists outside this repo: the `@subsquid/pipes` portal cursor key
`assetera-exchange-${chainId}` in **AsseteraEvmIndexerService** — renaming it silently re-indexes from
genesis. Change any of these only as a deliberate, coordinated migration.

## Git workflow

- **Never commit to `main`.** `main` is protected (no direct/force push, linear history, 1 code-owner
  review, CI green, thread-resolution) and **squash-merged** → one tidy commit per PR.
- **Branch naming — embed the Jira key** (ADR-0004 §6): ticketed work is `feat/AC-###-slug` (or
  `fix/AC-###-slug`). The Jira automation matches on the branch name (branch → In Progress · PR → In
  Test · merge → Shipped). Ticket-less chores use a `chore/…` prefix.
- Rebase on `main` before merging.

## Conventional Commits

`type(scope): summary`, scoped to the area touched. Types: `feat`, `fix`, `refactor`, `test`, `docs`,
`chore`, `ci`, `build`, `style`. Scopes in this repo:

| Scope | Area |
|---|---|
| `exchange` | `contracts/src/exchange/**` |
| `distribution` | `contracts/src/distribution/**` |
| `token` | `contracts/src/token/**` |
| `script` | `contracts/script/**` (deploy / verify / upgrade) |
| `test` | `contracts/test/**` |
| `sdk` | `packages/sdk/**` (the published package) |
| `deps` | submodule / dependency bumps |
| `ci` | `.github/workflows/**` |
| `docs` | `contracts/docs/**`, README |

e.g. `feat(exchange): add per-pair taker fee`, `fix(script): reuse existing forwarder on redeploy`,
`feat(sdk): export typed exchange events`.

## Solidity style

- **Solidity 0.8.28**, `via-IR`, optimizer 200 runs (see `contracts/foundry.toml`). Run `forge` from
  `contracts/`. Pin the same pragma in new files.
- **`forge fmt` is the formatter** — run it before committing; CI runs `forge fmt --check` as a gate.
- **`solhint` is the linter** (`.solhint.json` extends `solhint:recommended`). CI fails on solhint
  **errors**; warnings are advisory. The config relaxes a few rules that fight Foundry idioms:
  `no-console` (deploy scripts use `console2`), `func-name-mixedcase` (test `test_*` naming) and
  `import-path-check` (remapped submodule imports) are off; `gas-custom-errors` / `reason-string` /
  `var-name-mixedcase` are downgraded to warnings. Prefer custom errors over `require` strings in new code.
- Custom errors over revert strings; NatSpec on external/public functions; events for every state change
  the indexer needs (keep `contracts/docs/INDEXER_EVENT_SCHEMA.md` in sync).

## Dependencies

Contract deps are **git submodules** under `contracts/lib/`, pinned in `contracts/foundry.lock`
(forge-std, OpenZeppelin contracts + contracts-upgradeable). `lib/` is intentionally **not** git-ignored
so a fresh clone and CI build deterministically. Add/bump with `forge install <org/repo>@<tag>` (run from
`contracts/`) and commit the updated `.gitmodules` + `foundry.lock` + gitlink. Dependabot proposes
submodule bumps weekly. TypeScript deps are managed by npm workspaces from the repo root.

### Dependency-bump policy (upgradeable contracts)

The exchange is a **UUPS upgradeable proxy**, so a dependency bump is an upgrade-safety question, not just
a version number. Rules:

- **Never blind-merge a submodule bump.** Dependabot's `gitsubmodule` ecosystem tracks each submodule's
  default-branch HEAD, so it can propose **non-stable commits (RCs / master)** — check the bump lands on a
  real, stable release tag; if not, re-pin to the latest stable tag instead of merging the proposed commit.
- **OZ moves as a pair.** `openzeppelin-contracts` and `openzeppelin-contracts-upgradeable` must always be
  the **same version** (Dependabot groups them into one PR; keep it that way).
- **Freeze deps during an external audit** — auditors sign off on a pinned set.
- **The safety net:** `contracts/script/storage-layout.sh` (a committed storage-layout snapshot, checked in
  CI) plus `test_Upgrade_PreservesAllStorageAcrossEverySlot` make an OZ bump an *evidenced* decision. OZ v5
  bases use ERC-7201 namespaced storage, so a clean minor bump yields a **zero-line** layout diff — any diff
  on a dep bump is a red flag. After an *intended* storage change, re-baseline with
  `bash script/storage-layout.sh write`.

## CI

`.github/workflows/ci.yml` runs on every PR: `forge fmt --check` → `solhint` → `forge build` →
**storage-layout guard** (`script/storage-layout.sh`) → `forge test` (in `contracts/`, via the job's
`working-directory`). The **`build`** job is the required status check wired into branch protection. Keep
it green.
