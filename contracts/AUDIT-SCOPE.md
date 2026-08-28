# Assetera EVM Contracts — Audit Scope & Handover (COMBINED)

This is the entry point for an external security review of the Assetera on-chain venue. It is the
**umbrella** document: it defines the two surfaces, the shared toolchain, the shared trust model and the
shared assumptions, and it points at one document per surface for the file tables and the surface-specific
economics.

| Document | Surface | Files | LoC | Tests |
|---|---|---:|---:|---:|
| [`AUDIT-SCOPE-SECONDARY.md`](AUDIT-SCOPE-SECONDARY.md) | **`AsseteraECS`** — the secondary market: order book, offer book, escrow | 15 | 2,124 | 257 |
| [`AUDIT-SCOPE-PRIMARY.md`](AUDIT-SCOPE-PRIMARY.md) | **`AsseteraPrimarySales`** — the primary settlement router | 9 | 1,976 | 200 |
| **This document** | Both, combined | **24** | **4,100** | **457** |

The engagement can be quoted and run **per surface or as a whole**. The two per-surface documents are each
self-contained: an auditor handed only one of them has everything they need for that surface, including the
shared material repeated in place.

> ⚠️ **If you are working from a copy of this document dated before 2026-08-19, it declared 15 files and
> 2,105 LoC.** That covered the exchange only, was last refreshed in the gate-extraction commit
> `ebaa608` (AO-514, PR #57), and was never updated when the primary settlement contract landed
> immediately afterwards (AO-560, PR #58). The real production surface is roughly twice that. Every figure
> in the current set of documents was re-measured from the working tree.

## The two contracts, and why they are two

`AsseteraECS` and `AsseteraPrimarySales` are **separate proxies**, not modules of one contract:

- separate storage, so a primary-sales bug cannot reach the exchange's open-order escrow;
- separate pause levers and separate upgrade cadence;
- separate EIP-712 domains (`"AsseteraExchange"` and `"AsseteraPrimarySales"`), so an attestation minted
  for one recovers to a different address on the other and is rejected — cross-contract replay is
  impossible by construction rather than by check;
- separate role grants, and the router has one role the exchange does not (`SETTLEMENT_OPERATOR_ROLE`);
- and it simply would not fit: `AsseteraECS` has under 2 kB of EIP-170 margin left.

They do share code. `AsseteraPrimarySales` inherits the exchange's gate stack and calls its fee library:

```
GateTypes ─────────────────┬─ ExchangeTypes ─ ExchangeStorage ─ … ─ AsseteraECS
                           └─ PrimaryTypes ──┐
GateStorage ─ KycGate ─ FeeGate ─────────────┴─ PrimaryStorage ─ IntentGate
                                                ─ SettlementLimits ─ VenueSettler
                                                ─ AsseteraPrimarySales
```

**Five files are in both deployed bytecodes** — `src/types/GateTypes.sol`, `src/gates/GateStorage.sol`,
`src/gates/KycGate.sol`, `src/gates/FeeGate.sol` and `src/libs/FeeMath.sol`, 432 LoC together. They are
enumerated in the secondary document because that is where they were written. **A finding in any of them
lands on both proxies**, and a per-surface engagement should say so explicitly in the finding.

## Audit target (frozen commit)

Please audit a **single frozen commit**. We tag a dedicated release for the engagement (e.g. `audit-v1`);
confirm the exact commit hash with us before starting rather than tracking a moving branch. `main` is
protected, linear-history and squash-merged, so the tag is stable.

Every figure in these three documents was reproduced from the working tree with the commands shown.
Re-measure if you are handed a different commit.

## Scope at a glance

```bash
cd contracts
find src -name '*.sol' | xargs wc -l                        # 24 files, 4,100 total
find src -name '*.sol' -not -path 'src/primary/*' | xargs wc -l   # secondary: 15 files, 2,124
find src/primary -name '*.sol' | xargs wc -l                # primary:   9 files, 1,976
```

Per-file tables with a one-line role each are in the two surface documents. LoC is raw `wc -l`, including
licence header, NatSpec and blank lines. NatSpec is a large share of the primary surface: its design
rationale lives in the files rather than in a separate specification.

## Out of scope (both surfaces)

| Path | Why |
|---|---|
| `test/**`, `test/primary/**` — unit tests, the `test/invariants/` escrow-conservation suite, and all mocks | Tests and mocks. `test/mocks/FaucetToken.sol` is an **open-mint testnet faucet**, deployed only on Amoy / Sepolia / local anvil — never mainnet (see the mainnet section). Not part of the production surface. |
| `script/**` (`Deploy.s.sol`, `DeployBase.sol`, `DeploymentFile.sol`, `Verify.s.sol`, `UpgradeCalldata.s.sol`, `AdminCalldata.s.sol`, `storage-layout.sh`, `struct-layout.py`) | Deployment / verification / upgrade-safety tooling, not deployed bytecode. Reviewing the deploy story is welcome but it is not the contract under custody. |
| `docs/parked/OperatorFunctions.sol` | **Parked, not compiled, not deployed.** A commented reference implementation of `settle`/`refund` (`OPERATOR_ROLE`), kept outside `src/` so it is not on the attack surface. See `docs/FUNCTIONAL_SPEC.md §11` for the re-enable path. |
| The per-token **sale contract** fronting our own primary issuance | **AO-137, outside this repository and not yet built.** To the router it is an address in a signed intent. See [`AUDIT-SCOPE-PRIMARY.md`](AUDIT-SCOPE-PRIMARY.md). |
| `lib/**` | Pinned dependencies (below). |
| `packages/sdk/**`, `examples/**` | TypeScript SDK and consumer examples (in the monorepo, not the Foundry project). |

## Documentation map

| Document | Covers |
|---|---|
| [`docs/FUNCTIONAL_SPEC.md`](docs/FUNCTIONAL_SPEC.md) | The **exchange only**. It does not mention primary sales. |
| [`docs/INDEXER_EVENT_SCHEMA.md`](docs/INDEXER_EVENT_SCHEMA.md) | **Both** surfaces, including `PrimarySettled` and `IntentConsumed`. |
| [`docs/SECURITY-REVIEW-2026-07-14.md`](docs/SECURITY-REVIEW-2026-07-14.md) | The **exchange only**, at 14 files / ~1,680 LoC. Predates the AC-833 fee rework **and** the primary contract. Known findings M-1, L-1…L-3, I-1…I-4. Where it and these documents disagree, these documents and the code are current. |

🔴 **There is no security review of the primary surface, internal or external.** We looked: `contracts/docs/`
holds exactly one review, its header scopes it to AsseteraECS, and grepping it for `primary`, `VenueSettler`
or `IntentGate` returns no match referring to that contract. The known-findings register that exists for the
exchange has **no counterpart** for primary sales. See [`AUDIT-SCOPE-PRIMARY.md`](AUDIT-SCOPE-PRIMARY.md).

## Build & test

```bash
cd contracts
forge build                                     # Solidity 0.8.28, via-IR, optimizer 200 runs — clean
forge test                                      # 457 tests across 40 suites, 0 failures
forge test --no-match-path 'test/primary/*'     # secondary only: 257 tests across 9 suites
forge test --match-path 'test/primary/*'        # primary only:   200 tests across 31 suites
forge coverage --ir-minimum --no-match-coverage '(script|test)'
bash script/storage-layout.sh                   # upgrade-safety guard, both proxies
slither .                                       # 57 contracts, 101 detectors, 43 results
```

**`forge test` on this commit: 457 passed, 0 failed, 0 skipped, across 40 suites.**

> ⚠️ **The figure 129 appears in `docs/SECURITY-REVIEW-2026-07-14.md` and in older copies of this
> document. It is stale by two major workstreams.** Use your own measurement.

`--ir-minimum` on `forge coverage` is **required** — plain `forge coverage` disables the optimizer and
via-IR and fails "stack too deep" in `OfferBook.replaceOffer`.

**Coverage totals across both surfaces:**

| | % Lines | % Statements | % Branches | % Funcs |
|---|---:|---:|---:|---:|
| Secondary (`AsseteraECS`) | 97.34 (366/376) | 97.67 (503/515) | 98.06 (101/103) | 97.96 (48/49) |
| Primary (`AsseteraPrimarySales`) | 92.95 (145/156) | 93.98 (203/216) | 94.59 (35/37) | 96.77 (30/31) |
| **Total** | **96.05 (511/532)** | **96.58 (706/731)** | **97.14 (136/140)** | **97.50 (78/80)** |

Per-file tables and an honest reading of the residue are in the two surface documents. The weakest figure
in the repository is **branch coverage on `src/primary/settle/VenueSettler.sol`, 81.82 % (9/11)** — on the
file that moves the money.

`forge build` is clean; the only lint output is `block-timestamp` warnings on expiry and TTL comparisons
(benign — see the Slither triage).

## Upgrade-safety guard (`script/storage-layout.sh`)

A committed snapshot of each proxy's storage layout is diffed in CI on every PR: `storage/AsseteraECS.txt`
and `storage/AsseteraPrimarySales.txt`. On this commit the script exits 0 and prints:

```
✅ AsseteraECS storage layout unchanged
✅ AsseteraPrimarySales storage layout unchanged
```

Because the OZ v5 upgradeable bases use ERC-7201 namespaced storage, a clean minor dependency bump produces
a **zero-line diff** — any diff on a dep bump is a red flag. Paired with
`test_Upgrade_PreservesAllStorageAcrossEverySlot`.

Each snapshot has two halves: the top-level `forge inspect … storage-layout` table, **plus** (added in
AC-833, via `script/struct-layout.py`) the **per-struct member layout**. That second half closes a real
blind spot — `_orders` / `_offers` are mappings, so the top-level table records one slot each and says
nothing about the struct behind it. Appending to a struct held in a mapping is upgrade-safe; **reordering
or retyping** a member is not, and the old guard could not tell those apart.

Two asymmetries an auditor should know:

- `DeployBase.INPLACE_UPGRADE_ALLOWED` is `false` on this commit. It records the exchange's AO-514 layout
  break and makes both `Deploy.s.sol` and `UpgradeCalldata.s.sol` refuse an in-place exchange upgrade. It
  is a compile-time constant rather than an env flag because whether an implementation is installable is a
  property of the source tree, not of whoever runs the script.
- It deliberately does **not** gate the primary proxy, which `Deploy.s.sol` will `upgradeToAndCall` in
  place whenever the implementation bytecode differs. Nor does `AsseteraPrimarySales.*` have a salt
  version of its own. Both notes in `DeployBase.sol` say "give it one at the first storage-layout break
  after it is live" — and it **is** live on two testnets now, so that follow-up is outstanding.

## Toolchain & compiler settings (`foundry.toml`)

| Setting | Value |
|---|---|
| `solc` | `0.8.28` |
| `optimizer` / `optimizer_runs` | on / `200` |
| `via_ir` | `true` |
| `bytecode_hash` | `none` (deterministic bytecode) |
| `[fuzz] runs` | `256` (CI profile: `5000`) |
| `[invariant] runs` / `depth` | `64` / `50`, `fail_on_revert = false` |
| `forge` | `1.6.0-v1.7.0` (`f83bad9`) |

## Dependencies (pinned git submodules under `lib/`)

| Dependency | Version | Gitlink |
|---|---|---|
| `openzeppelin-contracts` | v5.1.0 | `69c8def5f222ff96f2b5beff05dfba996368aa79` |
| `openzeppelin-contracts-upgradeable` | v5.1.0 | `fa525310e45f91eb20a6d3baa2644be8e0adba31` |
| `forge-std` | v1.16.2 | `bf647bd6046f2f7da30d0c2bf435e5c76a780c1b` |
| `createx-forge` | (deploy tooling only, out of scope) | `cef15824154b2a7117bdac60870466b185fba684` |

Reproduce with `git submodule status contracts/lib/*`. `contracts/foundry.lock` records the same four revs
(an older note in this document said the lock disagreed with the gitlink on `forge-std`; it no longer
does). `forge-std` is a test-only dependency and is not linked into deployed bytecode. Dependencies are
**frozen for the duration of an external audit**.

## 🔴 Token limitations, and the one place the two contracts disagree

**The policy is the same on both surfaces: standard ERC-20 only. No fee-on-transfer, no rebasing, no
deflationary or elastic supply.** What differs is *how* that policy is enforced, and it differs completely.
This is the first thing an auditor will ask about, so it is stated here rather than left to be discovered.

| | Secondary (`AsseteraECS`) | Primary (`AsseteraPrimarySales`) |
|---|---|---|
| Balance-delta accounting | **None.** There is no `balanceOf` measurement anywhere in `src/core/OrderBook.sol` or `src/core/OfferBook.sol` — confirmed on this commit by `grep -rn 'balanceOf' src/core src/gates src/admin src/AsseteraECS.sol src/storage src/libs`, which returns nothing | **Yes.** `VenueSettler` snapshots its own balances and the buyer's asset balance, and measures deltas across the venue call |
| Fee-on-transfer settlement token | **Not detected.** Escrow is overstated and the pool can go insolvent — exchange finding **M-1** | **Refused on-chain.** `SettlementPullMismatch(requested, received)` if the pull delivers anything other than the exact amount |
| Enforcement of the policy | **Off-chain only** — token addresses are bound into the signed `paramsHash`, so the backend token allowlist gates what can enter escrow. No on-chain tradable-token allowlist | On-chain for the currency leg; the zero-standing-balance assertion covers the asset leg |
| Freezable / blacklistable (USDC) | **Supported but hazardous** — escrow can be stranded (finding L-1) | **Supported but hazardous** |

**Why they differ: history, not a considered symmetry.** The exchange shipped first and finding M-1 was
formally **accepted on 2026-07-15 as documentation-only** — recommendation #3, balance-delta accounting,
was explicitly declined, on the reasoning that standard ERC-20 semantics are a downstream
legal/compliance/risk control rather than an engineering fix. The primary settler was written afterwards,
and **both** its settlement-leg measurement and its asset-side zero-standing-balance assertion were added
on review of PR #58 — the first version measured only the asset leg and failed *dirty*, settling while
misreporting on a fee-on-transfer currency.

**The exchange's weird-token tests document the insolvency rather than prevent it.** Named here so nothing
looks hidden — all four are in `test/AsseteraECS.t.sol` and all four **pass**, by asserting the bad outcome
happens:

- `test_TokenSafety_FeeOnTransfer_EscrowOverstatedAtPlacement`
- `test_TokenSafety_FeeOnTransfer_PoolInsolvency_LastCancellerReverts`
- `test_TokenSafety_Rebasing_NegativeRebaseCausesInsolvency`
- `test_TokenSafety_FeeOnTransfer_AcceptOfferShortfall`

⚠️ **Production settlement will be real USDC on Polygon mainnet, which is neither fee-on-transfer nor
rebasing but is freezable and blacklistable.** So the M-1 assumption is one we hold off-chain, and L-1 is a
live operational risk on the exact token we intend to settle in.

**Whether the exchange should be brought in line with the router is a legitimate question for this
engagement, and we would like an answer to it.**

## Static analysis (Slither)

Config: [`slither.config.json`](slither.config.json) (filters `lib/`, `test/`, `script/`). Run: `slither .`
from `contracts/`. Current result: **57 contracts, 101 detectors, 43 results — all triaged benign.**

| Detector | Total | Secondary | Primary |
|---|---:|---:|---:|
| `timestamp` | 11 | 10 | 1 |
| `naming-convention` | 9 | 8 | 1 |
| `arbitrary-send-erc20` | 5 | 4 | 1 |
| `reentrancy-balance` | 4 | 0 | 4 |
| `cyclomatic-complexity` | 3 | 1 | 2 |
| `dead-code` | 3 | 2 | 1 |
| `low-level-calls` | 3 | 0 | 3 |
| `assembly` | 2 | 1 | 1 |
| `reentrancy-benign` | 1 | 1 | 0 |
| `reentrancy-events` | 1 | 0 | 1 |
| `uninitialized-local` | 1 | 1 | 0 |
| **Total** | **43** | **28** | **15** |

Per-result triage with verdicts is in the two surface documents. The one worth naming here: the four
`reentrancy-balance` hits on `VenueSettler._settleVenue` are the detector correctly pointing at the
contract's actual technique — measuring balances across an untrusted call is the whole design, the
snapshots are *supposed* to predate it, and the call is wrapped by `nonReentrant` with the intent nonce
already burned. It is the single most useful thing to review on the primary surface.

No high- or medium-severity true positives. (Exchange finding I-4 recommended committing a
`slither.db.json` triage file; that remains **deferred** — Slither is not currently a CI gate, so these
tables are the triage of record.)

## Trust model & centralization (by design — regulated venue)

Order and offer **matching happens off-chain**; the chain enforces settlement, escrow, attestation and
fees. Identity is resolved through `_msgSender()` (ERC-2771) on both proxies, sharing one trusted forwarder
address, so a relayer may submit gasless meta-transactions.

Roles are **separate grants per proxy** — same identifiers, different `AccessControl` storage. The
`allowedCollectors` allowlist likewise does not carry over: the primary router's starts empty.

| Role | Exchange | Primary router | Blast radius if compromised |
|---|:--:|:--:|---|
| `DEFAULT_ADMIN_ROLE` | ✅ | ✅ | Effectively full custody: `upgradeToAndCall` to arbitrary logic; on the exchange, force-cancel and route any escrow; on the router, the settlement caps, collector allowlist, compliance exemptions, pause and `whitelistHandshake` |
| `KYC_OPERATOR_ROLE` | ✅ | ✅ | Can authorise trade or settlement actions. Cannot move existing escrow beyond normal trading and **cannot set or redirect fees** |
| `FEE_OPERATOR_ROLE` | ✅ | ✅ | Bounded by `MAX_FEE_BPS` (10 000) and the collector allowlist. On the exchange it also **selects the settlement currency** (see the AC-833 notes in the secondary document); on the router the fee terms are additionally cross-checked against the buyer-signed intent |
| `SETTLEMENT_OPERATOR_ROLE` | — | ✅ | **The only role whose holder can cause a transfer.** Give it its own key. Bounded by the buyer's own signature over the intent, the buyer's exact per-transaction allowance, the per-token settlement cap, and the `_assertBuyerFee` cross-check |

This centralization is intentional and mandated by the regulatory model.

## Mainnet target

Production is **Polygon mainnet, chain id 137**. Neither proxy is deployed there yet: the SDK carries
deployment records for `80002` (Polygon Amoy) and `11155111` (Ethereum Sepolia) only
(`packages/sdk/src/deployments/`). Both contracts are live on both of those testnets.

The open-mint faucet tokens (`MockUSDC` / `MockRWA`, i.e. `test/mocks/FaucetToken.sol`) are **excluded from
a mainnet deploy by default, but not by construction.** `DeployBase._isTestnet`
(`script/DeployBase.sol:136-138`) returns true only for `31337` (local anvil), `80002` and `11155111`, so on
chain 137 the default is `false` and the faucet is not deployed. However `Deploy.s.sol:69` reads
`vm.envOr("DEPLOY_MOCKS", _isTestnet(chainId))`, so an environment variable can override that default and
force an open-mint token onto mainnet.

⚠️ **The comment above that line in `Deploy.s.sol` claims a mainnet deploy "can never publish a
permissionless-mint token". That claim is false as written**, and is flagged here rather than silently
corrected because this document describes the frozen commit. The deploy wrapper `scripts/deploy.sh` refuses
a mainnet broadcast with `DEPLOY_MOCKS` forced on, but that is tooling and tooling is out of scope, so on
the contract surface alone this remains an operator-discipline control rather than an enforced one.

## Known assumptions & findings

The exchange's register (M-1, L-1…L-3, I-1…I-4) is in
[`docs/SECURITY-REVIEW-2026-07-14.md`](docs/SECURITY-REVIEW-2026-07-14.md) and re-read against current code
in [`AUDIT-SCOPE-SECONDARY.md`](AUDIT-SCOPE-SECONDARY.md). The primary surface has **no register**, because
it has had no review; its known open items are listed in
[`AUDIT-SCOPE-PRIMARY.md`](AUDIT-SCOPE-PRIMARY.md).

Two items apply to **both** proxies and are therefore recorded here:

1. **Standard-ERC-20-only (exchange finding M-1). Status: accepted 2026-07-15, documentation only.** See
   the token-limitations section above, including the divergence in how the two contracts enforce it.
2. **Centralized signer and upgrade authority (exchange finding L-3). Status: OPEN, accepted as an
   operational item, not a code defect.** There is **no `TimelockController` anywhere in this repository**
   — verified on this commit by grep over `src/`, `script/` and `test/` — and `DEFAULT_ADMIN_ROLE` on each
   proxy is simply whatever address is passed to that proxy's `initialize`. The July review recorded this
   as design-inherent centralization required by the regulated venue model and deferred an on-chain
   timelock as a separate, larger-scoped change requiring its own design and test coverage. The mainnet
   readiness checklist (Safe multisig admin, upgrade timelock, dedicated well-managed keys per signer role,
   optional splitting of the collector-allowlist admin from the upgrade admin) is in
   `FUNCTIONAL_SPEC.md §2`. It applies to the primary router too, which additionally holds
   `SETTLEMENT_OPERATOR_ROLE`.

## Contact

Code owner: `@tomw1808` (see `CODEOWNERS`). Please route questions and preliminary findings through the
agreed engagement channel.
