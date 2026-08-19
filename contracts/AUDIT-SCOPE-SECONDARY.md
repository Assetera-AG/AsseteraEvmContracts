# AsseteraECS — Audit Scope & Handover (SECONDARY MARKET / EXCHANGE)

This document scopes an external security review of **`AsseteraECS`** — the secondary market: the
order book, the offer book and the escrow behind them. It is one of **two** contract surfaces in this
repository and can be audited on its own.

- The other surface is the **primary settlement router** (`AsseteraPrimarySales`), scoped in
  [`AUDIT-SCOPE-PRIMARY.md`](AUDIT-SCOPE-PRIMARY.md). It is a **separate proxy** with separate storage,
  a separate pause lever and a separate EIP-712 domain. It is **not** covered here.
- Shared context that applies to both surfaces — toolchain, pinned dependencies, build and test
  commands, the upgrade-safety guard, the trust model, the mainnet target and the contact route — is in
  the umbrella document [`AUDIT-SCOPE.md`](AUDIT-SCOPE.md). Everything an auditor needs for *this*
  surface is repeated here so the document stands alone.

Facts:

- **Project:** AsseteraECS (**E**xecution, **C**learing & **S**ettlement — formerly `AsseteraExchange`,
  renamed under AC-836) — the on-chain venue for a regulated real-world-asset (RWA) marketplace (MiFID).
- **Foundry root:** `contracts/` (point `forge`, `slither` and coverage here).
- **Functional specification:** [`docs/FUNCTIONAL_SPEC.md`](docs/FUNCTIONAL_SPEC.md). It documents this
  surface only.
- **Event schema (for indexers):** [`docs/INDEXER_EVENT_SCHEMA.md`](docs/INDEXER_EVENT_SCHEMA.md).
- **Internal pre-audit review:** [`docs/SECURITY-REVIEW-2026-07-14.md`](docs/SECURITY-REVIEW-2026-07-14.md)
  — read this for the known findings (M-1, L-1…L-3, I-1…I-4) we have already triaged. It reviewed this
  surface at 14 files / ~1,680 LoC and **predates both the AC-833 fee rework and the primary-sales
  contract**; where it and this document disagree, this document and the code are current.

> **Naming.** The contract, its file and its interface are `AsseteraECS` / `AsseteraECS.sol` /
> `IAsseteraECS.sol`. The **EIP-712 domain string is deliberately left as `"AsseteraExchange"`**
> (`AsseteraECS.sol`, in `initialize` → `__EIP712_init("AsseteraExchange", "1")`). Changing it would change
> the domain separator and invalidate every in-flight KYC and fee attestation; and because OZ v5
> `EIP712Upgradeable` stores the name in ERC-7201 namespaced storage written only by the `onlyInitializing`
> `__EIP712_init`, an implementation upgrade could not change it on a live proxy anyway. The mismatch
> between the contract name and the domain name is **intentional**, not an oversight. The generic module
> names (`OrderBook`, `OfferBook`, `ExchangeTypes`, `ExchangeStorage`, `ExchangeAdmin`, `KycGate`,
> `FeeGate`) are unchanged — "exchange" is an accurate common noun for the venue.
>
> The primary-sales router uses a **different** domain string, `"AsseteraPrimarySales"`, so an attestation
> minted for one contract recovers to a different address on the other and is rejected. Cross-contract
> attestation replay between the two surfaces is impossible by construction rather than by check.

## Audit target (frozen commit)

Please audit a **single frozen commit**. We tag a dedicated release for the engagement (e.g. `audit-v1`);
confirm the exact commit hash with us before starting rather than tracking a moving branch. `main` is
protected, linear-history and squash-merged, so the tag is stable.

Every figure below was reproduced from this worktree with the commands shown. Re-measure if you are handed
a different commit.

## In scope

The secondary-market surface under `contracts/src/`, i.e. everything except `src/primary/` —
**15 files, 2,124 LoC**:

```bash
find src -name '*.sol' -not -path 'src/primary/*' | xargs wc -l
```

| File | LoC | Role |
|---|---:|---|
| `src/AsseteraECS.sol` | 164 | UUPS proxy entrypoint; assembles the modules; `initialize`; `version()` (`4.0.0`); the exchange's `_paramsHashAllowed` action policy |
| `src/core/OrderBook.sol` | 391 | Order lifecycle: place / cancel / fill / sweep; pooled escrow + escrowed maker fee |
| `src/core/OfferBook.sol` | 403 | Offer lifecycle: make / replace / accept (atomic settle) / cancel / sweep |
| `src/core/PermitRelay.sol` | 116 | `permitAndCall`: ERC-2612 permit + one self-`delegatecall`, so approve-then-trade is one transaction (AO-298) |
| `src/gates/KycGate.sol` | 75 | EIP-712 KYC attestation verification + nonce burn |
| `src/gates/FeeGate.sol` | 141 | EIP-712 fee attestation verification + fee bounds / denomination / collector allowlist |
| `src/gates/GateStorage.sol` | 130 | Gate state in ERC-7201 namespaced storage (`assetera.storage.Gate`) + the OZ bases the gates need (AO-514) |
| `src/admin/ExchangeAdmin.sol` | 118 | Admin surface: pause, compliance toggles, collector allowlist, force-cancel |
| `src/storage/ExchangeStorage.sol` | 61 | Order-book storage base behind `__gap` |
| `src/types/ExchangeTypes.sol` | 119 | Order/Offer structs, enums (`Action`, statuses) |
| `src/types/GateTypes.sol` | 63 | The two EIP-712 attestation structs, gate-side so a non-order-book venue can use them (AO-514) |
| `src/libs/FeeMath.sol` | 23 | Fee arithmetic (floor division) + ceiling division |
| `src/interfaces/IAsseteraECS.sol` | 268 | External interface |
| `src/interfaces/IKycGate.sol` | 25 | Interface |
| `src/interfaces/IFeeGate.sol` | 27 | Interface |

