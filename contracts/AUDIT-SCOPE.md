# AsseteraECS — Audit Scope & Handover

This document is the entry point for an external security review of the AsseteraECS smart contracts
(**E**xecution, **C**learing & **S**ettlement — formerly `AsseteraExchange`, renamed under AC-836).
It defines exactly what is in scope, how to build and test it, the trust model, the economics, and the
known assumptions. Everything an auditor needs to reproduce our results should be reachable from here.

- **Project:** AsseteraECS — the on-chain venue for a regulated real-world-asset (RWA) marketplace (MiFID).
- **Foundry root:** `contracts/` (point `forge`, `slither`, and coverage here).
- **Functional specification:** [`docs/FUNCTIONAL_SPEC.md`](docs/FUNCTIONAL_SPEC.md).
- **Event schema (for indexers):** [`docs/INDEXER_EVENT_SCHEMA.md`](docs/INDEXER_EVENT_SCHEMA.md).
- **Internal pre-audit review:** [`docs/SECURITY-REVIEW-2026-07-14.md`](docs/SECURITY-REVIEW-2026-07-14.md) — read this
  for the known findings (M-1, L-1…L-3, I-1…I-4) we have already triaged. Note it predates the AC-833 fee
  rework described in [§ Economics](#economics--the-currency-exclusive-fee-model-ac-833) below; where the two
  disagree, this document and the code are current.

> **Naming.** The contract, its file and its interface are `AsseteraECS` / `AsseteraECS.sol` /
> `IAsseteraECS.sol`. The **EIP-712 domain string is deliberately left as `"AsseteraExchange"`**
> (`AsseteraECS.sol`, in `initialize` → `__EIP712_init("AsseteraExchange", "1")`). Changing it would change the
> domain separator and invalidate every in-flight KYC and fee attestation; and because OZ v5
> `EIP712Upgradeable` stores the name in ERC-7201 namespaced storage written only by the `onlyInitializing`
> `__EIP712_init`, an implementation upgrade could not change it on a live proxy anyway. The mismatch between
> the contract name and the domain name is **intentional**, not an oversight. The generic module names
> (`OrderBook`, `OfferBook`, `ExchangeTypes`, `ExchangeStorage`, `ExchangeAdmin`, `KycGate`, `FeeGate`) are
> unchanged — "exchange" is an accurate common noun for the venue.

## Audit target (frozen commit)

Please audit a **single frozen commit**. We tag a dedicated release for the engagement
(e.g. `audit-v1`); confirm the exact commit hash with us before starting rather than tracking a moving
branch. `main` is protected, linear-history, and squash-merged, so the tag is stable.

Every figure below was reproduced from a clean checkout with the commands shown. Re-measure if you are
handed a different commit.

## In scope

The production contract surface under `contracts/src/` — **12 files, 1,742 LoC**
(`find src -name '*.sol' | xargs wc -l`):

| File | LoC | Role |
|---|---:|---|
| `src/AsseteraECS.sol` | 109 | UUPS proxy entrypoint; assembles the modules; `initialize`; `version()` |
| `src/core/OrderBook.sol` | 401 | Order lifecycle: place / cancel / fill / sweep; pooled escrow + escrowed maker fee |
| `src/core/OfferBook.sol` | 402 | Offer lifecycle: make / replace / accept (atomic settle) / cancel / sweep |
| `src/gates/KycGate.sol` | 62 | EIP-712 KYC attestation verification + nonce burn |
| `src/gates/FeeGate.sol` | 108 | EIP-712 fee attestation verification + fee bounds / denomination / collector allowlist |
| `src/admin/ExchangeAdmin.sol` | 110 | Admin surface: pause, compliance toggles, collector allowlist, force-cancel |
| `src/storage/ExchangeStorage.sol` | 78 | Single storage base behind `__gap` (UUPS layout) |
| `src/types/ExchangeTypes.sol` | 148 | Structs, enums (`Action`), attestation types |
| `src/libs/FeeMath.sol` | 23 | Fee arithmetic (floor division) + ceiling division |
| `src/interfaces/IAsseteraECS.sol` | 242 | External interface |
| `src/interfaces/IKycGate.sol` | 29 | Interface |
| `src/interfaces/IFeeGate.sol` | 30 | Interface |

LoC is raw `wc -l` (including licence header, NatSpec and blank lines) on the frozen commit. The AC-836
rename is comment- and identifier-level only; it does not change bytecode (see the note above).

## Out of scope

| Path | Why |
|---|---|
| `test/**` — unit tests, the `test/invariants/` escrow-conservation suite, and mocks (`test/mocks/FaucetToken.sol`, `ReentrantToken.sol`, `FeeOnTransferToken.sol`, `RebasingToken.sol`, `AsseteraECSV2.sol`) | Tests and mocks. `FaucetToken` is an **open-mint testnet faucet**, deployed only on Amoy/Sepolia/local anvil — never mainnet (enforced in `Deploy.s.sol` via `_isTestnet`). Not part of the production surface. |
| `script/**` (`Deploy.s.sol`, `DeployBase.sol`, `Verify.s.sol`, `UpgradeCalldata.s.sol`, `storage-layout.sh`, `struct-layout.py`) | Deployment / verification / upgrade-safety tooling, not deployed bytecode. Reviewing the deploy story is welcome but it is not the contract under custody. |
| `docs/parked/OperatorFunctions.sol` | **Parked, not compiled, not deployed.** A commented reference implementation of `settle`/`refund` (`OPERATOR_ROLE`), kept outside `src/` so it is not on the attack surface. See `docs/FUNCTIONAL_SPEC.md §11` for the re-enable path. |
| `lib/**` | Pinned dependencies (see below). |
| `packages/sdk/**`, `examples/**` | TypeScript SDK and consumer examples (in the monorepo, not the Foundry project). |

## Build & test

```bash
cd contracts
forge build                 # Solidity 0.8.28, via-IR, optimizer 200 runs — clean
forge test                  # 190 tests across 4 suites, all passing
forge coverage --ir-minimum --no-match-coverage '(script|test)'
bash script/storage-layout.sh   # upgrade-safety guard; must print "storage layout unchanged"
slither .
```

**Test suite — 190 tests, 0 failures** (`forge test`):

| Suite | Tests |
|---|---:|
| `test/AsseteraECS.t.sol` | 179 |
| `test/FaucetToken.t.sol` | 6 |
| `test/DeployProvenance.t.sol` | 3 |
| `test/invariants/EscrowConservation.t.sol` | 2 (invariant runs: 64 × depth 50) |

**Coverage** (`forge coverage --ir-minimum --no-match-coverage '(script|test)'`). `--ir-minimum` is
**required** — plain `forge coverage` disables the optimizer and via-IR and fails "stack too deep" in
`OfferBook.replaceOffer`.

| File | % Lines | % Branches | % Funcs |
|---|---:|---:|---:|
| `src/core/OrderBook.sol` | 100.00 (104/104) | 100.00 (36/36) | 100.00 (11/11) |
| `src/core/OfferBook.sol` | 100.00 (144/144) | 95.45 (42/44) | 100.00 (9/9) |
| `src/gates/FeeGate.sol` | 100.00 (24/24) | 100.00 (13/13) | 100.00 (3/3) |
| `src/gates/KycGate.sol` | 100.00 (19/19) | 100.00 (10/10) | 100.00 (2/2) |
| `src/libs/FeeMath.sol` | 100.00 (4/4) | n/a (0/0) | 100.00 (2/2) |
| `src/admin/ExchangeAdmin.sol` | 94.59 (35/37) | 100.00 (7/7) | 100.00 (6/6) |
| `src/AsseteraECS.sol` | 75.86 (22/29) | 100.00 (1/1) | 85.71 (6/7) |
| **Total** | **97.51 (352/361)** | **98.20 (109/111)** | **97.50 (39/40)** |

The residue on `AsseteraECS.sol` is the ERC-2771 / UUPS plumbing (`_msgData`, `_contextSuffixLength`) —
overrides OZ requires but which the venue's own paths never take.

- `forge build` is clean; the only lint output is `block-timestamp` warnings on expiry comparisons (benign —
  the expiry windows dwarf validator drift; see the Slither triage).
- **Testing (internal finding I-2, resolved and since extended):** in addition to the unit suite, the review's
  coverage gap was closed with a handler-driven **escrow-conservation invariant** suite (`test/invariants/`),
  **fee-on-transfer / rebasing mock-token** tests that directly exercise the M-1 pool-insolvency mechanism, and
  **reentrancy-guard coverage on all 12 funds-custody entry points** (via a `ReentrantToken` armed with
  arbitrary calldata). AC-833 extended the invariant to the escrowed fee (below) and made the handler trade at
  real, non-zero fee rates so the escrowed-fee path is genuinely exercised rather than sitting at zero.

### Upgrade-safety guard (`script/storage-layout.sh`)

A committed snapshot of the proxy's storage layout (`storage/AsseteraECS.txt`), diffed in CI on every PR.
Because the OZ v5 upgradeable bases use ERC-7201 namespaced storage, a clean minor dependency bump produces a
**zero-line diff** — any diff on a dep bump is a red flag. Paired with
`test_Upgrade_PreservesAllStorageAcrossEverySlot`.

The snapshot has two halves. The top-level `forge inspect … storage-layout` table, **plus** (added in AC-833,
via `script/struct-layout.py`) the **per-struct member layout**. That second half closes a real blind spot:
`_orders` / `_offers` are mappings, so the top-level table records one slot each and says nothing about the
struct behind it — adding `feeToken` / `escrowedFee` to `Order` and `Offer` produced a zero-line diff and
sailed through the old check. Appending to a struct held in a mapping is upgrade-safe (each value lives at its
own hashed slot); **reordering or retyping** a member is not, and the guard could not tell those apart. It now
can. The AC-833 re-baseline is visibly purely additive: every pre-existing member keeps its slot and offset
(`Order` slot 8 was exactly full at `feeCollector`), so `feeToken` landed on a fresh slot 9 and `escrowedFee`
on slot 10.

## Toolchain & compiler settings (`foundry.toml`)

| Setting | Value |
|---|---|
| `solc` | `0.8.28` |
| `optimizer` / `optimizer_runs` | on / `200` |
| `via_ir` | `true` |
| `bytecode_hash` | `none` (deterministic bytecode) |
| `[fuzz] runs` | `256` (CI profile: `5000`) |
| `[invariant] runs` / `depth` | `64` / `50`, `fail_on_revert = false` |

## Dependencies (pinned git submodules under `lib/`)

| Dependency | Version | Gitlink |
|---|---|---|
| `openzeppelin-contracts` | v5.1.0 | `69c8def5f222ff96f2b5beff05dfba996368aa79` |
| `openzeppelin-contracts-upgradeable` | v5.1.0 | `fa525310e45f91eb20a6d3baa2644be8e0adba31` |
| `forge-std` | v1.16.2 | `bf647bd6046f2f7da30d0c2bf435e5c76a780c1b` |
| `createx-forge` | (deploy tooling only, out of scope) | `cef15824154b2a7117bdac60870466b185fba684` |

Reproduce with `git submodule status contracts/lib/*`. Note: `contracts/foundry.lock` still records forge-std
`v1.16.1` / `620536f` — the checked-out gitlink (the thing that actually builds) is `v1.16.2`. `forge-std` is a
test-only dependency and is not linked into deployed bytecode. Dependencies are **frozen for the duration of an
external audit**.

<a id="economics--the-currency-exclusive-fee-model-ac-833"></a>
## Economics — the currency-exclusive fee model (AC-833)

This is the part of the system that changed most recently and most materially, and the part where an auditor
reading older documentation would review the wrong thing. It shipped in PR #39 (SDK 3.0.0) and is the model on
`main` today.

### The rule

**Both fees are denominated in the settlement currency, and are exclusive on the payer.**

- Exactly one of the two legs of a trade is the **settlement currency**, identified by `feeToken`.
- `makerFeeBps` and `takerFeeBps` are both charged on the **notional** — the currency-leg amount for that fill —
  and both are paid in `feeToken`.
- The party **paying** currency pays `notional + their own fee`.
- The party **receiving** currency receives `notional − their own fee`.
- **The asset leg always moves gross.** Nothing is ever withheld from it.
- The collector receives exactly `makerFeeAmount + takerFeeAmount`, in one token, and zero of the asset.

Worked example — a taker filling "10 RWA for 100 USDC" at 1 % / 1 % pays **101 USDC** and receives the full
**10 RWA**; the maker receives **99 USDC**; the collector takes **2 USDC** and zero RWA
(`OrderBook.sol:253-266`, and asserted to the wei across all five accounts in
`test_Fee_Fill_BothFeesInSettlementCurrency_ExclusiveOnTaker`).

The books balance without any extra escrow from the asset side, because the currency receiver's own fee
cancels: `(cAmount − receiverFee) + (makerFee + takerFee) == cAmount + payerFee` (`OfferBook.sol:303-312`).

**Why it changed.** The previous model charged each fee on its own leg and deducted it from what each party
*received*, which left the fee collector holding fragments of a **restricted security token** — a
transfer-restriction problem, not merely an accounting one.

### `feeToken` — how the contract learns which leg is money

The contract knows token addresses, not markets, so it cannot infer which leg is currency. `feeToken` is
therefore a **signed field on `FeeAttestation`** and part of `FEE_TYPEHASH` (`FeeGate.sol:25-27`):

```
FeeAttestation(address account,uint8 action,uint256 nonce,uint256 deadline,bytes32 paramsHash,
               uint16 makerFeeBps,uint16 takerFeeBps,address feeCollector,address feeToken)
```

The fee service resolves it from the marketplace catalog (`token_pairs.settlement_currency_id`) and signs it.
On-chain, `_validateFees` asserts `feeToken ∈ {legA, legB}` (`FeeGate.sol:102`) — **unconditionally**, i.e.
independently of the `complianceRequired` toggle, as defence in depth. It is required **even for a zero-fee
order**, so that `feeToken == address(0)` means exactly one thing (below).

`feeToken`, `makerFeeBps`, `takerFeeBps` and `feeCollector` are **snapshotted onto the order/offer at creation**
and are immutable for its lifetime (`ExchangeTypes.sol:64-79`, `:94-105`).

Adding `feeToken` to the typehash is a **breaking change to the attestation format**: an attestation signed
under the old type recovers to a different address and is rejected by `FeeBadSigner`.

### The escrowed-fee invariant (load-bearing)

When the maker/proposer is the party **escrowing the currency leg**, they are the currency *payer*, so their
fee must be escrowed up front alongside the notional:

- **Orders** (`OrderBook.sol:162-183`, `:194`, `:214`): a buy-side order (`sellToken == feeToken`) escrows
  `sellAmount + floor(sellAmount × makerFeeBps / 10000)` in one `safeTransferFrom`. The unconsumed remainder is
  tracked as an explicit `Order.escrowedFee` field rather than recomputed at unwind time — after partial fills
  the two diverge by rounding.
- **Offers** (`OfferBook.sol:115-125`, `:97-98`, `:154`): identically, via `_proposerFee`, whenever the
  proposer's own leg is the currency.
- When the maker instead escrows the **asset**, nothing extra is escrowed — their fee is withheld from the
  currency the counterparty pays in.

> **Invariant: the escrowed fee is the maker's money until a fill earns it.** Every path that unwinds an
> order or offer must return whatever remains of it, and the final fill must return the rounding dust, so the
> contract never retains a residue.

All **eight** paths honour it:

| # | Path | Where |
|---|---|---|
| 1 | `OrderBook.cancelOrder` | `OrderBook.sol:241` |
| 2 | `OrderBook.sweepExpired` | `OrderBook.sol:382` |
| 3 | `OrderBook._settleFill` — final-fill rounding dust back to the maker | `OrderBook.sol:321-327`, `:337` |
| 4 | `ExchangeAdmin.cancelOrderForUser` (admin force-cancel) | `ExchangeAdmin.sol:60` |
| 5 | `OfferBook.replaceOffer` — refunds the outgoing proposer, re-escrows the incoming one | `OfferBook.sol:198-224` |
| 6 | `OfferBook.cancelOffer` | `OfferBook.sol:255`, `:263-265` |
| 7 | `OfferBook.sweepExpiredOffers` | `OfferBook.sol:385` |
| 8 | `ExchangeAdmin.cancelOfferForUser` (admin force-cancel) | `ExchangeAdmin.sol:96`, `:103-105` |

The per-fill decrement `o.escrowedFee -= makerFeeAmount` (`OrderBook.sol:321`) is safe by construction: the
per-fill fee is `floor(fᵢ · bps)` over fills whose `fᵢ` sum to `sellAmount`, and `Σ floor(x) ≤ floor(Σ x) =
escrowedFee`. Solidity 0.8 checked arithmetic means a violation of that argument would **revert**, not silently
underflow. The `escrowedFee` residue left by that inequality is returned to the maker on the last fill.

**Test evidence.** `test_AC833_BuySideOrder_EscrowsNotionalPlusMakerFee`,
`…_Fill_AssetGross_CurrencyNetToTaker`, `…_SweepExpired_RefundsEscrowedFee`,
`…_ForceCancel_RefundsEscrowedFee`, `…_FullFillInParts_ReturnsFeeDustToMaker`,
`…_Offer_MakerProposesCurrency_EscrowsOwnFee_AndRefundsOnCancel`,
`…_Offer_Replace_RefundsOldFeeEscrow_AndTakesNew`, `test_AC833_FeeTokenNotALeg_Reverts`,
`test_AC833_FeeTokenIsSignedOverAndCannotBeTampered`,
`test_AC833_LegacyOrder_CannotBeFilled_ButCanStillBeCancelled` (all in `test/AsseteraECS.t.sol`).

### Extended escrow-conservation invariant

The invariant suite's ground truth now counts the escrowed fee
(`test/invariants/EscrowHandler.sol:255-274`). For every token, after any fuzzed sequence of
place / fill / cancel / sweep / make / replace / accept / cancel-offer / sweep-offers:

```
balanceOf(exchange, token) ==
    Σ over Open orders with sellToken == token   (remainingQuantity + escrowedFee)
  + Σ over Open/Countered offers where the current proposer's leg == token
                                               (that leg's amount + escrowedFee)
```

The handler trades at real rates (1 % maker / 0.5 % taker, tokenB as settlement currency) with every actor
bringing a fee-inclusive amount, so the escrowed-fee path is genuinely driven. KYC gating is off (it has its
own dedicated coverage) but `_validateFees` still runs, so the denomination is enforced throughout.
Mutation-verified: dropping the fee refund from `cancelOrder` fails
`invariant_EscrowConservation_TokenB` with a stranded residue while leaving `TokenA` — the asset leg, which
carries no fee escrow — passing.

### Legacy (pre-AC-833) orders and offers

Storage was extended **append-only**, so orders and offers created before the upgrade still exist and read
`feeToken == address(0)`. Because `_validateFees` requires `feeToken` to be one of two already-non-zero legs,
a *new* order can never have `feeToken == 0` — the sentinel is unambiguous.

Such entries **cannot be traded** — `fillOrder` reverts `LegacyOrderMustBeUnwound` (`OrderBook.sol:278`),
`acceptOffer` and `replaceOffer` revert `LegacyOfferMustBeUnwound` (`OfferBook.sol:284`, `:173`) — because
their fees have no defined denomination. They **can** still be cancelled, swept and force-cancelled, so no
funds are stranded. `replaceOffer` is deliberately blocked too: countering a legacy offer would keep an
unacceptable offer alive indefinitely.

### Audit-relevant surface introduced or changed by AC-833

1. **`FEE_OPERATOR_ROLE` now chooses the settlement currency.** The on-chain check is only
   `feeToken ∈ {legA, legB}` — the contract cannot know which leg is *actually* money. A compromised fee signer
   could nominate the **asset** leg as `feeToken`, inverting who pays and who receives the fee, and causing the
   collector to be paid in the restricted token. Blast radius is bounded by `MAX_FEE_BPS` (10 000) and the
   `allowedCollectors` allowlist, and the fee terms are visible in `OrderPlaced` / `OfferMade` before any fill.
   This is a genuine widening of that role's authority versus the pre-AC-833 model and should be weighed as
   such.
2. **Fee terms are only *signed* when `complianceRequired[action]` is true.** `_verifyFee` early-returns when
   the toggle is off (`FeeGate.sol:44`), while `_validateFees` runs unconditionally. With gating disabled, fee
   terms are caller-chosen but still bounded by `MAX_FEE_BPS`, the collector allowlist and the leg check.
   Production runs with gating on for `Place` / `MakeOffer` (set in `initialize`).
3. **Allowance requirements changed for takers.** A sell-side fill pulls from the taker **twice**
   (`OrderBook.sol:342-343`): `notional − makerFee` to the maker and `makerFee + takerFee` to the collector. The
   taker must therefore approve `notional + takerFee`, not `notional`. `placeOrderWithPermit` correspondingly
   permits `_escrowTotal(...)` = `sellAmount + escrowedFee` (`OrderBook.sol:150-152`).
4. **`replaceOffer` swaps both halves of the fee escrow in one call** (`OfferBook.sol:195-224`) — the outgoing
   proposer's unconsumed fee is refunded and the incoming proposer escrows a fee recomputed on the **new**
   amounts, which may be a different party, side and token. It is also the highest-complexity function in the
   codebase (Slither cyclomatic complexity 12) and worth focused review.
5. **Rounding is deliberately asymmetric.** `FeeMath.feeAmount` floors (rounding favours maker and taker over
   the collector); `FeeMath.ceilDiv` on the fill's proportional amount ceils (protecting the maker from
   rounding loss on partial fills) — `OrderBook.sol:290`.
