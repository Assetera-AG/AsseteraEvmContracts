// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ISettler
/// @notice The vocabulary the settlement path shares: the one settlement event and the errors
///         raised while money moves. Single-sourced here and inherited (not redeclared) by the
///         settler module, exactly as `IKycGate`/`IFeeGate` single-source the gates' events and
///         errors.
///
/// @dev    ⚠️ **`ISettler` is an INTERNAL seam, not a deployment boundary.** There is ONE
///         proxy, `AsseteraPrimarySales`, and the settler is an `abstract contract` module
///         inherited into it — the same shape as `OrderBook`/`OfferBook` inside
///         `AsseteraECS`. No settler is ever deployed, registered or called by address.
///
///         The seam itself is one `internal virtual` function, which Solidity cannot express in
///         an `interface`, so it is declared on the module instead:
///
///         ```solidity
///         // settle/VenueSettler.sol — the constrained executor
///         function _settleVenue(
///             bytes calldata venueCalldata, SettlementIntent calldata intent, uint16 takerFeeBps
///         ) internal virtual returns (SettlementResult memory);
///         ```
///
///         ⚠️ **There is no second seam, and there deliberately is not going to be a mint
///         one.** A `MintSettler` stub used to sit beside `VenueSettler` for a family in which
///         this router held the minting right; it was deleted on 2026-08-14. Our own issuance
///         is reached through the SAME `_settleVenue` path, with the venue being a per-token
///         sale contract that the issuer — not us — grants the minting right to. The reason is
///         in `AsseteraPrimarySales`'s header, and it is that the sale contract is the only
///         control that actually bounds a compromised settlement signer. AO-137 builds it,
///         outside this repo.
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
    ///         WHAT KIND of primary sale this was is deliberately not a field — third-party
    ///         asset or our own issuance through its sale contract. The activity-ledger leg is
    ///         identical either way, and the distinction is on-chain in the same transaction
    ///         anyway: `IIntentGate.IntentConsumed` is emitted from the same call with the gated
    ///         `action` ordinal and the SAME `nonce` this event carries, so the two join on
    ///         `(buyer, nonce)` with no ambiguity.
    ///
    /// @param buyer             The party debited and delivered to; equals `_msgSender()`.
    /// @param assetToken        The asset the buyer ends up holding.
    /// @param venue             The address that was called: a third party's contract, or the
    ///                          per-token sale contract that fronts our own issuance.
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

    // ⚠️ `SettlerNotImplemented` USED TO BE DECLARED HERE and was removed on 2026-08-14. It was
    //    the skeleton's default body for a seam nobody had filled; `VenueSettler` is
    //    implemented, so the only thing still raising it was the `MintSettler` stub, and that
    //    stub is gone (see the header). Nothing in `src/` can revert with it any more.
    //    Removing an error is an ABI change: a consumer decoding this router's reverts by
    //    selector should drop the mapping rather than keep waiting for it. Do not reintroduce
    //    it to mark a "not yet built" path — a path that does not exist has no entry point, and
    //    an entry point that reverts unconditionally is a deployed surface nobody gated.

    /// @dev The venue delivered less than the buyer signed for. A revert, never a silent bad fill.
    error InsufficientAssetDelivered(uint256 delivered, uint256 minAssetOut);

    /// @dev The router's own balance of one of the two settled tokens did not return to its
    ///      pre-call value. The invariant is zero STANDING balance, not that the venue consumed
    ///      the whole quote.
    ///
    ///      ⚠️ **Both legs, deliberately one error.** It was the settlement leg only until the
    ///      review of PR #58; the asset leg is now held to the same standard, because asset
    ///      token a venue misdirected to the router otherwise accumulated with no sweep and no
    ///      event. Asset that lands here during a settlement is FORWARDED to the buyer (the
    ///      increase over the pre-call baseline, never the whole balance) and this error is what
    ///      proves the forward actually moved it. One selector rather than two: the two are the
    ///      same invariant on two tokens, the failing token is in the trace, and splitting them
    ///      would be an ABI change buying a consumer nothing it can act on differently.
    error RouterBalanceChanged();

    /// @dev The settlement-token pull did not move exactly what it was asked to move: the
    ///      router's MEASURED balance delta over `safeTransferFrom` is not `venueQuoteIn +
    ///      buyerFee`.
    ///
    ///      ⚠️ **Both directions revert, and the short one is the case that matters.** A
    ///      fee-on-transfer or deflationary settlement currency debits the buyer in full and
    ///      credits the router less. Proceeding on the quoted number instead of the measured
    ///      one does not fail closed — it settles while misreporting, counting the token's own
    ///      burn as venue consumption and paying the collector below the attested fee. Both are
    ///      silent. The buyer signed `venueQuoteIn + buyerFee`; approving the venue any less
    ///      than the signed quote would be a smaller purchase than the buyer consented to, and
    ///      paying the collector any less than the attested fee is exactly the defect this
    ///      error replaces — so a short pull is refused rather than absorbed. A surplus is
    ///      refused for the mirror reason: the router would report a venue consumption that
    ///      never happened.
    ///
    ///      Its practical consequence, stated rather than hidden: a deflationary settlement
    ///      currency cannot be settled in AT ALL. That is a listing decision, and it is now
    ///      taken at the first line that moves money instead of discovered in the ledger.
    /// @param requested The full authorised debit, `venueQuoteIn + buyerFee`.
    /// @param received  What the router's own balance actually grew by.
    error SettlementPullMismatch(uint256 requested, uint256 received);

    /// @dev The venue call reverted or returned failure.
    error VenueCallFailed();
}