LoC is raw `wc -l` (including licence header, NatSpec and blank lines) on the frozen commit. The AC-836
rename is comment- and identifier-level only; it does not change bytecode (see the naming note above).

### ⚠️ Five of these files are also compiled into the primary-sales proxy

`GateTypes.sol`, `GateStorage.sol`, `KycGate.sol`, `FeeGate.sol` and `FeeMath.sol` are **shared**. They are
listed here because they were written for this surface, but `AsseteraPrimarySales` inherits the whole gate
stack (`PrimaryStorage is PrimaryTypes, FeeGate, …`, and `PrimaryTypes is GateTypes`) and calls
`FeeMath.feeAmount` for its own fee.

Two consequences for an engagement scoped to this document only:

1. A change you recommend in any of those five files lands on **both** deployed proxies. Say so in the
   finding.
2. `FeeGate._validateFees` is the one place fee policy is expressed for the whole estate. The primary
   router calls it with the settlement token in **both** leg positions, which collapses the leg test into
   a strict "the fee must be denominated in the settlement currency" rule. A tightening here therefore
   also tightens the primary path, which is the intent.

## Out of scope

| Path | Why |
|---|---|
| `src/primary/**` (9 files, 1,976 LoC) | The **other** audit surface. A separate proxy with its own storage namespace, pause lever and EIP-712 domain. Scoped in [`AUDIT-SCOPE-PRIMARY.md`](AUDIT-SCOPE-PRIMARY.md); audit it under that document, not this one. |
| `test/**` — unit tests, the `test/invariants/` escrow-conservation suite, and mocks (`test/mocks/FaucetToken.sol`, `ReentrantToken.sol`, `FeeOnTransferToken.sol`, `RebasingToken.sol`, `DivergentDomainToken.sol`, `AsseteraECSV2.sol`, `GateOnlyVenue.sol`, `DinariLikeVenue.sol`) | Tests and mocks. `FaucetToken` is an **open-mint testnet faucet**, deployed only on Amoy / Sepolia / local anvil — never mainnet (see the mainnet note below). Not part of the production surface. |
| `test/primary/**` | Tests for the other surface. |
| `script/**` (`Deploy.s.sol`, `DeployBase.sol`, `DeploymentFile.sol`, `Verify.s.sol`, `UpgradeCalldata.s.sol`, `AdminCalldata.s.sol`, `storage-layout.sh`, `struct-layout.py`) | Deployment / verification / upgrade-safety tooling, not deployed bytecode. Reviewing the deploy story is welcome but it is not the contract under custody. |
| `docs/parked/OperatorFunctions.sol` | **Parked, not compiled, not deployed.** A commented reference implementation of `settle`/`refund` (`OPERATOR_ROLE`), kept outside `src/` so it is not on the attack surface. See `docs/FUNCTIONAL_SPEC.md §11` for the re-enable path. |
| `lib/**` | Pinned dependencies (see below). |
| `packages/sdk/**`, `examples/**` | TypeScript SDK and consumer examples (in the monorepo, not the Foundry project). |

## Build & test

```bash
cd contracts
forge build                             # Solidity 0.8.28, via-IR, optimizer 200 runs — clean
forge test                              # BOTH surfaces: 457 tests across 40 suites, all passing
forge test --no-match-path 'test/primary/*'   # THIS surface: 257 tests across 9 suites
forge coverage --ir-minimum --no-match-coverage '(script|test)'
bash script/storage-layout.sh           # upgrade-safety guard; must print "storage layout unchanged"
slither .                               # BOTH surfaces: 43 results, all triaged benign
```

**Test suite for this surface — 257 tests, 0 failures, 9 suites**
(`forge test --no-match-path 'test/primary/*'`):

| File | Suite | Tests |
|---|---|---:|
| `test/AsseteraECS.t.sol` | `AsseteraECSTest` | 201 |
| `test/ParamsHashVectors.t.sol` | `ParamsHashVectorsTest` | 17 (`paramsHash` vectors) |
| `test/ParamsHashVectors.t.sol` | `EIP712DigestVectorsTest` | 11 (full EIP-712 digest vectors) |
| `test/ParamsHashVectors.t.sol` | `ParamsHashVectorsOnChainTest` | 5 (on-chain acceptance) |
| `test/GateStorageNamespace.t.sol` | `GateStorageNamespaceTest` | 6 (ERC-7201 namespace) |
| `test/GateStorageNamespace.t.sol` | `GateReuseTest` | 5 (gate reuse by a non-order-book venue) |
| `test/FaucetToken.t.sol` | `FaucetTokenTest` | 6 |
| `test/DeployProvenance.t.sol` | `DeployProvenanceTest` | 3 |
| `test/invariants/EscrowConservation.t.sol` | `EscrowConservationInvariantTest` | 3 (2 invariants at 64 runs × depth 50, plus a non-vacuity unit test) |

> The whole repository runs **457 tests across 40 suites**; the remaining 200 tests in 31 suites belong to
> the primary surface. Earlier documents, including `docs/SECURITY-REVIEW-2026-07-14.md`, quote **129** —
> that figure is stale by two major workstreams and should not be used.

**Coverage** (`forge coverage --ir-minimum --no-match-coverage '(script|test)'`). `--ir-minimum` is
**required** — plain `forge coverage` disables the optimizer and via-IR and fails "stack too deep" in
`OfferBook.replaceOffer`. The run reports both surfaces in one table; the rows for this surface are:

