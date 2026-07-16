# AsseteraExchange — Functional Specification

**Version:** 3.1.0  
**Solidity:** 0.8.28  
**Network:** Polygon Amoy (testnet) → Polygon mainnet  
**Proxy pattern:** UUPS (ERC-1967)  
**Meta-tx:** ERC-2771 (OpenZeppelin ERC2771Forwarder)

---

## 1. Overview

AsseteraExchange is an escrow-based, off-chain-matched limit-order venue for regulated real-world asset (RWA) trading. It is designed around a MiFID-style compliance model:

- **Positive gate** — every user-initiated trade action requires a fresh, single-use EIP-712 *KYC attestation* signed by the platform's compliance backend. The backend refuses to sign for unverified or suspended users, effectively freezing them without on-chain writes.
- **Negative / escape hatch** — admin functions (`cancelOrderForUser`, `cancelOfferForUser`) allow the multisig to force-return escrowed funds to a compliance-chosen recipient, bypassing the KYC gate.
- **Fee gate (separate from KYC)** — the three fee-setting actions (`placeOrder`, `placeOrderWithPermit`, `makeOffer`) additionally require a *fee attestation* signed by a distinct fee service (`FEE_OPERATOR_ROLE`), not the KYC backend. Fee terms never ride inside the KYC attestation. See [§5](#5-fee-attestation).

There is **no on-chain matching engine**, and standard operation needs no operator actions at all — settlement/matching isn't done on-chain by an operator. `settle`/`refund` (order-level) are parked (AC-246; see [§11](#11-upgrade-considerations)), re-enableable later via a single UUPS upgrade if ever needed. `settleOffer` (offer-level) is retired outright, not parked — its logic was merged directly into `acceptOffer`, which settles atomically on acceptance (see [§7](#7-offer-lifecycle)) rather than waiting for a separate step. `pause`/`unpause` remain active as an admin-gated "stop the venue" lever, and `cancelOrderForUser`/`cancelOfferForUser` remain active as the admin's emergency-exit path.

Identity is resolved via `_msgSender()` (ERC-2771), so callers can be plain EOAs, gasless relayer-forwarded EOAs, or future ERC-4337 smart accounts — the contract is agnostic.

---

## 2. Actors and Roles

| Actor | Role constant | Capabilities |
|---|---|---|
| **Admin (multisig)** | `DEFAULT_ADMIN_ROLE` | Upgrade proxy, manage roles, force-cancel orders/offers, toggle KYC gating per action, manage fee collector allowlist, pause/unpause venue |
| **Operator** *(parked, AC-246)* | `OPERATOR_ROLE` | Not granted while parked. Previously: settle matched orders, refund orders. See `admin/OperatorFunctions.sol`. (Offer settlement is not part of this — `settleOffer` was retired outright, merged into `acceptOffer`.) |
| **KYC Backend** | `KYC_OPERATOR_ROLE` | Sign KYC attestations authorising user actions |
| **Fee Service** | `FEE_OPERATOR_ROLE` | Sign fee attestations authorising per-pair fee terms on `placeOrder`/`placeOrderWithPermit`/`makeOffer` — a distinct signer from the KYC backend |
| **Maker** | — | Place orders, place offers, cancel own orders (always unattested), cancel own offers (KYC-gated) |
| **Taker** | — | Fill orders (KYC-gated), accept/counter/cancel offers (KYC-gated) |
| **Anyone** | — | Sweep expired orders (`sweepExpired`) and offers (`sweepExpiredOffers`) |
| **Relayer** | — | Submit gasless meta-transactions via the ERC-2771 forwarder |

In development/testnet deployments all roles may be held by a single EOA. This centralization is intentional for a regulated MiFID-style venue — `DEFAULT_ADMIN_ROLE` is effectively full custody (can `upgradeToAndCall` to arbitrary logic and force-cancel/route any escrow) and must be operationally hardened before mainnet:

- **Admin must be a Safe multisig**, not a single EOA.
- **`upgradeToAndCall` should sit behind a timelock** (e.g. an OZ `TimelockController` as/behind the admin) so upgrades have a mandatory delay/notice window; not implemented on-chain today — deferred as an operational/deployment decision, not a code change, unless mainnet requirements dictate otherwise.
- **`KYC_OPERATOR_ROLE` and `FEE_OPERATOR_ROLE`** must each use a dedicated, well-managed key (separate from the admin multisig and from each other) with secure key management (e.g. HSM/KMS-backed signing).
- Consider splitting collector-allowlist administration from upgrade administration if a single multisig's blast radius is a concern.

---

## 3. Contract Architecture

```
User EOA  ──► ERC2771Forwarder ──► AsseteraExchange (proxy)
                                          │
                                    ERC-1967 proxy
                                          │
                                   AsseteraExchange (impl)
                                   ├── AccessControlUpgradeable
                                   ├── ReentrancyGuardUpgradeable
                                   ├── PausableUpgradeable
                                   ├── EIP712Upgradeable
                                   └── ERC2771ContextUpgradeable
```

- The **proxy** holds all state. The **implementation** holds all logic.
- The forwarder address is immutable in the implementation bytecode (set in the constructor). Changing the forwarder requires deploying a new implementation and upgrading.
- `_authorizeUpgrade` is restricted to `DEFAULT_ADMIN_ROLE`, so only the admin multisig can trigger an upgrade.

---

## 4. KYC Attestation

Every user-initiated state-changing action (except `cancelOrder` and permissionless sweeps) requires a `KycAttestation` signed by a `KYC_OPERATOR_ROLE` holder. It carries **no fee terms** — see [§5](#5-fee-attestation) for the separate fee-service attestation required alongside it on fee-setting actions.

### Struct

```solidity
struct KycAttestation {
    address account;      // the party being authorised; must equal _msgSender()
    Action  action;       // which action this authorises (see Action enum)
    uint256 orderId;      // bound order/offer ID (0 for Place / MakeOffer)
    uint256 nonce;        // single-use random value; burned on consumption
    uint256 deadline;     // unix timestamp after which the attestation is invalid
    bytes32 paramsHash;   // keccak256 of action-specific parameters (see below)
    bytes   signature;    // EIP-712 signature over the above fields
}
```

### EIP-712 Domain

```
name:              "AsseteraExchange"
version:           "1"
chainId:           <deployment chain>
verifyingContract: <proxy address>
```

### Type Hash

```
KycAttestation(address account,uint8 action,uint256 orderId,uint256 nonce,uint256 deadline,bytes32 paramsHash)
```

### Validation rules (enforced in `_verifyKyc`)

| Check | Error |
|---|---|
| `att.account != _msgSender()` | `KycAccountMismatch` |
| `att.action != expectedAction` | `KycActionMismatch` |
| `att.orderId != expectedId` | `KycOrderMismatch` |
| `block.timestamp > att.deadline` | `KycExpired` |
| `att.deadline > block.timestamp + 15 min` | `KycTtlTooLong` |
| Nonce already used | `KycNonceUsed` |
| Recovered signer lacks `KYC_OPERATOR_ROLE` | `KycBadSigner` |
| Non-zero `paramsHash` on a non-parameterised action | `ParamsHashMismatch` |

### paramsHash per action

| Action | paramsHash encoding |
|---|---|
| `Place` | `keccak256(abi.encode(sellToken, sellAmount, buyToken, buyAmount))` |
| `Fill`, `Settle` | `bytes32(0)` (no params hash — see rationale below) |
| `MakeOffer` | `keccak256(abi.encodePacked(taker, makerToken, makerAmount, takerToken, takerAmount))` |
| `ReplaceOffer` | `keccak256(abi.encodePacked(offerId, newMakerAmount, newTakerAmount))` |
| `AcceptOffer` | `keccak256(abi.encodePacked(offerId, makerAmount, takerAmount))` |
| `CancelOffer` | `keccak256(abi.encodePacked(offerId, makerAmount, takerAmount))` |

`AcceptOffer` and `CancelOffer` bind to the **current** `makerAmount` / `takerAmount` stored in the offer at call time, so a stale attestation signed before a `replaceOffer` counter-proposal will be rejected with `ParamsHashMismatch`.

`SettleOffer` (action 8) still exists in the `Action` enum (ordinal stability for off-chain systems) but is unused — `acceptOffer` settles atomically under `AcceptOffer`'s own gate (AC-246); there's no separate settle step to attest to. There is no order-level `Cancel` action — `cancelOrder` never requires (or consumes) a KYC attestation, so no replay concern applies to cancellation either.

**Rationale — why `Fill` does not bind the fill amount:**
Orders support partial fills, meaning `remainingQuantity` can change between the moment the KYC backend signs the attestation and the moment the taker submits the transaction (another taker may have partially filled the order in between). Binding `fillSellAmount` into `paramsHash` would invalidate the attestation whenever the remaining quantity changed, forcing the taker into a retry loop of requesting new signatures. The compliance intent is fully preserved without amount binding: the backend controls *who* may fill *which specific order* (via `orderId` binding); the order's price terms are fixed at placement and enforced by the contract for any fill amount; and the taker cannot redirect the attestation to a different order or act as a different account. Binding the amount would add friction with no additional compliance benefit given the partial-fill model.

---

## 5. Fee Attestation

The three fee-setting actions (`placeOrder`, `placeOrderWithPermit`, `makeOffer`) require a **second**, independent attestation — `FeeAttestation` — signed by a `FEE_OPERATOR_ROLE` holder (the fee service), not the KYC backend. This mirrors the KYC-gate pattern (`_verifyFee`, own EIP-712 typehash, own single-use nonce namespace; both attestations are consumed together via `_consumeKycAndFee`) but is a fully separate trust boundary: a compromised KYC signer can no longer set fees, and vice versa.

### Struct

```solidity
struct FeeAttestation {
    address account;      // the party being authorised; must equal _msgSender()
    Action  action;       // which action this authorises: Place or MakeOffer only
    uint256 nonce;        // single-use random value; burned on consumption (own namespace, usedFeeNonce)
    uint256 deadline;     // unix timestamp after which the attestation is invalid
    bytes32 paramsHash;   // must equal the paired KycAttestation's paramsHash
    uint16  makerFeeBps;  // per-pair maker fee
    uint16  takerFeeBps;  // per-pair taker fee
    address feeCollector; // must be on the admin fee-collector allowlist when either fee bps is non-zero
    bytes   signature;    // EIP-712 signature over the above fields
}
```

No `orderId` field — fee attestations only ever authorise `Place`/`MakeOffer`, both of which are always bound to `orderId == 0`.

### Type Hash

```
FeeAttestation(address account,uint8 action,uint256 nonce,uint256 deadline,bytes32 paramsHash,uint16 makerFeeBps,uint16 takerFeeBps,address feeCollector)
```

### Binding to the paired KycAttestation

`placeOrder`/`placeOrderWithPermit`/`makeOffer` take both `att` (KYC) and `feeAtt` (fee) and bind them together:

- Both are verified against the **same** `account` (`_msgSender()`) and the **same** `action` — so `feeAtt.account == att.account == _msgSender()` and `feeAtt.action == att.action` hold transitively, without an explicit cross-field check.
- Both `att.paramsHash` and `feeAtt.paramsHash` are checked against the **same** on-chain-computed hash (the four `placeOrder` params, or the five `makeOffer` params) — so `feeAtt.paramsHash == att.paramsHash` holds transitively.
- Both attestations are verified (pure/view) **before** either nonce is burned — an invalid fee attestation does not consume the KYC nonce, and vice versa.

A fee attestation therefore cannot be replayed against a different order/offer, paired with a mismatched KYC attestation, or reused by a different account.

### Validation rules (enforced in `_verifyFee`)

| Check | Error |
|---|---|
| `feeAtt.account != _msgSender()` | `FeeAccountMismatch` |
| `feeAtt.action != expectedAction` | `FeeActionMismatch` |
| `block.timestamp > feeAtt.deadline` | `FeeExpired` |
| `feeAtt.deadline > block.timestamp + 15 min` (`MAX_FEE_TTL`) | `FeeTtlTooLong` |
| Nonce already used (`usedFeeNonce`) | `FeeNonceUsed` |
| Recovered signer lacks `FEE_OPERATOR_ROLE` | `FeeBadSigner` |

### Fee bounds (enforced unconditionally by `placeOrder` / `placeOrderWithPermit` / `makeOffer`, defence in depth)

Unlike attestation *verification* above (which is skipped when `complianceRequired[action]` is `false`, same toggle as KYC gating for that action), these bounds are **always** enforced regardless of gating, so a compromised fee signer — or a test run with gating disabled — cannot set extreme fees or redirect them to an arbitrary wallet:

| Check | Error |
|---|---|
| `makerFeeBps > MAX_FEE_BPS` or `takerFeeBps > MAX_FEE_BPS` (`MAX_FEE_BPS = 10_000` = 100%) | `InvalidFee` |
| Either fee bps non-zero and `feeCollector == address(0)` | `ZeroAddress` |
| Either fee bps non-zero and `feeCollector` not on the admin-managed allowlist (`allowedCollectors`) | `FeeCollectorNotAllowed` |

Validation runs before either nonce is consumed, so a call that fails fee validation does not burn either attestation. The fee snapshot (`makerFeeBps`, `takerFeeBps`, `feeCollector`) is stored on the `Order`/`Offer` at creation and is immutable for that order's/offer's lifetime — `replaceOffer` renegotiates amounts but not fee terms, and downstream actions (`fillOrder`, `acceptOffer`, …) read the snapshot rather than requiring a fresh fee attestation.

---

## 6. Order Lifecycle

### State machine

```
                    ┌──────────────────────────────────────────┐
                    │                  OPEN                     │
                    └────┬──────┬──────┬──────┬──────┬─────────┘
                         │      │      │      │      │
                    fill │ fill │cancel│cancel│sweep
                  (part) │(full)│Order │Order │Expired
                         │      │      │ForUsr│
                         ▼      ▼      ▼      ▼
                       OPEN  FILLED  CANCEL FORCE   EXPIRED
                                       -LED  CANCEL
                                             -LED
```

`SETTLED` and `REFUNDED` are still valid `OrderStatus` values but are currently
unreachable — the only transitions into them (`settle`, `refund`) are parked
(AC-246). All terminal states are final — no transitions out.

### Functions

#### `placeOrder(sellToken, sellAmount, buyToken, buyAmount, expireTs, att, feeAtt)`
Maker escrows `sellAmount` of `sellToken`. Requires a `Place` `KycAttestation` (`att`) and a `Place` `FeeAttestation` (`feeAtt`), both with `paramsHash` bound to the four order parameters — see [§5](#5-fee-attestation) for how the two are bound together. `expireTs = 0` means the order never expires. `feeAtt`'s `makerFeeBps`/`takerFeeBps`/`feeCollector` are validated (see [Fee bounds](#fee-bounds-enforced-unconditionally-by-placeorder--placeorderwithpermit--makeoffer-defence-in-depth)) and snapshotted onto the order.

#### `placeOrderWithPermit(sellToken, sellAmount, buyToken, buyAmount, expireTs, permitDeadline, v, r, s, att, feeAtt)`
Same as `placeOrder` (including fee validation/snapshot) but attempts an ERC-2612 `permit` call before the `transferFrom`, allowing the maker to approve and place in a single transaction. The permit failure is swallowed — if the approval is already in place or the token does not support permit, the `transferFrom` still proceeds normally.

#### `cancelOrder(id)`
Maker self-cancel. Never requires a KYC attestation — a user must always be able to cancel their own open order and reclaim escrow, even if the KYC backend refuses to sign for them or is offline. Use `cancelOrderForUser` for compliance-routed release to a non-maker recipient.

#### `fillOrder(id, fillSellAmount, att)`
Taker takes `fillSellAmount` of the order's `sellToken` and pays a proportional `buyToken` amount (`buyAmountDue`) directly to the maker. Uses ceiling division on `buyAmountDue` to protect the maker from rounding loss. A partial fill leaves the order Open; a full fill transitions it to Filled. Requires a `Fill` attestation bound to the `orderId`.

Fees are taken from the order's snapshotted `makerFeeBps`/`takerFeeBps` (floor division, benefiting the maker/taker over the collector):
- `makerFeeAmount = buyAmountDue * makerFeeBps / 10_000` — deducted from what the maker receives (in `buyToken`); maker nets `buyAmountDue - makerFeeAmount`.
- `takerFeeAmount = fillSellAmount * takerFeeBps / 10_000` — deducted from what the taker receives (in `sellToken`); taker nets `fillSellAmount - takerFeeAmount`.
- Both fee legs are paid to the order's `feeCollector`.

#### `settle`, `refund` — parked (AC-246)
Formerly operator-only (`settle` settled two complementary open orders; `refund` returned an open order's remaining escrow to the maker). Neither is reachable on the active contract — see `admin/OperatorFunctions.sol` for the parked implementations and re-enable steps.

#### `cancelOrderForUser(id, recipient)`
Admin-only. Force-cancels any open order and routes escrow to `recipient` (may differ from the maker for compliance routing). Emits `OrderForceCancelled`.

#### `sweepExpired(ids[])`
Permissionless. Returns escrowed tokens to makers of expired open orders. Skips non-open, non-expired, and zero-expiry orders silently. Callers should batch at most 100 IDs per call to avoid out-of-gas. Emits `OrderExpired` for each swept order.

---

## 7. Offer Lifecycle

Offers are targeted bilateral negotiations between a specific maker and taker. Either party can propose, counter-propose, accept, or cancel. Acceptance settles the trade atomically in the same call (AC-246) — the accepting party's side is escrowed and both sides are released to their counterparties (fees deducted) in one transaction, with no separate operator step. `Accepted` is never a persisted state.

### State machine

```
         makeOffer
             │
             ▼
           OPEN ◄──────────────────────────────────────────┐
             │                                              │
     ┌───────┼────────────┐                                 │
     │       │            │                                 │
  replace  cancel      accept                               │
  Offer    Offer       Offer                                 │
     │       │            │                                 │
     ▼       ▼            ▼                           replaceOffer
 COUNTER  CANCEL      SETTLED                         (counter back)
 -ED      -LED      (atomic with                            │
     │                accept)                                │
     │                                                        │
     └──── replaceOffer ──────────────────────────────────►─┘
           (either party counters again)

Any non-terminal state ──► sweepExpiredOffers ──► EXPIRED  (Open/Countered only)
Any non-terminal state ──► cancelOfferForUser ──► FORCE-CANCELLED (Open/Countered only)
```

**Escrow invariant:** At any point, exactly one side's tokens are held by the contract — only the current proposer's tokens (`proposedBy` field), for `Open`/`Countered`. `acceptOffer` escrows the other side and releases both sides to their counterparties within the same call, so there's never a persisted state where both sides sit escrowed.

### Functions

#### `makeOffer(taker, makerToken, makerAmount, takerToken, takerAmount, expireTs, att, feeAtt)`
Creates a targeted offer from `_msgSender()` (maker) to `taker`. Escrows `makerAmount` of `makerToken`. Requires a `MakeOffer` `KycAttestation` (`att`) and a `MakeOffer` `FeeAttestation` (`feeAtt`), both with `paramsHash` binding all five offer parameters — see [§5](#5-fee-attestation) for how the two are bound together. The maker and taker must differ (`OfferSelfTarget`). `feeAtt`'s `makerFeeBps`/`takerFeeBps`/`feeCollector` are validated (see [Fee bounds](#fee-bounds-enforced-unconditionally-by-placeorder--placeorderwithpermit--makeoffer-defence-in-depth)) and snapshotted onto the offer for its lifetime.

#### `replaceOffer(offerId, newMakerAmount, newTakerAmount, expireTs, att)`
Either the maker or taker can counter-propose new amounts. The previous proposer's escrow is returned; the caller escrows their side at the new amounts. Status transitions to `Countered`. `proposedBy` is updated to the caller. Requires a `ReplaceOffer` attestation binding `offerId`, `newMakerAmount`, and `newTakerAmount`. **Fee terms are not renegotiated** — `makerFeeBps`/`takerFeeBps`/`feeCollector` remain fixed from `makeOffer`.

#### `acceptOffer(offerId, att)`
The non-proposing party accepts current terms — settlement is atomic with acceptance (AC-246), no separate operator step. The caller's side is escrowed, then both sides are released to their counterparties: maker receives `takerAmount` of `takerToken` minus `makerFeeBps`; taker receives `makerAmount` of `makerToken` minus `takerFeeBps` (same fee formula the retired `settleOffer` used). Status goes straight to `Settled`. Requires an `AcceptOffer` attestation with `paramsHash` bound to the current offer amounts — stale attestations signed before a counter-proposal will be rejected. Emits both `OfferAccepted` and `OfferSettled`.

#### `cancelOffer(offerId, att)`
Either the maker or taker can cancel while the offer is `Open` or `Countered`. Returns the current proposer's escrowed tokens. Cannot cancel a `Settled` offer. Requires a `CancelOffer` attestation (action 7) to prevent cross-function replay with other offer-level actions.

#### `cancelOfferForUser(offerId, makerRecipient, takerRecipient)`
Admin-only. Force-cancels an offer still `Open`/`Countered` and routes the current proposer's escrowed tokens to a compliance-chosen recipient. Mirrors `cancelOrderForUser`. Not usable on a `Settled` offer — there's no window where both sides sit escrowed waiting for a separate step, since `acceptOffer` completes the trade in the same call.

#### `sweepExpiredOffers(ids[])`
Permissionless. Returns the current proposer's escrowed tokens for expired `Open`/`Countered` offers. Silently skips non-eligible entries (including already-`Settled` offers).

---

## 8. Compliance Features

### KYC gating per action (`complianceRequired`)

Each `Action` enum value maps to a boolean in `complianceRequired`. When `false` for an action, `_verifyKyc` returns immediately, skipping all attestation validation for that action. This allows the admin to turn gating off per-action for testing or phased rollout. All actions default to `true` on deployment. "Freezing" a user is simply the KYC backend declining to sign for them — there is no on-chain blocklist; `cancelOrderForUser` / `cancelOfferForUser` are the compliance escape hatches for releasing a frozen user's escrowed funds.

### Pause

`pause()` / `unpause()` (admin-only, moved from `OPERATOR_ROLE` in AC-246) block all new position-opening calls (`placeOrder`, `placeOrderWithPermit`, `makeOffer`, `fillOrder`, `acceptOffer`, `replaceOffer`). Admin functions, self-cancel, and sweeps remain available while paused so that funds can always be returned.

### Fee collector allowlist

`setAllowedCollector(collector, allowed)` (admin-only) manages `allowedCollectors`, the set of addresses eligible to receive fee proceeds. A non-zero `makerFeeBps`/`takerFeeBps` on a fee attestation is only accepted if `feeCollector` is on this allowlist at the time of `placeOrder`/`placeOrderWithPermit`/`makeOffer` (see [Fee bounds](#fee-bounds-enforced-unconditionally-by-placeorder--placeorderwithpermit--makeoffer-defence-in-depth)). This bounds the blast radius of a compromised fee signer: even a forged fee attestation cannot redirect fee proceeds to an arbitrary wallet, only to a collector the admin multisig has already approved. Emits `CollectorAllowed`. The allowlist is checked **only at placement** — removing a collector does not affect orders/offers already placed against it; they still pay out to that collector on fill/settle (snapshot semantics, by design).

---

## 9. Security Properties

| Property | Mechanism |
|---|---|
| Reentrancy | `nonReentrant` on all state-changing external functions; CEI pattern throughout |
| Overflow / underflow | Solidity 0.8.28 built-in checks |
| Safe transfers | `SafeERC20` for all token operations |
| KYC replay | Per-account single-use nonce (`usedNonce`) burned on consumption |
| Fee-attestation replay | Separate per-account single-use nonce namespace (`usedFeeNonce`), independent of `usedNonce` |
| Cross-function replay | Separate `Action` enum values for order-level vs offer-level operations |
| KYC/fee cross-pairing | `feeAtt`/`att` bound to the same account, action, and on-chain-computed `paramsHash` on every fee-setting call — a fee attestation cannot be paired with a mismatched KYC attestation or a different order/offer |
| Stale attestation | 15-minute hard cap on KYC TTL (`MAX_KYC_TTL`) and fee TTL (`MAX_FEE_TTL`); `KycExpired`/`FeeExpired` revert after deadline |
| Partial attestation burn | `placeOrder`/`placeOrderWithPermit`/`makeOffer` (KYC + fee) verify all required attestations before consuming any nonce (`settle` has the same guarantee — parked, AC-246) |
| Price integrity | Ceiling division in `fillOrder` (`settle`'s cross-multiplication price check is parked, AC-246) |
| Upgrade authority | `_authorizeUpgrade` restricted to `DEFAULT_ADMIN_ROLE` |
| Self-trade | Rejected in `fillOrder` (`SelfTrade`) and `makeOffer` (`OfferSelfTarget`) |
| Zero-address recipient | Rejected in `cancelOrderForUser` and `cancelOfferForUser` |
| Fee-signer isolation | Fee terms are authorised by a distinct `FEE_OPERATOR_ROLE` signer, separate from `KYC_OPERATOR_ROLE` — a compromised KYC signer can no longer set or redirect fees, and vice versa |
| Fee bounds | `makerFeeBps`/`takerFeeBps` capped at `MAX_FEE_BPS` (10,000 = 100%); enforced unconditionally on every fee-setting call regardless of gating |
| Fee redirection | Non-zero-fee `feeCollector` must be on the admin-managed `allowedCollectors` allowlist — a compromised fee signer cannot redirect fee proceeds |
| Token standard | Escrow accounting (`remainingQuantity`, offer amounts) assumes a **standard, non-rebasing, non-fee-on-transfer ERC-20** — it records the nominal amount requested and assumes `transferFrom`/`transfer` delivers exactly that. This is **not enforced on-chain**; it is enforced by the backend token allowlist that already gates KYC/fee attestation signing, which must never approve a fee-on-transfer or rebasing token for trading. Listing a rebasing token would require a contract upgrade |
| Freezable/blacklistable tokens (known limitation) | If a maker or the contract itself is blacklisted on a token with an issuer-controlled freeze (e.g. USDC), `cancelOrder`/`sweepExpired`/`cancelOrderForUser` revert on transfer to the frozen party, stranding that escrow. `cancelOrderForUser` partially mitigates by routing to a *different*, compliance-chosen recipient, but cannot help if the **contract address itself** is frozen — that case is unrecoverable on-chain. Not enforced or worked around in code; the backend token allowlist must factor in a token's freeze/blacklist risk before approving it for trading |

---

## 10. Events

| Event | Emitted by |
|---|---|
| `OrderPlaced` | `placeOrder`, `placeOrderWithPermit` |
| `OrderCancelled` | `cancelOrder` |
| `OrderPartiallyFilled` | `fillOrder` (partial) |
| `OrderFilled` | `fillOrder` (full) |
| `OrderForceCancelled` | `cancelOrderForUser` |
| `OrderExpired` | `sweepExpired` |
| `OfferMade` | `makeOffer` |
| `OfferReplaced` | `replaceOffer` |
| `OfferAccepted` | `acceptOffer` |
| `OfferSettled` | `acceptOffer` (emitted alongside `OfferAccepted` — settles atomically, AC-246) |
| `OfferCancelled` | `cancelOffer` |
| `OfferForceCancelled` | `cancelOfferForUser` |
| `OfferExpired` | `sweepExpiredOffers` |
| `KycConsumed` | any KYC-gated action on attestation consumption |
| `FeeConsumed` | `placeOrder`, `placeOrderWithPermit`, `makeOffer` on fee attestation consumption |
| `ComplianceRequiredSet` | `setComplianceRequired` |
| `CollectorAllowed` | `setAllowedCollector` |

`OrderFilled`, `OrderPartiallyFilled`, `OfferMade` carry fee amounts/collector fields for indexer and client cost disclosure. For exact event signatures, indexed-vs-data parameter layout, and `topic0` values, see [`docs/INDEXER_EVENT_SCHEMA.md`](./INDEXER_EVENT_SCHEMA.md).

---

## 11. Upgrade Considerations

- The contract uses the UUPS proxy pattern. Only the admin (`DEFAULT_ADMIN_ROLE`) can call `upgradeToAndCall`.
- The forwarder address is immutable in each implementation. If the forwarder must change, a new implementation is deployed and the proxy is upgraded.
- Storage layout must be preserved across upgrades. The `__gap[42]` reserve leaves room for up to 42 additional storage slots in future versions of `AsseteraExchange` without colliding with inherited contract storage. (Restored from `[41]` after removing the `_blacklist` mapping freed one slot; `usedFeeNonce` still consumes one slot from the original `[42]` reserve.)
- `initialize(admin, kycSigner, feeSigner)` takes a required `feeSigner` param (granted `FEE_OPERATOR_ROLE`); this is a breaking change to the initializer signature, coordinated with a fresh deploy rather than an in-place upgrade of an already-initialized proxy. The previously-present `operator` param was dropped entirely (commit `78aee84`) since `OPERATOR_ROLE` is unused while parked — see below.
- If a future upgrade introduces new `complianceRequired` entries (new `Action` enum values), a `reinitializer` function must be included and called via `upgradeToAndCall` to initialise the new storage slots — they default to `false` and must be explicitly set.
- **Order-level operator functions are parked (AC-246):** `settle`, `refund`, and the `OPERATOR_ROLE` constant are commented out in `admin/OperatorFunctions.sol`, not deleted. `initialize` no longer has an `operator` parameter (dropped in commit `78aee84`), so re-enabling needs either an initializer ABI change (add `operator` back, requiring a fresh deploy) or a `reinitializer` function that grants `OPERATOR_ROLE` on an already-initialized proxy — plus uncommenting the file and wiring `OperatorFunctions` into `OrderBook`'s inheritance, then deploying a new implementation via `upgradeToAndCall`.
- **`settleOffer` is retired, not parked (AC-246):** its logic is merged into `acceptOffer`, which settles atomically on acceptance. There is nothing to re-enable via upgrade — reintroducing a separate offer-level operator settle step would require new code, not an uncomment.

---

## 12. Out of Scope

- **On-chain price discovery / matching** — Matching is done off-chain by the operator.
- **Dynamic/negotiated fees** — Fee terms (`makerFeeBps`/`takerFeeBps`/`feeCollector`) are snapshotted at `placeOrder`/`makeOffer` and are immutable for that order's/offer's lifetime; they cannot be renegotiated via `replaceOffer` or changed mid-life by the operator.
- **ERC-4337 account abstraction** — Supported in principle via ERC-2771 but not tested.
- **Multi-asset settlement** — Each order and offer is a simple two-token swap.
