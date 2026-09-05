# AsseteraECS — Interface & Event Schema (Indexer/API Reference)

**Contract version:** `AsseteraECS` 4.1.0 (AO-746), `AsseteraPrimarySales` 1.0.0 (both from `version()` in source). ⚠️ This is the version this document describes, i.e. what is in this source tree. A chain reports whatever implementation is installed on it, which can lag; ask the chain, do not assume.
**Solidity:** 0.8.28
**Proxy pattern:** UUPS (ERC-1967) — index the **proxy** address; ABI/events come from the **implementation**
**Meta-tx:** ERC-2771 (see [Actor resolution](#actor-resolution-erc-2771-meta-tx) — do not key identity off `tx.from`)
**Source of truth:** `src/AsseteraECS.sol`. This document is generated from that file directly (event/error signatures hashed independently), not from the checked-in `abi/AsseteraECS.json`, which is stale — see [Schema versioning](#schema-versioning--breaking-change) below.
**Second contract:** the primary market is `AsseteraPrimarySales` (`src/primary/AsseteraPrimarySales.sol`) — a **separate proxy at a separate address**, with its own EIP-712 domain, its own roles, its own nonce namespaces and its own events. Its event set is documented in [§4 · Primary sales](#primary-sales--a-second-contract-at-a-second-address). ⚠️ **Do not point one address filter at every event in this document.**
**Third kind of address:** each of our own primary offerings has its own **per-offering sale contract**, `AsseteraIssuanceVenue` — one deployment per token, not upgradeable, not in any deployment manifest, discovered from the catalogue's `primary_sale_contract` column. Its events are documented in [§4 · Issuance venues](#issuance-venues--a-third-kind-of-address-one-per-offering). A settlement is fully described by the router's `PrimarySettled` whether the venue is ours or a third party's, so subscribing to venues is a reconciliation choice rather than a requirement.

### Addresses

**Addresses are not listed in this document.** They live in `packages/sdk/src/deployments/<chainId>.json`,
one record per chain, written by the deploy script itself and shipped in the published SDK. Read them from
there, not from prose:

```ts
import { getDeployment, getEcsAddress } from '@asseteragmbh/evm-contracts/contracts';

const ecs       = getEcsAddress(chainId);                       // the exchange proxy
const record    = getDeployment(chainId);
const router    = record.contracts.AsseteraPrimarySales;        // a DIFFERENT address, see above
const forwarder = record.contracts.Forwarder;
const fromBlock = record.metadata.deployBlock;                  // where to start indexing
```

Non-TypeScript consumers can read the same JSON files directly; they are part of the package.

This section used to carry a hardcoded table. Every address in it was wrong: the proxy and forwarder listed
matched nothing in the repository, one of the two deployed chains was missing entirely, and the file path it
cited as its source had moved. That is the expected end state for addresses written into prose, which is why
there is no longer a table to update. A proxy address also survives implementation upgrades but **not** a
fresh deploy at a new salt, so treat any address you have cached as valid only for the deployment record it
came from.

⚠️ Confirm the current implementation via the `eip1967.proxy.implementation` slot or `proxiableUUID()` before
assuming this document's function set is what is deployed on a given network. The record names the
implementation the deploy script installed, not necessarily what is live now.

---

## 1. How to get the full ABI

```
abi/AsseteraECS.json
```

Regenerate after any contract change with `forge build` (emits `out/AsseteraECS.sol/AsseteraECS.json`, which should be copied/synced to `abi/`). **The current `abi/AsseteraECS.json` predates the fee-enrichment of `OfferMade`/`OfferSettled`, the `OrderPlaced`/`OrderCancelled` parity fields, and the AO-746 order link on `OfferMade`/`OfferAccepted` (plus the two events AO-746 added) — do not rely on it for those events until it is rebuilt.** All signatures, topics, and selectors in this document were computed directly from the current `src/AsseteraECS.sol` source, independent of that file.

---

## 2. Public interface reference

All state-changing functions accept a `KycAttestation calldata att` (or two, for two-party actions) unless noted. The three fee-setting actions (`placeOrder`, `placeOrderWithPermit`, `makeOffer`) additionally require a `FeeAttestation calldata feeAtt` from the separate fee service — fees are no longer carried inside `KycAttestation`. See [§3](#kycattestation-off-chain-struct) for both structs' shapes.

### Maker actions

| Function | Access | Notes |
|---|---|---|
| `placeOrder(address sellToken, uint256 sellAmount, address buyToken, uint256 buyAmount, uint64 expireTs, KycAttestation calldata att, FeeAttestation calldata feeAtt) → uint256 id` | KYC-gated (`Action.Place`) + fee-gated | Escrows `sellAmount` of `sellToken`. `att`/`feeAtt` are bound together (same account/action/paramsHash). Emits `OrderPlaced`. |
| `placeOrderWithPermit(address sellToken, uint256 sellAmount, address buyToken, uint256 buyAmount, uint64 expireTs, uint256 permitDeadline, uint8 v, bytes32 r, bytes32 s, KycAttestation calldata att, FeeAttestation calldata feeAtt) → uint256 id` | KYC-gated (`Action.Place`) + fee-gated | Same as `placeOrder`; attempts ERC-2612 `permit` first (best-effort, swallowed on failure). |
| `cancelOrder(uint256 id)` | maker only, no attestation required | A maker can always cancel their own open order and reclaim escrow, regardless of KYC status. Emits `OrderCancelled`. |

### Taker actions

| Function | Access | Notes |
|---|---|---|
| `fillOrder(uint256 id, uint256 fillSellAmount, KycAttestation calldata att)` | KYC-gated (`Action.Fill`) | No fee attestation — fee terms are read from the order's snapshot. Emits `OrderFilled` (full) or `OrderPartiallyFilled` (partial). |

### Offer lifecycle (maker/taker, party-restricted)

| Function | Access | Notes |
|---|---|---|
| `makeOffer(uint256 orderId, address taker, address makerToken, uint256 makerAmount, address takerToken, uint256 takerAmount, uint64 expireTs, KycAttestation calldata att, FeeAttestation calldata feeAtt) → uint256 id` | KYC-gated (`Action.MakeOffer`) + fee-gated | Targeted at a specific `taker`. **The leading `orderId` is new (AO-746)** — the order this offer is raised against, `0` for a standalone offer. `att`/`feeAtt` are bound together. Emits `OfferMade`, preceded by `OrderEscrowDrawn` when the maker funds their leg out of the linked order. |
| `replaceOffer(uint256 offerId, uint256 newMakerAmount, uint256 newTakerAmount, uint64 expireTs, KycAttestation calldata att)` | maker or taker, KYC-gated (`Action.ReplaceOffer`) | No fee attestation — fee terms are fixed from `makeOffer`, not renegotiated. Counter-proposal; flips `proposedBy`. Emits `OfferReplaced`, preceded by `OrderEscrowDrawn` when the incoming proposer owns the linked order (AO-746). |
| `cancelOffer(uint256 offerId, KycAttestation calldata att)` | maker or taker, KYC-gated (`Action.CancelOffer`) | Only while `Open`/`Countered`. Emits `OfferCancelled`. |
| `acceptOffer(uint256 offerId, KycAttestation calldata att)` | non-proposing party, KYC-gated (`Action.AcceptOffer`) | Settles atomically (AC-246) — escrows the accepting side, then releases both sides to their counterparties (fees deducted). No separate operator step. Emits `OfferAccepted` then `OfferSettled`, with `OrderEscrowDrawn` between them when the acceptor funds their leg out of the linked order, and `OrderClosedByOffer` last when that order is now fully consumed (AO-746). |

**Linking an offer to an order (AO-746).** Pass `orderId = 0` for a standalone offer. When it is non-zero the order must be `Open`, must be owned by the maker **or** the taker of the offer, and must sell a token that one of the two legs trades; otherwise `makeOffer` reverts with `OrderNotOpen(orderId)` or the new `OrderNotLinkable(orderId)`. A link the contract would never honour is refused at creation rather than recorded and ignored. What the link then does to escrow is the subject of [Orders and offers now share escrow](#orders-and-offers-now-share-escrow-ao-746) below — read that section before modelling `remainingQuantity`.

⚠️ **`orderId` is deliberately NOT part of the attestation `paramsHash`.** The MakeOffer preimage is unchanged — `keccak256(abi.encodePacked(taker, makerToken, makerAmount, takerToken, takerAmount))` — so **AsseteraComplianceService and AsseteraMarketplaceAPI need no change to their params-hash implementations**. No attestation encoding moved in AO-746. The escrow source is guarded on chain instead (only the order's own maker can draw, and only for the token that order already holds), so a substituted `orderId` can move no funds the caller had not already committed.

### Operator actions (`OPERATOR_ROLE`) — order-level parked, offer-level retired (AC-246)

`settle`, `refund`, and the `OPERATOR_ROLE` constant itself are commented out
(`docs/parked/OperatorFunctions.sol`), not part of the deployed ABI. Standard
order operation needs no operator actions — settlement/matching isn't done
on-chain. `OrderSettled`/`OrderRefunded` are likewise not emitted.
`settleOffer` is different: it isn't parked, it's **retired** — its logic was
merged into `acceptOffer` (above), which settles atomically on acceptance.
`OfferSettled` **is still emitted**, just from `acceptOffer` now. `pause()`/
`unpause()` moved to `DEFAULT_ADMIN_ROLE` (see below) rather than being parked,
since a "stop the venue" lever is worth keeping active.

### Admin actions (`DEFAULT_ADMIN_ROLE`)

| Function | Notes |
|---|---|
| `cancelOrderForUser(uint256 id, address recipient)` | Escape hatch for frozen makers. Emits `OrderForceCancelled`. |
| `cancelOfferForUser(uint256 offerId, address makerRecipient, address takerRecipient)` | Only `Open`/`Countered` — `Accepted` is never a persisted state (`acceptOffer` settles atomically, AC-246). Emits `OfferForceCancelled`. |
| `setAllowedCollector(address collector, bool allowed)` | Fee collector allowlist. Emits `CollectorAllowed`. |
| `setComplianceRequired(Action action, bool required)` | Per-action **KYC** gating toggle — does not affect fee-attestation verification (AC-884). Emits `ComplianceRequiredSet`. |
| `pause()` / `unpause()` | Moved from `OPERATOR_ROLE` (AC-246). Gates `whenNotPaused` functions. Emits standard `Paused(address)`/`Unpaused(address)`. |
| `upgradeToAndCall(address newImplementation, bytes data)` | Inherited UUPS; gated via `_authorizeUpgrade`. Emits standard `Upgraded(address)`. |

### Permissionless (anyone may call)

| Function | Notes |
|---|---|
| `sweepExpired(uint256[] calldata ids)` | Batch-sweeps expired `Open` orders back to maker. Silently skips non-matching entries. Batch ids in chunks of ≤100. Emits `OrderExpired` per swept id. |
| `sweepExpiredOffers(uint256[] calldata ids)` | Same, for offers. Emits `OfferExpired` per swept id. |

### Views

| Function | Returns |
|---|---|
| `getOrder(uint256 id)` | `Order` struct (see [§3](#order-struct)) — point read only; enumeration/pagination is served off-chain by the indexer |
| `getOffer(uint256 id)` | `Offer` struct |
| `totalOrders()` / `totalOffers()` | `uint256` — highest assigned id (ids are `1..total`) |
| `usedNonce(address account, uint256 nonce)` | `bool` — KYC nonce consumption state |
| `usedFeeNonce(address account, uint256 nonce)` | `bool` — fee attestation nonce consumption state (separate namespace from `usedNonce`) |
| `complianceRequired(uint8 action)` | `bool` — whether that action currently requires a **KYC** attestation. The argument is the `Action` ordinal; the getter is declared `uint8` since AO-514 because the gate is shared with venues that define their own action set (same selector, same argument type). Fee attestations are always required on `Place`/`MakeOffer`, independently of this (AC-884) |
| `allowedCollectors(address)` | `bool` |
| `version()` | `string` |
| `hasRole(bytes32 role, address account)`, `getRoleAdmin(bytes32 role)` | inherited `AccessControlUpgradeable` |
| `paused()` | inherited `PausableUpgradeable` |
| `eip712Domain()` | inherited `EIP712Upgradeable` |
| `isTrustedForwarder(address)`, `trustedForwarder()` | inherited `ERC2771ContextUpgradeable` |

---

## 3. Data model

### `OrderStatus` (uint8)

| Value | Name |
|---|---|
| 0 | `None` |
| 1 | `Open` |
| 2 | `Filled` — reached by a fill that takes `remainingQuantity` to zero, **or by an accepted offer that consumed the order** (AO-746, see `OrderClosedByOffer`) |
| 3 | `Settled` — unreachable while `settle` is parked (AC-246) |
| 4 | `Cancelled` |
| 5 | `Refunded` — unreachable while `refund` is parked (AC-246) |
| 6 | `ForceCancelled` |
| 7 | `Expired` |

### `OfferStatus` (uint8)

| Value | Name |
|---|---|
| 0 | `None` |
| 1 | `Open` |
| 2 | `Countered` |
| 3 | `Accepted` — defined but never a persisted state (AC-246); `acceptOffer` settles atomically, writing `Settled` directly |
| 4 | `Settled` — the reachable terminal state for a completed trade, written directly by `acceptOffer` (AC-246) |
| 5 | `Cancelled` |
| 6 | `ForceCancelled` |
| 7 | `Expired` |

### `Action` (uint8) — used in `KycConsumed.action` and `ComplianceRequiredSet.action`

| Value | Name |
|---|---|
| 0 | `None` |
| 1 | `Place` |
| 2 | `Fill` |
| 3 | `Settle` |
| 4 | `MakeOffer` |
| 5 | `ReplaceOffer` |
| 6 | `AcceptOffer` |
| 7 | `CancelOffer` |
| 8 | `SettleOffer` — unused (AC-246); kept for ordinal stability, never checked against any attestation. `acceptOffer` settles under its own `AcceptOffer` gate. |

There is no order-level `Cancel` action — `cancelOrder` never requires (or consumes) a KYC attestation. `CancelOffer` is deliberately distinct from `Settle` — an attestation for one cannot be replayed against the other.

### `Order` struct

| Field | Type | Notes |
|---|---|---|
| `id` | `uint256` | 1-indexed |
| `maker` | `address` | |
| `sellToken` | `address` | |
| `sellAmount` | `uint256` | original escrowed amount |
| `buyToken` | `address` | |
| `buyAmount` | `uint256` | original desired amount |
| `status` | `OrderStatus` | |
| `createdAt` | `uint64` | unix seconds |
| `remainingQuantity` | `uint256` | remaining `sellAmount` not yet filled/settled |
| `expireTs` | `uint64` | `0` = never expires |
| `makerFeeBps` | `uint16` | fee snapshot at placement, immutable thereafter |
| `takerFeeBps` | `uint16` | |
| `feeCollector` | `address` | allowlisted recipient |
| `feeToken` | `address` | the settlement currency both fees are denominated in; asserted to be one of `sellToken`/`buyToken` (AC-833) |
| `escrowedFee` | `uint256` | unconsumed maker-fee escrow, in `feeToken`. Non-zero only when the maker escrowed the currency leg. It is the maker's money until a fill earns it, so every unwind path returns whatever is left — including the AO-746 cross-close, which reports it as `OrderClosedByOffer.refunded` |

### `Offer` struct

| Field | Type | Notes |
|---|---|---|
| `id` | `uint256` | 1-indexed |
| `maker` | `address` | initiating party |
| `taker` | `address` | targeted counterparty |
| `makerToken` | `address` | |
| `makerAmount` | `uint256` | current round's terms |
| `takerToken` | `address` | |
| `takerAmount` | `uint256` | current round's terms |
| `status` | `OfferStatus` | |
| `createdAt` | `uint64` | |
| `expireTs` | `uint64` | |
| `proposedBy` | `address` | who made the current round's proposal (their tokens are escrowed) |
| `makerFeeBps` | `uint16` | fixed at `makeOffer`, not renegotiated by `replaceOffer` |
| `takerFeeBps` | `uint16` | |
| `feeCollector` | `address` | `address(0)` when no fee |
| `feeToken` | `address` | the settlement currency both fees are denominated in; asserted to be one of `makerToken`/`takerToken` (AC-833) |
| `escrowedFee` | `uint256` | unconsumed fee escrow of the **current** proposer, in `feeToken`. Offers are all-or-nothing, so it is either fully consumed by settlement or fully refunded — including by `replaceOffer`, which unwinds the previous proposer and re-escrows the caller at the new amounts |
| `orderId` | `uint256` | **appended by AO-746** — the order this offer was raised against, or `0` for a standalone offer. Set once at `makeOffer` and never changed. Mirrored out in `OfferMade.orderId` and `OfferAccepted.orderId`, so an indexer never has to call `getOffer` to recover the link |

`orderId` sits at struct word 12, appended after `escrowedFee`. Appending is upgrade-safe because `Offer` lives in a mapping (`_offers`), so each entry has its own hashed base and a new trailing word collides with nothing. A caller decoding `getOffer` by fixed tuple arity must be rebuilt; one decoding by ABI will pick the new field up.

When `orderId` is non-zero the two entries share escrow — see [Orders and offers now share escrow](#orders-and-offers-now-share-escrow-ao-746).

### `KycAttestation` (off-chain struct)

Not stored on-chain; passed as calldata to state-changing calls and reflected into `KycConsumed`. Carries **no fee terms** — see `FeeAttestation` below.

| Field | Type |
|---|---|
| `account` | `address` |
| `action` | `uint8` (the `Action` ordinal; declared `uint8` since AO-514) |
| `orderId` | `uint256` — the order **or offer** id the attestation is bound to, `0` for actions that create one (`Place`, `MakeOffer`). ⚠️ Not the AO-746 offer-to-order link: a `makeOffer` that links an order still signs `orderId == 0` here |
| `nonce` | `uint256` |
| `deadline` | `uint256` |
| `paramsHash` | `bytes32` |
| `signature` | `bytes` |

`KYC_TYPEHASH = 0x9d47d5391d5fdceebb227638b24f6b391e7e39fd6671f3b7478c9767dd1ba835`
(`keccak256("KycAttestation(address account,uint8 action,uint256 orderId,uint256 nonce,uint256 deadline,bytes32 paramsHash)")`)

### `FeeAttestation` (off-chain struct)

Not stored on-chain; required alongside a `KycAttestation` on `placeOrder`, `placeOrderWithPermit`, and `makeOffer` (the fee-setting actions), and reflected into `FeeConsumed`. Signed by a `FEE_OPERATOR_ROLE` holder (the fee service) — a separate signer from KYC. Has its own nonce namespace (`usedFeeNonce`, distinct from `usedNonce`). No `orderId` field: fee attestations only ever authorise Place/MakeOffer, both of which are bound via `orderId == 0`.

The contract binds `feeAtt` to the paired `kycAtt` by checking both against the *same* `account`/`action`, and both `paramsHash` fields against the *same* on-chain-computed hash — so a fee attestation cannot be replayed against a different order/offer or paired with a mismatched KYC attestation. The fee side of that binding holds whatever `complianceRequired[action]` says (AC-884); only the KYC side follows the toggle.

| Field | Type |
|---|---|
| `account` | `address` |
| `action` | `uint8` (the `Action` ordinal; declared `uint8` since AO-514) — `Place` or `MakeOffer` |
| `nonce` | `uint256` |
| `deadline` | `uint256` |
| `paramsHash` | `bytes32` — always bound to the call's on-chain-computed params hash; equal to the paired `KycAttestation.paramsHash` whenever KYC gating is on for the action |
| `makerFeeBps` | `uint16` |
| `takerFeeBps` | `uint16` |
| `feeCollector` | `address` |
| `feeToken` | `address` — the settlement currency; must be one of the two trade legs (AC-833) |
| `signature` | `bytes` |

`FEE_TYPEHASH = 0x3531aff0e1bd1af792c545fad8cd142e11c96b67decff1940a98277c8c4f530a`
(`keccak256("FeeAttestation(address account,uint8 action,uint256 nonce,uint256 deadline,bytes32 paramsHash,uint16 makerFeeBps,uint16 takerFeeBps,address feeCollector,address feeToken)")`)

The whole fee attestation is verified on every fee-setting call regardless of `complianceRequired` gating (AC-884) — signature, deadline, nonce and `paramsHash` — and the on-chain bounds (`MAX_FEE_BPS` cap, `allowedCollectors` allowlist check, `feeToken ∈ {legA, legB}`) are re-checked on top as defence in depth against a compromised fee signer.

### Role constants (for decoding inherited `RoleGranted`/`RoleRevoked` events)

| Role | Value |
|---|---|
| `DEFAULT_ADMIN_ROLE` | `0x0000000000000000000000000000000000000000000000000000000000000000` |
| `OPERATOR_ROLE` | `0x97667070c54ef182b0f5858b034beac1b6f3089aa2d3188bb1e8929f4fa9b929` — parked (AC-246): not granted, `RoleGranted` for it should not appear post-deploy |
| `KYC_OPERATOR_ROLE` | `0xdf54a8fce50b9de7187b8b9daaa3b95e6ef1bf1df5fe0a03ddea8faa73de2a10` |
| `FEE_OPERATOR_ROLE` | `0x8efbb70a6b43a0e337cb93750666361f6a0fe46a0aee356063f13c9b68520bb7` |

---

## 4. Event schema

Event summary — **`AsseteraECS` (the exchange / secondary market)**:

| Event | Emitted by |
|---|---|
| `OrderPlaced` | `placeOrder`, `placeOrderWithPermit` |
| `OrderCancelled` | `cancelOrder` |
| `OrderFilled` | `fillOrder` (full fill) |
| `OrderPartiallyFilled` | `fillOrder` (partial fill) |
| `OrderForceCancelled` | `cancelOrderForUser` |
| `OrderExpired` | `sweepExpired` (once per swept id) |
| `CollectorAllowed` | `setAllowedCollector` |
| `KycConsumed` | any KYC-gated action, on attestation consumption |
| `FeeConsumed` | `placeOrder`, `placeOrderWithPermit`, `makeOffer`, on fee attestation consumption |
| `ComplianceRequiredSet` | `setComplianceRequired` |
| `OfferMade` | `makeOffer` |
| `OfferReplaced` | `replaceOffer` |
| `OfferCancelled` | `cancelOffer` |
| `OfferForceCancelled` | `cancelOfferForUser` |
| `OfferExpired` | `sweepExpiredOffers` (once per swept id) |
| `OfferAccepted` | `acceptOffer` |
| `OfferSettled` | `acceptOffer` (emitted right after `OfferAccepted`, same transaction — AC-246) |
| `OrderEscrowDrawn` | `makeOffer`, `replaceOffer`, `acceptOffer` — only when the proposing/accepting party owns the linked order and funds their leg out of it (AO-746). Zero or one per call |
| `OrderClosedByOffer` | `acceptOffer` — only when settlement consumed the linked order's whole quantity (AO-746). Last event of the transaction |

`OrderSettled` (`settle`) and `OrderRefunded` (`refund`) are **not emitted** —
their emitting functions are parked (AC-246). See
[§5](#operator-functions-parked--offer-settlement-merged-into-acceptoffer-ac-246)
below; their event detail sections further down are kept for reference
(topic0/selector) in case of re-enable, not because they currently fire.
`OfferSettled` is the exception — it fires again, just from `acceptOffer`
instead of the now-retired `settleOffer`.

Event summary — **`AsseteraPrimarySales` (the primary market)**, a **different contract at a different address**:

| Event | Emitted by |
|---|---|
| `PrimarySettled` | `settlePrimary` — one per completed primary purchase |
| `PrimaryRedeemed` | `redeemPrimary` — one per completed sell back to a venue (AO-847). A **second topic**, not a change to `PrimarySettled` |
| `IntentConsumed` | `settlePrimary` and `redeemPrimary`, on intent consumption. The `action` ordinal is what tells the two legs apart |
| `SettlementCapSet` | `setSettlementCap` (admin) |
| `WhitelistHandshake` | `whitelistHandshake` (admin) — a venue funding-wallet handshake, no analogue on the exchange |
| `CollectorAllowed` | `setAllowedCollector` (admin) — **same signature and same `topic0`** as the exchange's |
| `ComplianceRequiredSet` | `setComplianceRequired` (admin) — **same `topic0`** as the exchange's, but a **different `Action` ordinal set** |
| `KycConsumed` | `settlePrimary` / `redeemPrimary`, when `complianceRequired[action]` — **same `topic0`** as the exchange's, different ordinals |
| `FeeConsumed` | `settlePrimary` / `redeemPrimary`, unconditionally — **same `topic0`** as the exchange's, different ordinals |

⚠️ The last four share their `topic0` with the exchange's events of the same name, because both
contracts inherit the same `KycGate`/`FeeGate` and the same admin surface. **They can only be
attributed by emitting address, never by topic**, and `KycConsumed.action` /
`ComplianceRequiredSet.action` mean different things depending on which address emitted them —
see [Primary sales](#primary-sales--a-second-contract-at-a-second-address) at the end of this
section for that contract's own ordinals.

Each `topic0` below (`keccak256` of the canonical signature) was computed independently against the current source, not the checked-in ABI JSON.

### Orders and offers now share escrow (AO-746)

⚠️ **Read this before modelling `Order.remainingQuantity` or the offer lifecycle.** Until AO-746 an offer and
an order were two unrelated entries in two independent id spaces. An accepted offer left the order it had been
negotiated over `Open` and still fillable by a third party, and the order's own maker had to fund both sides of
the same trade. `Offer.orderId` links the two, and the link changes what an indexer sees.

**The venue holds one pooled balance per token.** An order's `remainingQuantity` and an offer's escrowed leg are
two claims on that one balance, never two separate piles. So when the party who must escrow a leg **is** the
linked order's own maker, and the leg token is that order's `sellToken`, the leg is funded by reassigning the
claim — `remainingQuantity` goes down and `OrderEscrowDrawn` is emitted — instead of by a `transferFrom` on
their wallet. No ERC-20 `Transfer` accompanies the drawn part, because no tokens moved.

Three calls can draw: `makeOffer` (the maker), `replaceOffer` (the incoming proposer) and `acceptOffer` (the
acceptor). **Only the order's own maker can draw, and only for the token that order already holds.** Everything
else escrows from the wallet exactly as before: a counterparty proposing against someone else's listing, a
standalone offer, and an order that a fill, a cancel or a sweep has already closed. If the negotiated amount
exceeds what is left on the order, the order pays what it can and the wallet covers the shortfall, so raising
your price never becomes un-fundable.

**The draw is one way.** Cancelling, replacing away from, sweeping or force-cancelling the offer pays the
proposer's **wallet**. It does not restore the listing.

What that means downstream:

| What you will see | Why |
|---|---|
| `remainingQuantity` **decreases with no `OrderFilled`/`OrderPartiallyFilled`** | The quantity was drawn into an offer's escrow. `OrderEscrowDrawn` is the only event that reports it, and it already carries the post-draw `remainingQuantity`. |
| An order at **`remainingQuantity == 0` that is still `Open`** | Its whole listed quantity is committed to a live negotiation. Nothing has settled, and no fill can succeed (any fill exceeds remaining). **An "open orders" view must filter on `remainingQuantity > 0`, not on `status == Open`.** |
| An order that **stays `Open` at zero remaining indefinitely** | The offer that drew on it was cancelled, replaced, swept or force-cancelled, and those pay the proposer's wallet. The listing is not restored and the order reaches no terminal status on its own; its maker can still `cancelOrder` it. |
| An order that reaches **`Filled` with no fill event at all** | An accepted offer consumed the last of it. `OrderClosedByOffer` is the only event; there is no `OrderFilled`. |
| `OrderEscrowDrawn` **before** the `OfferMade` that created the offer it names | `makeOffer` escrows, then emits. Within one transaction `OrderEscrowDrawn.offerId` can reference an offer whose `OfferMade` sits at a later log index. Same ordering for `replaceOffer`/`OfferReplaced`. |

**Cross-close.** When an accepted offer has consumed the linked order's whole quantity, settlement sets the
order to `OrderStatus.Filled`, zeroes its `escrowedFee` and refunds that unconsumed fee to the order's maker —
no fill ever earned it. A **partly** consumed order stays `Open` with a reduced `remainingQuantity`:
negotiating three of ten does not retire the other seven. An order that is no longer `Open` (admin
force-cancelled during the negotiation, say) is **never relabelled**.

---

### `OrderPlaced`

```solidity
event OrderPlaced(uint256 indexed id, address indexed maker, address sellToken, uint256 sellAmount, address buyToken, uint256 buyAmount, uint64 expireTs, uint16 makerFeeBps, uint16 takerFeeBps, address feeCollector, address feeToken);
```
- **topic0:** `0x4234b3dbe8c54202b785e8802bd3eef8cf049cc71dc38c673dd5b76ee099b26d`
- **Indexed:** `id`, `maker`
- **Data:** `sellToken`, `sellAmount`, `buyToken`, `buyAmount`, `expireTs`, `makerFeeBps`, `takerFeeBps`, `feeCollector`, `feeToken`

| Field | Description |
|---|---|
| `id` | new order id |
| `maker` | resolved actor (`_msgSender()`), not necessarily `tx.from` — see [§6](#actor-resolution-erc-2771-meta-tx) |
| `sellToken`, `sellAmount` | escrowed leg |
| `buyToken`, `buyAmount` | desired leg at placement |
| `expireTs` | `0` = no expiry |
| `makerFeeBps`, `takerFeeBps`, `feeCollector` | fee terms snapshotted onto the order from the fee attestation (same fields `OfferMade` carries at creation) — mirrored back out in `OrderFilled`/`OrderPartiallyFilled` at fill time |
| `feeToken` | the settlement currency both fees are denominated in; one of `sellToken`/`buyToken` (AC-833). ⚠️ An order placed **before** AC-833 carries `address(0)` here and can never be filled — see `LegacyOrderMustBeUnwound` in [§7](#7-errors-for-revert-reason-decoding) |

---

### `OrderCancelled`

```solidity
event OrderCancelled(uint256 indexed id, address indexed maker, uint256 refunded);
```
- **topic0:** `0xc4058ebc534b64ecb27b2d4eaa1904f98997ec18ebe6ada4117593dde89478cc`
- **Indexed:** `id`, `maker`
- **Data:** `refunded`

| Field | Description |
|---|---|
| `refunded` | Total `sellToken` amount returned to `maker`: the order's unfilled balance PLUS any unconsumed `escrowedFee` (AC-833). ⚠️ Earlier revisions of this document called this field `remainingQuantity` and described it as the unfilled balance alone. That is wrong on a buy-side order, where the maker also escrowed their own fee: `refunded` is then strictly larger than the quantity, and a consumer that wrote it into an order's remaining-quantity column recorded a number the order never had. The signature and topic0 are unaffected, so this is a naming and meaning correction only, not a re-subscription. |

Always unattested — `cancelOrder` never requires a KYC attestation, so no `KycConsumed` event accompanies it.

---

### `OrderFilled` (full fill — `remainingQuantity` reaches 0)

```solidity
event OrderFilled(uint256 indexed id, address indexed maker, address indexed taker, uint256 filledSellAmount, uint256 filledBuyAmount, uint256 makerFeeAmount, uint256 takerFeeAmount, address feeCollector, address feeToken);
```
- **topic0:** `0x82ef6cdb950b657bb4bdf215b1727431a7b5ff2baf8339359a24de43461770c6`
- **Indexed:** `id`, `maker`, `taker`
- **Data:** `filledSellAmount`, `filledBuyAmount`, `makerFeeAmount`, `takerFeeAmount`, `feeCollector`, `feeToken`

| Field | Description |
|---|---|
| `filledSellAmount` | `sellToken` amount taken from the order (gross) |
| `filledBuyAmount` | `buyToken` amount the taker paid, **ceiling-divided** so the maker never loses to rounding (gross, pre-fee) |
| `makerFeeAmount` | the maker's fee for this fill, denominated in `feeToken` |
| `takerFeeAmount` | the taker's fee for this fill, denominated in `feeToken` |
| `feeCollector` | recipient of both fee legs; `address(0)` semantics only apply when both fee bps are 0 — collector is otherwise always allowlisted |
| `feeToken` | the settlement currency both fees are denominated in; one of `sellToken`/`buyToken` (AC-833). Both fee amounts are computed on whichever leg that is, so the collector's take is exactly `makerFeeAmount + takerFeeAmount` in this one token |

**Both amounts are gross, and only the currency leg carries fee (AC-833).** The asset leg always moves in full, so which party's receipt is reduced depends on which leg is `feeToken`:

- **`feeToken == buyToken`** (the taker pays the currency): the maker receives `filledBuyAmount - makerFeeAmount`, the taker receives `filledSellAmount` untouched, and the taker pays `filledBuyAmount + takerFeeAmount` out of pocket.
- **`feeToken == sellToken`** (the maker escrowed the currency): the taker receives `filledSellAmount - takerFeeAmount`, the maker receives `filledBuyAmount` untouched, and the maker's fee comes out of the escrow taken at placement.

⚠️ An earlier revision of this section deducted `makerFeeAmount` from the buy leg **and** `takerFeeAmount` from the sell leg on every fill. That reading predates AC-833 and only ever held when both legs happened to be the settlement currency.

---

### `OrderPartiallyFilled` (partial fill — `remainingQuantity` > 0 after)

```solidity
event OrderPartiallyFilled(uint256 indexed id, address indexed maker, address indexed taker, uint256 filledSellAmount, uint256 filledBuyAmount, uint256 remainingQuantity, uint256 makerFeeAmount, uint256 takerFeeAmount, address feeCollector, address feeToken);
```
- **topic0:** `0x59146430e12983429d60fe650176e2c6c6c1ded99f6f91460e02a23e56be2b75`
- **Indexed:** `id`, `maker`, `taker`
- **Data:** `filledSellAmount`, `filledBuyAmount`, `remainingQuantity`, `makerFeeAmount`, `takerFeeAmount`, `feeCollector`, `feeToken`

Same fee semantics as `OrderFilled`: both amounts gross, both fees denominated in `feeToken`, and only the currency leg reduced.

Since AC-833 the event carries `filledBuyAmount` — the gross notional for **this** fill — in its own right, so there is no longer any need to re-derive it off-chain from the order's original `sellAmount`/`buyAmount`. ⚠️ **`remainingQuantity` moved from field 5 to field 6** when `filledBuyAmount` was inserted ahead of it. A decoder written against the earlier eight-field version would read the buy amount where it expects the remaining balance, and both are plausible numbers — but the `topic0` moved too, so such a decoder stops matching the event outright rather than mis-reading it.

---

### `OrderSettled` (parked, AC-246 — not currently emitted; kept for reference)

```solidity
event OrderSettled(uint256 indexed buyId, uint256 indexed sellId, address indexed operator, uint256 settledSellAmount, uint256 settledBuyAmount, uint256 buyMakerFeeAmount, uint256 sellMakerFeeAmount, address buyFeeCollector, address sellFeeCollector);
```
- **topic0:** `0xafa4117f33f47e4da4c272f74e1d9f71700ddfade40becbba08a26a0d192b59b`
- **Indexed:** `buyId`, `sellId`, `operator`
- **Data:** `settledSellAmount`, `settledBuyAmount`, `buyMakerFeeAmount`, `sellMakerFeeAmount`, `buyFeeCollector`, `sellFeeCollector`

| Field | Description |
|---|---|
| `buyId`, `sellId` | the two complementary orders settled together |
| `operator` | `_msgSender()` of the `OPERATOR_ROLE` caller |
| `settledSellAmount` | gross `buyId` order's remaining quantity, transferred to `sellId`'s maker |
| `settledBuyAmount` | gross `sellId` order's remaining quantity, transferred to `buyId`'s maker |
| `buyMakerFeeAmount` | fee deducted from what `buyId`'s maker receives (in `sellId.sellToken`) |
| `sellMakerFeeAmount` | fee deducted from what `sellId`'s maker receives (in `buyId.sellToken`) |
| `buyFeeCollector` | `buyId` order's fee collector (receives `sellMakerFeeAmount`) |
| `sellFeeCollector` | `sellId` order's fee collector (receives `buyMakerFeeAmount`) |

Both orders transition to `Settled`; both `remainingQuantity` become 0 regardless of prior partial fills.

---

### `OrderRefunded` (parked, AC-246 — not currently emitted; kept for reference)

```solidity
event OrderRefunded(uint256 indexed id, address indexed maker, address indexed operator, string reason);
```
- **topic0:** `0x6a27e09533fed9d077355046c21b56d5681b38ca86c6f1d39e2fd06ca63ccc80`
- **Indexed:** `id`, `maker`, `operator`
- **Data:** `reason` (dynamic `string`, ABI-encoded with offset/length in the event data)

Full `remainingQuantity` returned to maker in `sellToken`.

---

### `OrderForceCancelled`

```solidity
event OrderForceCancelled(uint256 indexed id, address indexed maker, address recipient, address indexed admin);
```
- **topic0:** `0x6f91387bccb7daefb8b7dabc5a2009c674270731173202bdf3c61f86eb196923`
- **Indexed:** `id`, `maker`, `admin`
- **Data:** `recipient` — **note the non-indexed field sits between two indexed fields in declaration order**; decode by ABI position, not topic order.

`recipient` may differ from `maker` (compliance-directed payout for a frozen account).

---

### `OrderExpired`

```solidity
event OrderExpired(uint256 indexed id, address indexed maker, uint256 refunded);
```
- **topic0:** `0x795bce27c5ada1127ff0f376d1867477e3e67bfafda5931c1a00dd07c819eeb0`
- **Indexed:** `id`, `maker`
- **Data:** `refunded` — remaining escrow PLUS any unconsumed `escrowedFee` (AC-833), returned to `maker`. Same naming correction as `OrderCancelled` above.

Emitted once per swept id inside a `sweepExpired` batch call — a single tx can contain many of these.

---

### `CollectorAllowed`

```solidity
event CollectorAllowed(address indexed collector, bool allowed);
```
- **topic0:** `0x9ffd8415a6927e91c17a1cb9fbba3e8e410c044c2a5e3eb874de29b986eb117b`
- **Indexed:** `collector`
- **Data:** `allowed`

Admin config event — useful for validating that a `feeCollector` seen in trade events was allowlisted at the time.

---

### `KycConsumed`

```solidity
event KycConsumed(address indexed account, Action indexed action, uint256 indexed orderId, uint256 nonce);
```
- **topic0:** `0x4bcf8bc6cf85e5b8596ad43d86bddd9ad03457e48891f56a406eac524c7e5eb3`
- **Indexed:** `account`, `action`, `orderId`
- **Data:** `nonce`

Emitted **only** when `complianceRequired[action]` is `true` at call time (see `ComplianceRequiredSet`) — its absence in a trade tx means gating was disabled for that action, not that verification was skipped. `orderId` is `0` for actions not bound to an existing order/offer id (e.g. `Place`, `MakeOffer`). ⚠️ That stays true for a `makeOffer` that links an order (AO-746): the attestation is bound to `orderId == 0` and `KycConsumed.orderId` is `0`, so **do not read the link off this event** — read it off `OfferMade.orderId`. Useful as the canonical "attestation was consumed" audit trail, and to disambiguate `OrderCancelled` as described above.

---

### `FeeConsumed`

```solidity
event FeeConsumed(address indexed account, Action indexed action, uint256 nonce);
```
- **topic0:** `0xeaf112abadbe52fe1bec7bd8a3ce534907a37f5af958abdd0e957c64a11ddd27`
- **Indexed:** `account`, `action`
- **Data:** `nonce`

Emitted on `placeOrder`/`placeOrderWithPermit` (`action = Place`) and `makeOffer` (`action = MakeOffer`). **Unlike `KycConsumed`, it is emitted unconditionally** (AC-884): fee attestations are verified and their nonces burned whatever `complianceRequired[action]` says, so every fee-setting call produces exactly one `FeeConsumed`, and its absence means the call reverted. `KycConsumed` may or may not accompany it, depending on the KYC toggle. No `orderId` field — fee attestations are only ever bound to `orderId == 0` (Place/MakeOffer). `nonce` is drawn from the separate `usedFeeNonce` namespace, not `usedNonce`.

---

### `ComplianceRequiredSet`

```solidity
event ComplianceRequiredSet(Action indexed action, bool required);
```
- **topic0:** `0x9e21c2e33dd513cd0d70dfe567833a0857ea2998e4a82582cd046d9aa1ca8e41`
- **Indexed:** `action`
- **Data:** `required`

---

### `OfferMade`

```solidity
event OfferMade(uint256 indexed id, address indexed maker, address indexed taker, address makerToken, uint256 makerAmount, address takerToken, uint256 takerAmount, uint64 expireTs, uint16 makerFeeBps, uint16 takerFeeBps, address feeCollector, address feeToken, uint256 orderId);
```
- **topic0:** `0x96439f2b914d45cac3781d0a9fa97040586d84533c115ca1f47c89abc7abf0a0`
- **Indexed:** `id`, `maker`, `taker`
- **Data:** `makerToken`, `makerAmount`, `takerToken`, `takerAmount`, `expireTs`, `makerFeeBps`, `takerFeeBps`, `feeCollector`, `feeToken`, `orderId`

| Field | Description |
|---|---|
| `feeToken` | the settlement currency both fees are denominated in; one of the two legs (AC-833) |
| `orderId` | **appended by AO-746** — the order this offer was raised against, or `0` for a standalone offer. This is the only place the link is published at creation; `KycConsumed.orderId` on a `MakeOffer` is `0` and says nothing about it |

⚠️ **This topic0 changed again in AO-746** (a trailing `uint256 orderId`), on top of the earlier change against the previously-shipped ABI. An indexer still subscribed to either older topic **stops matching this event entirely** — see [Schema versioning](#schema-versioning--breaking-change).

---

### `OfferReplaced`

```solidity
event OfferReplaced(uint256 indexed id, address indexed by, uint256 newMakerAmount, uint256 newTakerAmount, uint64 expireTs);
```
- **topic0:** `0x2aba396fe7deb78b1c44cf1af6efedcfa9796de554d9f27dd4b290ff965ea280`
- **Indexed:** `id`, `by`
- **Data:** `newMakerAmount`, `newTakerAmount`, `expireTs`

`by` becomes the offer's new `proposedBy`. Fee terms (`makerFeeBps`/`takerFeeBps`/`feeCollector`) are **not** renegotiated by this call — they stay fixed from `OfferMade`; join back to that event (or `getOffer(id)`) if fee amounts are needed downstream.

---

### `OfferCancelled`

```solidity
event OfferCancelled(uint256 indexed id, address indexed by, uint256 makerAmount, uint256 takerAmount);
```
- **topic0:** `0x0f30ae9004015531e44539aa93fcbe6e33146abeeed21661204fa432da6bc075`
- **Indexed:** `id`, `by`
- **Data:** `makerAmount`, `takerAmount` (terms at cancellation time; only the current proposer's side was actually escrowed/returned)

---

### `OfferForceCancelled`

```solidity
event OfferForceCancelled(uint256 indexed id, address indexed maker, address makerRecipient, address takerRecipient, address indexed admin);
```
- **topic0:** `0xfd196904444e1daab8a58004c162bff7dff9432d5d04ca031319c8c306e272a1`
- **Indexed:** `id`, `maker`, `admin`
- **Data:** `makerRecipient`, `takerRecipient`

Both recipients are always present in the event even though only one side is ever actually escrowed — `cancelOfferForUser` only accepts `Open`/`Countered` offers (AC-246: `Accepted` is never a persisted state, since `acceptOffer` settles atomically). Check `proposedBy` via `getOffer`/state reconstruction if it matters which leg actually moved funds.

---

### `OfferExpired`

```solidity
event OfferExpired(uint256 indexed id, address indexed proposedBy, uint256 amountReturned);
```
- **topic0:** `0x73dedbcfa9a17d6e3f87cd88fa5c704da1a9abff4ec94d2f1a0b0fd0b24d082a`
- **Indexed:** `id`, `proposedBy`
- **Data:** `amountReturned`

Emitted once per swept id inside a `sweepExpiredOffers` batch call.

---

### `OfferAccepted`

```solidity
event OfferAccepted(uint256 indexed id, address indexed by, uint256 makerAmount, uint256 takerAmount, uint256 orderId);
```
- **topic0:** `0xb8c98ddc6dfe8462eae467b02e2713ddebdfb7807bb24647d4f9daab00a06361`
- **Indexed:** `id`, `by`
- **Data:** `makerAmount`, `takerAmount` (terms agreed to, at acceptance), `orderId`

| Field | Description |
|---|---|
| `orderId` | **appended by AO-746** — the order this offer was raised against, or `0` for a standalone offer. Acceptance therefore carries its order context in the event itself; a consumer no longer has to join back to `OfferMade` or call `getOffer` to know which listing this trade retires |

⚠️ **This topic0 changed in AO-746.** An indexer subscribed to the four-field version stops matching this event entirely — see [Schema versioning](#schema-versioning--breaking-change).

---

### `OfferSettled`

Emitted by `acceptOffer` (AC-246), immediately after `OfferAccepted`, in the same transaction — not by a separate `settleOffer` call (retired). `by` is the accepting party (`_msgSender()`), not an operator.

```solidity
event OfferSettled(uint256 indexed id, address indexed by, uint256 makerAmountGross, uint256 takerAmountGross, uint256 makerFeeAmount, uint256 takerFeeAmount, address feeCollector, address feeToken);
```
- **topic0:** `0xbf1754cbf531494bcfd0b7d7792977208334ff7a6613cbc4ef9ae24384eb7a8e`
- **Indexed:** `id`, `by`
- **Data:** `makerAmountGross`, `takerAmountGross`, `makerFeeAmount`, `takerFeeAmount`, `feeCollector`, `feeToken`

| Field | Description |
|---|---|
| `makerAmountGross` | the maker leg agreed at acceptance, **before** either fee |
| `takerAmountGross` | the taker leg agreed at acceptance, **before** either fee |
| `makerFeeAmount`, `takerFeeAmount` | the two fees, both denominated in `feeToken` |
| `feeCollector` | recipient of both fee legs |
| `feeToken` | the settlement currency; one of the two legs (AC-833) |

**Both amounts are gross.** Both fees are denominated in `feeToken`, so a party's net receipt is the gross
minus that party's **own** fee on whichever leg is the settlement currency: `makerAmountGross - makerFeeAmount`
and `takerAmountGross - takerFeeAmount` on the currency leg. **The asset leg always moves gross and
untouched.**

⚠️ An earlier revision of this section declared seven fields, named the two amounts
`makerReceived`/`takerReceived` and described them as already net of fee. All three were wrong: the build
declares eight fields, `src/core/OfferBook.sol` names them `makerAmountGross`/`takerAmountGross`, and the
amounts are pre-fee. The drift arrived with the fee-token work (AC-833), not with AO-746. The `topic0` above
did not move with the correction — it was already the artifact's value for the eight-field version — so an
indexer that matched this event still matches it, and only the decoding was wrong.

---

### `OrderEscrowDrawn` (new — AO-746)

```solidity
event OrderEscrowDrawn(uint256 indexed orderId, uint256 indexed offerId, uint256 drawn, uint256 remainingQuantity);
```
- **topic0:** `0x3f3c29852fe00ab850c55fa7c115603fe1f0f33d9b1ae26e3b7a8edb95211196`
- **Indexed:** `orderId`, `offerId`
- **Data:** `drawn`, `remainingQuantity`

| Field | Description |
|---|---|
| `orderId` | the order whose escrow funded the leg. Its maker is the party that escrowed |
| `offerId` | the offer the leg was escrowed for. ⚠️ On `makeOffer` this event is emitted **before** `OfferMade`, so the offer's creation event sits at a **higher** log index in the same transaction. A consumer that requires the offer to exist first must order by log index within the transaction, not process this event in isolation |
| `drawn` | amount of the order's `sellToken` moved from the order's claim to the offer's. Never more than the order's `remainingQuantity` at the time; a larger negotiated amount takes the shortfall from the proposer's wallet instead |
| `remainingQuantity` | the order's quantity **after** the draw. Use it directly; do not subtract `drawn` yourself |

Emitted by `makeOffer`, `replaceOffer` and `acceptOffer`, at most once per call, and **only** when the party
escrowing a leg is the linked order's own maker and the leg token is that order's `sellToken`. **No ERC-20
`Transfer` accompanies the drawn amount** — the venue holds one pooled balance per token and the draw only
reassigns the claim on it.

This is the **only** event that reports a fall in `remainingQuantity` outside a fill. An order can reach zero
remaining and stay `Open`, and it will stay that way if the offer is later cancelled, replaced, swept or
force-cancelled, because those pay the proposer's wallet and never restore the listing. See
[Orders and offers now share escrow](#orders-and-offers-now-share-escrow-ao-746).

---

### `OrderClosedByOffer` (new — AO-746)

```solidity
event OrderClosedByOffer(uint256 indexed orderId, uint256 indexed offerId, uint256 refunded);
```
- **topic0:** `0x14b99cb0eb5dfcb46ccec7a5dc5d34ff779fca02e581ba7a363cdba88c394657`
- **Indexed:** `orderId`, `offerId`
- **Data:** `refunded`

| Field | Description |
|---|---|
| `orderId` | the order the accepted offer consumed. Its status is now `OrderStatus.Filled` and it is no longer fillable by anyone else |
| `offerId` | the offer that consumed it — the same id as the `OfferAccepted`/`OfferSettled` pair earlier in the transaction |
| `refunded` | the order's unconsumed `escrowedFee`, returned to the order's maker in the order's `sellToken`. No fill ever earned it, so none of it is owed to the collector. `0` when the order held no fee escrow |

Emitted by `acceptOffer` only, as the **last** event of the transaction, after every transfer of the
settlement itself. The ordering within one `acceptOffer` is therefore: `KycConsumed` (if the gate is on) →
`OfferAccepted` → `OrderEscrowDrawn` (if the acceptor drew) → `OfferSettled` → `OrderClosedByOffer`.

It fires **only** when the linked order is still `Open` and its `remainingQuantity` has reached zero:

- a **partly** consumed order stays `Open` with a reduced `remainingQuantity` and produces no event here;
- an order that is no longer `Open` — force-cancelled or swept during the negotiation — is never relabelled;
- a standalone offer (`orderId == 0`) never produces one.

⚠️ **This is a terminal order transition with no fill event.** `OrderStatus.Filled` can now be reached without
`OrderFilled` ever being emitted, so a read model that keys order closure off the fill events alone will show
the order open forever. That is the defect AO-746 fixed on chain; consuming the event is what fixes it
downstream.

---

### Primary sales — a second contract at a second address

`AsseteraPrimarySales` is the **primary market**: a buyer's first acquisition of an asset, settled
against a venue — a third party's contract (Dinari, Backed, …) or, later, the per-token sale
contract fronting our own issuance. **There is one settlement family, not two**: our own issuance
goes down the same code path as everybody else's, because to this router a sale contract is an
address in a signed intent like any other venue. It is a separate
UUPS proxy from `AsseteraECS` — separate pause lever, separate audit scope, separate blast radius —
so **its events arrive from a different address and must be subscribed separately**. Not yet
deployed to any network at the time of writing; there is no row for it in the address table at the
top of this document.

Three things follow for an indexer:

- **Its EIP-712 domain is `("AsseteraPrimarySales", "1")`**, deliberately different from the
  exchange's `("AsseteraExchange", "1")`. An attestation minted for one contract recovers to a
  different address on the other and is rejected, so nothing replays across the two.
- **Its `Action` ordinals are its own**, unrelated to the exchange's (below). `KycConsumed` and
  `ComplianceRequiredSet` carry the same `topic0` from both contracts, so the emitting address is
  the only thing that says which ordinal set applies.
- **It has a THIRD nonce namespace** — settlement intents — on top of the KYC and fee namespaces
  it inherits. Three independent signers, three independent single-use counters. See
  `IntentConsumed` below.
- **A settlement carries FOUR signatures, not three.** The compliance backend, the fee service and
  the settlement operator sign the three payloads above; the **buyer** signs the settlement intent
  too, over the very same EIP-712 digest the settlement operator signs. It is a fourth signature
  but not a fourth nonce namespace — the buyer signs the intent, so the intent's own single-use
  nonce is the buyer's replay protection as well. `settlePrimary` takes both signatures as
  separate arguments and they are **not interchangeable**: the operator's is accepted only if it
  recovers to a `SETTLEMENT_OPERATOR_ROLE` holder, the buyer's only if it validates for
  `intent.buyer` (ERC-1271 aware, so a Safe or an embedded smart account is a valid buyer).
  ⚠️ `INTENT_TYPEHASH` is **unchanged** by this — the struct did not move, only the
  `settlePrimary` selector did.

#### `Action` (uint8) — `AsseteraPrimarySales`' own set, **not** the exchange's

| Value | Name |
|---|---|
| 0 | `None` — never gated, never accepted; a zero action is an unset field |
| 1 | `SettleVenue` — a venue settlement through the constrained executor. **The only reachable ordinal**, and the one every settlement runs under, including our own issuance |
| 2 | `SettleMint` — **RESERVED and unreachable.** `settlePrimary` hardcodes ordinal 1 and is the only settlement entry point, so no transaction can run under this ordinal and **no event can carry it**. Held because subscribing to our own issuance may later warrant different compliance treatment even though it uses the same code path; keeping the ordinal means that distinction costs no renumbering |

Ordinals are append-only (the signer service signs the ordinal). `Action.SettleVenue` here and
`Action.Place` on the exchange are both ordinal 1 and have nothing to do with each other.

⚠️ **Do not build a branch on ordinal 2.** An indexer that treats it as a second settlement shape
is coding against a design this contract does not have; if it ever becomes reachable it will be
announced as a schema change here first.

#### Role constants (`AsseteraPrimarySales`)

| Role | Value |
|---|---|
| `DEFAULT_ADMIN_ROLE` | `0x0000000000000000000000000000000000000000000000000000000000000000` |
| `KYC_OPERATOR_ROLE` | `0xdf54a8fce50b9de7187b8b9daaa3b95e6ef1bf1df5fe0a03ddea8faa73de2a10` — same constant as the exchange's, granted independently on this proxy |
| `FEE_OPERATOR_ROLE` | `0x8efbb70a6b43a0e337cb93750666361f6a0fe46a0aee356063f13c9b68520bb7` — likewise |
| `SETTLEMENT_OPERATOR_ROLE` | `keccak256("SETTLEMENT_OPERATOR_ROLE")` — a **third** role, with its own key. The only one of the three whose holder can cause a transfer |

---

### `PrimarySettled`

```solidity
event PrimarySettled(address indexed buyer, address indexed assetToken, address indexed venue, uint256 assetDelivered, address settlementToken, uint256 venueIn, uint256 refund, uint256 fee, address feeCollector, bytes32 supplierReference, uint256 nonce);
```
- **topic0:** `0x30b9072b6411a3b6352a8664921029a444d29156e42a80d3a2076aa4ca87868e`
- **Indexed:** `buyer`, `assetToken`, `venue`
- **Data:** `assetDelivered`, `settlementToken`, `venueIn`, `refund`, `fee`, `feeCollector`, `supplierReference`, `nonce`
- **Emitted by:** `AsseteraPrimarySales`, **not** `AsseteraECS`

| Field | Description |
|---|---|
| `buyer` | the party debited and delivered to; resolved actor (`_msgSender()`), not necessarily `tx.from` — see [§6](#actor-resolution-erc-2771-meta-tx). Always equals the signed `intent.buyer`; nobody settles on somebody else's behalf |
| `assetToken` | the asset the buyer ends up holding. ⚠️ **may be a claim token rather than the final instrument** — see below |
| `venue` | the address that was called. For our own issuance this is the **per-token sale contract**, never the token itself — the router holds no minting right and calls no token directly. Never zero, and never either of the two settled tokens (`VenueIsASettledToken`) |
| `assetDelivered` | **measured** `assetToken` balance delta on `buyer` across the venue call. Asserted `>= intent.minAssetOut` or the whole transaction reverts (`InsufficientAssetDelivered`) |
| `settlementToken` | the currency debited. Enforced equal to the fee attestation's `feeToken`, so the fee never comes out of what the buyer receives. ⚠️ **The revert is the shared `IFeeGate.FeeTokenNotALeg(address feeToken)`, not a primary-specific error.** A primary sale has one currency leg, so it passes the settlement token in both leg positions of the estate-wide fee check and the shared leg test collapses to the strict denomination rule. The `SettlementTokenMismatch` error an earlier revision raised here **is gone from the ABI** — a selector-based decoder still carrying it will never match |
| `venueIn` | **measured** settlement token the venue actually consumed. **May be less than the quote** the buyer signed (`intent.venueQuoteIn`) — a venue that rounds a fill down is normal, not an error |
| `refund` | `intent.venueQuoteIn - venueIn`, returned to `buyer` in the same transaction. The router keeps no standing balance (`RouterBalanceChanged` guards it) |
| `fee` | settlement token paid to `feeCollector`. Charged **on top of** the quote, not carved out of it. Cross-checked on-chain against `FeeMath.feeAmount(venueQuoteIn, feeAtt.takerFeeBps)` — **floored**, the same rounding every other fee in the estate uses — so the settlement signer and the fee signer must agree on one number |
| `feeCollector` | the allowlisted recipient of `fee`. ⚠️ This router keeps its **own** allowlist, which starts empty; the exchange's entries do not carry over |
| `supplierReference` | the venue's own quote/order id, carried through from the signed intent so the activity ledger can be reconciled against the supplier's records |
| `nonce` | the settlement-intent nonce. Joins to `IntentConsumed` on `(buyer, nonce)`, and to the signer service's audit row for the intent that authorised this settlement |

Net buyer debit = `venueIn + fee`. Gross pull = `intent.venueQuoteIn + fee`, itself capped by the
signed `intent.maxSettlementIn` and by the per-transaction settlement cap (`SettlementCapSet`).

**Every amount here is MEASURED, not quoted.** `assetDelivered` is the observed `assetToken`
balance delta on the buyer; `venueIn` is the observed settlement-token consumption. The event is
generated by us from balance deltas this contract took before and after the call, **not relayed
from whatever the venue chose to emit**. That is why the indexer needs **no per-supplier decoder**:
one signature covers every venue we will ever settle against, and a lying venue's own logs are
irrelevant to what this event reports.

**No family discriminator on the BUY leg, because there is only one buy family.** Every purchase
this router performs runs through the same constrained executor and emits this one event, whether
the venue is a third party's contract or the per-token sale contract fronting our own issuance.
There is no mint-specific event to wait for; a stub for one existed during development and was
deleted before this contract's first release. **Do not build a family discriminator for purchases.**

⚠️ **There IS a second event now, and it is a different leg rather than a different family.**
`PrimaryRedeemed` (AO-847, below) reports a sell BACK to a venue. It is a separate `topic0`, so a
deployed filter on `PrimarySettled` keeps matching exactly what it always matched and picks the new
leg up by adding a filter. Nothing about this event's shape or meaning changed.

What distinguishes one settlement from another is the venue address, which the catalogue already
maps to a supplier. `IntentConsumed` is emitted from the same call with the **same `nonce`**, so the
two join on `(buyer, nonce)` with no ambiguity, but its `action` ordinal is `1` on every settlement
and carries no information.

⚠️ **`assetToken` may be a CLAIM TOKEN, not the final instrument — open modelling question,
AO-550.** Every supplier we settle against today is atomic, and where a supplier's mint is genuinely
asynchronous it is always **fronted by a claim token minted synchronously in the same transaction**
— which is exactly what makes the balance delta measurable and keeps this contract correct either
way. Nothing on-chain can tell a claim from the instrument, and the contract does not try to. What
is **not** settled is what the layers above do with one:

- a claim is **not a final position** and must not be counted as one in the activity ledger;
- our `fee` has **already been charged** against a claim whose second leg (claim → instrument) could
  still fail;
- that second leg is a separate event that **nothing currently emits**.

Deliberately deferred (2026-08-14) rather than designed, on the reasoning that the indexer already
watches every token in the catalogue so the transfers are observed regardless. **The distinction is
owned by the indexer work (AO-550), not by the contract** — do not wait for a contract change to
resolve it.

---

### `PrimaryRedeemed`

```solidity
event PrimaryRedeemed(address indexed seller, address indexed assetToken, address indexed venue, uint256 assetIn, address settlementToken, uint256 venueOut, uint256 assetRefund, uint256 fee, address feeCollector, bytes32 supplierReference, uint256 nonce);
```
- **topic0:** `0x8cda59bfeb2102501e5e556f5265da55930da46e4aeb3add87d19081b4ab503b`
- **Indexed:** `seller`, `assetToken`, `venue`
- **Data:** `assetIn`, `settlementToken`, `venueOut`, `assetRefund`, `fee`, `feeCollector`, `supplierReference`, `nonce`
- **Emitted by:** `AsseteraPrimarySales`, **not** `AsseteraECS`
- **Entry point:** `redeemPrimary(venueCalldata, intent, intentSignature, sellerSignature, kyc, fee)`

One sell BACK to a venue: the seller hands the asset over and receives settlement currency (AO-847).
It is the mirror of `PrimarySettled` and shares its discipline — every amount is a balance delta
this contract measured, never a number the venue quoted or emitted.

| Field | Description |
|---|---|
| `seller` | the party whose asset was taken and who received the net proceeds; resolved actor (`_msgSender()`). Always equals the signed `intent.seller` |
| `assetToken` | the asset the seller gave up |
| `venue` | the address that was called. Never zero, and never either of the two settled tokens |
| `assetIn` | **measured** `assetToken` the venue actually consumed, in the token's **VISIBLE units** even when the router measured it in shares. May be less than the signed `intent.maxAssetIn` — a venue that takes less than it was approved is normal |
| `settlementToken` | the currency received. Enforced equal to the fee attestation's `feeToken` |
| `venueOut` | **measured** settlement token the venue paid the router, **GROSS**. Judged against the seller's floor after the fee is taken out (`InsufficientSettlementOut`) |
| `assetRefund` | asset approved but not consumed, returned to the seller in the same transaction, in visible units. Under share accounting this is returned as an exact SHARE count and only then converted for reporting |
| `fee` | settlement token paid to `feeCollector`. 🔴 **CARVED OUT of `venueOut`, not charged on top of it.** This is the one place the sell leg's amount model differs from the buy leg's, and reading `PrimarySettled`'s model across would overstate the seller's proceeds by the fee. Cross-checked on-chain against `FeeMath.feeAmount(venueQuoteOut, feeAtt.takerFeeBps)` — floored, the same rounding the buy leg uses |
| `feeCollector` | the allowlisted recipient of `fee`, from this router's own allowlist |
| `supplierReference` | the venue's own quote/order id, carried from the signed intent |
| `nonce` | the redemption intent's nonce. Joins to `IntentConsumed` on `(seller, nonce)` |

**Net seller proceeds = `venueOut - fee`.** The seller's asset debit is `assetIn`; anything the
router pulled beyond that came straight back as `assetRefund`, so `assetIn + assetRefund` is what
the seller's allowance was actually spent on.

**The maker-fee rule is the buy leg's.** A non-zero `makerFeeBps` on the fee attestation reverts
with `MakerFeeNotSupported`: the router does not control the issuer side of a venue redemption any
more than it controls the proceeds side of a purchase.

⚠️ **New revert selectors on this leg**, all additions — nothing was removed from the buy leg's set:
`AssetPullMismatch(uint256 requested, uint256 received)`, `InsufficientSettlementOut(uint256 net,
uint256 minSettlementOut)`, `AssetApprovalNotCleared()`, `SellerFeeMismatch(uint256 attested,
uint256 expected)`, and on the gate `IntentSellerMismatch()`, `SellerConsentBadSignature()`,
`ZeroRedemptionQuote()`, `SellerFeeExceedsProceeds()`, `MinSettlementTooHigh()`.

---

### `IntentConsumed`

```solidity
event IntentConsumed(address indexed buyer, uint8 indexed action, uint256 nonce);
```
- **topic0:** `0xe055bda62338f5ab6dbe0f78d908fdf9b5316f60582944ade75297d40f7f79b9`
- **Indexed:** `buyer`, `action`
- **Data:** `nonce`
- **Emitted by:** `AsseteraPrimarySales`, **not** `AsseteraECS`

| Field | Description |
|---|---|
| `buyer` | the intent's party, which is also the actor (`_msgSender()`): the BUYER on `settlePrimary` and the SELLER on `redeemPrimary`. The field name is frozen and does not change with the leg |
| `action` | the primary-sale `Action` ordinal the intent was consumed under — **this contract's ordinals**, not the exchange's. ⚠️ **`1` (`SettleVenue`) for a purchase and `3` (`RedeemVenue`) for a sell back (AO-847).** It used to be constant at `1` and a decoder was told not to branch on it; that is no longer true, and this field is now the cheapest way to tell the two legs apart before joining |
| `nonce` | the intent's single-use nonce, now burned |

A settlement intent was verified and its single-use nonce marked spent. Emitted **unconditionally**
on every settlement — unlike `KycConsumed`, it does not follow the `complianceRequired` toggle,
because a settlement always needs a valid intent whatever the KYC gate says. Its absence in a
transaction means the call reverted.

⚠️ **`nonce` is drawn from a THIRD namespace — `usedIntentNonce(address buyer, uint256 nonce)` —
independent of the KYC namespace (`usedNonce`) and the fee namespace (`usedFeeNonce`). Do not
conflate the three.** They are three independent single-use counters because three independent
signers issue three independent payloads: the compliance backend decides who may trade, the fee
service decides the terms, and the settlement operator (`SETTLEMENT_OPERATOR_ROLE`, its own key)
decides that money moves and where. A shared counter would let one signer invalidate another's
payload. A single `settlePrimary` call therefore burns **three** nonces and emits up to three
consumption events (`IntentConsumed`, `FeeConsumed`, and `KycConsumed` when the KYC gate is on) —
all four signatures — the three payloads plus the buyer's countersignature on the intent — are
verified before **any** nonce is burned, so an invalid one cannot spend the others.

For joining: `IntentConsumed` and `PrimarySettled` (or `PrimaryRedeemed`) from the same transaction
share `(party, nonce)`. Both attestations riding along carry a `paramsHash` equal to the intent's
EIP-712 struct hash, which is the join key to `AsseteraSignerService`'s audit row for the intent:

| Leg | Payload | Typehash |
|---|---|---|
| purchase | `SettlementIntent` | `0xa24f008693b1ca921f2aca00e79f4bc40748d499f86d54d0d8377dfdc884bf68` |
| sell back | `RedemptionIntent` | `0x0f518f193bdea7541e9281c432a5e8447455bc3e86b4d1ed635daecfd1daa481` |

⚠️ An earlier revision of this paragraph quoted `0x86c9b91e614acc7421e39417dc43dd7b9bd2e0b2c8ce196c12f8b7391d281a03`
as the settlement typehash. That value was superseded on 2026-08-24 when `accountingMode` was added
to `SettlementIntent` (AO-713) and nothing has been signed against it since.

⚠️ **The intent nonce namespace is SHARED by the two legs**, because it is keyed on the party
address and on nothing else. A nonce is spent by whichever leg presents it first, so `(party,
nonce)` is unique across both and the join is unambiguous — but the signer service must not issue
the same number to a purchase and a sell back for one account.

---

### `SettlementCapSet`

```solidity
event SettlementCapSet(address indexed token, uint256 wholeUnits, uint256 rawCap, uint8 decimals);
```
- **topic0:** `0x41c4d334f937d3fd4eabead8ae5a391ca83c26a05e66ab1bbd5f7377e101dd96`
- **Indexed:** `token`
- **Data:** `wholeUnits`, `rawCap`, `decimals`
- **Emitted by:** `AsseteraPrimarySales`, **not** `AsseteraECS`

| Field | Description |
|---|---|
| `token` | the settlement currency the cap applies to |
| `wholeUnits` | the cap as it was **set**: whole tokens, the number a human typed into the Safe |
| `rawCap` | the cap as it is **stored and enforced**: `wholeUnits * 10 ** decimals` |
| `decimals` | the token's `decimals()` at the moment the cap was set, on the record so a token that later changes them can be spotted |

Admin config event — the analogue of `CollectorAllowed`, useful for validating that a settlement
seen in `PrimarySettled` was within the cap in force at the time. ⚠️ **A cap of zero means "this
token cannot be settled in at all", not "unlimited"** — every token starts unconfigured and
fails closed, and clearing a cap emits `SettlementCapSet(token, 0, 0, 0)`.

---

### `WhitelistHandshake`

```solidity
event WhitelistHandshake(address indexed destination, uint256 amount);
```
- **topic0:** `0x95a1ea0f6d9b937e6e314bb73abd153560ef93b7048bb65aa6f4b4ba2f668af1`
- **Indexed:** `destination`
- **Data:** `amount`
- **Emitted by:** `AsseteraPrimarySales`, **not** `AsseteraECS`

| Field | Description |
|---|---|
| `destination` | the address the venue nominated for its funding-wallet whitelist |
| `amount` | the native currency forwarded, in full, in the same call (`msg.value`) |

Admin-only, and the **only** movement of native currency anywhere in this estate's contracts.
Third-party venues such as Backed onboard a funding wallet by having it nominate an address and
move a token amount of native currency to it; the funding wallet has to be this router, because
the router is what holds the buyer allowances and makes the venue calls.

⚠️ **Pass-through only: the router has no `receive()` and no sweep.** It never holds a native
balance — a bare value transfer to it still reverts — so there is no "sweep" event to watch for
and no accumulating balance to reconcile. Nothing about a settlement flows through this event;
it exists for the audit trail of an operational one-off.

### Issuance venues — a THIRD kind of address, one per offering

`AsseteraIssuanceVenue` (`src/primary/sale/AsseteraIssuanceVenue.sol`) is the per-token primary
sale contract that fronts **our own** issuance. It is deployed **once per offering**, with its
settlement currency and its asset token fixed at deployment, and it does one thing: take
settlement currency from the router and mint the asset to the buyer at a price a compliance
officer set.

To `AsseteraPrimarySales` it is simply a venue — an address in a signed intent, called with
calldata bound by hash and selector, judged on measured balance deltas — so **nothing about
indexing a settlement changes when the venue is one of ours**. `PrimarySettled.venue` is the
venue's address, and everything the activity-ledger leg needs is already on that event.

Four things follow for an indexer:

- **There is no fixed address list.** Unlike the exchange and the router, venues are created as
  offerings are onboarded. The authority for "which address is the sale contract for this
  offering" is the catalogue's `primary_sale_contract` column, not this document and not a
  deployment manifest. A venue address never appears in
  `packages/sdk/src/deployments/<chainId>.json`.
- **It is NOT a proxy and is NOT upgradeable.** The address is the implementation. A new price
  band, a different shape, or a second round means a **new venue at a new address**, with the old
  one paused. Do not assume an address's behaviour is stable by upgrading; assume it is stable
  because it cannot change.
- **Its events are optional for the settlement leg and useful for reconciliation.** A settlement
  is fully described by `PrimarySettled` from the router. `IssuanceMinted` below is the same
  money seen from the other side of the same transaction, and the two joining on the transaction
  hash is a cheap correctness check: `PrimarySettled.venueIn` must equal
  `IssuanceMinted.settlementIn`, and `PrimarySettled.assetDelivered` must be at least
  `IssuanceMinted.assetMinted`.
- **`ProceedsWithdrawn` is not a trade.** Settlement currency accumulates in the venue and the
  issuer withdraws it later, so a venue's balance is not a settlement obligation and a withdrawal
  is not a fill. Any balance-reconciliation job over a venue address needs both events or it will
  report a hole the size of every withdrawal.

#### Role constants (`AsseteraIssuanceVenue`)

| Role | Value |
|---|---|
| `DEFAULT_ADMIN_ROLE` | `0x0000000000000000000000000000000000000000000000000000000000000000` — role administration, the purchase cap, and `unpause` |
| `RATE_SETTER_ROLE` | `keccak256("RATE_SETTER_ROLE")` — may move the price within immutable bounds and may do nothing else |
| `PAUSER_ROLE` | `keccak256("PAUSER_ROLE")` — may stop purchases; ⚠️ **may not restart them** |
| `TREASURY_ROLE` | `keccak256("TREASURY_ROLE")` — the issuer: withdraws proceeds, rescues a stray token |

⚠️ These are **the venue's own roles**, unrelated to the router's. A `RoleGranted` from a venue
address says nothing about the router.

---

### `IssuanceMinted`

```solidity
event IssuanceMinted(address indexed buyer, address indexed assetToken, uint256 assetMinted, address settlementToken, uint256 settlementIn, uint256 unitPrice);
```
- **topic0:** `0x648a6b6a3ea393436e5059f30c1efbd0ea17293356ee55fab4a2cbb6c2b4a9b5`
- **Indexed:** `buyer`, `assetToken`
- **Data:** `assetMinted`, `settlementToken`, `settlementIn`, `unitPrice`
- **Emitted by:** an `AsseteraIssuanceVenue`, **not** the router and **not** the exchange

| Field | Description |
|---|---|
| `buyer` | who received the asset. Named by the router in the venue calldata; the router separately asserts that this is the buyer named in four signatures, so a mismatch cannot settle |
| `assetToken` | the asset minted. Fixed at this venue's deployment |
| `assetMinted` | ⚠️ **the quantity ISSUED, not the buyer's measured balance delta.** The venue asserts the delta is at least this and then reports what it created, so an unrelated inflation of the buyer's existing position (an upward rebase inside the call) does not enter the offering's issuance record. The router's `PrimarySettled.assetDelivered` is the measured number |
| `settlementToken` | the currency taken. Fixed at this venue's deployment |
| `settlementIn` | what the purchase actually cost, measured as the venue's own balance delta over the pull. At most what the router authorised |
| `unitPrice` | the price in force when the purchase executed: **the cost of ONE WHOLE asset token, in the settlement token's smallest unit.** With a 6-decimal currency and an 18-decimal asset, `12500000` means 12.50 per token |

⚠️ **Units.** `assetMinted` is in the asset token's decimals, `settlementIn` and `unitPrice` are
both in the **settlement** token's decimals. The identity an indexer can check is
`settlementIn ≈ assetMinted * unitPrice / 10 ** assetDecimals`, rounded up. It is exact whenever
the venue charged the full offer, which is always the case when the settlement token has fewer
decimals than the asset.

---

### `UnitPriceSet`

```solidity
event UnitPriceSet(uint256 previousUnitPrice, uint256 newUnitPrice);
```
- **topic0:** `0x331ae672633d644ea349b76b039faa0137315afd2db07030227a7413ce1f048e`
- **Indexed:** none
- **Data:** `previousUnitPrice`, `newUnitPrice`
- **Emitted by:** an `AsseteraIssuanceVenue`

The offering was repriced by a `RATE_SETTER_ROLE` holder. Both values are in settlement-token
units. **Emitted once at deployment too**, with `previousUnitPrice = 0`, which is the opening
price and the only time zero appears in this event — the price itself can never be zero, because
the immutable floor is greater than zero.

A repricing is not retroactive and is not coordinated with intents in flight: an intent signed at
the old price either still clears its signed delivery floor or reverts.

---

### `PurchaseCapSet`

```solidity
event PurchaseCapSet(uint256 wholeUnits, uint256 rawCap, uint8 decimals);
```
- **topic0:** `0x3d970bcaa46e2d36c05622ac4cde436d08bc804c16586bf9215c72d23995659b`
- **Indexed:** none
- **Data:** `wholeUnits`, `rawCap`, `decimals`
- **Emitted by:** an `AsseteraIssuanceVenue`

The venue's own per-purchase cap on settlement currency, the analogue of the router's
`SettlementCapSet` and sized the same way: a bound on arithmetic and decimals **bugs**, not a loss
limit. Also emitted once at deployment. ⚠️ **A cap of zero means "this venue cannot sell at all",
not "unlimited"**, so a venue deployed or set to zero is closed.

The two caps are independent: the router's is per settlement currency across every venue, this one
is per purchase within one offering.

---

### `ProceedsWithdrawn`

```solidity
event ProceedsWithdrawn(address indexed to, uint256 amount);
```
- **topic0:** `0x0f2fb75cc1977a496e94837f859e957f68e26e70dc1b75d9945ee92ae57969ba`
- **Indexed:** `to`
- **Data:** `amount`
- **Emitted by:** an `AsseteraIssuanceVenue`

Settlement currency leaving the venue for the issuer. ⚠️ **Not a trade and not a settlement.**
Proceeds accumulate in the venue rather than being forwarded during a purchase, so this is the
only way the settlement currency legitimately leaves, and any reconciliation over a venue's
balance must net it off. The destination is chosen per call and never stored.

---

### `TokensRescued`

```solidity
event TokensRescued(address indexed token, address indexed to, uint256 amount);
```
- **topic0:** `0x77023e19c7343ad491fd706c36335ca0e738340a91f29b1fd81e2673d44896c4`
- **Indexed:** `token`, `to`
- **Data:** `amount`
- **Emitted by:** an `AsseteraIssuanceVenue`

A token that is **not** the settlement currency being swept out of the venue by
`TREASURY_ROLE`. The venue never takes custody of the asset it mints and holds nothing but its
proceeds, so anything this event names arrived by accident. The settlement currency is refused by
name here and must leave through `ProceedsWithdrawn`, so one event means one thing.

---

---

## 5. Schema versioning — breaking change

### Order-linked offers (AO-746) — ⚠️ `OfferMade` and `OfferAccepted` topic0 both changed

Linking an offer to the order it was raised against appended a trailing `uint256 orderId` to both events, so
both `topic0` values moved. The values below were read from the build artifact (`forge inspect AsseteraECS
events`), not computed by hand:

| Event | topic0 before AO-746 | topic0 now |
|---|---|---|
| `OfferMade` (gained a trailing `uint256 orderId`) | `0x9f9508b9495a4afab9b9ff1494b7153fef8bcdc6e7fc74b6a03682502763ae02` | `0x96439f2b914d45cac3781d0a9fa97040586d84533c115ca1f47c89abc7abf0a0` |
| `OfferAccepted` (gained a trailing `uint256 orderId`) | `0x1af0dda70fa313a26fdffb3d1ad4e70836d36fedc4a635c8064748e893ea5d19` | `0xb8c98ddc6dfe8462eae467b02e2713ddebdfb7807bb24647d4f9daab00a06361` |

**An indexer still subscribed to the old topics stops matching those two events completely** the moment the
upgraded implementation is installed. It does not mis-decode into plausible wrong numbers — it sees nothing at
all, so the symptom is "no offers have been made or accepted since the upgrade", not quietly corrupted
amounts. **The subscription must be updated in lockstep with the upgrade**, and a backfill that spans the
upgrade block has to accept both topics and branch decoding on `topics[0]`.

Also changed by AO-746:

| Item | Before | After |
|---|---|---|
| `makeOffer` selector | `0xc1155711` | `0x03269a4a` — now takes a leading `uint256 orderId` (read from the artifact's `methodIdentifiers`) |
| new event `OrderEscrowDrawn(uint256,uint256,uint256,uint256)` | *(did not exist)* | `0x3f3c29852fe00ab850c55fa7c115603fe1f0f33d9b1ae26e3b7a8edb95211196` |
| new event `OrderClosedByOffer(uint256,uint256,uint256)` | *(did not exist)* | `0x14b99cb0eb5dfcb46ccec7a5dc5d34ff779fca02e581ba7a363cdba88c394657` |
| new error `OrderNotLinkable(uint256)` | *(did not exist)* | selector `0xa9fdb0c4` |
| `Offer` struct | 12 words | 13 words — `orderId` appended at word 12 |

**No attestation encoding changed.** `orderId` is deliberately not part of the MakeOffer `paramsHash`
preimage, which is still `keccak256(abi.encodePacked(taker, makerToken, makerAmount, takerToken, takerAmount))`
— so **AsseteraComplianceService and AsseteraMarketplaceAPI need no params-hash change for AO-746**. Neither
typehash moved either.

The two new events are additive: an existing subscription keeps working, it just misses the escrow draws and
the cross-close. Missing them is not cosmetic — see
[Orders and offers now share escrow](#orders-and-offers-now-share-escrow-ao-746) for what a read model gets
wrong without them.

### Earlier waves

The checked-in `abi/AsseteraECS.json` (last built before fee support was added to offers, and before `OrderPlaced`/`OrderCancelled` were brought to parity with the offer-side events) has **stale topic0 hashes** for four events. If any indexer is currently subscribed to the old topics, it will silently stop matching once the enriched contract is deployed:

| Event | Legacy topic0 | Current topic0 |
|---|---|---|
| `OfferMade` | `0x547283f9a0401a8e098b3155b4d4c0f9bf7869b8ecb4c52f21c976711e8c0d8d` | `0x96439f2b914d45cac3781d0a9fa97040586d84533c115ca1f47c89abc7abf0a0` — a third generation, after AO-746 appended `orderId`. The value this row used to carry (`0x9a2215dd…`) matched neither the deployed nor the current artifact |
| `OfferSettled` | `0x0d2bd4eb3b4bff159e439b937b915dc9bf99da19cac03d49bfab382a2340154f` | `0xbf1754cbf531494bcfd0b7d7792977208334ff7a6613cbc4ef9ae24384eb7a8e` — the artifact's value, for the eight-field declaration. The value this row used to carry (`0xd56117b4…`) matched nothing in the build |
| `OrderPlaced` | `0x30b02d7ba46ca0b62bd7a8b61fa27bac46398a1017ac00cff82412e6c3a9b2eb` | `0x4234b3dbe8c54202b785e8802bd3eef8cf049cc71dc38c673dd5b76ee099b26d` — the artifact's value, for the eleven-field declaration. The value this row used to carry (`0x97355e9b…`) was for a ten-field declaration that predates the AC-833 `feeToken` field |
| `OrderCancelled` | `0xc0362da6f2ff36b382b34aec0814f6b3cdf89f5ef282a1d1f114d0c0b036d596` | `0xc4058ebc534b64ecb27b2d4eaa1904f98997ec18ebe6ada4117593dde89478cc` |

Legacy signatures (for reference, do not use going forward):
```solidity
event OfferMade(uint256 indexed id, address indexed maker, address indexed taker, address makerToken, uint256 makerAmount, address takerToken, uint256 takerAmount, uint64 expireTs);
event OfferSettled(uint256 indexed id, address indexed operator, uint256 makerReceived, uint256 takerReceived);
event OrderPlaced(uint256 indexed id, address indexed maker, address sellToken, uint256 sellAmount, address buyToken, uint256 buyAmount, uint64 expireTs);
event OrderCancelled(uint256 indexed id, address indexed maker);
```

`OrderPlaced` gained `makerFeeBps`/`takerFeeBps`/`feeCollector` (parity with `OfferMade`, which already carried fee terms at creation). `OrderCancelled` gained `refunded` (parity with `OfferCancelled`, which already carried the refunded amounts).

### Fee token on the order-side events (AC-833) — ⚠️ three more topic0 values moved

The **Earlier waves** table above was itself found stale while AO-746 was written, and at that time only its
two offer rows could be corrected against the build. **Every value in it has since been read from the build
artifact and replaced.** The fee-token work (AC-833) appended a trailing `address feeToken` to `OrderPlaced`, `OrderFilled` and
`OfferSettled`, and gave `OrderPartiallyFilled` a `filledBuyAmount` field as well — a change this document had
never absorbed, so it carried topic0 values for declarations the contract no longer has.

The superseded values are listed here because an indexer wired from an earlier revision of **this document**
is subscribed to them, and they match nothing on the upgraded implementation:

| Event | topic0 this document used to publish | topic0 now (from the artifact) |
|---|---|---|
| `OrderPlaced` (gained a trailing `address feeToken`) | `0x97355e9b15ceac24ea3e32052aed14133a1c3c5eb69ed02fb8134f509cc11225` | `0x4234b3dbe8c54202b785e8802bd3eef8cf049cc71dc38c673dd5b76ee099b26d` |
| `OrderFilled` (gained a trailing `address feeToken`) | `0xd3cd2f38d9c34b52a0736b4e7cab0fa3b5a3dd6ee7153055aa025ebd5053bb58` | `0x82ef6cdb950b657bb4bdf215b1727431a7b5ff2baf8339359a24de43461770c6` |
| `OrderPartiallyFilled` (gained `filledBuyAmount` **and** a trailing `address feeToken`) | `0x4db2a2416e658fbaa61eff2658367836b1734cfc0e80661376e1062dcb89ad14` | `0x59146430e12983429d60fe650176e2c6c6c1ded99f6f91460e02a23e56be2b75` |

`OrderCancelled`, `OrderExpired` and `OrderForceCancelled` were re-read at the same time and are **unchanged**
by AC-833: `0xc4058ebc534b64ecb27b2d4eaa1904f98997ec18ebe6ada4117593dde89478cc`,
`0x795bce27c5ada1127ff0f376d1867477e3e67bfafda5931c1a00dd07c819eeb0` and
`0x6f91387bccb7daefb8b7dabc5a2009c674270731173202bdf3c61f86eb196923` respectively.

`OfferSettled`'s `topic0` did not move with its correction — the value in this document was already the
artifact's, for the eight-field declaration; only the field names and the net-versus-gross reading were wrong.
The errors `LegacyOrderMustBeUnwound(uint256)` and `LegacyOfferMustBeUnwound(uint256)`, also from AC-833, were
missing from [§7](#7-errors-for-revert-reason-decoding) and are now listed there.

Action items for indexer/API teams, for both waves above:
- Subscribe to the **current** topic0 values listed in §4, not the ones in the stale ABI file and not the ones an earlier revision of this document published.
- If backfilling historical logs across a deployment that was upgraded from a pre-enrichment implementation, both topics may appear in the log history for each event above — branch decoding on `topics[0]`.
- Rebuild `abi/AsseteraECS.json` from source (`forge build`) before treating it as authoritative again.

`OrderSettled`/`OrderRefunded` are unchanged between the committed ABI and current source, but they are parked and not emitted (AC-246). `OrderFilled` and `OrderPartiallyFilled` are **not** unchanged — see the AC-833 table above; an earlier revision of this document claimed they were.

### Fee decoupling (⚠️ off-chain-breaking, coordinated release)

`makerFeeBps`/`takerFeeBps`/`feeCollector` were removed from `KycAttestation` and now travel in a separate `FeeAttestation`, signed by a new `FEE_OPERATOR_ROLE` holder (the fee service) instead of the KYC signer. This changes both the KYC EIP-712 typehash and the calldata shape of every fee-setting call — **backend signing code and this doc must deploy in lockstep**:

| Item | Before | After |
|---|---|---|
| `KYC_TYPEHASH` | `keccak256("KycAttestation(...,uint16 makerFeeBps,uint16 takerFeeBps,address feeCollector)")`, 9 fields | `0x9d47d5391d5fdceebb227638b24f6b391e7e39fd6671f3b7478c9767dd1ba835`, 6 fields (fee fields removed) |
| `FEE_TYPEHASH` | *(did not exist)* | `0xf16e0cd6fda16a8c595f563a1b6429cd3f4afc445eadd7aa847cee6a22c843ce` — new, signed by `FEE_OPERATOR_ROLE`. **Superseded by AC-833**, which appended `address feeToken`: the current value is `0x3531aff0e1bd1af792c545fad8cd142e11c96b67decff1940a98277c8c4f530a` (see [§3](#feeattestation-off-chain-struct)) |
| `placeOrder` selector | `0x3a0bd1ce` | `0x35768180` — now takes `(KycAttestation, FeeAttestation)`. The value this row used to carry (`0x1c17a0b2`) predates AC-833, which appended `feeToken` to the `FeeAttestation` tuple and moved every selector that takes one |
| `placeOrderWithPermit` selector | `0xfc71b24e` | `0xe6c02b3c` — now takes `(..., KycAttestation, FeeAttestation)`. The earlier `0xd6f26c85` is superseded for the same AC-833 reason |
| `makeOffer` selector | `0x3e6f6a3a` | `0xc1155711` — took `(KycAttestation, FeeAttestation)`. ⚠️ **Superseded by AO-746**, which added the leading `uint256 orderId`: the current selector is `0x03269a4a` |
| `initialize` selector | `0xc0c53b8b` (`admin,operator,kycSigner`) | `0xc0c53b8b` — ⚠️ **the same selector, but not the same function.** `initialize` is now `initialize(address admin, address kycSigner, address feeSigner)`. The `operator` parameter went when `OPERATOR_ROLE` was parked (AC-246) and the new `feeSigner` took its place, so the arity is still three addresses and the selector collides with the pre-fee-decoupling one. A caller holding old deployment scripts encodes three addresses that still ABI-encode cleanly and lands `feeSigner` where `kycSigner` used to sit — check the argument order, not the selector. An earlier revision of this row claimed `0xf8c8765e` for a four-address `initialize`; no such function exists in the build |

Downstream actions (`fillOrder`, `cancelOrder`, `settle`, `acceptOffer`, `replaceOffer`, `cancelOffer`, `settleOffer`) are unaffected — they still take only `KycAttestation` and read fee terms already snapshotted on the `Order`/`Offer` at placement/offer-creation time. See [§3](#feeattestation-off-chain-struct) for the new struct and [§4](#feeconsumed) for the new `FeeConsumed` event.

### Blacklist removal (⚠️ behavioral change — sweep now always refunds)

The on-chain compliance blacklist (`setBlacklisted`, `BlacklistUpdated`, `AccountBlacklisted`) has been removed entirely. Freezing a user is now purely a backend decision (the KYC signer declines to sign); there is no on-chain enumerable/pseudonymised blocklist to index.

- `setBlacklisted(bytes32,bool)` no longer exists — calling it reverts (function selector unrecognized).
- `BlacklistUpdated(bytes32 indexed hashedAccount, bool blocked)` is no longer emitted.
- `AccountBlacklisted()` is no longer a possible revert reason for any function.
- **`sweepExpired`/`sweepExpiredOffers` behavior changed**: previously, expired orders/offers belonging to a blacklisted maker/proposer were silently skipped (funds stayed locked until `cancelOrderForUser`/`cancelOfferForUser`). Now expired orders/offers **always** sweep back to the maker/proposer once expired, regardless of KYC status. `cancelOrderForUser`/`cancelOfferForUser` remain available as an admin escape hatch to redirect funds to a compliance-chosen recipient while an order/offer is still `Open`/`Accepted` (before expiry).

### Operator functions parked / offer settlement merged into acceptOffer (AC-246)

Standard operation needs no operator actions — settlement/matching isn't done
on-chain by an operator. Order-level `settle` and `refund` are parked
(commented out in `docs/parked/OperatorFunctions.sol`, not deleted) so they can be
re-enabled later via a single UUPS upgrade if ever needed. Offer-level
`settleOffer` is **retired outright, not parked** — its transfer/fee logic was
merged directly into `acceptOffer`, which now settles atomically on acceptance
(no separate step, no operator attestation). `pause`/`unpause` moved from
`OPERATOR_ROLE` to `DEFAULT_ADMIN_ROLE` rather than being parked — a "stop the
venue" lever is worth keeping active. `cancelOrderForUser`/`cancelOfferForUser`
(already `DEFAULT_ADMIN_ROLE`) remain the emergency-exit path — note
`cancelOfferForUser` now only accepts `Open`/`Countered` offers, since
`Accepted` is never a persisted state anymore (see below).

- `settle(uint256,uint256,KycAttestation,KycAttestation)` and
  `refund(uint256,string)` no longer exist on the deployed ABI — calling either
  reverts (function selector unrecognized).
- `settleOffer(uint256,KycAttestation,KycAttestation)` also no longer exists —
  but unlike `settle`/`refund`, it isn't parked for later; its logic lives on
  inside `acceptOffer` permanently.
- `OrderSettled` and `OrderRefunded` are no longer emitted.
  `OrderStatus.Settled`/`OrderStatus.Refunded` are still valid enum values but
  are currently unreachable (their only transitions were through the now-parked
  order functions).
- **`OfferSettled` IS still emitted** — just from `acceptOffer` instead of a
  separate `settleOffer` call, in the same transaction as `OfferAccepted`.
  `OfferStatus.Settled` is very much reachable (it's now the terminal state
  `acceptOffer` writes directly). `OfferStatus.Accepted` is defined in the enum
  but is never a persisted state — don't expect to observe it via `getOffer`.
- `NotComplementary`, `PriceNotCrossed` (order-side) are no longer possible
  revert reasons for any reachable function — exclusive to parked `settle`.
  `OfferNotAccepted` is no longer possible either, for a different reason:
  `acceptOffer`'s precondition was always `OfferNotOpen`, and the retired
  `settleOffer`'s own `OfferNotAccepted` check went with it.
- `OPERATOR_ROLE()` getter no longer exists on the contract, and the constant is
  not granted during `initialize`. ⚠️ **The `operator` parameter is gone, not
  retained**: the build declares `initialize(address,address,address)` — `admin`,
  `kycSigner`, `feeSigner`. An earlier revision of this document said the parameter
  was kept but unused, to leave a signature-free re-enable path for
  `settle`/`refund`; it was not, so re-enabling those needs an explicit role grant
  after the upgrade. Expect no `RoleGranted(OPERATOR_ROLE, ...)` event post-deploy.
- **Reconciliation impact**: `OrderRefunded` is no longer one of the ways
  escrow can leave the contract without a matching `Fill`. `OfferSettled`
  remains one (now via `acceptOffer`, not a separate call). See
  [§8](#8-backfill--reconciliation-notes) — the reconciliation note there is
  updated accordingly.

---

## 6. Actor resolution (ERC-2771 meta-tx)

The contract resolves identity via `_msgSender()` (ERC-2771), so a relayed call's EVM-level `tx.origin`/outer `msg.sender` will be the **trusted forwarder** (`contracts.Forwarder` in the chain's deployment record), not the actual user. **Never key user identity off the transaction's `from` field** when the forwarder is in play — always use the address embedded in the event itself (`maker`, `taker`, `account`, `by`, `proposedBy`, `buyer`, etc.), which is already correctly resolved by the contract before emission.

`AsseteraPrimarySales` resolves identity the same way, through the **same** trusted forwarder, so a gasless primary sale works exactly like a gasless order and `PrimarySettled.buyer` / `IntentConsumed.buyer` are already resolved. The contract additionally requires `intent.buyer == _msgSender()` (`IntentBuyerMismatch`), so nobody settles on somebody else's behalf.

`isTrustedForwarder(address)` / `trustedForwarder()` are available for indexers that want to detect and flag relayed transactions.

---

## 7. Errors (for revert-reason decoding)

All reverts are custom errors (no revert strings). 4-byte selectors, for API layers that need to decode `eth_call`/`eth_estimateGas` revert data.

⚠️ **Two tables.** The first is `AsseteraECS`; the second is `AsseteraPrimarySales`, which is a
different contract at a different address with its own error set. A few selectors appear in both
because the two share the fee and attestation-binding code.

### `AsseteraECS`

| Error | Selector |
|---|---|
| `ZeroAddress()` | `0xd92e233d` |
| `ZeroAmount()` | `0x1f2a2005` |
| `SameToken()` | `0x201b580a` |
| `OrderNotOpen(uint256)` | `0x410e0437` |
| `NotMaker(uint256)` | `0x9f220883` |
| `NotComplementary(uint256,uint256)` | `0x357d4e12` — parked (AC-246), unreachable |
| `PriceNotCrossed(uint256,uint256)` | `0x16c1ab33` — parked (AC-246), unreachable |
| `SelfTrade(uint256)` | `0x0d789560` |
| `OrderIsExpired(uint256)` | `0xfcdee3a5` |
| `InvalidExpiry()` | `0xd36c8500` |
| `FillAmountZero()` | `0x7e3e9917` |
| `FillExceedsRemaining(uint256,uint256)` | `0xbb86b38c` |
| `ParamsHashMismatch()` | `0xb1561fdb` |
| `FeeCollectorNotAllowed(address)` | `0x4eda3f1b` |
| `InvalidFee()` | `0x58d620b3` |
| `OfferNotFound(uint256)` | `0x1f376e4c` |
| `OfferNotOpen(uint256)` | `0xf270fad7` |
| `OfferNotAccepted(uint256)` | `0x9c9407ec` — retired (AC-246), no longer possible; was exclusive to the now-retired `settleOffer` |
| `NotOfferParty(uint256)` | `0xfca59ad9` |
| `OfferSelfTarget()` | `0xf5e59dba` |
| `AcceptorIsProposer(uint256)` | `0xf39ecaf3` |
| `OfferIsExpired(uint256)` | `0xe24e370c` |
| `LegacyOrderMustBeUnwound(uint256)` | `0xd41439cf` — an order created before the AC-833 fee-token change carries `feeToken == address(0)`, so its fees cannot be denominated. It can still be cancelled, swept or force-cancelled, but it can never be filled |
| `LegacyOfferMustBeUnwound(uint256)` | `0xe5d19dda` — the same for an offer: cancellable, sweepable and force-cancellable, but never counterable or acceptable |
| `OrderNotLinkable(uint256)` | `0xa9fdb0c4` — new (AO-746): `makeOffer` named an order that no party to the offer owns, or that sells a token neither leg trades. Such a link could never fund anything, so it is refused at creation. An order that exists but is not `Open` raises `OrderNotOpen(uint256)` instead |
| `KycAccountMismatch()` | `0x542c202e` |
| `KycActionMismatch()` | `0x95016318` |
| `KycOrderMismatch()` | `0x19e30b01` |
| `KycExpired()` | `0x03500634` |
| `KycTtlTooLong()` | `0x95b88c37` |
| `KycNonceUsed()` | `0x6ad0f3dd` |
| `KycBadSigner()` | `0x36c9d94d` |
| `FeeAccountMismatch()` | `0x97e73bff` |
| `FeeActionMismatch()` | `0x0e61c26a` |
| `FeeExpired()` | `0x77fe4a46` |
| `FeeTtlTooLong()` | `0x1a2d6586` |
| `FeeNonceUsed()` | `0xd77d3a82` |
| `FeeBadSigner()` | `0x26aa3fdd` |
| `FeeTokenNotALeg(address)` | `0x11488bf1` — the fee attested in a token that is neither leg of the trade |

### `AsseteraPrimarySales`

Emitted from the **primary-sales proxy**, not the exchange. Everything below is reachable on
`settlePrimary`.

| Error | Selector | Meaning |
|---|---|---|
| `FeeTokenNotALeg(address)` | `0x11488bf1` | ⚠️ **the fee attested in a token other than `intent.settlementToken`.** A primary sale has one currency leg, so the shared leg test becomes the strict denomination rule. **This is the error a `settlementToken`/`feeToken` disagreement raises.** An earlier revision raised `SettlementTokenMismatch()` (`0x913c5c21`) here; that error **is not in the ABI** and will never be returned |
| `InsufficientAssetDelivered(uint256,uint256)` | `0xd2c62759` | measured delivery to the buyer was below the signed `intent.minAssetOut`. The venue underfilled or delivered nothing |
| `SettlementPullMismatch(uint256,uint256)` | `0x75310e1b` | the settlement currency actually received by the router differed from what it debited. Fee-on-transfer or rebasing currency, refused rather than absorbed |
| `RouterBalanceChanged()` | `0xa3e853d4` | the router did not end the call with the balances it started with. Should never be seen; treat as an alertable invariant breach, not a user error |
| `VenueCallFailed()` | `0xc2e441e5` | the venue reverted. **Its revert data is not propagated**, so there is no inner reason to decode; diagnose from the venue's own tooling |
| `VenueIsASettledToken()` | `0x01d03f44` | the intent named one of the two settled tokens as the venue |
| `BuyerFeeMismatch(uint256,uint256)` | `0x3e7e427a` | the attested fee did not equal `FeeMath.feeAmount(venueQuoteIn, takerFeeBps)`. The fee signer and the settlement signer disagree on the number |
| `PerTxCapExceeded(address,uint256,uint256)` | `0x4edf5886` | the gross pull exceeded the admin cap for that currency. ⚠️ **An unset cap is zero and zero means closed**, so this is also what an unconfigured currency returns |
| `TokenDecimalsUnavailable(address)` | `0x9cf5ab50` | cap configuration could not read `decimals()` on the currency |
| `TokenDecimalsImplausible(address,uint256)` | `0x623f73cd` | `decimals()` returned a value outside the accepted band |
| `MakerFeeNotSupported()` | `0x0b7d56e6` | the fee attestation carried a non-zero `makerFeeBps`. This router charges the buyer side only |
| `MaxSettlementTooLow()` | `0x5fd4bec1` | the signed `maxSettlementIn` cannot cover `venueQuoteIn + fee` |
| `ZeroVenueQuote()` | `0x0754d23a` | `venueQuoteIn` was zero. Its own error rather than the shared `ZeroAmount()`, so a zero quote is distinguishable from a zero elsewhere in the intent |
| `FeeCollectorMismatch()` | `0x2c75e203` | the fee attestation and the intent named different collectors, both allowlisted |
| `CalldataHashMismatch()` | `0xcb8a4609` | the venue calldata passed in did not hash to the value the buyer and the operator signed |
| `SelectorMismatch()` | `0x42214767` | the venue calldata's leading 4 bytes were not the signed selector |
| `IntentBuyerMismatch()` | `0xb5fccf4d` | the resolved actor was not `intent.buyer`. Nobody settles on somebody else's behalf |
| `IntentExpired()` | `0x408b2234` | the intent's deadline has passed |
| `IntentTtlTooLong()` | `0xc404a1ea` | the intent's TTL exceeded the accepted window |
| `IntentNonceUsed()` | `0xbf493317` | the intent nonce was already burned. **Third namespace**, not the KYC or fee one |
| `IntentBadSigner()` | `0x5055cade` | the operator signature did not recover to a `SETTLEMENT_OPERATOR_ROLE` holder |
| `BuyerConsentBadSignature()` | `0xf97769d0` | the buyer's signature over the same digest did not validate (ERC-1271 aware, so a Safe is a valid buyer) |
| `HandshakeTransferFailed(address,uint256)` | `0x6e6a21f1` | an admin handshake transfer failed |
| `ParamsHashMismatch()` | `0xb1561fdb` | shared with the exchange; an attestation's `paramsHash` did not bind to the intent |
| `SameToken()` | `0x201b580a` | shared; asset and settlement token were the same address |
| `ZeroAmount()` | `0x1f2a2005` | shared |
| `ZeroAddress()` | `0xd92e233d` | shared |
| `InvalidFee()` | `0x58d620b3` | shared; the attested bps was outside the accepted bound |
| `FeeCollectorNotAllowed(address)` | `0x4eda3f1b` | shared code, **separate allowlist** — this router's starts empty and the exchange's entries do not carry over |

The KYC and fee attestation errors (`Kyc*`, `Fee*` in the table above) are raised from the same
shared code on this contract too, with the same selectors.

### `AsseteraIssuanceVenue`

Emitted from a **per-offering issuance venue**, not from the router. ⚠️ A settlement that fails
inside the venue reaches the caller as the router's `VenueCallFailed()` (`0xc2e441e5`) with the
inner reason **not propagated**, so these selectors are what a trace shows and what a direct call
to the venue returns — they are not what `settlePrimary` reverts with.

| Error | Selector | Meaning |
|---|---|---|
| `CallerNotRouter(address)` | `0xfb217bcd` | somebody other than the configured router called `purchase`. There is exactly one legitimate caller and it is fixed at deployment, so this is also what a hostile token attempting reentrancy gets |
| `PurchaseCapExceeded(uint256,uint256)` | `0xa48e687d` | the purchase asks to spend more than the venue's per-purchase cap. ⚠️ **A zero cap means the venue cannot sell**, so this is also what an unopened or deliberately closed venue returns |
| `NothingToMint(uint256,uint256)` | `0xd668208c` | the payment is too small to buy a single unit at the current price. Refused rather than taken for nothing. Unreachable when the settlement token has fewer decimals than the asset |
| `InsufficientAssetOut(uint256,uint256)` | `0x7e529415` | the current price yields less than the caller's floor: the offering was repriced between the intent being signed and the transaction landing |
| `SettlementPullMismatch(uint256,uint256)` | `0x75310e1b` | the venue's measured balance delta over the pull was not the amount charged. Same signature and selector as the router's, raised for the same reason: a fee-on-transfer or deflationary settlement currency **cannot be sold in at all** |
| `AssetDeliveryShortfall(uint256,uint256)` | `0x47f51046` | the mint did not put the quoted quantity in the buyer's hands — a `mint` that no-ops, one that returns `false` rather than reverting, an asset that charges a transfer fee, or a downward rebase inside the call |
| `ChargeExceedsAuthorised(uint256,uint256)` | `0xcbed1e84` | the venue computed a charge above the amount offered. Unreachable by construction and guarded anyway; treat as an alertable invariant breach, not a user error |
| `UnitPriceOutOfBounds(uint256,uint256,uint256)` | `0x488c8017` | a repricing outside the bounds fixed at deployment. Both bounds are inclusive and the floor is always greater than zero |
| `PriceBoundsInvalid(uint256,uint256)` | `0x7a845289` | deployment-time only: a zero price floor, or a floor above the ceiling |
| `RescueOfSettlementToken()` | `0xf3a72631` | `rescue` was pointed at the settlement currency. Proceeds leave through `withdraw` |
| `TokenDecimalsImplausible(address,uint256)` | `0x623f73cd` | deployment-time only; same selector as the router's |
| `SameToken()` | `0x201b580a` | deployment-time only: the settlement currency and the asset are the same address |
| `ZeroAddress()` | `0xd92e233d` | shared |
| `ZeroAmount()` | `0x1f2a2005` | shared |
| `EnforcedPause()` | `0xd93c0665` | OpenZeppelin `Pausable`: this offering is stopped. The router is unaffected |
| `AccessControlUnauthorizedAccount(address,bytes32)` | `0xe2517d3f` | OpenZeppelin `AccessControl`. ⚠️ **Also what a purchase returns when the ISSUER never granted the venue the minting right on the asset token** — the account named is the venue and the role is the token's minter role |
| `ReentrancyGuardReentrantCall()` | `0x3ee5aeb5` | OpenZeppelin `ReentrancyGuard`, shared by `purchase`, `withdraw` and `rescue` |


---

## 8. Backfill / reconciliation notes

- Orders and offers are 1-indexed; `totalOrders()`/`totalOffers()` give the current high-water mark. Enumeration/pagination (e.g. "all open orders") is served off-chain by the indexer / Marketplace API — the contract only exposes point reads (`getOrder`/`getOffer`).
- Every state-changing path emits exactly one primary lifecycle event per order/offer per call, so a correct read model can be built purely from events without ever calling `getOrder`/`getOffer` — the view functions are for point-in-time reconciliation/debugging, not required for the primary indexing path. ⚠️ Since AO-746 one call can touch **two** entries: an offer call that draws on, or closes, a linked order emits the offer's own event **plus** `OrderEscrowDrawn` and/or `OrderClosedByOffer` for the order. Both are needed for the order's balances and status to stay correct.
- `OrderCancelled`, `OfferCancelled`, `OrderForceCancelled`, `OfferForceCancelled`, and both `sweep*` events are the ways escrow leaves the contract without a matching `Fill`/`OfferSettled` — make sure these are included in any balance-reconciliation job, or on-chain token balance will not match the sum of indexed fills/settlements. (`OrderRefunded`/`OrderSettled` are not currently emitted — `refund`/`settle` are parked, AC-246. `OfferSettled` is the exception: it still fires, from `acceptOffer` rather than a separate `settleOffer` call — see [§5](#operator-functions-parked--offer-settlement-merged-into-acceptoffer-ac-246).)
- **`OrderEscrowDrawn` moves no tokens (AO-746).** It reassigns a claim inside one pooled per-token balance, so a reconciliation job that treats it as an outflow will double-count. What it does change is the order's `remainingQuantity`, which can now fall, all the way to zero, with the order still `Open` and no fill event anywhere. If the offer that drew on an order is later cancelled, replaced, swept or force-cancelled, the tokens go to the **proposer's wallet** under the offer's own event, never the order's, and the order stays `Open` at the reduced quantity permanently.
- **`OrderClosedByOffer` is a terminal order transition with no fill event (AO-746).** It is the only path from `Open` to `Filled` that emits no `OrderFilled`, and its `refunded` field is an outflow (the order's unconsumed escrowed fee, returned to the order's maker in the order's `sellToken`). A read model that closes orders on fill events alone leaves these open forever, which is the defect AO-746 fixed.
