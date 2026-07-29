// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ExchangeTypes
/// @notice Shared enum/struct vocabulary for the exchange. Declared as an
///         `abstract contract` (not an interface) — qualified `Contract.Type`
///         access to a struct/enum only resolves reliably when the type is
///         declared directly in the contract being referenced or reached via
///         plain contract inheritance; nested types declared in an `interface`
///         do not reliably propagate through `Contract.Type` qualified access
///         once inherited. `interfaces/{IKycGate,IFeeGate,IAsseteraECS}.sol`
///         therefore reference these types via qualified import
///         (`ExchangeTypes.Action`, etc.) rather than by inheriting this contract.
abstract contract ExchangeTypes {
    enum OrderStatus {
        None, // 0
        Open, // 1
        Filled, // 2 — fully filled by taker
        Settled, // 3 — operator-settled (fully or final partial)
        Cancelled, // 4 — by maker (unattested self-cancel)
        Refunded, // 5 — by operator
        ForceCancelled, // 6 — by admin (cancelOrderForUser)
        Expired // 7 — swept after expireTs
    }

    enum OfferStatus {
        None, // 0
        Open, // 1 — initial proposal by maker
        Countered, // 2 — either party has replaced with new terms
        Accepted, // 3 — defined but never persisted (AC-246): acceptOffer settles
        // atomically and writes Settled directly, no intermediate step
        Settled, // 4 — non-proposer accepted; acceptOffer transferred both sides (AC-246)
        Cancelled, // 5 — cancelled by maker or taker
        ForceCancelled, // 6 — admin escape hatch (cancelOfferForUser)
        Expired // 7 — swept after expireTs via sweepExpiredOffers
    }

    /// @notice Trade actions that can be KYC-gated. Order-level cancel is intentionally
    ///         absent — `cancelOrder` never requires an attestation.
    enum Action {
        None, // 0
        Place, // 1
        Fill, // 2
        Settle, // 3 — order-level settle only
        MakeOffer, // 4
        ReplaceOffer, // 5
        AcceptOffer, // 6
        CancelOffer, // 7 — offer-level cancel
        SettleOffer // 8 — unused (AC-246): acceptOffer settles atomically under its own
        // AcceptOffer gate; kept for ordinal stability, never checked
    }

    struct Order {
        uint256 id;
        address maker;
        address sellToken;
        uint256 sellAmount; // original escrowed amount
        address buyToken;
        uint256 buyAmount; // original desired amount
        OrderStatus status;
        uint64 createdAt;
        uint256 remainingQuantity; // remaining sellAmount not yet filled/settled
        uint64 expireTs; // unix expiry; 0 = never expires
        // Fee snapshot — set at placement, immutable for the lifetime of the order.
        // BOTH fees are denominated in `feeToken` (the settlement currency) and are
        // EXCLUSIVE on the payer: the currency payer pays notional + their own fee,
        // the currency receiver receives notional − their own fee, and the asset leg
        // always moves gross. See AC-833.
        uint16 makerFeeBps; // maker's fee, charged on the notional, in feeToken
        uint16 takerFeeBps; // taker's fee, charged on the notional, in feeToken
        address feeCollector; // allowlisted recipient of collected fees
        // --- appended (AC-833); append-only, `Order` is stored in a mapping ---
        address feeToken; // the settlement currency; asserted ∈ {sellToken, buyToken}
        /// @dev Unconsumed maker-fee escrow, denominated in `feeToken`. Non-zero only
        ///      when the maker escrows the CURRENCY (sellToken == feeToken, a buy-side
        ///      order): placement escrows `sellAmount + fee(sellAmount, makerFeeBps)`.
        ///      It is the MAKER'S MONEY until a fill earns it, so every unwind path —
        ///      and the final fill — must return whatever remains.
        uint256 escrowedFee;
    }

    struct Offer {
        uint256 id;
        address maker; // initiating party
        address taker; // targeted counterparty
        address makerToken; // maker's sell token
        uint256 makerAmount;
        address takerToken; // taker's sell token
        uint256 takerAmount;
        OfferStatus status;
        uint64 createdAt;
        uint64 expireTs;
        address proposedBy; // who made the current round's proposal (their tokens are escrowed)
        // Both fees are denominated in `feeToken` and exclusive on the payer — see `Order`.
        uint16 makerFeeBps; // maker's fee, charged on the currency leg, in feeToken
        uint16 takerFeeBps; // taker's fee, charged on the currency leg, in feeToken
        address feeCollector; // allowlisted recipient; address(0) when no fee
        // --- appended (AC-833); append-only, `Offer` is stored in a mapping ---
        address feeToken; // the settlement currency; asserted ∈ {makerToken, takerToken}
        /// @dev Unconsumed fee escrow of the CURRENT proposer, in `feeToken`. Non-zero
        ///      only when the proposer's own leg is the currency. Offers are
        ///      all-or-nothing, so this is either fully consumed by a settlement or
        ///      fully refunded — including by `replaceOffer`, which unwinds the
        ///      previous proposer and re-escrows the caller at the new amounts.
        uint256 escrowedFee;
    }

    /// @notice A single-use KYC authorization. The first five fields are EIP-712
    ///         signed by a `KYC_OPERATOR_ROLE` holder; `signature` is that sig.
    ///         Carries no fee terms — fees are authorised separately via
    ///         `FeeAttestation`, signed by the (distinct) fee service.
    struct KycAttestation {
        address account; // the party being authorized; must equal the actor
        Action action; // which action this authorizes
        uint256 orderId; // bound order (0 for Place)
        uint256 nonce; // single-use, per-account
        uint256 deadline; // unix expiry (backend sets ~3 min)
        bytes32 paramsHash; // keccak256(abi.encode(sellToken,sellAmount,buyToken,buyAmount)) for Place; bytes32(0) otherwise
        bytes signature; // KYC operator's EIP-712 signature over the above
    }

    /// @notice A single-use fee authorization from the fee service, required
    ///         alongside a `KycAttestation` on fee-setting actions (`placeOrder`,
    ///         `placeOrderWithPermit`, `makeOffer`). Bound to the same actor and
    ///         action as the paired KYC attestation, and to the same `paramsHash`
    ///         (both are checked against the identical on-chain-computed hash),
    ///         so a fee attestation cannot be replayed against a different order/
    ///         offer or paired with a mismatched KYC attestation. Uses a separate
    ///         nonce namespace (`usedFeeNonce`) from KYC.
    struct FeeAttestation {
        address account; // the party being authorized; must equal the actor
        Action action; // which action this authorizes (Place or MakeOffer)
        uint256 nonce; // single-use, per-account, separate from KYC nonces
        uint256 deadline; // unix expiry (fee service sets ~3 min)
        bytes32 paramsHash; // must equal the paired KycAttestation's paramsHash
        uint16 makerFeeBps; // maker's fee on the notional, denominated in feeToken
        uint16 takerFeeBps; // taker's fee on the notional, denominated in feeToken
        address feeCollector; // must be in the on-chain allowlist when non-zero fees
        /// @dev The settlement currency both fees are denominated in (AC-833). The fee
        ///      service resolves it from the catalog (`token_pairs.settlement_currency_id`)
        ///      — the contract knows tokens, not markets, so it cannot infer which leg is
        ///      money. Asserted on-chain to be one of the two legs; required even when
        ///      both bps are zero, so that a legacy (pre-AC-833) order stays
        ///      distinguishable by `feeToken == address(0)`.
        address feeToken;
        bytes signature; // fee operator's EIP-712 signature over the above
    }
}
