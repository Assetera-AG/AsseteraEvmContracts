# Releasing `@asseteragmbh/evm-contracts`

Releases are driven by **release-please + npm OIDC trusted publishing** (ADR-0007 / ADR-0016 / ADR-0026 D7) —
Conventional Commits → a release PR → tag → publish, with **no stored npm token**. See
[`.github/workflows/release-please.yml`](.github/workflows/release-please.yml).

## Steady state (after bootstrap)

1. Land `feat:` / `fix:` commits on `main` (SDK scope: `packages/sdk/**`).
2. release-please opens/updates a **release PR** (version bump + `CHANGELOG.md`). Review + merge it.
3. Merging tags the release; the `publish` job builds and `npm publish`es via OIDC. Nothing to configure.

## One-time bootstrap ⚠️

npm cannot configure a trusted publisher until the package **exists**, so the first version is published
manually (npm CLI ≥ 11.5.1, Node ≥ 22.14):

```bash
npm login                       # as an @asseteragmbh org owner
npm ci
npm run build -w @asseteragmbh/evm-contracts   # needs Foundry (codegen runs forge build)
npm publish -w @asseteragmbh/evm-contracts     # publishes 0.1.0, access = restricted (publishConfig)
```

Then on npmjs.com → **`@asseteragmbh/evm-contracts` → Settings → Trusted Publisher → GitHub Actions**, set:

- **Repository:** `Assetera-AG/AsseteraEvmContracts`
- **Workflow:** `release-please.yml`
- **Environment:** _(leave blank — the workflow uses none)_

After that, delete any local publish token; all future releases go through the workflow, token-free.

> **Visibility:** `publishConfig.access` is `restricted` (private, ADR-0007 default). The `@asseteragmbh`
> org is on a paid npm plan, so we keep it private **while the contracts are still churning** — no pre-launch
> interface exposure. **Flip to `public` at launch** once the contracts are finalized (a one-line
> `publishConfig` change), like `@asseteragmbh/metakyc`. Either way the package ships only compiled SDK +
> ABIs + addresses — **no Solidity source**.
>
> **Provenance:** the workflow now publishes with `--provenance`. The original rationale for omitting it
> (ADR-0016 D4 — "while the repo is private") no longer applies: `Assetera-AG/AsseteraEvmContracts` is
> **public**. Two things are worth knowing:
>
> - Under **trusted publishing**, npm generates provenance **automatically** — the flag is belt-and-braces,
>   not the thing that turns it on. npm: _"When you publish using trusted publishing from GitHub Actions or
>   GitLab CI/CD, npm automatically generates and publishes provenance attestations for your package. This
>   happens by default—you don't need to add the `--provenance` flag."_
> - That automatic generation applies only when the repo **and the package** are public. Ours is still
>   `access: restricted`, so provenance is expected to be skipped — and passing `--provenance` explicitly
>   may make npm **fail** the publish rather than skip it: _"Can't generate provenance for new or private
>   package, you must set `access` to public."_
>
> **So the remaining blocker is package access, not repo visibility.** Provenance starts working for real
> when `publishConfig.access` flips to `public` at launch (see *Visibility* above) — a maintainer decision,
> not something to force here by adding `--access public` to the publish step. If a release job fails on
> the provenance step, the revert is one line: drop `--provenance` from
> [`.github/workflows/release-please.yml`](.github/workflows/release-please.yml).
>
> The other prerequisites are already met by the workflow: `permissions: id-token: write` on the `publish`
> job, npm ≥ 11.5.1 (`npm install -g npm@latest`), Node ≥ 22.14 (`node-version: 24`), cloud-hosted runner.
>
> **Addresses:** the package ships whatever real-network deployment JSON is committed under
> `packages/sdk/src/deployments/` — deploy to a network and commit its `<chainId>.json` before releasing so
> consumers get populated addresses. Local `31337` is git-ignored and never published.
