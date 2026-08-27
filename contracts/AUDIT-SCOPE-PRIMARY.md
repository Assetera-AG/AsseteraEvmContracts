# AsseteraPrimarySales — Audit Scope & Handover (PRIMARY MARKET / SETTLEMENT ROUTER)

This document scopes an external security review of **`AsseteraPrimarySales`** — the router a buyer's
**first** acquisition of an asset goes through. It is one of **two** contract surfaces in this repository
and can be audited on its own.

- The other surface is the **secondary market / exchange** (`AsseteraECS`), scoped in
  [`AUDIT-SCOPE-SECONDARY.md`](AUDIT-SCOPE-SECONDARY.md). It is a **separate proxy** with separate storage,
  a separate pause lever and a separate EIP-712 domain. It is **not** covered here.
- Shared context that applies to both surfaces is in the umbrella document
  [`AUDIT-SCOPE.md`](AUDIT-SCOPE.md). Everything an auditor needs for *this* surface is repeated here so
  the document stands alone.

## 🔴 Read this first: this surface has never been independently reviewed

**There is no security review of the primary-sales contract, internal or external.** We looked for one and
did not find one:

- `contracts/docs/` contains exactly one review, `SECURITY-REVIEW-2026-07-14.md`. Its own header scopes it
  to "the live AsseteraECS surface (14 source files, ~1,680 LoC)" and it is dated **2026-07-14**. The
  primary contract landed on `main` afterwards, in PR #58. Grepping that document for `primary`,
  `VenueSettler`, `IntentGate` or `Settlement` returns **no** match that refers to this contract.
- `contracts/docs/FUNCTIONAL_SPEC.md` **does not mention primary sales at all** (grep for `primary`,
  `VenueSettler`, `IntentGate` returns nothing). The functional specification covers the exchange only.
  There is no equivalent written spec for this surface; the design rationale lives in the NatSpec of
  `AsseteraPrimarySales.sol` and `settle/VenueSettler.sol`, which is unusually extensive and is the
  intended reading.
- `contracts/docs/INDEXER_EVENT_SCHEMA.md` **does** cover this surface (`PrimarySettled`,
  `IntentConsumed`).

So the known-findings register that exists for the exchange (M-1, L-1…L-3, I-1…I-4) has **no counterpart
here**. Every finding on this surface will be a first finding. Please do not read the exchange's triage as
covering this contract.

The contract **is already deployed** on Polygon Amoy and Ethereum Sepolia
(`packages/sdk/src/deployments/80002.json`, `11155111.json`) and has a substantial adversarial test suite
(200 tests, below), but neither of those is a review.

## What it is

- **Project:** `AsseteraPrimarySales` — the constrained executor for primary-market settlement in a
  regulated real-world-asset (RWA) marketplace (MiFID). Shipped under AO-560, PR #58.
- **Foundry root:** `contracts/` (point `forge`, `slither` and coverage here).
- **`version()`:** `1.0.0`. First release; nothing on chain reads it.
- **EIP-712 domain:** `__EIP712_init("AsseteraPrimarySales", "1")` — deliberately **different** from the
  exchange's `"AsseteraExchange"`, so an attestation minted for one contract recovers to a different
  address on the other and is rejected as `KycBadSigner`. Cross-contract attestation replay between the
  two surfaces is impossible by construction rather than by check. Pinned by
  `test_ExchangeAttestation_CannotBeReplayedHere`.

### The shape of one settlement

`settlePrimary(venueCalldata, intent, intentSignature, buyerSignature, kyc, fee)` is the **only**
state-changing entry point that moves money. Since AO-713 it can be reached two ways — called directly, or
wrapped by `permitAndCall` so that the buyer's ERC-2612 `permit` and the settlement are one transaction —
but there is one implementation, one selector and one guard either way; the second route is a
self-`delegatecall` into this same function. It:

1. verifies **four signatures from four signers** before burning any nonce — the settlement operator's
   intent signature, the **buyer's own** signature over the same digest (EOA or ERC-1271), the KYC
   attestation and the fee attestation;
2. binds the opaque `venueCalldata` to the intent by `keccak256` **and** by 4-byte selector;
3. pins both attestations to the intent's EIP-712 struct hash (that struct hash **is** the `paramsHash`);
4. burns **three** nonce namespaces (KYC, fee, intent) and charges a per-transaction settlement cap;
5. hands the calldata to `intent.venue` — an address bound in the signed intent and checked against **no
   on-chain allowlist** — and judges the result purely on **measured balance deltas**;
6. refunds what the venue did not consume, forwards any asset that landed on the router, pays the fee, and
   asserts the router holds no standing balance on either token.

Three design decisions an auditor should know before reading a line:

- **The buyer's signature is load-bearing, not ceremonial.** Without it a compromised settlement operator
  sets `minAssetOut` to one wei and the buyer's own transaction pays for it. Wallet simulation would
  normally catch that, but ERC-2771 destroys it (the buyer signs a `ForwardRequest` whose `data` is opaque
  bytes), so an EIP-712 payload with named fields is what restores the protection.
- **There is no venue, selector, asset or currency allowlist on-chain.** Decided 2026-08-13 after three
  rounds of narrowing. What absorbs the loss instead is the per-transaction settlement cap
  (`SettlementLimits`) plus the fact that the buyer's allowance to the router is an exact amount for one
  transaction, never a standing grant.
- **This router holds no minting right on any path.** Our own issuance is routed through a per-token sale
  contract called exactly as a third-party venue is. That sale contract is **AO-137 and lives outside this
  repository**; to this router it is just an address in a signed intent. The security argument for that
  split is written out at length at the top of `AsseteraPrimarySales.sol` and is worth reading.

## Audit target (frozen commit)

Please audit a **single frozen commit**. We tag a dedicated release for the engagement (e.g. `audit-v1`);
confirm the exact commit hash with us before starting rather than tracking a moving branch. `main` is
protected, linear-history and squash-merged, so the tag is stable.

Every figure below was reproduced from this worktree with the commands shown. Re-measure if you are handed
a different commit.

