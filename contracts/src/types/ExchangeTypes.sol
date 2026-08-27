// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GateTypes} from "./GateTypes.sol";

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
///
///         The two attestation structs moved to `GateTypes` (AO-514) so the gates
///         are usable without the order book. They are still inherited here, but
///         ⚠️ **inheritance only carries a nested type into TYPE position**:
///         `ExchangeTypes.KycAttestation memory att` still compiles, while the
///         struct LITERAL `ExchangeTypes.KycAttestation({…})` does not — an
///         expression-position `Contract.Type` must name the contract that
///         declares the type. Write `GateTypes.KycAttestation({…})` there. The
///         same asymmetry applies to enum members (`GateTypes.Foo.Bar`), and it
///         is the sharp edge behind this contract being a contract at all.
abstract contract ExchangeTypes is GateTypes {
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
        // --- appended (AO-746); append-only, `Order` is stored in a mapping ---
        /// @dev How much `buyToken` this order has actually received, across fills AND
        ///      linked-offer settlements. It cannot be derived from `remainingQuantity`:
        ///      that counts the token the order SELLS, and a fill holds the listed price
        ///      while a negotiated offer does not, so the two stop tracking each other the
        ///      moment an offer settles at anything other than the listed price. Without
        ///      this, a buy-side order whose whole intent was met by a cheaper offer keeps
        ///      its unspent change listed as a live bid (AO-746).
        uint256 boughtQuantity;
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
        // --- appended (AO-746); append-only, `Offer` is stored in a mapping ---
        /// @dev The order this offer was raised against, or 0 for a standalone offer.
        ///      An offer and an order are two entries in two independent id spaces, so
        ///      without this link an accepted offer left its originating order Open and
        ///      still fillable, and the order maker had to fund BOTH sides of the same
        ///      trade (AO-746). When it is set and the order's own maker is the party
        ///      that must escrow a leg, that leg is drawn from the order's escrow
        ///      instead of from their wallet — one economic commitment, not two.
        ///
        ///      ⚠️ Not covered by the KYC/fee attestation's `paramsHash`: the encoding
        ///      is a frozen cross-repo vector (see `test/ParamsHashVectors.t.sol`). The
        ///      draw is guarded on chain instead — only the order's OWN maker can draw,
        ///      and only the token the order already holds.
        uint256 orderId;
    }
}
