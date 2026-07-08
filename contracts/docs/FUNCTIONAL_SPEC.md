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

There is **no on-chain matching engine**. Orders and offers are matched off-chain by the operator, who then drives the settlement call. This keeps gas costs low and lets the operator apply compliance logic before any settlement.

Identity is resolved via `_msgSender()` (ERC-2771), so callers can be plain EOAs, gasless relayer-forwarded EOAs, or future ERC-4337 smart accounts — the contract is agnostic.

---

## 2. Actors and Roles

| Actor | Role constant | Capabilities |
|---|---|---|
| **Admin (multisig)** | `DEFAULT_ADMIN_ROLE` | Upgrade proxy, manage roles, force-cancel orders/offers, toggle KYC gating per action, update blacklist, manage fee collector allowlist |
| **Operator** | `OPERATOR_ROLE` | Settle matched orders, settle accepted offers, refund orders, pause/unpause venue |
| **KYC Backend** | `KYC_OPERATOR_ROLE` | Sign KYC attestations authorising user actions |
| **Fee Service** | `FEE_OPERATOR_ROLE` | Sign fee attestations authorising per-pair fee terms on `placeOrder`/`placeOrderWithPermit`/`makeOffer` — a distinct signer from the KYC backend |
| **Maker** | — | Place orders, place offers, cancel own orders (always unattested), cancel own offers (KYC-gated) |
| **Taker** | — | Fill orders (KYC-gated), accept/counter/cancel offers (KYC-gated) |
| **Anyone** | — | Sweep expired orders (`sweepExpired`) and offers (`sweepExpiredOffers`) |
| **Relayer** | — | Submit gasless meta-transactions via the ERC-2771 forwarder |

In development/testnet deployments all roles may be held by a single EOA. On mainnet the admin must be a Safe multisig and the KYC backend must use a dedicated key with secure key management.

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
| Account on blacklist | `AccountBlacklisted` |
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
| `SettleOffer` | `keccak256(abi.encodePacked(offerId, makerAmount, takerAmount))` |

`AcceptOffer`, `CancelOffer`, and `SettleOffer` bind to the **current** `makerAmount` / `takerAmount` stored in the offer at call time, so a stale attestation signed before a `replaceOffer` counter-proposal will be rejected with `ParamsHashMismatch`.

`SettleOffer` (action 8) is intentionally distinct from `Settle` (action 3) to prevent cross-function attestation replay between order-level and offer-level operations. There is no order-level `Cancel` action — `cancelOrder` never requires (or consumes) a KYC attestation, so no such replay is possible for cancellation.

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
| Account on blacklist | `AccountBlacklisted` |
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

Validation runs before either nonce is consumed, so a call that fails fee validation does not burn either attestation. The fee snapshot (`makerFeeBps`, `takerFeeBps`, `feeCollector`) is stored on the `Order`/`Offer` at creation and is immutable for that order's/offer's lifetime — `replaceOffer` renegotiates amounts but not fee terms, and downstream actions (`fillOrder`, `settle`, `acceptOffer`, `settleOffer`, …) read the snapshot rather than requiring a fresh fee attestation.

---

## 6. Order Lifecycle

### State machine

```
                    ┌─────────────────────────────────────────────────────┐
                    │                      OPEN                           │
                    └────┬──────┬──────┬──────┬──────┬──────┬────────────┘
                         │      │      │      │      │      │
                    fill │ fill │settle│cancel│refund│cancel│sweep
                  (part) │(full)│      │Order │      │Order │Expired
                         │      │      │      │      │ForUsr│
                         ▼      ▼      ▼      ▼      ▼      ▼
                       OPEN  FILLED SETTLED CANCEL REFUND FORCE   EXPIRED
                                          -LED   -ED    CANCEL
                                                        -LED
```

All terminal states are final — no transitions out.

### Functions