6. **Fill/settle events now carry GROSS amounts** plus `feeToken`, and `OrderPartiallyFilled` additionally
   carries `filledBuyAmount`. Consumers must not re-derive net figures the old way. See
   `docs/INDEXER_EVENT_SCHEMA.md`.

## Static analysis (Slither)

Config: [`slither.config.json`](slither.config.json) (filters `lib/`, `test/`, `script/`). Run: `slither .`
from `contracts/`. Current result: **42 contracts, 101 detectors, 26 results — all triaged benign.**

| Detector | Location | Verdict |
|---|---|---|
| `arbitrary-send-erc20` (×4) | `OfferBook._settleOffer` (`OfferBook.sol:338-342`) | **False positive** — `from` is always `o.maker` or `o.taker`, and the caller has already been checked to be one of them (`acceptOffer`, `OfferBook.sol:288`). You can only pull tokens from yourself. Moved here from `acceptOffer` when AC-833 split settlement into `_settleOffer`. |
| `uninitialized-local` | `OrderBook._settleFill.feeDust` (`OrderBook.sol:316`) | **Benign, new in AC-833** — the zero default *is* the intended value; `feeDust` is only assigned on the final fill of a buy-side order, and the guarded `if (feeDust > 0)` transfer makes the unassigned case a no-op. |
| `reentrancy-benign` | `OrderBook.placeOrderWithPermit` | Guarded by `nonReentrant`; state writes after the `permit` external call are harmless. |
| `timestamp` (×10) | expiry / TTL comparisons in `OrderBook`, `OfferBook`, `KycGate._verifyKyc`, `FeeGate._verifyFee` | Benign — validator drift (seconds) is immaterial to the expiry/TTL windows (`MAX_KYC_TTL` / `MAX_FEE_TTL` are 15 minutes; order expiries are hours-plus). |
| `cyclomatic-complexity` | `OfferBook.replaceOffer` (12) | **New in AC-833** — the function now swaps both parties' escrow *and* both fee escrows. Accepted; flagged above as a focused-review target. |
| `dead-code` (`_msgData`) | `AsseteraECS` | OZ-required ERC-2771 override. |
| `naming-convention` (×8) | `IFeeGate` / `IKycGate` constant getters, `ExchangeStorage.__gap` | Getters mirror public constants; `__gap` is the OZ storage-gap idiom. |

