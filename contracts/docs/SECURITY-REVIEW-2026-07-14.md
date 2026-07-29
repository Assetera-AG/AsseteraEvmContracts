# AsseteraECS — Security Review

**Date:** 2026-07-14
**Reviewer:** Internal (Claude Code, Trail of Bits `building-secure-contracts` skill set)
**Commit:** `b2ca27f` (`chore: release main (#23)`), branch `adr/AC-93-security-review`
**Scope:** `contracts/src/**` — the live AsseteraECS surface (14 source files, ~1,680 LoC)
**Out of scope:** `test/`, `script/`, `lib/`, `packages/sdk/`, `examples/`; the parked
`admin/OperatorFunctions.sol` (fully commented out — not on the deployed surface)
**Methodology:** entry-point mapping → line-by-line context build → Slither detector suite →
`forge test`/coverage → token-integration analysis → manual review of attestation/rounding/escrow/UUPS
logic → code-maturity scorecard.

> This is an **internal pre-audit review**, not a substitute for an independent third-party audit before
> mainnet custody of real user funds. Its goal is to surface issues early and raise the codebase's
> audit-readiness.

---

## 1. Summary

The contract is **well-architected, tightly scoped, and defensively coded.** No critical or high-severity
issues were found. Slither reports **no true positives** (all flags triaged benign/false-positive below).
The dominant theme in the findings is **non-standard ERC-20 token behaviour against a pooled escrow**, plus
standard **centralization/upgrade trust** that is inherent to the MiFID-venue design and must be operationally
controlled on mainnet.

| Severity | Count | IDs |
|---|---|---|
| Critical | 0 | — |
| High | 0 | — |
| Medium | 1 | M-1 |
| Low | 3 | L-1, L-2, L-3 |
| Informational | 4 | I-1 … I-4 |

**Tooling results at a glance**
- `forge test`: **129 passed / 0 failed.**
- Coverage (core): lines **~95–100%** across books/gates; **branch coverage 58–72%** on
  `OrderBook`/`OfferBook`/`FeeGate` — the notable gap (see I-2).
- Slither: 0 true-positive high/medium; residue is benign (see I-4).

---

## 2. Entry-point map (attack surface)

All state-changing external functions on the assembled `AsseteraECS` (view/pure excluded).

### Public (permissionless)
| Function | Gate | Notes |
|---|---|---|
| `placeOrder` / `placeOrderWithPermit` | KYC + Fee attestation, `whenNotPaused` | maker escrows sellToken |
| `fillOrder` | KYC attestation, `whenNotPaused` | taker; self-trade rejected |
| `cancelOrder` | **none** (by design) | maker self-cancel; always available |
| `makeOffer` | KYC + Fee attestation, `whenNotPaused` | maker escrows makerToken |
| `replaceOffer` / `acceptOffer` | KYC attestation, `whenNotPaused` | party-restricted (maker/taker) |
| `cancelOffer` | KYC attestation | party-restricted; available while paused |
| `sweepExpired` / `sweepExpiredOffers` | none | returns escrow to owner; idempotent |

### Role-restricted
| Function | Role |
|---|---|
| `setAllowedCollector`, `pause`, `unpause`, `setComplianceRequired`, `cancelOrderForUser`, `cancelOfferForUser` | `DEFAULT_ADMIN_ROLE` |
| `upgradeToAndCall` | `DEFAULT_ADMIN_ROLE` (via `_authorizeUpgrade`) |
| `grantRole` / `revokeRole` | `DEFAULT_ADMIN_ROLE` |
| (attestation signers) | `KYC_OPERATOR_ROLE`, `FEE_OPERATOR_ROLE` — off-chain signing, not callers |

`OPERATOR_ROLE` and its `settle`/`refund` functions are **parked** (commented out in
`OperatorFunctions.sol`); `initialize` no longer grants it. Not part of the live attack surface.

---

## 3. Findings

