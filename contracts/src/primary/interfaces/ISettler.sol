// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ISettler
/// @notice The vocabulary every settlement family shares: the one settlement event and the
///         errors raised while money moves. Single-sourced here and inherited (not
///         redeclared) by the family modules, exactly as `IKycGate`/`IFeeGate` single-source
///         the gates' events and errors.
///
/// @dev    ⚠️ **`ISettler` is an INTERNAL seam, not a deployment boundary.** There is ONE
///         proxy, `AsseteraPrimarySales`, and the families are `abstract contract` modules
///         inherited into it — the same shape as `OrderBook`/`OfferBook` inside
///         `AsseteraECS`. No settler is ever deployed, registered or called by address.
///
///         The seam itself is a pair of `internal virtual` functions, which Solidity cannot
///         express in an `interface`, so they are declared on the module stubs instead:
///
///         ```solidity
///         // settle/VenueSettler.sol — S2, filled by the constrained-executor packet
///         function _settleVenue(
///             bytes calldata venueCalldata, SettlementIntent calldata intent, uint16 takerFeeBps
///         ) internal virtual returns (SettlementResult memory);
///
///         // settle/MintSettler.sol — S1, filled by the mint packet
///         function _settleMint(SettlementIntent calldata intent)
///             internal virtual returns (SettlementResult memory);
///         ```
///
///         Why not separate settler contracts: funds or approvals would have to move to
///         them, which reintroduces exactly the standing-approval surface the constrained
///         executor exists to remove; events would come from several addresses, so the
///         indexer would need a registry to know which to trust; and the zero-balance and
///         zero-approval invariants could no longer be asserted in one place.
interface ISettler {
    /// @notice One primary settlement, reported entirely from MEASURED effects.
    ///
    ///         Every amount here is a balance delta this contract observed, not a number the
    ///         venue quoted or emitted. That is what lets the indexer build an activity-ledger
    ///         leg — and delivery reconciliation compare it against the off-chain order —
    ///         without a decoder per supplier.
    ///
    /// @dev    ⚠️ **FROZEN.** `AsseteraEvmIndexerService` decodes this signature and
    ///         `topic0` is derived from it, so any change to the field list, order or types
    ///         silently stops matching the deployed filter.
    ///
    ///         The settlement FAMILY (venue vs mint) is deliberately not a field: the
    ///         activity-ledger leg is identical either way, and the family is on-chain in the
    ///         same transaction anyway — `IIntentGate.IntentConsumed` is emitted from the same
    ///         call with the gated `action` and the SAME `nonce` this event carries, so the
    ///         two join on `(buyer, nonce)` with no ambiguity.
    ///
    /// @param buyer             The party debited and delivered to; equals `_msgSender()`.
    /// @param assetToken        The asset the buyer ends up holding.
    /// @param venue             The address that was called (the minted token, in the mint family).
    /// @param assetDelivered    Measured `assetToken` delta on the buyer; at least `minAssetOut`.
    /// @param settlementToken   The currency debited; equals the fee attestation's `feeToken`.
    /// @param venueIn           Settlement token the venue actually consumed, measured.
    /// @param refund            Approved-but-unconsumed settlement token returned to the buyer.
    /// @param fee               Settlement token paid to `feeCollector`.
    /// @param feeCollector      The allowlisted recipient of `fee`.
    /// @param supplierReference The venue's own quote/order id, carried from the signed intent.
    /// @param nonce             The intent nonce, so this settlement joins to the signer
    ///                          service's audit row for the intent that authorised it.
    event PrimarySettled(
        address indexed buyer,
        address indexed assetToken,
        address indexed venue,
        uint256 assetDelivered,
        address settlementToken,
        uint256 venueIn,
        uint256 refund,
        uint256 fee,
        address feeCollector,
        bytes32 supplierReference,
        uint256 nonce
    );

    /// @dev The skeleton's default body for both seams. `AsseteraPrimarySales` is deployable
    ///      and fully testable with no family implemented, which is what proves the seam is a
    ///      real boundary rather than a comment; a settlement attempted against an unfilled
    ///      family fails closed, here, after every signature has already been checked.
    error SettlerNotImplemented();

    /// @dev The venue delivered less than the buyer signed for. A revert, never a silent bad fill.
    error InsufficientAssetDelivered(uint256 delivered, uint256 minAssetOut);

    /// @dev The router's own settlement-token balance did not return to its pre-call value.
    ///      The invariant is zero STANDING balance, not that the venue consumed the whole quote.
    error RouterBalanceChanged();

    /// @dev The venue call reverted or returned failure.
    error VenueCallFailed();
}