| File | % Lines | % Statements | % Branches | % Funcs |
|---|---:|---:|---:|---:|
| `src/core/OrderBook.sol` | 100.00 (96/96) | 100.00 (138/138) | 100.00 (29/29) | 100.00 (10/10) |
| `src/core/OfferBook.sol` | 100.00 (141/141) | 99.02 (202/204) | 95.12 (39/41) | 100.00 (9/9) |
| `src/core/PermitRelay.sol` | 100.00 (8/8) | 100.00 (6/6) | 100.00 (1/1) | 100.00 (2/2) |
| `src/gates/FeeGate.sol` | 100.00 (27/27) | 100.00 (45/45) | 100.00 (14/14) | 100.00 (4/4) |
| `src/gates/KycGate.sol` | 100.00 (19/19) | 100.00 (30/30) | 100.00 (10/10) | 100.00 (3/3) |
| `src/gates/GateStorage.sol` | 90.00 (9/10) | 80.00 (4/5) | n/a (0/0) | 100.00 (5/5) |
| `src/libs/FeeMath.sol` | 100.00 (4/4) | 100.00 (4/4) | n/a (0/0) | 100.00 (2/2) |
| `src/admin/ExchangeAdmin.sol` | 94.59 (35/37) | 95.00 (38/40) | 100.00 (7/7) | 100.00 (6/6) |
| `src/AsseteraECS.sol` | 79.41 (27/34) | 83.72 (36/43) | 100.00 (1/1) | 87.50 (7/8) |
| **Subtotal (this surface)** | **97.34 (366/376)** | **97.67 (503/515)** | **98.06 (101/103)** | **97.96 (48/49)** |

The residue on `AsseteraECS.sol` is the ERC-2771 / UUPS plumbing (`_msgData`, `_contextSuffixLength`) —
overrides OZ requires but which the venue's own paths never take. The one line on `GateStorage.sol` is
`$.slot := GATE_STORAGE_LOCATION` inside the ERC-7201 accessor: solc's coverage instrumentation does not
reach into inline assembly, so that line can never be marked hit. What it does is pinned directly by
`test/GateStorageNamespace.t.sol`, which re-derives the namespace and reads the resulting slots.

- `forge build` is clean; the only lint output is `block-timestamp` warnings on expiry comparisons (benign
  — the expiry windows dwarf validator drift; see the Slither triage).
- **Testing (internal finding I-2, resolved and since extended):** in addition to the unit suite, the
  review's coverage gap was closed with a handler-driven **escrow-conservation invariant** suite
  (`test/invariants/`), **fee-on-transfer / rebasing mock-token** tests that directly exercise the M-1
  pool-insolvency mechanism, and **reentrancy-guard coverage on all 12 funds-custody entry points** (via a
  `ReentrantToken` armed with arbitrary calldata). AC-833 extended the invariant to the escrowed fee and
  made the handler trade at real, non-zero fee rates so the escrowed-fee path is genuinely exercised rather
  than sitting at zero. AC-884 made the handler sign its fee attestations with the fee-operator key (they
  are no longer skippable) and added `test_HandlerCanDriveFeeAttestedEntryPoints` — the handler swallows
  every revert, so without that pin a broken signing helper would create zero orders and both invariants
  would pass vacuously.

### Upgrade-safety guard (`script/storage-layout.sh`)

A committed snapshot of each proxy's storage layout (`storage/AsseteraECS.txt` for this surface,
`storage/AsseteraPrimarySales.txt` for the other), diffed in CI on every PR. On this commit the script
prints:

```
✅ AsseteraECS storage layout unchanged
✅ AsseteraPrimarySales storage layout unchanged
```

Because the OZ v5 upgradeable bases use ERC-7201 namespaced storage, a clean minor dependency bump produces
a **zero-line diff** — any diff on a dep bump is a red flag. Paired with
`test_Upgrade_PreservesAllStorageAcrossEverySlot`.

The snapshot has two halves. The top-level `forge inspect … storage-layout` table, **plus** (added in
AC-833, via `script/struct-layout.py`) the **per-struct member layout**. That second half closes a real
blind spot: `_orders` / `_offers` are mappings, so the top-level table records one slot each and says
nothing about the struct behind it — adding `feeToken` / `escrowedFee` to `Order` and `Offer` produced a
zero-line diff and sailed through the old check. Appending to a struct held in a mapping is upgrade-safe
(each value lives at its own hashed slot); **reordering or retyping** a member is not, and the guard could
not tell those apart. It now can.

⚠️ **The layout on this commit is NOT upgrade-compatible with the pre-AO-514 exchange proxies.** AO-514
moved the four gate mappings out of the linear layout and into `GateStorage`'s ERC-7201 namespace, which
shifts `_offers` 5 → 2, `totalOffers` 6 → 3 and `__gap` 8 → 4. That break was weighed against preserving
the old order with reserved gaps and taken on purpose; it was landed by a coordinated **fresh deploy**,
never by `upgradeToAndCall` on an existing proxy. `version()` reports `4.0.0` for the same reason: the
major digit is what tells ops the two are not interchangeable.

**That is enforced in code, not only stated here.** `Deploy.s.sol` upgrades a proxy in place the moment the
implementation bytecode differs, so both it and `UpgradeCalldata.s.sol` refuse outright while
`DeployBase.INPLACE_UPGRADE_ALLOWED` is `false` — which it still is on this commit. It is a compile-time
constant rather than an environment flag because whether an implementation is installable is a property of
the source tree, not of whoever runs the script.