### M-1 · Pooled escrow assumes standard ERC-20 semantics (fee-on-transfer / rebasing break solvency)
**Severity:** Medium · **Component:** `core/OrderBook.sol`, `core/OfferBook.sol`

`OrderBook` holds a **shared pool** of each `sellToken` across all open orders and records
`remainingQuantity = sellAmount` at placement (`_placeOrder`, `OrderBook.sol:177`), *assuming
`transferFrom` delivers exactly `sellAmount`.* For a **fee-on-transfer / deflationary** token the contract
receives less than `sellAmount`, so recorded escrow overstates the pool. Downstream payouts
(`fillOrder`, `cancelOrder`, `sweepExpired`, `cancelOrderForUser`) draw at the recorded amounts, so the pool
can become **insolvent** — the shortfall is silently borne by *other* makers' escrow, and the last withdrawer
reverts. **Rebasing** tokens (positive or negative) desync the same way. There is **no on-chain tradable-token
allowlist**. Offer settlement (`acceptOffer`) is per-offer balanced by construction, but the same
transfer-in-vs-release delta applies to a fee-on-transfer offer token.

**Mitigating control (present, but implicit):** for `Place`/`MakeOffer`, the token addresses are bound into
`paramsHash` and re-derived on-chain, and the KYC **and** fee backends must both sign — so *which* tokens can
enter escrow is effectively gated off-chain. This meaningfully reduces exposure (an attacker cannot introduce
an arbitrary weird token without a backend signature), **but it is an undocumented trust assumption, not an
on-chain invariant**, and `fillOrder` inherits whatever token the order already fixed.

**Recommendation (any/all):**
1. Document "**standard, non-rebasing, non-fee-on-transfer ERC-20 only**" as an explicit security property in
   `FUNCTIONAL_SPEC.md §9`, and enforce it in the backend token allowlist that gates attestation signing.
2. Optionally add an **on-chain tradable-token allowlist** (mirrors the existing `allowedCollectors` pattern)
   so the invariant is not solely backend-enforced.
3. Optionally adopt **balance-delta accounting** — measure `balanceOf(address(this))` before/after the
   `transferFrom` and escrow the *actual* received amount — which makes the pool robust to fee-on-transfer
   tokens without an allowlist.
4. Add tests with a fee-on-transfer / rebasing mock asserting the escrow-conservation invariant (see I-2).

> **Status: Accepted 2026-07-15.** No contract change. Treated as a
> downstream legal/compliance/risk control, not an engineering fix: recommendation #1 adopted — the backend
> token allowlist that already gates attestation signing must not list fee-on-transfer or rebasing tokens
> (now stated as an explicit invariant in `FUNCTIONAL_SPEC.md §9`). Recommendations #2 (on-chain allowlist)
> and #3 (balance-delta accounting) declined for now; if rebasing-token support is ever required, that needs
> a contract upgrade first. Original finding text above left unmodified for the audit trail.

---

### L-1 · Blacklistable / freezable settlement tokens can permanently lock escrow
**Severity:** Low · **Component:** all escrow paths

If a maker — or the exchange contract itself — is blacklisted on a token like USDC, then `cancelOrder`,
`sweepExpired`, and even the admin escape hatch `cancelOrderForUser` revert on transfer, stranding escrow.
This is inherent to freezable tokens. The escape hatch partially mitigates (admin can route to a *different*
recipient), **unless the contract address itself is frozen**, in which case funds are unrecoverable.
**Recommendation:** document as a known limitation; factor token freezability into the backend allowlist.