## In scope

The primary-sales surface under `contracts/src/primary/` — **9 files, 1,976 LoC**:

```bash
find src/primary -name '*.sol' | xargs wc -l
```

| File | LoC | Role |
|---|---:|---|
| `src/primary/AsseteraPrimarySales.sol` | 482 | UUPS proxy entrypoint; assembles the modules; `initialize`; the frozen `settlePrimary` entry point; the fail-CLOSED `complianceRequired` override; admin surface (collector allowlist, compliance toggle, pause, `whitelistHandshake`) |
| `src/primary/settle/VenueSettler.sol` | 415 | **The money path.** Snapshot / pull / measure / approve / call venue / revoke / measure / refund / forward / assert delivery / pay fee / assert zero standing balance |
| `src/primary/admin/SettlementLimits.sol` | 239 | Per-token per-transaction value cap in whole units; `_authorizeSettlement`, the shared preamble every settlement path must run; defensive `decimals()` probing |
| `src/primary/IntentGate.sol` | 228 | The third gate: EIP-712 settlement-intent verification (operator + buyer), TTL, single-use nonce, calldata/selector binding, attestation binding |
| `src/primary/types/PrimaryTypes.sol` | 169 | `Action` enum, the frozen `SettlementIntent` struct (14 static members), `INTENT_TYPEHASH`, `SettlementResult` |
| `src/primary/interfaces/ISettler.sol` | 136 | The frozen `PrimarySettled` event and the settlement errors |
| `src/primary/storage/PrimaryStorage.sol` | 123 | Router state in its own ERC-7201 namespace; `SETTLEMENT_OPERATOR_ROLE` |
| `src/primary/interfaces/ISettlementLimits.sol` | 105 | Interface |
| `src/primary/interfaces/IIntentGate.sol` | 104 | Interface |

One more **external entry point** on this proxy does not live under `src/primary/` at all, because it is
shared with the exchange. It is in scope for this engagement and must be read with the table above:

| File | LoC | Role |
|---|---:|---|
| `src/core/PermitRelay.sol` | 138 | `permitAndCall`: ERC-2612 `permit` + one self-`delegatecall`, so a primary purchase is one transaction rather than approve-then-settle (AO-298 on the exchange, extended to this router by AO-713). One implementation, inherited by both proxies. Sectioned below. |

LoC is raw `wc -l` (including licence header, NatSpec and blank lines). NatSpec is a large share of it on
this surface: the design rationale is deliberately in the files rather than in a separate spec.

### ⚠️ Six files this contract compiles in are listed under the OTHER document

The router inherits the exchange's gate stack and its permit relay, and calls its fee library. The
inheritance chain is:

```
GateTypes
  └─ PrimaryTypes                                        (src/primary/types/)
GateStorage  ─ KycGate ─ FeeGate
  └─ PrimaryStorage  ─ IntentGate ─ SettlementLimits ─ VenueSettler ─┐
ContextUpgradeable                                                   ├─ AsseteraPrimarySales
  └─ PermitRelay                                    (src/core/)     ─┘
```

So `src/types/GateTypes.sol`, `src/gates/GateStorage.sol`, `src/gates/KycGate.sol`,
`src/gates/FeeGate.sol`, `src/libs/FeeMath.sol` and `src/core/PermitRelay.sol` (**570 LoC together**) are
**inside this proxy's deployed bytecode** even though they are enumerated in
[`AUDIT-SCOPE-SECONDARY.md`](AUDIT-SCOPE-SECONDARY.md). An engagement scoped to this document should read
them, and any finding in them lands on **both** deployed proxies.

`PermitRelay` joins that list under AO-713 and is the only one of the six that adds an **external
function** to this proxy rather than internal machinery, which is why it also has a section of its own
below. Its base was `ExchangeStorage` until AO-713 and is now `ContextUpgradeable`: the file touches no
storage on either proxy, so the exchange's storage root was incidental, and the rebase is what lets one
implementation serve both routers instead of a copy under `src/primary/` drifting away from it.
`bash script/storage-layout.sh` reports **both** snapshots unchanged across that rebase, byte for byte.

Three shared-code behaviours that matter specifically here:

1. **`FeeGate._validateFees` is called with the settlement token in BOTH leg positions.** Its leg test is
   `feeToken != legA && feeToken != legB`, so one token in both positions collapses it into the strict
   "the fee must be denominated in the settlement currency" rule this path wants. A fee attested in the
   **asset** token therefore reverts `FeeTokenNotALeg(feeToken)`. This is deliberately a call rather than a
   restatement: `_validateFees` is the one place the estate tightens fee policy, and a private copy here
   would let the next tightening apply to the exchange only.
2. **`GateStorage.complianceRequired` is a fail-OPEN mapping — and this router inverts it.** See the next
   section; it is the single most important shared-code interaction on this surface.
3. **`PermitRelay.permitAndCall` can delegate into ANY function on this proxy**, admin surface included,
   with the caller's own `_msgSender()`. It reaches nothing the caller could not already reach directly;
   the argument, and where each half of it is pinned, is in its own section below.

## The fail-closed compliance gate (read carefully)

`GateStorage` stores `mapping(uint8 action => bool required) complianceRequired`. An action nobody wrote
reads `false`, and `KycGate._verifyKyc` returns on its **first line** when it does. On the exchange that is
held safe by an initializer that enumerates every action plus a test that re-enumerates them.

On a primary-sales router a single ungated action is an **unscreened first acquisition of a security**, so
`AsseteraPrimarySales` overrides the getter:

```solidity
function complianceRequired(uint8 action) public view override returns (bool) {
    return !_primary().complianceExempt[action];
}
```

- The router stores the **inverse** — an exemption — in its **own** ERC-7201 namespace, where the zero
  value means "not exempt". Every `uint8`, declared or not, is gated from the moment the proxy is
  initialised, with **nothing written at initialization** and nothing to keep in step with the enum.
  `test_ComplianceGate_IsClosedForEveryOrdinal` fuzzes all 256 ordinals.