No high- or medium-severity true positives. (I-4 recommended committing a `slither.db.json` triage file; that
remains **deferred** — Slither is not currently a CI gate, so the table above is the triage of record.)

## Trust model & centralization (by design — regulated venue)

- `DEFAULT_ADMIN_ROLE` is effectively full custody: it can `upgradeToAndCall` to arbitrary logic and
  force-cancel/route any escrow (including the escrowed fee). **Mainnet requirement:** a Safe multisig, plus a
  timelock on upgrades.
- `KYC_OPERATOR_ROLE` signs KYC attestations (off-chain signer). Compromise cannot move escrow beyond
  normal trading and **cannot set/redirect fees**.
- `FEE_OPERATOR_ROLE` signs fee attestations (a distinct signer). Bounded by `MAX_FEE_BPS` and the
  `allowedCollectors` allowlist — but note it now also selects the settlement currency (see the AC-833
  surface notes above).
- Order/offer **matching happens off-chain**; the chain enforces settlement, escrow, attestation, and fees.
- Identity is resolved through `_msgSender()` (ERC-2771), so a trusted forwarder may relay gasless meta-txs.
- This centralization is intentional and mandated by the regulatory model. See L-3 in the internal review.

## Known security assumptions & findings

Fully described in the internal review; the load-bearing ones, re-read against the current code:

1. **M-1 — standard-ERC-20-only.** The pooled escrow assumes tokens transfer exactly the requested amount.
   **Only standard, non-rebasing, non-fee-on-transfer ERC-20 tokens may trade.** Enforced off-chain today
   (attestation-gated token addresses); no on-chain tradable-token allowlist. See `FUNCTIONAL_SPEC.md §9`.
   **The assumption still holds after AC-833, with a slightly larger blast radius:** the escrowed fee is pulled
   in the *same* `safeTransferFrom` as the notional (`OrderBook.sol:214`, `OfferBook.sol:98`), so a
   fee-on-transfer token now overstates recorded escrow by the transfer tax on `notional + fee`, not just on
   `notional`, and the refund paths pay out that overstated figure. The failure mode is unchanged — last-out
   insolvency — and is directly exercised by `test_TokenSafety_FeeOnTransfer_EscrowOverstatedAtPlacement`,
   `…_PoolInsolvency_LastCancellerReverts` and `…_AcceptOfferShortfall`.
2. **L-1 — freezable tokens** (e.g. USDC) can strand escrow if a party or the exchange is blacklisted. Now also
   applies to the escrowed fee, which is denominated in the settlement currency — precisely the leg most likely
   to be a freezable stablecoin.
3. **L-2 — fee snapshot outlives collector de-allowlisting.** `feeCollector` is checked against
   `allowedCollectors` only at placement; de-allowlisting does not affect orders already placed against it.
   Accepted (re-checking at payout would let the admin retroactively divert agreed fee terms). AC-833 extends
   the same snapshot semantics to `feeToken`.
4. **L-3 — centralized signer/upgrade authority** — operationalize with multisig + timelock on mainnet.

## Contact

Code owner: `@tomw1808` (see `CODEOWNERS`). Please route questions and preliminary findings through the
agreed engagement channel.
