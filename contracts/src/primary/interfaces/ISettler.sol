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
///         A seam itself is an `internal virtual` function, which Solidity cannot express in an
///         `interface`, so each is declared on its own module. See below for both.
///
///         ⚠️ **There is a SECOND seam since AO-847, and this paragraph used to say there would
///         never be one. That reversal is recorded here rather than tidied away.** What it said
///         was that a `MintSettler` stub had been deleted on 2026-08-14 and that our own issuance
///         reaches the SAME `_settleVenue` path, with the venue being a per-token sale contract
///         that the issuer — not us — grants the minting right to. All of that still holds, and
///         the argument behind it is unchanged: the sale contract is the only control that
///         actually bounds a compromised settlement signer (AO-137, outside this repo).
///
///         What was wrong was the generalisation. "One seam" was a claim about MINTING, and it
///         got written down as a claim about seams. Selling an asset BACK to a venue is a
///         different money path in every step that matters — the router pulls the ASSET rather
///         than the currency, approves in the asset, measures proceeds rather than delivery, and
///         carves the fee OUT of what it received rather than charging it on top — so folding it
///         into `_settleVenue` behind a direction flag would have branched every line of an
///         audited function. There are now two:
///
///         ```solidity
///         // settle/VenueSettler.sol — the BUY leg
///         function _settleVenue(
///             bytes calldata venueCalldata, SettlementIntent calldata intent, uint16 takerFeeBps
///         ) internal virtual returns (SettlementResult memory);
///
///         // settle/VenueRedeemer.sol — the SELL BACK leg
///         function _redeemVenue(
///             bytes calldata venueCalldata, RedemptionIntent calldata intent, uint16 takerFeeBps
///         ) internal virtual returns (RedemptionResult memory);
///         ```
///
///         Both are `abstract contract` modules inherited into the SAME proxy, and the second one
///         inherits the first, so the accounting-mode dispatch, the fee-derivation helper and
///         every storage region are shared rather than copied. Nothing about the deployment shape
///         changed: still one proxy, still no settler deployed or called by address.
///
///         ⚠️ **ADR-0047 (the issuance-venue decision) states the one-seam position and needs an
///         amendment.** Filed separately; this file is the code-side record.
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

    /// @notice One sell back to a venue, reported entirely from MEASURED effects (AO-847).
    ///
    ///         The mirror of `PrimarySettled`, with the same discipline: every amount is a balance
    ///         delta this contract observed, never a number the venue quoted or emitted.
    ///
    /// @dev    ⚠️ **`PrimarySettled` is untouched.** Its `topic0` and its field list are exactly
    ///         what they were; the sell-back leg gets its OWN topic rather than a direction field
    ///         on the buy's event, so a deployed indexer filter keeps matching what it always
    ///         matched and picks the new leg up by adding a filter rather than by changing one.
    ///
    ///         ⚠️ This event is FROZEN from here on for the same reason `PrimarySettled` is.
    ///
    ///         The `IntentConsumed` join works identically: it is emitted from the same call with
    ///         `action = Action.RedeemVenue` and the SAME `nonce` this event carries, so the two
    ///         join on `(seller, nonce)`.
    ///
    /// @param seller           The party whose asset was taken and who received the net proceeds;
    ///                         equals `_msgSender()`.
    /// @param assetToken       The asset the seller gave up.
    /// @param venue            The address that was called.
    /// @param assetIn          Measured `assetToken` the venue actually consumed, in the token's
    ///                         VISIBLE units even under share accounting.
    /// @param settlementToken  The currency received; equals the fee attestation's `feeToken`.
    /// @param venueOut         Measured settlement token the venue paid the router, GROSS.
    /// @param assetRefund      Asset approved but not consumed, returned to the seller in the same
    ///                         transaction, in visible units.
    /// @param fee              Settlement token paid to `feeCollector`, CARVED OUT of `venueOut`.
    ///                         The seller received `venueOut - fee`.
    /// @param feeCollector     The allowlisted recipient of `fee`.
    /// @param supplierReference The venue's own quote/order id, carried from the signed intent.
    /// @param nonce            The redemption intent's nonce.
    event PrimaryRedeemed(
        address indexed seller,
        address indexed assetToken,
        address indexed venue,
        uint256 assetIn,
        address settlementToken,
        uint256 venueOut,
        uint256 assetRefund,
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

    /// @dev The intent named an `AssetAccountingMode` ordinal this router has no implementation
    ///      for.
    ///
    ///      Checked in step 0 of `VenueSettler._settleVenue`, before anything moves, and named
    ///      rather than left to the `Panic(0x21)` an out-of-range enum decode would produce.
    ///      That is why `SettlementIntent.accountingMode` is a `uint8` and not the enum itself
    ///      — see `PrimaryTypes.AssetAccountingMode`.
    ///
    ///      ⚠️ Appending an ordinal to that enum WITHOUT giving it a branch in all three of the
    ///      settler's accounting helpers lands here rather than settling wrongly. Fail-closed is
    ///      the intended behaviour of their default arms.
    error UnsupportedAccountingMode(uint8 mode);

    /// @dev `transferShares` returned false, under `AssetAccountingMode.RebasingShares`.
    ///
    ///      🔴 There is no SafeERC20 equivalent for `transferShares`, so nothing in the
    ///      OpenZeppelin stack normalises a token that returns nothing, and nothing would
    ///      otherwise stop a `false` return from reading as a successful delivery. The return is
    ///      checked explicitly at the one call site. A token that reverts instead never reaches
    ///      this error, which is equally fine: both refuse the settlement.
    error ShareTransferFailed();

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

    // ── the sell-back leg (AO-847) ────────────────────────────────────────────────────────────
    //
    // ⚠️ ADDED, never replacing. `VenueSettler`'s errors above are what the buy leg still reverts
    //    with, and the sell-back leg reuses every one of them that states the same thing —
    //    `UnsupportedAccountingMode`, `ShareTransferFailed`, `RouterBalanceChanged`,
    //    `VenueCallFailed`. What follows is only what the buy has no counterpart for.

    /// @dev The asset pull did not move exactly what it was asked to move: the router's MEASURED
    ///      delta over `transferFrom` / `transferSharesFrom` is not the amount requested.
    ///
    ///      ⚠️ The mirror of `SettlementPullMismatch`, and it fails in both directions for the
    ///      same reasons. A fee-on-transfer asset debits the seller in full and credits the router
    ///      less, so proceeding on the quoted number would approve the venue more asset than the
    ///      router holds and break the residue assertion at the end anyway — named here instead,
    ///      at the first line that moved anything. A surplus is refused because the router would
    ///      then hand the venue asset this settlement never pulled.
    ///
    ///      It also fires when a `RebasingShares` pull converts `maxAssetIn` to ZERO shares, which
    ///      is what a ceiling below one share looks like.
    /// @param requested The units the pull asked for: nominal under `Erc20Balance`, SHARES under
    ///                  `RebasingShares`.
    /// @param received  What the router's own holding actually grew by, in the same unit.
    error AssetPullMismatch(uint256 requested, uint256 received);

    /// @dev The venue paid less than the seller signed for, net of our fee. A revert, never a
    ///      silent bad fill — the mirror of `InsufficientAssetDelivered`.
    /// @param net              The measured proceeds minus `sellerFee`, clamped at zero so a venue
    ///                         that paid nothing reports through this error rather than panicking.
    /// @param minSettlementOut The floor the seller signed.
    error InsufficientSettlementOut(uint256 net, uint256 minSettlementOut);

    /// @dev The router's asset approval to the venue is still non-zero after the settler revoked
    ///      it. Nothing in `src/` can leave one, so this is a statement about the TOKEN: an asset
    ///      whose `approve` is a no-op, or which re-grants inside a callback, would otherwise
    ///      leave the venue a standing claim on a router that is supposed to hold nothing.
    error AssetApprovalNotCleared();
}