- `setComplianceRequired(action, required)` keeps its external signature, event and observable behaviour;
  it writes `complianceExempt[uint8(action)] = !required`.
- ⚠️ **Consequence worth an auditor's attention: `_gate().complianceRequired` is DEAD storage for this
  proxy.** Nothing reads it. A future module that reads the mapping instead of calling the getter would
  silently reopen the gate. The `virtual` keyword on the base getter is the whole of the shared change, and
  every gate reaches the policy through the function (`_verifyKyc`, `_consumeKyc`, `_consumeKycAndFee`,
  `_bindParamsHash`), so the override binds all of them.
- The exchange does **not** override the getter, so its live mapping is read exactly as before.

`Action` has three ordinals: `None` (0, never accepted), `SettleVenue` (1, the only reachable one) and
`SettleMint` (2, **reserved and unreachable** — nothing in `src/` runs under it). Holding a reserved
ordinal is only safe because of the fail-closed override above; the NatSpec says so explicitly.

## Out of scope

| Path | Why |
|---|---|
| `src/` outside `src/primary/` (15 files, 2,146 LoC) | The **other** audit surface, `AsseteraECS`. Scoped in [`AUDIT-SCOPE-SECONDARY.md`](AUDIT-SCOPE-SECONDARY.md). Note the six-file exception above: `GateTypes`, `GateStorage`, `KycGate`, `FeeGate`, `FeeMath` and `PermitRelay` are compiled into **this** proxy and should be read. `PermitRelay` is the one that also puts an external function on this proxy. |
| The per-token **sale contract** that fronts our own issuance | **AO-137, outside this repository and not yet built.** To this router it is an address in a signed intent, indistinguishable from Backed or Dinari. Nothing here changes when it lands. It is, however, the only control that bounds a compromised settlement signer for our own issuance — see the argument at the top of `AsseteraPrimarySales.sol`. |
| `test/primary/**` — the suites and mocks (`CappedPrimarySalesHarness.sol`, `ContractWalletBuyer.sol`, `HostileVenue.sol`, `HostileWallets.sol`, `PrimarySalesHarness.sol`, `PrimaryWeirdTokens.sol`) | Tests and mocks, not deployed bytecode. |
| `test/**` (exchange suites and mocks) | Tests and mocks. |
| `script/**` (`Deploy.s.sol`, `DeployBase.sol`, `DeploymentFile.sol`, `Verify.s.sol`, `UpgradeCalldata.s.sol`, `AdminCalldata.s.sol`, `storage-layout.sh`, `struct-layout.py`) | Deployment / verification / upgrade-safety tooling, not deployed bytecode. Reviewing the deploy story is welcome; note the upgrade-guard asymmetry flagged below. |
| `docs/parked/OperatorFunctions.sol` | Parked, not compiled, not deployed. Belongs to the exchange. |
| `lib/**` | Pinned dependencies (see below). |
| `packages/sdk/**`, `examples/**` | TypeScript SDK and consumer examples (in the monorepo, not the Foundry project). |

## Build & test

```bash
cd contracts
forge build                          # Solidity 0.8.28, via-IR, optimizer 200 runs — clean
forge test                           # BOTH surfaces: 457 tests across 40 suites, all passing
forge test --match-path 'test/primary/*'   # THIS surface: 200 tests across 31 suites
forge coverage --ir-minimum --no-match-coverage '(script|test)'
bash script/storage-layout.sh        # upgrade-safety guard; must print "storage layout unchanged"
slither .                            # BOTH surfaces: 43 results, all triaged benign
```

**Test suite for this surface — 200 tests, 0 failures, 31 suites**
(`forge test --match-path 'test/primary/*'`):

| File | Suites | Tests | What it covers |
|---|---:|---:|---|
| `test/primary/AsseteraPrimarySales.t.sol` | 6 | 69 | Init (13), entry point (24), admin (14), buyer consent (10), EIP-712 domain (4), settled state (4) |
| `test/primary/VenueSettlerHostile.t.sol` | 8 | 40 | A lying venue (10), reentrancy (7), fee-on-transfer currency (5), cap boundary (5), rebasing asset (4), venue identity (4), silent transfers (3), sender surcharge (2) |
| `test/primary/VenueSettler.t.sol` | 5 | 29 | Happy path (8), reverts (8), hardcoded fee vectors (7), limits (4), refunds (2) |
| `test/primary/SettlementLimits.t.sol` | 6 | 27 | `decimals()` handling (7), admin (6), enforcement (5), through the entry point (4), applies to every family (3), storage (2) |
| `test/primary/PrimarySalesAdversarial.t.sol` | 4 | 26 | Replay (12), hostile wallet / ERC-1271 (6), meta-transaction (5), buyer-consent replay (3) |
| `test/primary/PrimaryStorageNamespace.t.sol` | 1 | 5 | ERC-7201 namespace derivation and slot reads |
| `test/primary/PrimaryIntentVectors.t.sol` | 1 | 4 | Hardcoded `INTENT_TYPEHASH` / digest vectors, cross-repo pinning |

> The whole repository runs **457 tests across 40 suites**; the remaining 257 in 9 suites belong to the
> exchange. Earlier documents, including `docs/SECURITY-REVIEW-2026-07-14.md`, quote **129** — that figure
> predates this contract entirely and should not be used.

**Coverage** (`forge coverage --ir-minimum --no-match-coverage '(script|test)'`). `--ir-minimum` is
**required** — plain `forge coverage` disables the optimizer and via-IR and fails "stack too deep" in
`OfferBook.replaceOffer`. The run reports both surfaces in one table; the rows for this surface are:

| File | % Lines | % Statements | % Branches | % Funcs |
|---|---:|---:|---:|---:|
| `src/primary/IntentGate.sol` | 100.00 (30/30) | 100.00 (50/50) | 100.00 (16/16) | 100.00 (5/5) |
| `src/primary/admin/SettlementLimits.sol` | 100.00 (32/32) | 100.00 (40/40) | 100.00 (6/6) | 100.00 (6/6) |
| `src/primary/settle/VenueSettler.sol` | 97.44 (38/39) | 95.71 (67/70) | 81.82 (9/11) | 100.00 (3/3) |
| `src/primary/AsseteraPrimarySales.sol` | 82.35 (42/51) | 83.33 (45/54) | 100.00 (4/4) | 93.33 (14/15) |
| `src/primary/storage/PrimaryStorage.sol` | 75.00 (3/4) | 50.00 (1/2) | n/a (0/0) | 100.00 (2/2) |
| **Subtotal (this surface)** | **92.95 (145/156)** | **93.98 (203/216)** | **94.59 (35/37)** | **96.77 (30/31)** |

Reading the residue honestly:

- `AsseteraPrimarySales.sol` at 82 % lines is the lowest figure in the repository. Most of it is the
  ERC-2771 / UUPS plumbing (`_msgData`, `_contextSuffixLength`) that OZ requires but the router's own paths
  never take, plus the `whitelistHandshake` failure branch. **It is lower than the exchange's entry point
  and is the file with the most admin surface. Worth a look.**
- `VenueSettler.sol` **branch** coverage is **81.82 % (9/11)** — the weakest branch figure on either
  surface, on the file that moves the money. Two branches are unexercised.
- `PrimaryStorage.sol`'s missed line is `$.slot := PRIMARY_STORAGE_LOCATION` inside the ERC-7201 accessor:
  solc's coverage instrumentation does not reach into inline assembly, so it can never be marked hit. What
  it does is pinned directly by `test/primary/PrimaryStorageNamespace.t.sol`.

`forge build` is clean; the only lint output is `block-timestamp` warnings on TTL comparisons (benign).

## The money path, step by step (`VenueSettler._settleVenue`)

The file's own NatSpec is the authoritative description; this is the map.

| Step | What happens | Notable |
|---:|---|---|
| 0 | Structural guards: `intent.venue` may be neither `settlementToken` nor `assetToken` (`VenueIsASettledToken`); buyer-fee cross-check | Two comparisons against fields of the **same** intent, not a list |
| 1 | *(value cap already charged by `SettlementLimits._authorizeSettlement`, before this function is entered)* | Deliberate: a cap each path opts into is not a cap |
| 2 | Snapshot `assetToken.balanceOf(buyer)`, and the router's **own** currency **and** asset balances | Against pre-call balances, not zero, so a third party's donation is never handed to the next buyer |
| 3 | `safeTransferFrom(buyer, this, venueQuoteIn + buyerFee)` and **measure what arrived** | `SettlementPullMismatch(requested, received)` on any difference — see the token section |
| 4 | `forceApprove(venue, venueQuoteIn)` then `venue.call(venueCalldata)` | `buyerFee` is deliberately **not** in the approval; the venue's revert data is not bubbled (`VenueCallFailed`) |
| 5 | `forceApprove(venue, 0)` unconditionally, then measure consumption | `held` must lie in `[routerBefore + buyerFee, routerBefore + received]`, else `RouterBalanceChanged` |
| 6 | Refund `venueQuoteIn − venueIn` to the buyer | Consuming less than approved is normal, not an error |
| 7 | Forward any **increase** in the router's asset balance to the buyer, then assert `delivered >= minAssetOut` | `InsufficientAssetDelivered`. Forwarding happens **before** the delta is measured, so a venue that splits delivery does not fail the floor |
| 8 | `safeTransfer(feeCollector, buyerFee)` | |
| 9 | Assert **both** the currency and the asset balance returned to their pre-call values | `RouterBalanceChanged`. Made once, last, where it is strongest |
| 10 | Return the four **measured** numbers into `PrimarySettled` | Every amount is measured; every identifier is one the operator signed |

### Economics

- **`buyerFee` is charged ON TOP of `venueQuoteIn`**, in the settlement currency, never carved out of it.
- **Two independent signers must agree on one number.** `_assertBuyerFee` requires
  `intent.buyerFee == FeeMath.feeAmount(intent.venueQuoteIn, fee.takerFeeBps)` — the settlement operator's
  number against the fee service's basis points — or reverts `BuyerFeeMismatch(attested, expected)`.
  Without it the settlement signer alone decides the fee and the attested bps are decorative.
- **Floor rounding, deliberately.** `FeeMath.feeAmount` floors, matching every other fee calculation in the
  estate. It is an interop contract with `AsseteraSignerService` and `AsseteraMarketplaceAPI`: a one-wei
  disagreement would revert every settlement whose fee does not divide exactly. Pinned by hardcoded vectors
  in `test/primary/VenueSettler.t.sol`.
- **A maker fee is refused outright.** `if (fee.makerFeeBps != 0) revert MakerFeeNotSupported();` — the
  router does not control the proceeds side, so an issuer-side fee cannot be charged. It is checked
  **before** `_bindAttestations` on purpose, so the revert names the real defect rather than
  `FeeCollectorNotAllowed`. Pinned by
  `test_SettlePrimary_RejectsANonZeroMakerFeeBeforeTheCollectorChecks`.
- **The collector allowlist is this proxy's own and starts EMPTY.** The exchange's entries do not carry
  over. A non-zero fee cannot settle until a collector is listed here.
- **An unset settlement cap is CLOSED.** `_consumeSettlementLimit` treats `cap == 0` as "this token cannot
  settle at all" — the explicit zero test is not redundant with the `>` comparison, because a zero debit
  against a zero cap would pass `0 > 0`. Every settlement currency needs an explicit `setSettlementCap`
  before the first sale in it can succeed. The number charged is the **full authorised debit**
  (`venueQuoteIn + buyerFee`), not the net one, because the refund is not known before the venue is called.

## Token limitations — what may and may not settle here

**Policy: standard ERC-20 only. No fee-on-transfer, no rebasing, no deflationary or elastic supply** — the
same policy as the exchange. What differs is that on this surface a fee-on-transfer **currency** is
enforced **on-chain**.

