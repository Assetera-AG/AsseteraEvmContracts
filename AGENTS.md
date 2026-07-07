# AGENTS.md — AsseteraEvmContracts

Local conventions for this repo. Cross-repo rules live in the workspace `CLAUDE.md`; engineering
workflow is **ADR-0004** and github-config-as-code is **ADR-0013** (AsseteraADRs repo). The deploy
pipeline + published SDK design is **ADR-0026**.

## Layout (npm-workspaces monorepo)

```
contracts/        self-contained Foundry project — the audit scope (foundry.toml, src/, test/, script/, lib/)
packages/sdk/     @asseteragmbh/evm-contracts — the published TypeScript SDK (generated from the contracts)
examples/         consumer apps that import the SDK (proof + living docs)
```

Point Foundry/Slither/reviewers at `contracts/`. Everything TypeScript lives under `packages/` and
`examples/`. `contracts/src/` is grouped by domain (`exchange/`, `distribution/`, `token/`, `interfaces/`,
`libraries/`).

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

## CI

`.github/workflows/ci.yml` runs on every PR: `forge fmt --check` → `solhint` → `forge build` →
`forge test` (in `contracts/`, via the job's `working-directory`). The **`build`** job is the required
status check wired into branch protection. Keep it green.
