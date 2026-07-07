# AsseteraExchange — Interface & Event Schema (Indexer/API Reference)

**Contract version:** `3.1.0` (`version()`)
**Solidity:** 0.8.28
**Proxy pattern:** UUPS (ERC-1967) — index the **proxy** address; ABI/events come from the **implementation**
**Meta-tx:** ERC-2771 (see [Actor resolution](#actor-resolution-erc-2771-meta-tx) — do not key identity off `tx.from`)
**Source of truth:** `src/AsseteraExchange.sol`. This document is generated from that file directly (event/error signatures hashed independently), not from the checked-in `abi/AsseteraExchange.json`, which is stale — see [Schema versioning](#schema-versioning--breaking-change) below.

| Network | Chain ID | Proxy address | Forwarder |
|---|---|---|---|
| Polygon Amoy (testnet) | 80002 | `0x8B75B0c5Dc41Fca81c87Af0cbBA9Cf764aFE8616` | `0xc2D759d37bbfbE5a73b60d1cD4CFFd1B73CC4d7F` |

Source: `deployments/80002.json`. Confirm the current implementation address via `eip1967.proxy.implementation` slot or `proxiableUUID()` before assuming this doc's function set is deployed on a given network.

---

## 1. How to get the full ABI

```
abi/AsseteraExchange.json
```

Regenerate after any contract change with `forge build` (emits `out/AsseteraExchange.sol/AsseteraExchange.json`, which should be copied/synced to `abi/`). **The current `abi/AsseteraExchange.json` predates the fee-enrichment of `OfferMade`/`OfferSettled` — do not rely on it for those two events until it is rebuilt.** All signatures, topics, and selectors in this document were computed directly from the current `src/AsseteraExchange.sol` source, independent of that file.

---

## 2. Public interface reference

All state-changing functions accept a `KycAttestation calldata att` (or two, for two-party actions) unless noted. See [§4 KycAttestation](#kycattestation-off-chain-struct) for its shape.

### Maker actions

| Function | Access | Notes |
|---|---|---|
| `placeOrder(address sellToken, uint256 sellAmount, address buyToken, uint256 buyAmount, uint64 expireTs, KycAttestation calldata att) → uint256 id` | KYC-gated (`Action.Place`) | Escrows `sellAmount` of `sellToken`. Emits `OrderPlaced`. |
| `placeOrderWithPermit(address sellToken, uint256 sellAmount, address buyToken, uint256 buyAmount, uint64 expireTs, uint256 permitDeadline, uint8 v, bytes32 r, bytes32 s, KycAttestation calldata att) → uint256 id` | KYC-gated (`Action.Place`) | Same as `placeOrder`; attempts ERC-2612 `permit` first (best-effort, swallowed on failure). |
| `cancelOrder(uint256 id)` | maker only, no attestation required | A maker can always cancel their own open order and reclaim escrow, regardless of KYC/blacklist status. Emits `OrderCancelled`. |

### Taker actions

| Function | Access | Notes |
|---|---|---|
| `fillOrder(uint256 id, uint256 fillSellAmount, KycAttestation calldata att)` | KYC-gated (`Action.Fill`) | Emits `OrderFilled` (full) or `OrderPartiallyFilled` (partial). |

### Offer lifecycle (maker/taker, party-restricted)

| Function | Access | Notes |
|---|---|---|
| `makeOffer(address taker, address makerToken, uint256 makerAmount, address takerToken, uint256 takerAmount, uint64 expireTs, KycAttestation calldata att) → uint256 id` | KYC-gated (`Action.MakeOffer`) | Targeted at a specific `taker`. Emits `OfferMade`. |
| `replaceOffer(uint256 offerId, uint256 newMakerAmount, uint256 newTakerAmount, uint64 expireTs, KycAttestation calldata att)` | maker or taker, KYC-gated (`Action.ReplaceOffer`) | Counter-proposal; flips `proposedBy`. Emits `OfferReplaced`. |
| `cancelOffer(uint256 offerId, KycAttestation calldata att)` | maker or taker, KYC-gated (`Action.CancelOffer`) | Only while `Open`/`Countered`. Emits `OfferCancelled`. |
| `acceptOffer(uint256 offerId, KycAttestation calldata att)` | non-proposing party, KYC-gated (`Action.AcceptOffer`) | Escrows the accepting side. Emits `OfferAccepted`. |

### Operator actions (`OPERATOR_ROLE`)

| Function | Notes |
|---|---|
| `settle(uint256 buyId, uint256 sellId, KycAttestation calldata attBuy, KycAttestation calldata attSell)` | Requires both makers' fresh `Action.Settle` attestations. Emits `OrderSettled`. |
| `settleOffer(uint256 offerId, KycAttestation calldata makerAtt, KycAttestation calldata takerAtt)` | Requires both parties' fresh `Action.SettleOffer` attestations. Emits `OfferSettled`. |
| `refund(uint256 id, string calldata reason)` | Returns remaining escrow to maker. Emits `OrderRefunded`. |
| `pause()` / `unpause()` | Gates `whenNotPaused` functions. Emits standard `Paused(address)`/`Unpaused(address)`. |

### Admin actions (`DEFAULT_ADMIN_ROLE`)

| Function | Notes |
|---|---|
| `cancelOrderForUser(uint256 id, address recipient)` | Escape hatch for frozen/blacklisted makers. Emits `OrderForceCancelled`. |
| `cancelOfferForUser(uint256 offerId, address makerRecipient, address takerRecipient)` | Works in any non-terminal state incl. `Accepted`. Emits `OfferForceCancelled`. |
| `setAllowedCollector(address collector, bool allowed)` | Fee collector allowlist. Emits `CollectorAllowed`. |
| `setComplianceRequired(Action action, bool required)` | Per-action KYC gating toggle. Emits `ComplianceRequiredSet`. |
| `setBlacklisted(bytes32 hashedAccount, bool blocked)` | `hashedAccount = keccak256(abi.encodePacked(account))`, pseudonymised. Emits `BlacklistUpdated`. |
| `upgradeToAndCall(address newImplementation, bytes data)` | Inherited UUPS; gated via `_authorizeUpgrade`. Emits standard `Upgraded(address)`. |

### Permissionless (anyone may call)

| Function | Notes |
|---|---|
| `sweepExpired(uint256[] calldata ids)` | Batch-sweeps expired `Open` orders back to maker. Silently skips non-matching/blacklisted entries. Batch ids in chunks of ≤100. Emits `OrderExpired` per swept id. |
| `sweepExpiredOffers(uint256[] calldata ids)` | Same, for offers. Emits `OfferExpired` per swept id. |

### Views

| Function | Returns |
|---|---|
| `getOrder(uint256 id)` | `Order` struct (see [§4](#order-struct)) — point read only; enumeration/pagination is served off-chain by the indexer |
| `getOffer(uint256 id)` | `Offer` struct |
| `totalOrders()` / `totalOffers()` | `uint256` — highest assigned id (ids are `1..total`) |
| `usedNonce(address account, uint256 nonce)` | `bool` — KYC nonce consumption state |
| `complianceRequired(Action action)` | `bool` — whether that action currently requires an attestation |
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
| 2 | `Filled` |
| 3 | `Settled` |
| 4 | `Cancelled` |
| 5 | `Refunded` |
| 6 | `ForceCancelled` |
| 7 | `Expired` |

### `OfferStatus` (uint8)

| Value | Name |
|---|---|
| 0 | `None` |
| 1 | `Open` |
| 2 | `Countered` |
| 3 | `Accepted` |
| 4 | `Settled` |
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
| 8 | `SettleOffer` |

There is no order-level `Cancel` action — `cancelOrder` never requires (or consumes) a KYC attestation. `CancelOffer`/`SettleOffer` are deliberately distinct from `Settle` — an attestation for one cannot be replayed against the other.

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

### `KycAttestation` (off-chain struct)

Not stored on-chain; passed as calldata to state-changing calls and reflected into `KycConsumed`.

| Field | Type |
|---|---|
| `account` | `address` |
| `action` | `Action` (`uint8`) |
| `orderId` | `uint256` |
| `nonce` | `uint256` |
| `deadline` | `uint256` |
| `paramsHash` | `bytes32` |
| `makerFeeBps` | `uint16` |
| `takerFeeBps` | `uint16` |
| `feeCollector` | `address` |
| `signature` | `bytes` |

`KYC_TYPEHASH = 0x2bc2d563768338fb74d89d51a723dffab422263d3ac6a8caf9e0d41de82235d9`
(`keccak256("KycAttestation(address account,uint8 action,uint256 orderId,uint256 nonce,uint256 deadline,bytes32 paramsHash,uint16 makerFeeBps,uint16 takerFeeBps,address feeCollector)")`)

### Role constants (for decoding inherited `RoleGranted`/`RoleRevoked` events)

| Role | Value |
|---|---|
| `DEFAULT_ADMIN_ROLE` | `0x0000000000000000000000000000000000000000000000000000000000000000` |
| `OPERATOR_ROLE` | `0x97667070c54ef182b0f5858b034beac1b6f3089aa2d3188bb1e8929f4fa9b929` |
| `KYC_OPERATOR_ROLE` | `0xdf54a8fce50b9de7187b8b9daaa3b95e6ef1bf1df5fe0a03ddea8faa73de2a10` |

---

## 4. Event schema

Event summary:

| Event | Emitted by |
|---|---|
| `OrderPlaced` | `placeOrder`, `placeOrderWithPermit` |
| `OrderCancelled` | `cancelOrder` |
| `OrderFilled` | `fillOrder` (full fill) |
| `OrderPartiallyFilled` | `fillOrder` (partial fill) |
| `OrderSettled` | `settle` |
| `OrderRefunded` | `refund` |
| `OrderForceCancelled` | `cancelOrderForUser` |
| `OrderExpired` | `sweepExpired` (once per swept id) |
| `CollectorAllowed` | `setAllowedCollector` |
| `KycConsumed` | any KYC-gated action, on attestation consumption |
| `ComplianceRequiredSet` | `setComplianceRequired` |
| `BlacklistUpdated` | `setBlacklisted` |
| `OfferMade` | `makeOffer` |
| `OfferReplaced` | `replaceOffer` |
| `OfferCancelled` | `cancelOffer` |
| `OfferForceCancelled` | `cancelOfferForUser` |
| `OfferExpired` | `sweepExpiredOffers` (once per swept id) |
| `OfferAccepted` | `acceptOffer` |
| `OfferSettled` | `settleOffer` |

Each `topic0` below (`keccak256` of the canonical signature) was computed independently against the current source, not the checked-in ABI JSON.

---

### `OrderPlaced`

```solidity
event OrderPlaced(uint256 indexed id, address indexed maker, address sellToken, uint256 sellAmount, address buyToken, uint256 buyAmount, uint64 expireTs);
```
- **topic0:** `0x30b02d7ba46ca0b62bd7a8b61fa27bac46398a1017ac00cff82412e6c3a9b2eb`
- **Indexed:** `id`, `maker`
- **Data:** `sellToken`, `sellAmount`, `buyToken`, `buyAmount`, `expireTs`

| Field | Description |
|---|---|
| `id` | new order id |
| `maker` | resolved actor (`_msgSender()`), not necessarily `tx.from` — see [§5](#actor-resolution-erc-2771-meta-tx) |
| `sellToken`, `sellAmount` | escrowed leg |
| `buyToken`, `buyAmount` | desired leg at placement |
| `expireTs` | `0` = no expiry |

---

### `OrderCancelled`

```solidity
event OrderCancelled(uint256 indexed id, address indexed maker);
```
- **topic0:** `0xc0362da6f2ff36b382b34aec0814f6b3cdf89f5ef282a1d1f114d0c0b036d596`
- **Indexed:** `id`, `maker`
- **Data:** *(none)*

Always unattested — `cancelOrder` never requires a KYC attestation, so no `KycConsumed` event accompanies it.

---

### `OrderFilled` (full fill — `remainingQuantity` reaches 0)

```solidity
event OrderFilled(uint256 indexed id, address indexed maker, address indexed taker, uint256 filledSellAmount, uint256 filledBuyAmount, uint256 makerFeeAmount, uint256 takerFeeAmount, address feeCollector);
```
- **topic0:** `0xd3cd2f38d9c34b52a0736b4e7cab0fa3b5a3dd6ee7153055aa025ebd5053bb58`
- **Indexed:** `id`, `maker`, `taker`
- **Data:** `filledSellAmount`, `filledBuyAmount`, `makerFeeAmount`, `takerFeeAmount`, `feeCollector`

| Field | Description |
|---|---|
| `filledSellAmount` | `sellToken` amount taken from the order (gross) |
| `filledBuyAmount` | `buyToken` amount the taker paid, **ceiling-divided** so the maker never loses to rounding (gross, pre-fee) |
| `makerFeeAmount` | deducted from `filledBuyAmount` before the maker receives it (in `buyToken`) |
| `takerFeeAmount` | deducted from `filledSellAmount` before the taker receives it (in `sellToken`) |
| `feeCollector` | recipient of both fee legs; `address(0)` semantics only apply when both fee bps are 0 — collector is otherwise always allowlisted |

Net maker receipt = `filledBuyAmount - makerFeeAmount` (buyToken). Net taker receipt = `filledSellAmount - takerFeeAmount` (sellToken).

---

### `OrderPartiallyFilled` (partial fill — `remainingQuantity` > 0 after)

```solidity
event OrderPartiallyFilled(uint256 indexed id, address indexed maker, address indexed taker, uint256 filledSellAmount, uint256 remainingQuantity, uint256 makerFeeAmount, uint256 takerFeeAmount, address feeCollector);
```
- **topic0:** `0x4db2a2416e658fbaa61eff2658367836b1734cfc0e80661376e1062dcb89ad14`
- **Indexed:** `id`, `maker`, `taker`
- **Data:** `filledSellAmount`, `remainingQuantity`, `makerFeeAmount`, `takerFeeAmount`, `feeCollector`

Same fee semantics as `OrderFilled`. Note the 5th field is `remainingQuantity` (order's new remaining balance), **not** `filledBuyAmount` — reconstruct the buy-side amount off-chain as `(filledSellAmount * order.buyAmount + order.sellAmount - 1) / order.sellAmount` against the order's original `sellAmount`/`buyAmount`, or read `getOrder(id)`.

---

### `OrderSettled`

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

### `OrderRefunded`

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

`recipient` may differ from `maker` (compliance-directed payout for a frozen/blacklisted account).

---

### `OrderExpired`

```solidity
event OrderExpired(uint256 indexed id, address indexed maker, uint256 remainingQuantity);
```
- **topic0:** `0x795bce27c5ada1127ff0f376d1867477e3e67bfafda5931c1a00dd07c819eeb0`
- **Indexed:** `id`, `maker`
- **Data:** `remainingQuantity` (amount returned to maker)

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

Emitted **only** when `complianceRequired[action]` is `true` at call time (see `ComplianceRequiredSet`) — its absence in a trade tx means gating was disabled for that action, not that verification was skipped (blacklist checks are unconditional and still enforced). `orderId` is `0` for actions not bound to an existing order/offer id (e.g. `Place`, `MakeOffer`). Useful as the canonical "attestation was consumed" audit trail, and to disambiguate `OrderCancelled` as described above.

---

### `ComplianceRequiredSet`

```solidity
event ComplianceRequiredSet(Action indexed action, bool required);
```
- **topic0:** `0x9e21c2e33dd513cd0d70dfe567833a0857ea2998e4a82582cd046d9aa1ca8e41`
- **Indexed:** `action`
- **Data:** `required`

---

### `BlacklistUpdated`

```solidity
event BlacklistUpdated(bytes32 indexed hashedAccount, bool blocked);
```
- **topic0:** `0xdcf7bb788a4c8c91f85b15fa04797101b624ce86f804c2ccc49d8474adeb90ba`
- **Indexed:** `hashedAccount`
- **Data:** `blocked`

`hashedAccount = keccak256(abi.encodePacked(account))` — the plaintext address is **never** on-chain (pseudonymisation). An indexer cannot reverse this to an address; it can only confirm/deny membership for a specific address it already suspects, by hashing it client-side and comparing.

---

### `OfferMade`

```solidity
event OfferMade(uint256 indexed id, address indexed maker, address indexed taker, address makerToken, uint256 makerAmount, address takerToken, uint256 takerAmount, uint64 expireTs, uint16 makerFeeBps, uint16 takerFeeBps, address feeCollector);
```
- **topic0:** `0x9a2215dd4757ce4fb8f33ba1aa34263336106138872458642dd644b63b367aa0`
- **Indexed:** `id`, `maker`, `taker`
- **Data:** `makerToken`, `makerAmount`, `takerToken`, `takerAmount`, `expireTs`, `makerFeeBps`, `takerFeeBps`, `feeCollector`

⚠️ **This topic0 differs from the previously-shipped ABI** — see [Schema versioning](#schema-versioning--breaking-change).

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

Both recipients are always present in the event even if only one side was actually escrowed (non-`Accepted` states) — check prior offer status via `getOffer`/state reconstruction if it matters which leg actually moved funds.

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
event OfferAccepted(uint256 indexed id, address indexed by, uint256 makerAmount, uint256 takerAmount);
```
- **topic0:** `0x1af0dda70fa313a26fdffb3d1ad4e70836d36fedc4a635c8064748e893ea5d19`
- **Indexed:** `id`, `by`
- **Data:** `makerAmount`, `takerAmount` (terms agreed to, at acceptance)

---

### `OfferSettled`

```solidity
event OfferSettled(uint256 indexed id, address indexed operator, uint256 makerReceived, uint256 takerReceived, uint256 makerFeeAmount, uint256 takerFeeAmount, address feeCollector);
```
- **topic0:** `0xd56117b42362b08e3c76f631c76916c329307575ac77d99398dc012b03c26223`
- **Indexed:** `id`, `operator`
- **Data:** `makerReceived`, `takerReceived`, `makerFeeAmount`, `takerFeeAmount`, `feeCollector`

⚠️ **This topic0 differs from the previously-shipped ABI** — see below. `makerReceived`/`takerReceived` here are already **net of fee** (unlike `OrderSettled`'s gross amounts) — `makerReceived = takerAmount - makerFeeAmount`, `takerReceived = makerAmount - takerFeeAmount`.

---

## 5. Schema versioning — breaking change

The checked-in `abi/AsseteraExchange.json` (last built before fee support was added to offers) has **stale topic0 hashes** for two events. If any indexer is currently subscribed to the old topics, it will silently stop matching once the enriched contract is deployed:

| Event | Legacy topic0 (pre-fee, 8/4 params) | Current topic0 (post-fee) |
|---|---|---|
| `OfferMade` | `0x547283f9a0401a8e098b3155b4d4c0f9bf7869b8ecb4c52f21c976711e8c0d8d` | `0x9a2215dd4757ce4fb8f33ba1aa34263336106138872458642dd644b63b367aa0` |
| `OfferSettled` | `0x0d2bd4eb3b4bff159e439b937b915dc9bf99da19cac03d49bfab382a2340154f` | `0xd56117b42362b08e3c76f631c76916c329307575ac77d99398dc012b03c26223` |

Legacy signatures (for reference, do not use going forward):
```solidity
event OfferMade(uint256 indexed id, address indexed maker, address indexed taker, address makerToken, uint256 makerAmount, address takerToken, uint256 takerAmount, uint64 expireTs);
event OfferSettled(uint256 indexed id, address indexed operator, uint256 makerReceived, uint256 takerReceived);
```

Action items for indexer/API teams:
- Subscribe to the **current** topic0 values listed in §4, not the ones in the stale ABI file.
- If backfilling historical logs across a deployment that was upgraded from a pre-fee implementation, both topics may appear in the log history — branch decoding on `topics[0]`.
- Rebuild `abi/AsseteraExchange.json` from source (`forge build`) before treating it as authoritative again; all other events/functions in the current committed ABI file match this document.

All other events (`OrderPlaced`, `OrderFilled`, `OrderPartiallyFilled`, `OrderSettled`, etc.) are unchanged between the committed ABI and current source.

---

## 6. Actor resolution (ERC-2771 meta-tx)

The contract resolves identity via `_msgSender()` (ERC-2771), so a relayed call's EVM-level `tx.origin`/outer `msg.sender` will be the **trusted forwarder** (`0xc2D759d37bbfbE5a73b60d1cD4CFFd1B73CC4d7F` on Amoy), not the actual user. **Never key user identity off the transaction's `from` field** when the forwarder is in play — always use the address embedded in the event itself (`maker`, `taker`, `account`, `by`, `proposedBy`, etc.), which is already correctly resolved by the contract before emission.

`isTrustedForwarder(address)` / `trustedForwarder()` are available for indexers that want to detect and flag relayed transactions.

---

## 7. Errors (for revert-reason decoding)

All reverts are custom errors (no revert strings). 4-byte selectors, for API layers that need to decode `eth_call`/`eth_estimateGas` revert data:

| Error | Selector |
|---|---|
| `ZeroAddress()` | `0xd92e233d` |
| `ZeroAmount()` | `0x1f2a2005` |
| `SameToken()` | `0x201b580a` |
| `OrderNotOpen(uint256)` | `0x410e0437` |
| `NotMaker(uint256)` | `0x9f220883` |
| `NotComplementary(uint256,uint256)` | `0x357d4e12` |
| `PriceNotCrossed(uint256,uint256)` | `0x16c1ab33` |
| `SelfTrade(uint256)` | `0x0d789560` |
| `OrderIsExpired(uint256)` | `0xfcdee3a5` |
| `InvalidExpiry()` | `0xd36c8500` |
| `FillAmountZero()` | `0x7e3e9917` |
| `FillExceedsRemaining(uint256,uint256)` | `0xbb86b38c` |
| `AccountBlacklisted()` | `0x7d28af3f` |
| `ParamsHashMismatch()` | `0xb1561fdb` |
| `FeeCollectorNotAllowed(address)` | `0x4eda3f1b` |
| `InvalidFee()` | `0x58d620b3` |
| `OfferNotFound(uint256)` | `0x1f376e4c` |
| `OfferNotOpen(uint256)` | `0xf270fad7` |
| `OfferNotAccepted(uint256)` | `0x9c9407ec` |
| `NotOfferParty(uint256)` | `0xfca59ad9` |
| `OfferSelfTarget()` | `0xf5e59dba` |
| `AcceptorIsProposer(uint256)` | `0xf39ecaf3` |
| `OfferIsExpired(uint256)` | `0xe24e370c` |
| `KycAccountMismatch()` | `0x542c202e` |
| `KycActionMismatch()` | `0x95016318` |
| `KycOrderMismatch()` | `0x19e30b01` |
| `KycExpired()` | `0x03500634` |
| `KycTtlTooLong()` | `0x95b88c37` |
| `KycNonceUsed()` | `0x6ad0f3dd` |
| `KycBadSigner()` | `0x36c9d94d` |

---

## 8. Backfill / reconciliation notes

- Orders and offers are 1-indexed; `totalOrders()`/`totalOffers()` give the current high-water mark. Enumeration/pagination (e.g. "all open orders") is served off-chain by the indexer / Marketplace API — the contract only exposes point reads (`getOrder`/`getOffer`).
- Every state-changing path emits exactly one primary lifecycle event per order/offer per call, so a correct read model can be built purely from events without ever calling `getOrder`/`getOffer` — the view functions are for point-in-time reconciliation/debugging, not required for the primary indexing path.
- `OrderRefunded`, `OrderForceCancelled`, and both `sweep*` events are the only ways escrow leaves the contract without a matching `Fill`/`Settle` — make sure these are included in any balance-reconciliation job, or on-chain token balance will not match the sum of indexed fills/settlements.