| Behaviour | Settlement currency | Asset token |
|---|---|---|
| Standard ERC-20 | **Supported** | **Supported** |
| Fee-on-transfer / deflationary | **Refused ON-CHAIN.** Step 3 measures the pull; anything other than the exact amount reverts `SettlementPullMismatch`. A deflationary settlement currency simply cannot settle | **Refused on-chain in effect.** Step 9 asserts the router's asset balance returned to its pre-call value, which fails if the step-7 forward moved less than it was asked to |
| Rebasing | **Refused on-chain in effect** (the same pull measurement) | **Partially unsafe — see below** |
| Missing / non-decodable `decimals()` | **Cannot be capped**, therefore cannot settle. `SettlementLimits._tokenDecimals` uses a low-level `staticcall` rather than `try`, because `try` does not catch a contract that returns undecodable data; both cases fail closed with `TokenDecimalsUnavailable` / `TokenDecimalsImplausible` (bound: 36 decimals) | Never read |
| Freezable / blacklistable (USDC and friends) | **Supported but hazardous** — this is what production actually uses | **Supported but hazardous** |

⚠️ **Production settlement will be real USDC on Polygon mainnet.** USDC is neither fee-on-transfer nor
rebasing, so the on-chain measurement above will not fire in normal operation; it is freezable and
blacklistable, which is the live operational risk on the exact token we intend to settle in.

### The rebasing-asset limitation, stated honestly

The delivery assertion is a **balance delta on the buyer**, and the venue is arbitrary code that can call
the asset token during its own execution. The three tests in `VenueSettlerRebasingAssetTest`
(`test/primary/VenueSettlerHostile.t.sol`) pin what is actually true:

- A rebase **before** the call contributes nothing — the snapshot is taken inside the call rather than
  carried across blocks (`test_Rebasing_ARebaseBeforeTheCallIsOutsideTheMeasurement`). Any path that holds
  a rebasing asset **across blocks** and reasons about a raw balance is still wrong.
- A rebase **during** the call **is counted as delivery**
  (`test_Rebasing_ARebaseDuringTheCallIsCountedAsDelivery`: the venue takes the whole quote, delivers
  nothing, rebases the buyer's existing position up by 10 % and clears the floor). Nothing on-chain can
  distinguish it from an honest transfer, because both are only a balance delta.
- The practical bound: it grants a venue that **fully controls** the asset token nothing new, since such a
  venue could simply mint to the buyer — and minting to the buyer *is* honest delivery. Where it bites is a
  genuinely rebasing asset whose rebase the venue can trigger but does not control, **and** it additionally
  requires the buyer to already hold a position in that asset, which a primary sale usually does not
  (`test_Rebasing_TheSameVenueIsRefusedWhenTheBuyerHoldsNoPosition`).

**Reported rather than patched.** The venue and the asset are both named in an intent the buyer signed, and
there is no on-chain check that separates the two cases. We would welcome a view on whether that is the
right trade.

### ⚠️ This surface and the exchange take OPPOSITE positions on the same risk

An auditor will notice this immediately, so it is stated up front rather than left to be discovered.

- **This contract measures balance deltas.** `VenueSettler` snapshots its own balances and the buyer's
  asset balance, measures what actually arrived, and reverts `SettlementPullMismatch` when the currency
  delivered anything other than what was debited. **Both** legs are measured, and both the settlement-leg
  measurement and the asset-side zero-standing-balance assertion were added **on review of PR #58** — the
  first version measured only the asset leg, and its failure was not clean: it failed closed only when the
  venue happened to ask for the whole quote, and otherwise settled while misreporting (the token's own burn
  counted as venue consumption, the collector credited below the attested fee, both silently).
- **The exchange escrow does none of this.** There is no `balanceOf` measurement anywhere in
  `src/core/OrderBook.sol` or `src/core/OfferBook.sol` — confirmed on this commit by grep. Standard ERC-20
  semantics are treated there as an invariant enforced **off-chain**, because the token addresses are bound
  into the signed `paramsHash`. That is exchange finding **M-1**, formally **accepted on 2026-07-15 as
  documentation-only**: recommendation #3, balance-delta accounting, was explicitly declined.
- The exchange's four weird-token tests (`test_TokenSafety_FeeOnTransfer_EscrowOverstatedAtPlacement`,
  `test_TokenSafety_FeeOnTransfer_PoolInsolvency_LastCancellerReverts`,
  `test_TokenSafety_Rebasing_NegativeRebaseCausesInsolvency`,
  `test_TokenSafety_FeeOnTransfer_AcceptOfferShortfall`, all in `test/AsseteraECS.t.sol`) **document the
  insolvency rather than prevent it** — they pass by asserting the bad outcome happens.
- **The divergence is history, not a considered symmetry.** The exchange shipped first; this contract was
  written afterwards and tightened during its own review. Whether the two should be brought in line is a
  legitimate question for this engagement.

## The four signatures and three nonce namespaces

| Signature | Signer | Checked against | Nonce namespace |
|---|---|---|---|
| Settlement intent | `SETTLEMENT_OPERATOR_ROLE` | `hasRole(...)` after `ECDSA.recover` → `IntentBadSigner` | `usedIntentNonce[buyer][nonce]` |
| The **same** intent digest | The **buyer** | `SignatureChecker.isValidSignatureNow(intent.buyer, digest, sig)` — EOA **or ERC-1271** → `BuyerConsentBadSignature` | shares the intent nonce |
| KYC attestation | `KYC_OPERATOR_ROLE` | shared `KycGate._verifyKyc` | `usedNonce[account][nonce]` |
| Fee attestation | `FEE_OPERATOR_ROLE` | shared `FeeGate._verifyFee` | `usedFeeNonce[account][nonce]` |

- **All four are verified before any nonce is burned**, so an invalid one cannot spend the others.
- **One digest, two signers.** There is deliberately no separate `BuyerConsent` struct: a mirror struct
  drifts, one payload cannot. `INTENT_TYPEHASH` is unchanged by the buyer-signature addition; only the
  `settlePrimary` selector moved.
