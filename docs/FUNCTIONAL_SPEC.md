# AsseteraExchange — Functional Specification

**Version:** 2.9.1  
**Solidity:** 0.8.28  
**Network:** Polygon Amoy (testnet) → Polygon mainnet  
**Proxy pattern:** UUPS (ERC-1967)  
**Meta-tx:** ERC-2771 (OpenZeppelin ERC2771Forwarder)

---

## 1. Overview

AsseteraExchange is an escrow-based, off-chain-matched limit-order venue for regulated real-world asset (RWA) trading. It is designed around a MiFID-style compliance model:

- **Positive gate** — every user-initiated trade action requires a fresh, single-use EIP-712 *KYC attestation* signed by the platform's compliance backend. The backend refuses to sign for unverified or suspended users, effectively freezing them without on-chain writes.
- **Negative / escape hatch** — admin functions (`cancelOrderForUser`, `cancelOfferForUser`) allow the multisig to force-return escrowed funds to a compliance-chosen recipient, bypassing the KYC gate.

There is **no on-chain matching engine**. Orders and offers are matched off-chain by the operator, who then drives the settlement call. This keeps gas costs low and lets the operator apply compliance logic before any settlement.

Identity is resolved via `_msgSender()` (ERC-2771), so callers can be plain EOAs, gasless relayer-forwarded EOAs, or future ERC-4337 smart accounts — the contract is agnostic.

---

## 2. Actors and Roles

| Actor | Role constant | Capabilities |
|---|---|---|
| **Admin (multisig)** | `DEFAULT_ADMIN_ROLE` | Upgrade proxy, manage roles, force-cancel orders/offers, toggle KYC gating per action, update blacklist |
| **Operator** | `OPERATOR_ROLE` | Settle matched orders, settle accepted offers, refund orders, pause/unpause venue |
| **KYC Backend** | `KYC_OPERATOR_ROLE` | Sign KYC attestations authorising user actions |
| **Maker** | — | Place orders, place offers, cancel own orders/offers (KYC-gated or self-cancel) |
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

Every user-initiated state-changing action (except `cancelOrderSelf` and permissionless sweeps) requires a `KycAttestation` signed by a `KYC_OPERATOR_ROLE` holder.

### Struct