#### `placeOrder(sellToken, sellAmount, buyToken, buyAmount, expireTs, att, feeAtt)`
Maker escrows `sellAmount` of `sellToken`. Requires a `Place` `KycAttestation` (`att`) and a `Place` `FeeAttestation` (`feeAtt`), both with `paramsHash` bound to the four order parameters — see [§5](#5-fee-attestation) for how the two are bound together. `expireTs = 0` means the order never expires. `feeAtt`'s `makerFeeBps`/`takerFeeBps`/`feeCollector` are validated (see [Fee bounds](#fee-bounds-enforced-unconditionally-by-placeorder--placeorderwithpermit--makeoffer-defence-in-depth)) and snapshotted onto the order.

#### `placeOrderWithPermit(sellToken, sellAmount, buyToken, buyAmount, expireTs, permitDeadline, v, r, s, att, feeAtt)`
Same as `placeOrder` (including fee validation/snapshot) but attempts an ERC-2612 `permit` call before the `transferFrom`, allowing the maker to approve and place in a single transaction. The permit failure is swallowed — if the approval is already in place or the token does not support permit, the `transferFrom` still proceeds normally.

#### `cancelOrder(id)`
Maker self-cancel. Never requires a KYC attestation and is not blocked by the blacklist — a user must always be able to cancel their own open order and reclaim escrow, even if the KYC backend refuses to sign for them or is offline. Use `cancelOrderForUser` for compliance-routed release to a non-maker recipient.

#### `fillOrder(id, fillSellAmount, att)`
Taker takes `fillSellAmount` of the order's `sellToken` and pays a proportional `buyToken` amount (`buyAmountDue`) directly to the maker. Uses ceiling division on `buyAmountDue` to protect the maker from rounding loss. A partial fill leaves the order Open; a full fill transitions it to Filled. Requires a `Fill` attestation bound to the `orderId`.

Fees are taken from the order's snapshotted `makerFeeBps`/`takerFeeBps` (floor division, benefiting the maker/taker over the collector):
- `makerFeeAmount = buyAmountDue * makerFeeBps / 10_000` — deducted from what the maker receives (in `buyToken`); maker nets `buyAmountDue - makerFeeAmount`.
- `takerFeeAmount = fillSellAmount * takerFeeBps / 10_000` — deducted from what the taker receives (in `sellToken`); taker nets `fillSellAmount - takerFeeAmount`.
- Both fee legs are paid to the order's `feeCollector`.

#### `settle(buyId, sellId, attBuy, attSell)`
Operator-only. Settles two complementary open orders at their full remaining quantities. Verifies both KYC attestations before consuming either nonce — if the second attestation is invalid, the first nonce is not burned. Performs cross-multiplication price checks to ensure both makers receive at least their limit rate.

Only each order's **maker fee** applies at settlement (taker fee is not charged here, since there is no taker in a settle — both sides are makers): `buyId`'s maker fee is deducted from what `sellId`'s maker receives (and vice versa), each paid to its own order's `feeCollector`.

#### `refund(id, reason)`
Operator-only. Returns an open order's remaining escrow to the maker. Emits `OrderRefunded` with a human-readable reason string for audit trail.

#### `cancelOrderForUser(id, recipient)`
Admin-only. Force-cancels any open order and routes escrow to `recipient` (may differ from the maker for compliance routing). Emits `OrderForceCancelled`.

#### `sweepExpired(ids[])`
Permissionless. Returns escrowed tokens to makers of expired open orders. Skips non-open, non-expired, zero-expiry, and blacklisted-maker orders silently. Callers should batch at most 100 IDs per call to avoid out-of-gas. Emits `OrderExpired` for each swept order.

---

## 7. Offer Lifecycle

Offers are targeted bilateral negotiations between a specific maker and taker. Either party can propose, counter-propose, accept, or cancel. The operator settles once both sides have committed.

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
 COUNTER  CANCEL      ACCEPTED                        (counter back)
 -ED      -LED            │                                 │
     │                    ├──── settleOffer ──► SETTLED     │
     │                    └──── cancelOfferForUser ──► FORCE-CANCELLED
     │
     └──── replaceOffer ──────────────────────────────────►─┘
           (either party counters again)

Any non-terminal state ──► sweepExpiredOffers ──► EXPIRED  (Open/Countered only)
Any non-terminal state ──► cancelOfferForUser ──► FORCE-CANCELLED
```

**Escrow invariant:** At any point, exactly one side's tokens are held by the contract:
- `Open` / `Countered` → only the current proposer's tokens (`proposedBy` field)
- `Accepted` → both sides' tokens

### Functions

#### `makeOffer(taker, makerToken, makerAmount, takerToken, takerAmount, expireTs, att, feeAtt)`
Creates a targeted offer from `_msgSender()` (maker) to `taker`. Escrows `makerAmount` of `makerToken`. Requires a `MakeOffer` `KycAttestation` (`att`) and a `MakeOffer` `FeeAttestation` (`feeAtt`), both with `paramsHash` binding all five offer parameters — see [§5](#5-fee-attestation) for how the two are bound together. The maker and taker must differ (`OfferSelfTarget`). `feeAtt`'s `makerFeeBps`/`takerFeeBps`/`feeCollector` are validated (see [Fee bounds](#fee-bounds-enforced-unconditionally-by-placeorder--placeorderwithpermit--makeoffer-defence-in-depth)) and snapshotted onto the offer for its lifetime.

#### `replaceOffer(offerId, newMakerAmount, newTakerAmount, expireTs, att)`
Either the maker or taker can counter-propose new amounts. The previous proposer's escrow is returned; the caller escrows their side at the new amounts. Status transitions to `Countered`. `proposedBy` is updated to the caller. Requires a `ReplaceOffer` attestation binding `offerId`, `newMakerAmount`, and `newTakerAmount`. **Fee terms are not renegotiated** — `makerFeeBps`/`takerFeeBps`/`feeCollector` remain fixed from `makeOffer`.

#### `acceptOffer(offerId, att)`
The non-proposing party accepts current terms and escrows their side. If the taker accepts, `takerAmount` of `takerToken` is escrowed; if the maker accepts a counter, `makerAmount` of `makerToken` is escrowed. Status transitions to `Accepted`. Requires an `AcceptOffer` attestation with `paramsHash` bound to the current offer amounts — stale attestations signed before a counter-proposal will be rejected.

#### `cancelOffer(offerId, att)`
Either the maker or taker can cancel while the offer is `Open` or `Countered`. Returns the current proposer's escrowed tokens. Cannot cancel an `Accepted` offer — use `cancelOfferForUser` (admin). Requires a `CancelOffer` attestation (action 7) to prevent cross-function replay with other offer-level actions.

#### `settleOffer(offerId, makerAtt, takerAtt)`
Operator-only. Transfers escrowed tokens between parties: maker receives `takerAmount` of `takerToken`; taker receives `makerAmount` of `makerToken`. Both parties must provide a `SettleOffer` attestation with `paramsHash` bound to the current offer amounts. Both attestations are verified before either nonce is consumed.

Fees use the offer's snapshotted `makerFeeBps`/`takerFeeBps` (floor division), both paid to the single offer-level `feeCollector`:
- `makerFeeAmount = takerAmount * makerFeeBps / 10_000` — maker nets `takerAmount - makerFeeAmount`.
- `takerFeeAmount = makerAmount * takerFeeBps / 10_000` — taker nets `makerAmount - takerFeeAmount`.

#### `cancelOfferForUser(offerId, makerRecipient, takerRecipient)`
Admin-only. Force-cancels any non-terminal offer and routes escrowed tokens to compliance-chosen recipients. If the offer is `Accepted` (both sides escrowed), both recipients receive their respective tokens. For `Open`/`Countered`, only the current proposer's tokens are held and returned to `makerRecipient` or `takerRecipient` as appropriate.

#### `sweepExpiredOffers(ids[])`
Permissionless. Returns the current proposer's escrowed tokens for expired `Open`/`Countered` offers. `Accepted` offers are not swept (both sides are locked; use `cancelOfferForUser` to release). Silently skips non-eligible and blacklisted-proposer entries.

---

## 8. Compliance Features

### KYC gating per action (`complianceRequired`)

Each `Action` enum value maps to a boolean in `complianceRequired`. When `false` for an action, `_verifyKyc` returns immediately after the blacklist check, skipping all attestation validation for that action. This allows the admin to turn gating off per-action for testing or phased rollout. All actions default to `true` on deployment.

### Blacklist

Accounts are stored pseudonymously as `keccak256(abi.encodePacked(account))`. A blacklisted account is blocked from all KYC-gated actions. `cancelOrder` is exempt — a maker can always cancel their own open order regardless of blacklist status. Expired orders and offers belonging to blacklisted makers/proposers are skipped by the sweep functions — their funds can only be released via `cancelOrderForUser` / `cancelOfferForUser` to a compliance-chosen recipient.

### Pause

`pause()` / `unpause()` (operator-only) block all new position-opening calls (`placeOrder`, `placeOrderWithPermit`, `makeOffer`, `fillOrder`, `acceptOffer`, `replaceOffer`). Admin and operator functions, self-cancel, and sweeps remain available while paused so that funds can always be returned.

### Fee collector allowlist

`setAllowedCollector(collector, allowed)` (admin-only) manages `allowedCollectors`, the set of addresses eligible to receive fee proceeds. A non-zero `makerFeeBps`/`takerFeeBps` on a fee attestation is only accepted if `feeCollector` is on this allowlist at the time of `placeOrder`/`placeOrderWithPermit`/`makeOffer` (see [Fee bounds](#fee-bounds-enforced-unconditionally-by-placeorder--placeorderwithpermit--makeoffer-defence-in-depth)). This bounds the blast radius of a compromised fee signer: even a forged fee attestation cannot redirect fee proceeds to an arbitrary wallet, only to a collector the admin multisig has already approved. Emits `CollectorAllowed`.

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
| Partial attestation burn | `settle`, `settleOffer`, and `placeOrder`/`placeOrderWithPermit`/`makeOffer` (KYC + fee) verify all required attestations before consuming any nonce |
| Price integrity | Cross-multiplication price check in `settle`; ceiling division in `fillOrder` |
| Upgrade authority | `_authorizeUpgrade` restricted to `DEFAULT_ADMIN_ROLE` |
| Self-trade | Rejected in `fillOrder` (`SelfTrade`) and `makeOffer` (`OfferSelfTarget`) |
| Zero-address recipient | Rejected in `cancelOrderForUser` and `cancelOfferForUser` |
| Fee-signer isolation | Fee terms are authorised by a distinct `FEE_OPERATOR_ROLE` signer, separate from `KYC_OPERATOR_ROLE` — a compromised KYC signer can no longer set or redirect fees, and vice versa |
| Fee bounds | `makerFeeBps`/`takerFeeBps` capped at `MAX_FEE_BPS` (10,000 = 100%); enforced unconditionally on every fee-setting call regardless of gating |
| Fee redirection | Non-zero-fee `feeCollector` must be on the admin-managed `allowedCollectors` allowlist — a compromised fee signer cannot redirect fee proceeds |

---

## 10. Events

| Event | Emitted by |
|---|---|
| `OrderPlaced` | `placeOrder`, `placeOrderWithPermit` |
| `OrderCancelled` | `cancelOrder` |
| `OrderPartiallyFilled` | `fillOrder` (partial) |
| `OrderFilled` | `fillOrder` (full) |
| `OrderSettled` | `settle` |
| `OrderRefunded` | `refund` |
| `OrderForceCancelled` | `cancelOrderForUser` |
| `OrderExpired` | `sweepExpired` |
| `OfferMade` | `makeOffer` |
| `OfferReplaced` | `replaceOffer` |
| `OfferAccepted` | `acceptOffer` |
| `OfferCancelled` | `cancelOffer` |
| `OfferSettled` | `settleOffer` |
| `OfferForceCancelled` | `cancelOfferForUser` |
| `OfferExpired` | `sweepExpiredOffers` |
| `KycConsumed` | any KYC-gated action on attestation consumption |
| `FeeConsumed` | `placeOrder`, `placeOrderWithPermit`, `makeOffer` on fee attestation consumption |
| `ComplianceRequiredSet` | `setComplianceRequired` |
| `BlacklistUpdated` | `setBlacklisted` |
| `CollectorAllowed` | `setAllowedCollector` |

`OrderFilled`, `OrderPartiallyFilled`, `OrderSettled`, `OfferMade`, and `OfferSettled` carry fee amounts/collector fields for indexer and client cost disclosure. For exact event signatures, indexed-vs-data parameter layout, and `topic0` values, see [`docs/INDEXER_EVENT_SCHEMA.md`](./INDEXER_EVENT_SCHEMA.md).

---

## 11. Upgrade Considerations

- The contract uses the UUPS proxy pattern. Only the admin (`DEFAULT_ADMIN_ROLE`) can call `upgradeToAndCall`.
- The forwarder address is immutable in each implementation. If the forwarder must change, a new implementation is deployed and the proxy is upgraded.
- Storage layout must be preserved across upgrades. The `__gap[41]` reserve leaves room for up to 41 additional storage slots in future versions of `AsseteraExchange` without colliding with inherited contract storage. (Reduced from `[42]` when the `usedFeeNonce` mapping was added, which consumed one reserved slot.)
- `initialize` now takes a required `feeSigner` param (granted `FEE_OPERATOR_ROLE`) in addition to `admin`/`operator`/`kycSigner`; this is a breaking change to the initializer signature, coordinated with a fresh deploy rather than an in-place upgrade of an already-initialized proxy.
- If a future upgrade introduces new `complianceRequired` entries (new `Action` enum values), a `reinitializer` function must be included and called via `upgradeToAndCall` to initialise the new storage slots — they default to `false` and must be explicitly set.

---

## 12. Out of Scope

- **On-chain price discovery / matching** — Matching is done off-chain by the operator.
- **Dynamic/negotiated fees** — Fee terms (`makerFeeBps`/`takerFeeBps`/`feeCollector`) are snapshotted at `placeOrder`/`makeOffer` and are immutable for that order's/offer's lifetime; they cannot be renegotiated via `replaceOffer` or changed mid-life by the operator.
- **ERC-4337 account abstraction** — Supported in principle via ERC-2771 but not tested.
- **Multi-asset settlement** — Each order and offer is a simple two-token swap.