- **Buyer consent is taken inside `_verifyIntent`, not in the entry point**, so no future entry point can
  acquire intent verification without also acquiring the buyer's consent.
- **`orderId` is passed as a literal zero** into the KYC gate. There is no order book on this path, and a
  non-zero `orderId` on the attestation is rejected (`KycOrderMismatch`) rather than left as a second
  unchecked degree of freedom in a signature the compliance signer produces.
- **The action ordinal is hardcoded** to `Action.SettleVenue` in `settlePrimary`, never taken from the
  caller or the intent — letting a request choose it would let a request choose which compliance policy it
  is screened under.
- **`_bindAttestations` binds BOTH `paramsHash` values unconditionally**, unlike the shared
  `FeeGate._bindParamsHash` which makes the KYC half conditional. It also cross-checks
  `feeAtt.feeCollector == intent.feeCollector`, which `_validateFees` cannot do because it has no intent to
  compare against.

### Intent validation (`IntentGate._verifyIntent`)

`intent.buyer == _msgSender()` (ERC-2771 aware, so nobody settles on somebody else's behalf); no zero
addresses; `assetToken != settlementToken`; `minAssetOut != 0` (`ZeroAmount` — a zero floor makes the
post-call assertion vacuous); `venueQuoteIn != 0` (`ZeroVenueQuote` — the mirror image, "pay nothing,
receive something", which no other check catches because a zero debit passes every value check);
`maxSettlementIn >= venueQuoteIn + buyerFee` under checked arithmetic; `deadline` not passed and not more
than `MAX_INTENT_TTL` (15 minutes) ahead; nonce unused.

⚠️ **A genuinely free distribution — a promotional allocation — has exactly the shape `ZeroVenueQuote`
forbids.** That is the deliberate safe default: the intent a giveaway signs and the intent a compromised
settlement signer signs are indistinguishable on-chain.

### Calldata binding

`_bindCalldata` requires `keccak256(venueCalldata) == intent.calldataHash` **and**
`bytes4(venueCalldata) == intent.selector`. The `bytes4` cast is safe because the exact bytes are already
pinned by the hash check; calldata shorter than four bytes is zero-padded rather than truncated, and the
signer would have had to sign both that padded selector and the hash of those short bytes.

The signed payload is typed fields; the opaque bytes ride along bound by hash. ADR-0020 D5 rejected a blind
signing oracle by name.

## The one-transaction purchase (`permitAndCall`, AO-713)

`src/core/PermitRelay.sol` adds one external function to this proxy, `permitAndCall`, which runs an
ERC-2612 `permit` for the caller and then `delegatecall`s one function on this same contract. On this
surface the function it is meant to wrap is `settlePrimary`, and the win is not mainly gas: an `approve`
takes 15-30 seconds to mine, a firm venue quote is not good for that long, and the storefront therefore had
to keep the approval off the quote's clock and confirm a purchase in two phases. A permit is a signature,
so the constraint disappears rather than shrinking.

**No new selector, and `settlePrimary` is unchanged.** `permitAndCall` is already generic over the call it
wraps, so extending it to this router was an inheritance-list change and nothing else. The struct, the
typehash, the digests, every attestation in flight and the `PrimarySettled` event are exactly what they
were, which matters because the signer service, the marketplace API and the indexer all consume them.

**One implementation, two proxies.** The same file is compiled into `AsseteraECS`, where it has been live
since AO-298. Its base was rebased from `ExchangeStorage` to `ContextUpgradeable` to make that possible;
the file declares and reads no storage, so nothing moved. `bash script/storage-layout.sh` reports both
snapshots unchanged.

It is a **self-`delegatecall` with caller-supplied calldata**, which we expect a reviewer to want to look at
closely. The claims we make about it on THIS surface, and where each is pinned
(`test/primary/PermitAndSettle.t.sol`, 14 tests):

1. **No privilege escalation.** Authorisation on this router is `_msgSender()` throughout — the role checks
   included — and `permitAndCall` re-appends the ERC-2771 sender suffix to `data` before delegating (the
   same detection OpenZeppelin's `Multicall` uses: `msg.sender != _msgSender()` means the call arrived
   through the trusted forwarder). The inner function therefore resolves the same actor it would have
   resolved on a direct call, relayed or not. Pinned by
   `test_PermitAndSettle_Relayed_IdentityIsTheBuyerNotTheRelayer` and
   `test_PermitAndSettle_CannotReachAdminFunctionsWithoutTheRole`.
2. **`IntentGate` is unchanged and still binding.** `intent.buyer == _msgSender()` holds through the
   `delegatecall`, so the permit `owner`, the caller and the party debited are structurally one address.
   A third party cannot carry somebody else's permit into a settlement: `_tryPermit` names `_msgSender()`
   as the owner, so their call presents their own permit, and the settlement is then refused outright with
   `IntentBuyerMismatch`. Pinned by `test_PermitAndSettle_AStrangerCannotCarryTheBuyersPermit`.
3. **The reentrancy guard still holds.** `permitAndCall` is deliberately NOT `nonReentrant` — taking the
   guard here would make `settlePrimary`'s own guard revert the inner call — and the one external call it
   makes before delegating is `token.permit` on a caller-chosen address, at which point it holds no state
   and has moved no funds. The guard that must hold is the inner one, including when the permit token is
   the one re-entering. Pinned by `test_PermitAndSettle_ReentrantTokenCannotReenterSettlePrimary`, and the
   happy-path tests are the mutation check: a guard on the wrapper would take all of them red.
4. **The pause lever is not routed around.** `whenNotPaused` sits on `settlePrimary`, which is what the
   relay delegates into. Pinned by `test_PermitAndSettle_IsStoppedByThePauseLever`.
5. **No `msg.value` to double-spend.** The classic multicall bug does not apply: `permitAndCall` is not
   payable, so `msg.value` is zero on every path through it and a `delegatecall` cannot conjure one. This
   router does have one payable function, `whitelistHandshake`, unlike the exchange — it is
   `DEFAULT_ADMIN_ROLE`-only and would forward the same zero.
6. **Permit failure stays swallowed**, exactly as on the exchange, so adding the relay cannot take a
   settlement currency away from this router. The first return value, `permitAccepted`, makes the failure
   observable on simulation instead of silent. Three real cases need the swallow and each is tested here
   against a real settlement: a token with no ERC-2612 at all
   (`test_PermitAndSettle_TokenWithoutErc2612_FallsBackToAllowance`), a signature that does not recover
   (`test_PermitAndSettle_SignatureThatDoesNotRecover_DoesNotRevertTheSettlement`), and a token whose
   EIP-712 domain name is not its `name()` — EUROP's shape, `DivergentDomainToken`, two tests. The faucet
   tokens on playground pass their own `name()` to `ERC20Permit`, so playground cannot reproduce the
   divergence; the mock exists for exactly that reason. The one failure that is NOT swallowed is a `token`
   address with no code, because Solidity's `extcodesize` check happens outside the `try`
   (`test_PermitAndSettle_CodelessTokenAddressReverts`).
7. **The buyer's allowance stays exact and short-lived.** The permit grants one settlement's worth and the
   settlement spends it to zero, so the ceiling on a compromised settlement signer is unchanged — a permit
   must not quietly turn an exact grant into a standing one. Pinned by
   `test_PermitAndSettle_LeavesNoStandingAllowance`.

`controlled-delegatecall` does not fire in Slither because the delegatecall target is `address(this)`, not
caller-supplied.

⚠️ **This route is EOA-only, and the two-transaction route has to stay.** ERC-2612 `permit` takes a
`(v, r, s)` and OpenZeppelin's `ERC20Permit` recovers it with `ECDSA.recover`, so a contract wallet cannot
present one. This router does accept an ERC-1271 buyer signature on the intent itself
(`test/primary/mocks/ContractWalletBuyer.sol`), so a smart-account buyer can settle — but only after a
separate `approve`. Removing the plain-allowance path would silently exclude them.

⚠️ **The client obligation is real and is not on this contract.** A permit signed against a domain the
token does not verify against is silently rejected, and the settlement then fails on the allowance. The
domain must be resolved from the token rather than assumed to be its `name()`; the package ships
`resolvePermitDomain` for that.

## Storage & upgrade safety

- All router state lives in its own ERC-7201 namespace via `PrimaryStorage._primary()`, separate from the
  shared gate namespace: `usedIntentNonce`, `settlementPerTxCap`, `settlementPerTxCapWholeUnits`,
  `complianceExempt`.
- A committed snapshot, `storage/AsseteraPrimarySales.txt`, is diffed in CI on every PR by
  `script/storage-layout.sh`. On this commit it prints:

```
✅ AsseteraECS storage layout unchanged
✅ AsseteraPrimarySales storage layout unchanged
```

⚠️ **Upgrade-guard asymmetry worth flagging.** `DeployBase.INPLACE_UPGRADE_ALLOWED` is `false` on this
commit and blocks in-place upgrades of the **exchange** proxy. It deliberately does **not** gate this one:
`Deploy.s.sol` calls `AsseteraPrimarySales(proxy).upgradeToAndCall(impl, "")` whenever the implementation
bytecode differs, with no equivalent guard. The stated reason is that the constant records the exchange's
AO-514 layout break and says nothing about this contract. `DeployBase._saltVersion` likewise gives
`AsseteraPrimarySales.*` no salt version of its own. Both notes say "give it one at the first storage-layout
break after it is live" — and it **is** live on two testnets now, so that follow-up is outstanding.

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

## Static analysis (Slither)

Config: [`slither.config.json`](slither.config.json) (filters `lib/`, `test/`, `script/`). Run: `slither .`
from `contracts/`. Current result across **both** surfaces: **57 contracts, 101 detectors, 43 results — all
triaged benign.** Of those, **15 are attributable to this surface**:

| Detector | Count | Location | Verdict |
|---|---:|---|---|
| `reentrancy-balance` | 4 | `VenueSettler._settleVenue` — `routerBefore`, `received`, `buyerAssetBefore`, `routerAssetBefore` read before `venue.call` and used in conditions after it (`VenueSettler.sol:232-234`, `:253`, `:291`, `:345`, `:358-359`) | **By design, and the detector is pointing at the actual mechanism.** Measuring across the untrusted call is the whole technique: the snapshots are *supposed* to predate it. The call is wrapped by `settlePrimary`'s `nonReentrant` and the intent nonce is already burned, so the venue cannot re-enter or replay. Exercised directly by `VenueSettlerReentrancyTest` (7 tests) and `VenueSettlerLyingVenueTest` (10 tests). **The single most useful thing to review on this contract.** |
| `low-level-calls` | 3 | `VenueSettler` venue call (`:270`), `SettlementLimits._tokenDecimals` `staticcall` (`:229`), `AsseteraPrimarySales.whitelistHandshake` (`:413`) | All three are deliberate and documented: opaque venue bytes; a `staticcall` because `try` does not catch undecodable return data; a `call` rather than `transfer` because a venue's nominated address is as likely to be a Safe as an EOA. |
| `cyclomatic-complexity` | 2 | `IntentGate._verifyIntent` (12), `VenueSettler._settleVenue` (13) | Accepted. `_settleVenue` is the highest in the repository and is a focused-review target. |
| `arbitrary-send-erc20` | 1 | `currency.safeTransferFrom(intent.buyer, address(this), debit)` (`:241`) | **False positive** — `intent.buyer` has already been checked equal to `_msgSender()` in `_verifyIntent`, and the buyer signed the intent. You can only pull from yourself. |
| `reentrancy-events` | 1 | `whitelistHandshake` emits after the `call` | Admin-only, no state read or written, nothing to protect. |
| `assembly` | 1 | `PrimaryStorage._primary()` (`:101-106`) | The ERC-7201 namespaced-storage accessor idiom. |
| `timestamp` | 1 | `IntentGate._verifyIntent` deadline / `MAX_INTENT_TTL` | Benign — validator drift is immaterial against a 15-minute window. |
| `dead-code` | 1 | `AsseteraPrimarySales._msgData` | OZ-required ERC-2771 override. |
| `naming-convention` | 1 | `IIntentGate.MAX_INTENT_TTL()` | Getter mirrors a public constant. |

No high- or medium-severity true positives, but note that unlike the exchange this triage has **not** been
through an independent review.

The remaining 28 results belong to the exchange and are triaged in
[`AUDIT-SCOPE-SECONDARY.md`](AUDIT-SCOPE-SECONDARY.md).

## Trust model & centralization (by design — regulated venue)

Four roles on this proxy, all separate grants from the exchange's (same identifiers, different
`AccessControl` storage):

- **`SETTLEMENT_OPERATOR_ROLE` — the one that matters, and it does not exist on the exchange.** It is the
  only role whose holder can cause a transfer. ⚠️ **Give it its own key.** What bounds a compromise:
  - the **buyer's own signature** over the same intent — a settlement the buyer did not sign cannot happen;
  - the buyer's allowance to the router, which is an exact amount for one transaction and never a standing
    grant, making the loss ceiling one transaction *structurally* rather than by policy;
  - the **per-transaction settlement cap**, which is closed until an admin sizes it;
  - `MakerFeeNotSupported` and the `_assertBuyerFee` cross-check, which stop the operator inventing a fee;
  - for our **own issuance**, the per-token sale contract (AO-137, outside this repo), which is the only
    control that bounds the signer where the venue is ours: an intent with a zero quote makes the sale
    contract's own pull from this router fail, so nothing is minted. **The signer cannot mint without
    paying, whatever they sign.**
- **`KYC_OPERATOR_ROLE`** signs KYC attestations. Cannot set or redirect fees.
- **`FEE_OPERATOR_ROLE`** signs fee attestations. Bounded by `MAX_FEE_BPS` and this proxy's own
  `allowedCollectors` allowlist, and cross-checked against the intent's collector.
- **`DEFAULT_ADMIN_ROLE`** is effectively full custody: `upgradeToAndCall` to arbitrary logic, the
  settlement caps, the collector allowlist, the compliance exemptions, pause, and `whitelistHandshake`.
  **Mainnet requirement:** a Safe multisig, plus a timelock on upgrades. See the open item below.

Identity is resolved through `_msgSender()` (ERC-2771) with the **same trusted forwarder address as the
exchange**, so a gasless primary sale works the way a gasless order does.

**`whitelistHandshake` is pass-through only, by design.** There is deliberately no `receive()` and no
sweep: a stray value transfer to this router still reverts, nothing accumulates by accident, there is no
sweep function to get the access control on, and the zero-standing-balance invariant stays a flat
statement. If a venue ever needs the router to receive rather than send, that is a new decision with a new
threat model.

## Mainnet target

Production is **Polygon mainnet, chain id 137**. This proxy is not deployed there yet: the SDK carries
deployment records for `80002` (Polygon Amoy) and `11155111` (Ethereum Sepolia) only.

The open-mint faucet tokens (`MockUSDC` / `MockRWA`) are **structurally excluded from a mainnet deploy**:
`DeployBase._isTestnet` (`script/DeployBase.sol:136-138`) returns true only for `31337`, `80002` and
`11155111`, and `Deploy.s.sol:69` reads `vm.envOr("DEPLOY_MOCKS", _isTestnet(chainId))`. On chain 137 the
default is `false`. The `DEPLOY_MOCKS` environment variable can override it, so the guard is a safe default
rather than an absolute bar.

## Known open items on this surface

Not findings from a review — there has been none — but things we know and have decided about.

1. **No independent review of this contract.** Stated at the top. This is the item.
2. **No functional specification.** `docs/FUNCTIONAL_SPEC.md` covers the exchange only. The design
   rationale is in the NatSpec of `AsseteraPrimarySales.sol` and `settle/VenueSettler.sol`.
3. **Centralized signer and upgrade authority (the exchange's L-3, which applies here too). Status: OPEN,
   accepted as an operational item.** There is **no `TimelockController` anywhere in this repository**
   (verified by grep over `src/`, `script/` and `test/` on this commit), and `DEFAULT_ADMIN_ROLE` is simply
   whatever address is passed to `initialize`. The July review recorded this for the exchange as
   design-inherent centralization required by the regulated venue model, not a code defect, and deferred an
   on-chain timelock as a separate, larger-scoped change. The same reasoning and the same mainnet checklist
   (`FUNCTIONAL_SPEC.md §2`) apply to this proxy, which additionally has `SETTLEMENT_OPERATOR_ROLE`.
4. **Rebase-during-call counts as delivery.** Reported rather than patched — see the token section.
5. **`AO-550`: `intent.assetToken` may be a CLAIM token rather than the instrument the buyer bought**, and
   nothing on-chain can tell the difference. Every supplier we settle against is atomic, and where a mint is
   genuinely asynchronous it is fronted by a claim minted in the same transaction — which is what makes the
   balance delta measurable and this contract correct either way. What is **not** settled is what the layers
   above do with a claim: the activity ledger could report it as a final position, and the
   claim-to-instrument leg is a second event nothing currently emits. Deliberately deferred (2026-08-14).
   Marked as a `TODO` in `VenueSettler.sol`.
6. **`Action.SettleMint` (ordinal 2) is reserved and unreachable.** Safe only because of the fail-closed
   compliance override; the NatSpec says not to reserve ordinals again if that override is ever removed.
7. **`_gate().complianceRequired` is dead storage on this proxy.** A future module reading the mapping
   instead of the getter would silently reopen the gate.
8. **The upgrade-guard and salt-version asymmetry** described under storage and upgrade safety.
9. **`BuyerFeeMismatch` and `VenueIsASettledToken` are declared in `VenueSettler` rather than in
   `ISettler`**, against house style, only because `src/primary/interfaces/**` was frozen by the packet that
   built it. Cosmetic; move them when that file next opens.

## Contact

Code owner: `@tomw1808` (see `CODEOWNERS`). Please route questions and preliminary findings through the
agreed engagement channel.