```solidity
struct KycAttestation {
    address account;    // the party being authorised; must equal _msgSender()
    Action  action;     // which action this authorises (see Action enum)
    uint256 orderId;    // bound order/offer ID (0 for Place / MakeOffer)
    uint256 nonce;      // single-use random value; burned on consumption
    uint256 deadline;   // unix timestamp after which the attestation is invalid
    bytes32 paramsHash; // keccak256 of action-specific parameters (see below)
    bytes   signature;  // EIP-712 signature over the above fields
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
| `Fill`, `Cancel`, `Settle` | `bytes32(0)` (no params hash — see rationale below) |
| `MakeOffer` | `keccak256(abi.encodePacked(taker, makerToken, makerAmount, takerToken, takerAmount))` |
| `ReplaceOffer` | `keccak256(abi.encodePacked(offerId, newMakerAmount, newTakerAmount))` |
| `AcceptOffer` | `keccak256(abi.encodePacked(offerId, makerAmount, takerAmount))` |
| `CancelOffer` | `keccak256(abi.encodePacked(offerId, makerAmount, takerAmount))` |
| `SettleOffer` | `keccak256(abi.encodePacked(offerId, makerAmount, takerAmount))` |

`AcceptOffer`, `CancelOffer`, and `SettleOffer` bind to the **current** `makerAmount` / `takerAmount` stored in the offer at call time, so a stale attestation signed before a `replaceOffer` counter-proposal will be rejected with `ParamsHashMismatch`.

`CancelOffer` (action 8) and `SettleOffer` (action 9) are intentionally distinct from `Cancel` (action 4) and `Settle` (action 3) to prevent cross-function attestation replay between order-level and offer-level operations.

**Rationale — why `Fill` does not bind the fill amount:**
Orders support partial fills, meaning `remainingQuantity` can change between the moment the KYC backend signs the attestation and the moment the taker submits the transaction (another taker may have partially filled the order in between). Binding `fillSellAmount` into `paramsHash` would invalidate the attestation whenever the remaining quantity changed, forcing the taker into a retry loop of requesting new signatures. The compliance intent is fully preserved without amount binding: the backend controls *who* may fill *which specific order* (via `orderId` binding); the order's price terms are fixed at placement and enforced by the contract for any fill amount; and the taker cannot redirect the attestation to a different order or act as a different account. Binding the amount would add friction with no additional compliance benefit given the partial-fill model.

---

## 5. Order Lifecycle

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

#### `placeOrder(sellToken, sellAmount, buyToken, buyAmount, expireTs, att)`
Maker escrows `sellAmount` of `sellToken`. Requires a `Place` attestation with `paramsHash` bound to the four order parameters. `expireTs = 0` means the order never expires.

#### `placeOrderWithPermit(sellToken, sellAmount, buyToken, buyAmount, expireTs, permitDeadline, v, r, s, att)`
Same as `placeOrder` but attempts an ERC-2612 `permit` call before the `transferFrom`, allowing the maker to approve and place in a single transaction. The permit failure is swallowed — if the approval is already in place or the token does not support permit, the `transferFrom` still proceeds normally.

#### `cancelOrder(id, att)`
KYC-gated maker cancel. Requires a `Cancel` attestation bound to the specific `orderId`. The KYC backend will refuse to sign for suspended users, preventing them from self-cancelling. Use `cancelOrderForUser` to release frozen funds.

#### `cancelOrderSelf(id)`
Maker self-cancel with no KYC attestation required. Blocked only by the on-chain blacklist. Does not consume a KYC nonce, so it remains available even if the KYC backend is offline.

#### `fillOrder(id, fillSellAmount, att)`
Taker takes `fillSellAmount` of the order's `sellToken` and pays a proportional `buyToken` amount directly to the maker. Uses ceiling division to protect the maker from rounding loss. A partial fill leaves the order Open; a full fill transitions it to Filled. Requires a `Fill` attestation bound to the `orderId`.

#### `settle(buyId, sellId, attBuy, attSell)`
Operator-only. Settles two complementary open orders at their full remaining quantities. Verifies both KYC attestations before consuming either nonce — if the second attestation is invalid, the first nonce is not burned. Performs cross-multiplication price checks to ensure both makers receive at least their limit rate.

#### `refund(id, reason)`
Operator-only. Returns an open order's remaining escrow to the maker. Emits `OrderRefunded` with a human-readable reason string for audit trail.

#### `cancelOrderForUser(id, recipient)`
Admin-only. Force-cancels any open order and routes escrow to `recipient` (may differ from the maker for compliance routing). Emits `OrderForceCancelled`.

#### `sweepExpired(ids[])`
Permissionless. Returns escrowed tokens to makers of expired open orders. Skips non-open, non-expired, zero-expiry, and blacklisted-maker orders silently. Callers should batch at most 100 IDs per call to avoid out-of-gas. Emits `OrderExpired` for each swept order.

---

## 6. Offer Lifecycle

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

#### `makeOffer(taker, makerToken, makerAmount, takerToken, takerAmount, expireTs, att)`
Creates a targeted offer from `_msgSender()` (maker) to `taker`. Escrows `makerAmount` of `makerToken`. Requires a `MakeOffer` attestation with `paramsHash` binding all five offer parameters. The maker and taker must differ (`OfferSelfTarget`).

#### `replaceOffer(offerId, newMakerAmount, newTakerAmount, expireTs, att)`
Either the maker or taker can counter-propose new amounts. The previous proposer's escrow is returned; the caller escrows their side at the new amounts. Status transitions to `Countered`. `proposedBy` is updated to the caller. Requires a `ReplaceOffer` attestation binding `offerId`, `newMakerAmount`, and `newTakerAmount`.

#### `acceptOffer(offerId, att)`
The non-proposing party accepts current terms and escrows their side. If the taker accepts, `takerAmount` of `takerToken` is escrowed; if the maker accepts a counter, `makerAmount` of `makerToken` is escrowed. Status transitions to `Accepted`. Requires an `AcceptOffer` attestation with `paramsHash` bound to the current offer amounts — stale attestations signed before a counter-proposal will be rejected.

#### `cancelOffer(offerId, att)`
Either the maker or taker can cancel while the offer is `Open` or `Countered`. Returns the current proposer's escrowed tokens. Cannot cancel an `Accepted` offer — use `cancelOfferForUser` (admin). Requires a `CancelOffer` attestation (action 8, distinct from order-level `Cancel`) to prevent cross-function replay.

#### `settleOffer(offerId, makerAtt, takerAtt)`
Operator-only. Transfers escrowed tokens between parties: maker receives `takerAmount` of `takerToken`; taker receives `makerAmount` of `makerToken`. Both parties must provide a `SettleOffer` attestation with `paramsHash` bound to the current offer amounts. Both attestations are verified before either nonce is consumed.

#### `cancelOfferForUser(offerId, makerRecipient, takerRecipient)`
Admin-only. Force-cancels any non-terminal offer and routes escrowed tokens to compliance-chosen recipients. If the offer is `Accepted` (both sides escrowed), both recipients receive their respective tokens. For `Open`/`Countered`, only the current proposer's tokens are held and returned to `makerRecipient` or `takerRecipient` as appropriate.

#### `sweepExpiredOffers(ids[])`
Permissionless. Returns the current proposer's escrowed tokens for expired `Open`/`Countered` offers. `Accepted` offers are not swept (both sides are locked; use `cancelOfferForUser` to release). Silently skips non-eligible and blacklisted-proposer entries.

---

## 7. Compliance Features

### KYC gating per action (`complianceRequired`)

Each `Action` enum value maps to a boolean in `complianceRequired`. When `false` for an action, `_verifyKyc` returns immediately after the blacklist check, skipping all attestation validation for that action. This allows the admin to turn gating off per-action for testing or phased rollout. All actions default to `true` on deployment.

### Blacklist

Accounts are stored pseudonymously as `keccak256(abi.encodePacked(account))`. A blacklisted account is blocked from all KYC-gated actions and from `cancelOrderSelf`. Expired orders and offers belonging to blacklisted makers/proposers are skipped by the sweep functions — their funds can only be released via `cancelOrderForUser` / `cancelOfferForUser` to a compliance-chosen recipient.

### Pause

`pause()` / `unpause()` (operator-only) block all new position-opening calls (`placeOrder`, `placeOrderWithPermit`, `makeOffer`, `fillOrder`, `acceptOffer`, `replaceOffer`). Admin and operator functions, self-cancel, and sweeps remain available while paused so that funds can always be returned.

---

## 8. Security Properties

| Property | Mechanism |
|---|---|
| Reentrancy | `nonReentrant` on all state-changing external functions; CEI pattern throughout |
| Overflow / underflow | Solidity 0.8.28 built-in checks |
| Safe transfers | `SafeERC20` for all token operations |
| KYC replay | Per-account single-use nonce burned on consumption |
| Cross-function replay | Separate `Action` enum values for order-level vs offer-level operations |
| Stale attestation | 15-minute hard cap on KYC TTL (`MAX_KYC_TTL`); `KycExpired` revert after deadline |
| Partial attestation burn | `settle` and `settleOffer` verify both attestations before consuming either nonce |
| Price integrity | Cross-multiplication price check in `settle`; ceiling division in `fillOrder` |
| Upgrade authority | `_authorizeUpgrade` restricted to `DEFAULT_ADMIN_ROLE` |
| Self-trade | Rejected in `fillOrder` (`SelfTrade`) and `makeOffer` (`OfferSelfTarget`) |
| Zero-address recipient | Rejected in `cancelOrderForUser` and `cancelOfferForUser` |

---

## 9. Events

| Event | Emitted by |
|---|---|
| `OrderPlaced` | `placeOrder`, `placeOrderWithPermit` |
| `OrderCancelled` | `cancelOrder`, `cancelOrderSelf` |
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
| `ComplianceRequiredSet` | `setComplianceRequired` |
| `BlacklistUpdated` | `setBlacklisted` |

---

## 10. Upgrade Considerations

- The contract uses the UUPS proxy pattern. Only the admin (`DEFAULT_ADMIN_ROLE`) can call `upgradeToAndCall`.
- The forwarder address is immutable in each implementation. If the forwarder must change, a new implementation is deployed and the proxy is upgraded.
- Storage layout must be preserved across upgrades. The `__gap[43]` reserve leaves room for up to 43 additional storage slots in future versions of `AsseteraExchange` without colliding with inherited contract storage.
- If a future upgrade introduces new `complianceRequired` entries (new `Action` enum values), a `reinitializer` function must be included and called via `upgradeToAndCall` to initialise the new storage slots — they default to `false` and must be explicitly set.

---

## 11. Out of Scope

- **On-chain price discovery / matching** — Matching is done off-chain by the operator.
- **Fee collection** — No fee mechanism is present in this version.
- **ERC-4337 account abstraction** — Supported in principle via ERC-2771 but not tested.
- **Multi-asset settlement** — Each order and offer is a simple two-token swap.
