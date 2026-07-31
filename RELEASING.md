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
npm publish -w @asseteragmbh/evm-contracts     # publishes 0.1.0; access comes from publishConfig (now public)
```

Then on npmjs.com → **`@asseteragmbh/evm-contracts` → Settings → Trusted Publisher → GitHub Actions**, set:

- **Repository:** `Assetera-AG/AsseteraEvmContracts`
- **Workflow:** `release-please.yml`
- **Environment:** _(leave blank — the workflow uses none)_

After that, delete any local publish token; all future releases go through the workflow, token-free.

> **Visibility:** `publishConfig.access` is **`public`**, and the package is public on npmjs — the flip from
> the `restricted` default (ADR-0007) happened once the contracts stabilised and the repo went public, the
> same posture as `@asseteragmbh/metakyc`. It ships only the compiled SDK + ABIs + addresses — **no Solidity
> source** (`files: ["dist"]`). Anyone can now `npm install @asseteragmbh/evm-contracts` without credentials;
> consumers no longer need the Key Vault read token for this package.
>
> Note the two settings are independent and both matter: `publishConfig.access` governs **future** publishes,
> while the visibility of **already-published** versions is a registry-side setting (npmjs package settings,
> or `npm access set status=public`). Changing access applies retroactively to every published version.
>
> **Provenance:** the workflow publishes with `--provenance`. The original rationale for omitting it
> (ADR-0016 D4 — "while the repo is private") no longer applies, and neither does the package-access blocker:
>
> - npm requires **both** the repo and the package to be public. Both now are.
> - Under **trusted publishing**, npm generates provenance **automatically** — the flag does not turn it on.
>   npm: _"When you publish using trusted publishing from GitHub Actions or GitLab CI/CD, npm automatically
>   generates and publishes provenance attestations for your package. This happens by default—you don't need
>   to add the `--provenance` flag."_ We pass it explicitly anyway so the intent is visible in the run log and
>   so a regression in either precondition **fails loudly** instead of silently dropping the attestation.
>
> If a release ever fails on the provenance step, check package access first (`npm access get status
> @asseteragmbh/evm-contracts`); the fallback is a one-line revert dropping `--provenance` from
> [`.github/workflows/release-please.yml`](.github/workflows/release-please.yml).
>
> The other prerequisites are already met by the workflow: `permissions: id-token: write` on the `publish`
> job, npm ≥ 11.5.1 (`npm install -g npm@latest`), Node ≥ 22.14 (`node-version: 24`), cloud-hosted runner.
>
> **Addresses:** the package ships whatever real-network deployment JSON is committed under
> `packages/sdk/src/deployments/` — deploy to a network and commit its `<chainId>.json` before releasing so
> consumers get populated addresses. Local `31337` is git-ignored and never published.