> **Status: Accepted 2026-07-15.** No contract change (inherent to freezable tokens; the "contract itself
> frozen" case has no on-chain remedy by construction). Documented as a known limitation in
> `FUNCTIONAL_SPEC.md §9` ("Freezable/blacklistable tokens") — the backend token allowlist that gates
> attestation signing must factor in a token's freeze/blacklist risk. Original finding text above left
> unmodified for the audit trail.

### L-2 · Fee snapshot can outlive collector de-allowlisting
**Severity:** Low · **Component:** `gates/FeeGate.sol`, order/offer fee snapshot

`feeCollector` is checked against `allowedCollectors` **only at placement** (`_validateFees`). If the admin
later removes that collector, existing orders/offers still pay it on fill/settle (snapshot semantics, by
design). There is no lever short of `pause` / force-cancel to cut off a collector that must be immediately
stopped. **Recommendation:** accept and document, or (if a kill-switch is desired) re-check the allowlist at
payout time — noting that would let the admin retroactively divert already-agreed fee terms, a trade-off to
weigh.

> **Status: Accepted 2026-07-15.** No contract change — snapshot semantics kept as-is (re-checking the
> allowlist at payout time would let the admin retroactively divert already-agreed fee terms, which is a
> worse trade-off). Already documented in `FUNCTIONAL_SPEC.md §8` ("Fee collector allowlist": *"The
> allowlist is checked only at placement — removing a collector does not affect orders/offers already
> placed against it"*) and restated in `§9`. Original finding text above left unmodified for the audit trail.

### L-3 · Centralized signer & upgrade authority (by design — operationalize it)
**Severity:** Low (design-inherent) · **Component:** roles, UUPS

- A compromised **`KYC_OPERATOR_ROLE`** key can authorize arbitrary users' trade actions. Blast radius is
  bounded: it cannot move existing escrow beyond normal trading, and it **cannot set/redirect fees** (separate
  `FEE_OPERATOR_ROLE`, and collectors are allowlisted).
- A compromised **`FEE_OPERATOR_ROLE`** key is bounded by `MAX_FEE_BPS` and the collector allowlist.
- **`DEFAULT_ADMIN_ROLE`** is effectively full custody: it can `upgradeToAndCall` to arbitrary logic and
  force-cancel/route any escrow.

This centralization is intended for a regulated venue. **Recommendation for mainnet:** admin **must** be a
Safe multisig (spec already says so); add a **timelock** on `upgradeToAndCall`; use dedicated,
well-managed keys for the two signer roles; consider splitting the collector-allowlist admin from the
upgrade admin.

> **Status: Accepted 2026-07-15, documentation-only for now.** No contract change (no on-chain timelock
> implementation) per explicit decision — this is design-inherent centralization required by the regulated
> venue model, and adding a timelock is an operational/deployment decision, not a code defect fix. Documented
> as a mainnet-readiness checklist in `FUNCTIONAL_SPEC.md §2` (Safe multisig admin, upgrade timelock,
> dedicated/well-managed signer keys per role, optional admin-role splitting). If mainnet requirements later
> mandate an on-chain timelock (e.g. `TimelockController` as/behind the admin), that is a separate,
> larger scoped change requiring its own design and test coverage. Original finding text above left
> unmodified for the audit trail.

---

### I-1 · Documentation drift in `FUNCTIONAL_SPEC.md`
`§2` and `§11` still describe `initialize` taking an `operator` parameter and granting `OPERATOR_ROLE`; the
current signature is `initialize(admin, kycSigner, feeSigner)` (the `operator` param was dropped in commit
#22, `78aee84`). Update §11's "initialize now takes … admin/operator/kycSigner" wording to match.

> **Status: Resolved 2026-07-15.** `FUNCTIONAL_SPEC.md §11` corrected to state
> `initialize(admin, kycSigner, feeSigner)` with no `operator` param, and to describe re-enabling
> `OPERATOR_ROLE` as requiring either a new initializer param (fresh deploy) or a `reinitializer` step,
> rather than "uncomment a retained param" (which was no longer true). Also fixed two stale comments that
> had the same drift: `AsseteraECS.sol::initialize`'s commented-out `_grantRole(OPERATOR_ROLE,
> operator)` line (referenced a param that no longer exists) and the re-enable instructions atop
> `admin/OperatorFunctions.sol`. Original finding text above left unmodified for the audit trail.

### I-2 · Branch coverage gap on funds-custody paths
Line coverage is excellent (~95–100% on core), but **branch coverage is 58–72%** on
`OrderBook`/`OfferBook`/`FeeGate`. Untested branches are mostly revert/edge paths (fee-bound rejections,
`ParamsHashMismatch`, expiry edges, force-cancel of `Countered` offers). For a custody contract, add:
(a) **fee-on-transfer / rebasing mock-token** tests asserting pool solvency (ties to M-1);
(b) an **invariant/fuzz** suite on escrow conservation (Σ escrowed == contract `balanceOf` per token) and
`fillOrder` ceiling-division rounding;
(c) a **reentrancy** test driving every state-changer through a malicious ERC-777-style token (a
`ReentrantToken` mock already exists — confirm it exercises each entry point).

> **Status: Resolved 2026-07-15.**
> - (a) `test_TokenSafety_FeeOnTransfer_EscrowOverstatedAtPlacement`, `test_TokenSafety_FeeOnTransfer_PoolInsolvency_LastCancellerReverts`,
>   `test_TokenSafety_FeeOnTransfer_AcceptOfferShortfall`, `test_TokenSafety_Rebasing_NegativeRebaseCausesInsolvency` in
>   `test/AsseteraECS.t.sol`, backed by new `test/mocks/{FeeOnTransferToken,RebasingToken}.sol` — prove the M-1
>   insolvency scenario directly.
> - (b) `test/invariants/{EscrowHandler,EscrowConservation}.t.sol` — a handler-driven invariant suite that
>   independently recomputes Σ escrowed (from ground-truth `getOrder`/`getOffer` state, not a ghost mirror of the
>   contract's own arithmetic) and asserts it equals `balanceOf` per token, across `placeOrder`/`fillOrder`/
>   `cancelOrder`/`sweepExpired`/`makeOffer`/`replaceOffer`/`cancelOffer`/`acceptOffer`/`sweepExpiredOffers`
>   (64 runs × depth 50, 0 reverts). `fillOrder` ceiling-division rounding covered separately by
>   `testFuzz_FillOrder_CeilDivNeverShortchangesMaker`.
> - (c) `ReentrantToken` generalized to arm arbitrary calldata against any target. All 12 funds-custody entry
>   points now have a dedicated `..._ReentrancyGuarded` test: `placeOrder`, `placeOrderWithPermit`, `cancelOrder`,
>   `fillOrder`, `sweepExpired`, `makeOffer`, `replaceOffer`, `cancelOffer`, `acceptOffer`, `sweepExpiredOffers`,
>   `cancelOrderForUser`, `cancelOfferForUser`.
>
> 146/146 tests passing (`forge test`). Original finding text above left unmodified for the audit trail.

### I-3 · `_tryPermit` failure-swallow is correct (noted positively)
`placeOrderWithPermit` wraps `permit` in `try/catch` (`OrderBook.sol:150-154`), so the classic
"front-run the permit to grief the tx" DoS does **not** apply — a pre-consumed/again-submitted permit simply
falls through to `safeTransferFrom`. No action.

### I-4 · Slither residue — all benign / false-positive
- **`arbitrary-send-erc20` on `acceptOffer`** → **false positive.** The `from` is always the caller:
  `caller == taker ⇒ transferFrom(taker, …)`, else `transferFrom(maker, …)`; the caller is verified to be
  maker or taker. You can only pull tokens from yourself.
- **`reentrancy-benign` on `placeOrderWithPermit`** → guarded by `nonReentrant`; state writes after the
  `permit` external call are harmless. Optional cleanup: move `_tryPermit` before nonce consumption.
- **`timestamp`** → expiry comparisons; miner drift (~seconds) is immaterial to the expiry windows. Benign.
- **`dead-code` (`_msgData`), `naming-convention`** → OZ-required ERC-2771 overrides and interface getters
  mirroring public constants. Cosmetic.
**Recommendation:** add a `slither.db.json` triage file so CI stays green without suppressing new findings.

---

## 4. Positive observations (verified correct)

- **Attestation integrity:** verify-**before**-burn on paired KYC+Fee attestations (no partial nonce
  consumption on revert); distinct `KYC_OPERATOR_ROLE` vs `FEE_OPERATOR_ROLE` trust boundaries with
  **separate nonce namespaces** (`usedNonce` / `usedFeeNonce`).
- **Replay resistance:** distinct `Action` enum values block cross-function replay; `orderId`/`offerId`
  binding blocks cross-instance replay; `paramsHash` is **re-derived on-chain** and both attestations checked
  against the same value; EIP-712 domain binds `chainId` + `verifyingContract`; OZ `ECDSA` rejects malleable
  signatures; 15-minute hard TTL cap on both attestation types.
- **Reentrancy:** single shared `nonReentrant` guard across all state-changers (no cross-function
  reentrancy); strict CEI — status is written before every external transfer.
- **Rounding:** `fillOrder` uses ceiling division for `buyAmountDue` (protects the maker); fees floor-divide
  (favor the payer); OrderBook fill accounting is **exactly balanced** (no dust) for standard tokens.
- **Escrow invariant (offers):** at most one side is ever escrowed; `acceptOffer` escrows the accepting side
  and releases both atomically — verified balanced in both `proposedBy == maker` and `== taker` cases.
- **Upgrade safety:** proxy init is **atomic** (`initData` in the `ERC1967Proxy` constructor,
  `Deploy.s.sol:92-94`) and the impl calls `_disableInitializers()` → no init front-running. Clean UUPS
  storage layout: all mutable state lives in `ExchangeStorage` behind a single `__gap`; every derived module
  declares only constants/events/errors (no storage) → no collision risk across the inheritance linearization.
- **Liveness under pause:** self-cancel and sweeps remain callable while paused → users can always retrieve
  funds.

---

## 5. Code maturity scorecard (Trail of Bits, 9 categories)

| Category | Rating | Notes |
|---|---|---|
| Arithmetic | **Satisfactory** | 0.8 checked math; explicit ceil/floor rationale; no value-path `unchecked`. |
| Auditing & logging | **Strong** | Event per indexer-relevant state change; dedicated `INDEXER_EVENT_SCHEMA.md`. |
| Access controls | **Satisfactory** | Role-separated; mainnet needs multisig + timelock (L-3). |
| Complexity mgmt | **Strong** | Small, modular, single-purpose files; clear inheritance story (AC-242). |
| Decentralization | **Moderate** | Intentionally centralized compliance/upgrade — regulatory mandate. |
| Documentation | **Strong** | Thorough NatSpec + `FUNCTIONAL_SPEC.md`; drift resolved (I-1). |
| Testing & verification | **Satisfactory (gap)** | 129 passing, high line cov; branch cov + weird-token/invariant/fuzz gap (I-2). |
| Token handling | **Needs improvement** | M-1: no on-chain allowlist / balance-delta accounting. |
| Low-level code | **Strong** | No assembly in scope; `SafeERC20` throughout. |

---

## 6. Recommended next steps (priority order)

1. ~~**M-1**~~ — **Accepted 2026-07-15**, documentation-only (see finding).
2. ~~**I-2**~~ — **Resolved 2026-07-15** (see finding).
3. **L-3** — before mainnet: Safe multisig admin + upgrade timelock + hardened signer key management.
   **Accepted 2026-07-15, documentation-only for now** — checklist captured in `FUNCTIONAL_SPEC.md §2`;
   actual multisig/timelock deployment remains an operational TODO before mainnet.
4. ~~**I-1 / L-1 / L-2**~~ — **Resolved/Accepted 2026-07-15** — documentation fixes and known-limitation
   notes landed (see findings).
5. **I-4** — commit a Slither triage DB to keep CI signal clean. **Deferred** — Slither is not currently
   wired into CI at all; adding it is a separate scoping decision (tool install, runtime cost, failure
   policy), not addressed in this pass.
6. Independent third-party audit before real-fund custody.