> **Status note, measured on this commit rather than carried over.** The fresh deploy has already happened:
> the exchange salt labels were renamed to `AsseteraECS.*` (PR #62), which computes a new CREATE3 address,
> and the resulting deployments were recorded for Polygon Amoy and Ethereum Sepolia (PRs #64 and #65). The
> proxies live on those two testnets today therefore already carry **this** layout.
> `EXCHANGE_SALT_VERSION` is still `"v1"` because the label rename, not a version bump, is what moved the
> address. `INPLACE_UPGRADE_ALLOWED` has deliberately **not** been flipped back to `true`; flipping it is a
> follow-up decision, not part of the fresh deploy.

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

Reproduce with `git submodule status contracts/lib/*`; `contracts/foundry.lock` records the same four revs.
Dependencies are **frozen for the duration of an external audit**.

## Token limitations — what may and may not trade here

**Policy: standard ERC-20 only. No fee-on-transfer, no rebasing, no deflationary or elastic supply.**

| Behaviour | This surface |
|---|---|
| Standard ERC-20 (`transfer` / `transferFrom` move exactly the requested amount) | **Supported** — the only supported class |
| Fee-on-transfer / deflationary | **Refused by policy, not by code.** Nothing on-chain detects it; the escrow becomes overstated and the pool can go insolvent (finding M-1) |
| Rebasing (positive or negative) | **Refused by policy, not by code.** A negative rebase desyncs recorded escrow from the real balance (finding M-1) |
| Non-standard `decimals()` / missing `decimals()` | Never read by this surface |
| Freezable / blacklistable (USDC and friends) | **Supported but hazardous** — escrow can be permanently stranded (finding L-1). This is what production actually uses |
| Missing / divergent ERC-2612 `permit` | **Supported.** `PermitRelay._tryPermit` swallows the failure and falls back to a pre-existing allowance; `permitAccepted` makes it observable on simulation |

**Enforcement is entirely off-chain.** For `Place` and `MakeOffer` the token addresses are bound into
`paramsHash`, re-derived on-chain and signed by **both** the KYC backend and the fee service, so which
tokens can enter escrow is gated by the backend token allowlist. There is **no on-chain tradable-token
allowlist**, and `fillOrder` inherits whatever tokens the order already fixed.

⚠️ **Production settlement will be real USDC on Polygon mainnet, which is neither fee-on-transfer nor
rebasing but is freezable and blacklistable.** So M-1 (below) is a policy assumption we hold off-chain, and
L-1 is a live operational risk on the exact token we intend to settle in.

### ⚠️ This surface and the primary router take OPPOSITE positions on the same risk

An auditor will notice this immediately, so it is stated up front rather than left to be discovered.

- **The exchange escrow does no balance-delta accounting.** There is no `balanceOf` measurement anywhere in
  `OrderBook.sol` or `OfferBook.sol` — confirmed on this commit by
  `grep -rn 'balanceOf' src/core src/gates src/admin src/AsseteraECS.sol src/storage src/libs`, which
  returns nothing. Standard ERC-20 semantics are treated as an **invariant enforced off-chain**, because
  the token addresses are bound into the signed `paramsHash`.
- **The primary settler does the opposite.** `src/primary/settle/VenueSettler.sol` snapshots its own
  balances, measures what actually arrived, and reverts with `SettlementPullMismatch(requested, received)`
  when the two differ — making a fee-on-transfer settlement currency unsettleable rather than lossy.
- **The reason is history, not a considered symmetry.** The exchange shipped first and M-1 was formally
  **accepted on 2026-07-15 as documentation-only** (recommendation #3, balance-delta accounting, was
  explicitly declined); the primary settler was written afterwards, and its measurement was added on review
  of PR #58. Whether the exchange should be brought in line is a legitimate question for this engagement,
  and we would like an answer to it.

**The exchange's weird-token tests document the insolvency rather than prevent it.** Named here so nothing
looks hidden — all four are in `test/AsseteraECS.t.sol` and all four **pass**, by asserting that the bad
outcome happens:

| Test | What it pins |
|---|---|
| `test_TokenSafety_FeeOnTransfer_EscrowOverstatedAtPlacement` | Recorded escrow exceeds the tokens actually received |
| `test_TokenSafety_FeeOnTransfer_PoolInsolvency_LastCancellerReverts` | The shortfall is borne by other makers; the last withdrawer reverts |
| `test_TokenSafety_Rebasing_NegativeRebaseCausesInsolvency` | A negative rebase desyncs the pool the same way |
| `test_TokenSafety_FeeOnTransfer_AcceptOfferShortfall` | The same delta on the offer-settlement path |

<a id="economics--the-currency-exclusive-fee-model-ac-833"></a>
## Economics — the currency-exclusive fee model (AC-833)

This is the part of the system that changed most recently and most materially, and the part where an
auditor reading older documentation would review the wrong thing. It shipped in PR #39 (SDK 3.0.0) and is
the model on `main` today.

### The rule

**Both fees are denominated in the settlement currency, and are exclusive on the payer.**

- Exactly one of the two legs of a trade is the **settlement currency**, identified by `feeToken`.
- `makerFeeBps` and `takerFeeBps` are both charged on the **notional** — the currency-leg amount for that
  fill — and both are paid in `feeToken`.
- The party **paying** currency pays `notional + their own fee`.
- The party **receiving** currency receives `notional − their own fee`.
- **The asset leg always moves gross.** Nothing is ever withheld from it.
- The collector receives exactly `makerFeeAmount + takerFeeAmount`, in one token, and zero of the asset.

Worked example — a taker filling "10 RWA for 100 USDC" at 1 % / 1 % pays **101 USDC** and receives the full
**10 RWA**; the maker receives **99 USDC**; the collector takes **2 USDC** and zero RWA
(`OrderBook._settleFill`, `OrderBook.sol:287-355`, and asserted to the wei across all five accounts in
`test_Fee_Fill_BothFeesInSettlementCurrency_ExclusiveOnTaker`).

The books balance without any extra escrow from the asset side, because the currency receiver's own fee
cancels: `(cAmount − receiverFee) + (makerFee + takerFee) == cAmount + payerFee`
(`OfferBook.sol:309-311`, implemented in `_settleOffer`, `OfferBook.sol:314-360`).

**Why it changed.** The previous model charged each fee on its own leg and deducted it from what each party
*received*, which left the fee collector holding fragments of a **restricted security token** — a
transfer-restriction problem, not merely an accounting one.

### `feeToken` — how the contract learns which leg is money

The contract knows token addresses, not markets, so it cannot infer which leg is currency. `feeToken` is
therefore a **signed field on `FeeAttestation`** and part of `FEE_TYPEHASH` (`FeeGate.sol`):

```
FeeAttestation(address account,uint8 action,uint256 nonce,uint256 deadline,bytes32 paramsHash,
               uint16 makerFeeBps,uint16 takerFeeBps,address feeCollector,address feeToken)
```

The fee service resolves it from the marketplace catalog (`token_pairs.settlement_currency_id`) and signs
it. On-chain, `FeeGate._validateFees` asserts `feeToken ∈ {legA, legB}` — **unconditionally**, i.e.
independently of the `complianceRequired` toggle, as defence in depth. It is required **even for a
zero-fee order**, so that `feeToken == address(0)` means exactly one thing (below).

`feeToken`, `makerFeeBps`, `takerFeeBps` and `feeCollector` are **snapshotted onto the order/offer at
creation** (`OrderBook.sol:186-202`, `OfferBook.sol:139-156`) and are immutable for its lifetime.

Adding `feeToken` to the typehash was a **breaking change to the attestation format**: an attestation
signed under the old type recovers to a different address and is rejected by `FeeBadSigner`.

### The escrowed-fee invariant (load-bearing)

When the maker/proposer is the party **escrowing the currency leg**, they are the currency *payer*, so
their fee must be escrowed up front alongside the notional:

- **Orders** (`OrderBook._makerEscrowedFee` / `_escrowTotal`, `OrderBook.sol:157-173`; the pull is
  `OrderBook.sol:204`): a buy-side order (`sellToken == feeToken`) escrows
  `sellAmount + floor(sellAmount × makerFeeBps / 10000)` in one `safeTransferFrom`. The unconsumed
  remainder is tracked as an explicit `Order.escrowedFee` field rather than recomputed at unwind time —
  after partial fills the two diverge by rounding.
- **Offers** (`OfferBook._proposerFee`, `OfferBook.sol:119-126`; the pull is `OfferBook.sol:99`;
  the field is set at `OfferBook.sol:155`): identically, whenever the proposer's own leg is the currency.
- When the maker instead escrows the **asset**, nothing extra is escrowed — their fee is withheld from the
  currency the counterparty pays in.

> **Invariant: the escrowed fee is the maker's money until a fill earns it.** Every path that unwinds an
> order or offer must return whatever remains of it, and the final fill must return the rounding dust, so
> the contract never retains a residue.

All **eight** paths honour it:

| # | Path | Where |
|---|---|---|
| 1 | `OrderBook.cancelOrder` | `OrderBook.sol:231`, `:235` |
| 2 | `OrderBook.sweepExpired` | `OrderBook.sol:372`, `:379` |
| 3 | `OrderBook._settleFill` — final-fill rounding dust back to the maker | `OrderBook.sol:314-317`, `:327` |
| 4 | `ExchangeAdmin.cancelOrderForUser` (admin force-cancel) | `ExchangeAdmin.sol:68`, `:72` |
| 5 | `OfferBook.replaceOffer` — refunds the outgoing proposer, re-escrows the incoming one | `OfferBook.sol:196-225` |
| 6 | `OfferBook.cancelOffer` | `OfferBook.sol:256`, `:263-267` |
| 7 | `OfferBook.sweepExpiredOffers` | `OfferBook.sol:385-391` |
| 8 | `ExchangeAdmin.cancelOfferForUser` (admin force-cancel) | `ExchangeAdmin.sol:104`, `:110-114` |

The per-fill decrement `o.escrowedFee -= makerFeeAmount` (`OrderBook.sol:311`) is safe by construction: the
per-fill fee is `floor(fᵢ · bps)` over fills whose `fᵢ` sum to `sellAmount`, and
`Σ floor(x) ≤ floor(Σ x) = escrowedFee`. Solidity 0.8 checked arithmetic means a violation of that argument
would **revert**, not silently underflow. The `escrowedFee` residue left by that inequality is returned to
the maker on the last fill.

**Test evidence.** `test_AC833_BuySideOrder_EscrowsNotionalPlusMakerFee`,
`…_Fill_AssetGross_CurrencyNetToTaker`, `…_SweepExpired_RefundsEscrowedFee`,
`…_ForceCancel_RefundsEscrowedFee`, `…_FullFillInParts_ReturnsFeeDustToMaker`,
`…_Offer_MakerProposesCurrency_EscrowsOwnFee_AndRefundsOnCancel`,
`…_Offer_Replace_RefundsOldFeeEscrow_AndTakesNew`, `test_AC833_FeeTokenNotALeg_Reverts`,
`test_AC833_FeeTokenIsSignedOverAndCannotBeTampered`,
`test_AC833_LegacyOrder_CannotBeFilled_ButCanStillBeCancelled` (all in `test/AsseteraECS.t.sol`).

### Extended escrow-conservation invariant

The invariant suite's ground truth counts the escrowed fee (`test/invariants/EscrowHandler.sol`). For every
token, after any fuzzed sequence of place / fill / cancel / sweep / make / replace / accept / cancel-offer /
sweep-offers:

```
balanceOf(exchange, token) ==
    Σ over Open orders with sellToken == token   (remainingQuantity + escrowedFee)
  + Σ over Open/Countered offers where the current proposer's leg == token
                                               (that leg's amount + escrowedFee)
```

The handler trades at real rates (1 % maker / 0.5 % taker, tokenB as settlement currency) with every actor
bringing a fee-inclusive amount, so the escrowed-fee path is genuinely driven. KYC gating is off (it has its
own dedicated coverage) but `_validateFees` still runs, so the denomination is enforced throughout. On this
commit both invariants report **64 runs × 3,200 calls, 0 reverts**, with every handler selector called
roughly 300 times.

Mutation-verified: dropping the fee refund from `cancelOrder` fails `invariant_EscrowConservation_TokenB`
with a stranded residue while leaving `TokenA` — the asset leg, which carries no fee escrow — passing.

### Legacy (pre-AC-833) orders and offers

Storage was extended **append-only**, so orders and offers created before the upgrade still exist and read
`feeToken == address(0)`. Because `_validateFees` requires `feeToken` to be one of two already-non-zero
legs, a *new* order can never have `feeToken == 0` — the sentinel is unambiguous.

Such entries **cannot be traded** — `fillOrder` reverts `LegacyOrderMustBeUnwound` (`OrderBook.sol:268`),
`acceptOffer` and `replaceOffer` revert `LegacyOfferMustBeUnwound` (`OfferBook.sol:285`, `:174`) — because
their fees have no defined denomination. They **can** still be cancelled, swept and force-cancelled, so no
funds are stranded. `replaceOffer` is deliberately blocked too: countering a legacy offer would keep an
unacceptable offer alive indefinitely.

### Audit-relevant surface introduced or changed by AC-833

1. **`FEE_OPERATOR_ROLE` now chooses the settlement currency.** The on-chain check is only
   `feeToken ∈ {legA, legB}` — the contract cannot know which leg is *actually* money. A compromised fee
   signer could nominate the **asset** leg as `feeToken`, inverting who pays and who receives the fee, and
   causing the collector to be paid in the restricted token. Blast radius is bounded by `MAX_FEE_BPS`
   (10 000) and the `allowedCollectors` allowlist, and the fee terms are visible in `OrderPlaced` /
   `OfferMade` before any fill. This is a genuine widening of that role's authority versus the pre-AC-833
   model and should be weighed as such.
2. **Fee terms are always signed — the KYC kill switch is CLOSED (AC-884, PR #48).** As shipped in AC-833,
   `_verifyFee` early-returned on `complianceRequired[action]`, so `setComplianceRequired(Place, false)` —
   an admin lever named and documented as a *KYC* control — also disabled signature, deadline and nonce
   checking on the *fee* attestation, letting any caller hand-craft an unsigned zero-fee attestation and
   place a permanently fee-free order. Never triggered on any deployment (Amoy read 2026-07-29 showed the
   initializer defaults untouched), but a footgun in an admin API.
   **Verified against `src/gates/FeeGate.sol` on this commit:**
   - `_verifyFee` (`FeeGate.sol:56-79`) has **no** `complianceRequired` guard on any line. Account, action,
     deadline, `MAX_FEE_TTL`, nonce reuse and the `FEE_OPERATOR_ROLE` signature recovery all run
     unconditionally.
   - `_bindParamsHash` binds the **fee** attestation's `paramsHash` unconditionally
     (`if (feeAtt.paramsHash != paramsHash) revert ParamsHashMismatch();`); only the **KYC** half stays
     behind `complianceRequired(action)`, which is the gate it belongs to.
   - `_consumeKycAndFee` burns the **fee** nonce and emits `FeeConsumed` unconditionally; only the KYC
     nonce burn sits inside `if (complianceRequired(action))`.
   So `setComplianceRequired(action, false)` now governs KYC only. Fee-free trading is still expressible —
   the fee service signs `makerFeeBps == takerFeeBps == 0`, which `_validateFees` explicitly permits — so
   nothing was lost beyond the ability to reach it unauthenticated.
3. **Allowance requirements changed for takers.** A sell-side fill pulls from the taker **twice**
   (`OrderBook.sol:332-333`): `notional − makerFee` to the maker and `makerFee + takerFee` to the collector.
   The taker must therefore approve `notional + takerFee`, not `notional`. `placeOrderWithPermit`
   correspondingly permits `_escrowTotal(...)` = `sellAmount + escrowedFee` (`OrderBook.sol:146-148`).
4. **`replaceOffer` swaps both halves of the fee escrow in one call** (`OfferBook.sol:196-225`) — the
   outgoing proposer's unconsumed fee is refunded and the incoming proposer escrows a fee recomputed on the
   **new** amounts, which may be a different party, side and token. It is one of the three
   highest-complexity functions in the codebase (Slither cyclomatic complexity 12) and worth focused
   review.
5. **Rounding is deliberately asymmetric.** `FeeMath.feeAmount` floors (rounding favours maker and taker
   over the collector); `FeeMath.ceilDiv` on the fill's proportional amount ceils (protecting the maker
   from rounding loss on partial fills) — `OrderBook.sol:280`.
6. **Fill/settle events carry GROSS amounts** plus `feeToken`, and `OrderPartiallyFilled` additionally
   carries `filledBuyAmount`. Consumers must not re-derive net figures the old way. See
   `docs/INDEXER_EVENT_SCHEMA.md`.

### Audit-relevant surface introduced by AO-298 (`permitAndCall`)

`src/core/PermitRelay.sol` adds one external function, `permitAndCall`, which runs an ERC-2612 `permit` for
the caller and then `delegatecall`s one function on this same contract. It exists because
`placeOrderWithPermit` only ever helped the maker placing an order: the taker on `fillOrder` and both
parties across `makeOffer` / `replaceOffer` / `acceptOffer` had to send a separate `approve` transaction
first. We chose one generic entry point over four `…WithPermit` twins on measured size (373 bytes of
runtime code versus 513, against roughly 2.6 kB of EIP-170 headroom) and because it also covers any
token-pulling function added later, including the parked operator `settle`/`refund`.

It is a **self-`delegatecall` with caller-supplied calldata**, which we expect a reviewer to want to look at
closely. The claims we make about it, and where each is pinned:

1. **No privilege escalation.** Authorisation everywhere in this contract is `_msgSender()`.
   `permitAndCall` re-appends the ERC-2771 sender suffix to `data` before delegating (the same detection
   OpenZeppelin's `Multicall` uses: `msg.sender != _msgSender()` means the call arrived through the trusted
   forwarder). The inner function therefore resolves the same actor it would have resolved on a direct
   call, whether relayed or not, so `data` reaches nothing the caller could not already reach. Pinned by
   `test_PermitAndCall_Relayed_IdentityIsUserNotRelayer` and
   `test_PermitAndCall_CannotReachAdminFunctionsWithoutTheRole`.
2. **The reentrancy guard still holds.** `permitAndCall` is deliberately not `nonReentrant` — taking the
   guard would make the inner call revert — and every function it can delegate into carries its own guard.
   The one external call it makes before delegating is `token.permit` on a caller-chosen address, at which
   point it holds no state and has moved no funds. Pinned by
   `test_PermitAndCall_ReentrantTokenCannotReenterGuardedCall`.
3. **No `msg.value` to double-spend.** The classic multicall bug does not apply: the venue has no payable
   functions and `permitAndCall` is not payable.
4. **Permit failure stays swallowed**, as in `placeOrderWithPermit`. The first return value,
   `permitAccepted`, makes the failure observable on simulation instead of silent. Three real cases need
   the swallow, and all three are tested against mocks: a token with no ERC-2612 at all
   (`test_PermitAndCall_TokenWithoutErc2612_FallsBackToAllowance`), a token whose EIP-712 domain name is not
   its `name()` — EUROP's shape (`DivergentDomainToken`, three tests) — and a token whose ERC-5267
   `eip712Domain()` reverts — USDC's shape (`test_PermitAndCall_TokenWithoutErc5267_StillPermits`). The
   faucet tokens on playground pass their own `name()` to `ERC20Permit`, so playground cannot reproduce
   either divergence; the mock exists for exactly that reason.

`controlled-delegatecall` does not fire in Slither because the delegatecall target is `address(this)`, not
caller-supplied.

The **storage layout is unchanged**: `PermitRelay` declares no state. The committed snapshot
(`storage/AsseteraECS.txt`) was nevertheless re-baselined in the AO-298 commit, because it embeds solc AST
node ids in type names (`t_struct(Order)11439_storage` → `…11533_storage`) and adding a source file shifts
them. Every slot, offset and member is byte-identical either side of that diff. That the guard produces a
diff on a change it is not meant to detect is a real weakness worth fixing separately.

## Static analysis (Slither)

Config: [`slither.config.json`](slither.config.json) (filters `lib/`, `test/`, `script/`). Run: `slither .`
from `contracts/`. Current result across **both** surfaces: **57 contracts, 101 detectors, 43 results — all
triaged benign.** Of those, **28 are attributable to this surface**:

| Detector | Count | Location | Verdict |
|---|---:|---|---|
| `arbitrary-send-erc20` | 4 | `OfferBook._settleOffer` (`OfferBook.sol:314-360`, transfers at `:339-343`) | **False positive** — `from` is always `o.maker` or `o.taker`, and the caller has already been checked to be one of them (`acceptOffer`, `OfferBook.sol:289`). You can only pull tokens from yourself. |
| `timestamp` | 10 | expiry / TTL comparisons in `OrderBook` (4), `OfferBook` (4), `KycGate._verifyKyc`, `FeeGate._verifyFee` | Benign — validator drift (seconds) is immaterial to the expiry/TTL windows (`MAX_KYC_TTL` / `MAX_FEE_TTL` are 15 minutes; order expiries are hours-plus). |
| `naming-convention` | 8 | `IFeeGate` (4) and `IKycGate` (3) constant getters, `ExchangeStorage.__gap` | Getters mirror public constants; `__gap` is the OZ storage-gap idiom. |
| `dead-code` | 2 | `AsseteraECS._msgData`, `KycGate._paramsHashAllowed` | OZ-required ERC-2771 override; and the virtual default that both venues override. |
| `uninitialized-local` | 1 | `OrderBook._settleFill.feeDust` (`OrderBook.sol:306`) | **Benign** — the zero default *is* the intended value; `feeDust` is only assigned on the final fill of a buy-side order, and the guarded `if (feeDust > 0)` transfer makes the unassigned case a no-op. |
| `reentrancy-benign` | 1 | `OrderBook.placeOrderWithPermit` (external call in `PermitRelay._tryPermit`) | Guarded by `nonReentrant`; state writes after the `permit` external call are harmless. |
| `assembly` | 1 | `GateStorage._gate()` (`GateStorage.sol:53-58`) | The ERC-7201 namespaced-storage accessor idiom. |
| `cyclomatic-complexity` | 1 | `OfferBook.replaceOffer` (12) | Accepted; flagged above as a focused-review target. |

No high- or medium-severity true positives. (I-4 recommended committing a `slither.db.json` triage file;
that remains **deferred** — Slither is not currently a CI gate, so the table above is the triage of record.)

The remaining 15 results belong to the primary surface and are triaged in
[`AUDIT-SCOPE-PRIMARY.md`](AUDIT-SCOPE-PRIMARY.md).

## Trust model & centralization (by design — regulated venue)

- `DEFAULT_ADMIN_ROLE` is effectively full custody: it can `upgradeToAndCall` to arbitrary logic and
  force-cancel/route any escrow (including the escrowed fee). **Mainnet requirement:** a Safe multisig,
  plus a timelock on upgrades. See L-3 below.
- `KYC_OPERATOR_ROLE` signs KYC attestations (off-chain signer). Compromise cannot move escrow beyond
  normal trading and **cannot set/redirect fees**.
- `FEE_OPERATOR_ROLE` signs fee attestations (a distinct signer). Bounded by `MAX_FEE_BPS` and the
  `allowedCollectors` allowlist — but note it now also selects the settlement currency (see the AC-833
  surface notes above).
- Order/offer **matching happens off-chain**; the chain enforces settlement, escrow, attestation and fees.
- Identity is resolved through `_msgSender()` (ERC-2771), so a trusted forwarder may relay gasless
  meta-transactions. The primary router shares the same forwarder address.
- The roles on this proxy are **separate grants** from the roles on the primary-sales proxy: same role
  identifiers, different `AccessControl` storage, and the primary router additionally has
  `SETTLEMENT_OPERATOR_ROLE`, which does not exist here. Its `allowedCollectors` allowlist likewise starts
  empty and does not inherit this contract's entries.
- This centralization is intentional and mandated by the regulatory model.

## Mainnet target

Production is **Polygon mainnet, chain id 137**. Neither proxy is deployed there yet: the SDK carries
deployment records for `80002` (Polygon Amoy) and `11155111` (Ethereum Sepolia) only
(`packages/sdk/src/deployments/`).

The open-mint faucet tokens (`MockUSDC` / `MockRWA`, i.e. `test/mocks/FaucetToken.sol`) are **structurally
excluded from a mainnet deploy**: `DeployBase._isTestnet` (`script/DeployBase.sol:136-138`) returns true
only for `31337` (local anvil), `80002` and `11155111`, and `Deploy.s.sol:69` reads
`vm.envOr("DEPLOY_MOCKS", _isTestnet(chainId))`. On chain 137 the default is therefore `false` and the
faucet is never deployed. Note the `DEPLOY_MOCKS` environment variable can override it, so the guard is a
safe default rather than an absolute bar.

## Known security assumptions & findings

Fully described in the internal review; the load-bearing ones, re-read against the current code:

1. **M-1 — standard-ERC-20-only. Status: accepted 2026-07-15, documentation only.** The pooled escrow
   assumes tokens transfer exactly the requested amount. **Only standard, non-rebasing,
   non-fee-on-transfer ERC-20 tokens may trade.** Enforced off-chain (attestation-gated token addresses);
   no on-chain tradable-token allowlist, and recommendation #3 (balance-delta accounting) was explicitly
   declined for this surface. See `FUNCTIONAL_SPEC.md §9` and the token-limitations section above.
   **The assumption still holds after AC-833, with a slightly larger blast radius:** the escrowed fee is
   pulled in the *same* `safeTransferFrom` as the notional (`OrderBook.sol:204`, `OfferBook.sol:99`), so a
   fee-on-transfer token now overstates recorded escrow by the transfer tax on `notional + fee`, not just
   on `notional`, and the refund paths pay out that overstated figure. The failure mode is unchanged —
   last-out insolvency.
2. **L-1 — freezable tokens** (e.g. USDC) can strand escrow if a party or the exchange is blacklisted. Now
   also applies to the escrowed fee, which is denominated in the settlement currency — precisely the leg
   most likely to be a freezable stablecoin, and precisely what production will settle in.
3. **L-2 — fee snapshot outlives collector de-allowlisting.** `feeCollector` is checked against
   `allowedCollectors` only at placement; de-allowlisting does not affect orders already placed against it.
   Accepted (re-checking at payout would let the admin retroactively divert agreed fee terms). AC-833
   extends the same snapshot semantics to `feeToken`.
4. **L-3 — centralized signer / upgrade authority. Status: OPEN, accepted as an operational item.** There
   is **no `TimelockController` anywhere in this repository** (verified by grep over `src/`, `script/` and
   `test/` on this commit), and `DEFAULT_ADMIN_ROLE` is simply whatever address is passed to `initialize`.
   The July review recorded this as design-inherent centralization required by the regulated venue model,
   not a code defect, and deferred the on-chain timelock as a separate, larger-scoped change. The mainnet
   readiness checklist (Safe multisig admin, upgrade timelock, dedicated keys per signer role, optional
   admin-role splitting) is in `FUNCTIONAL_SPEC.md §2`. It applies to the primary-sales proxy too.
5. **I-1…I-4** are informational and described in the internal review. I-2 (branch-coverage gap) and I-3
   (`_tryPermit` failure swallow) are resolved; I-4 (Slither triage file) remains deferred.

## Contact

Code owner: `@tomw1808` (see `CODEOWNERS`). Please route questions and preliminary findings through the
agreed engagement channel.
