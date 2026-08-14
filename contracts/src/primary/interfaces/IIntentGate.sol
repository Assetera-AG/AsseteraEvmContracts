// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IIntentGate
/// @notice The settlement-intent gate's event, errors and getters, single-sourced here and
///         inherited by `IntentGate` (not redeclared), as `IKycGate`/`IFeeGate` are.
///
///         The intent is the THIRD attestation on a primary settlement, alongside the KYC
///         attestation from the compliance backend and the fee attestation from the fee
///         service. It has its own role and its own key because it is the only one of the
///         three whose signer can cause a transfer.
interface IIntentGate {
    /// @notice A settlement intent was verified and its single-use nonce burned.
    /// @param buyer  The intent's buyer, which is also the actor.
    /// @param action The primary-sale action ordinal the intent was consumed under.
    /// @param nonce  The intent's single-use nonce, in this router's own namespace.
    event IntentConsumed(address indexed buyer, uint8 indexed action, uint256 nonce);

    /// @dev `intent.buyer` is not the ERC-2771 `_msgSender()`. Nobody may settle for somebody else.
    error IntentBuyerMismatch();
    /// @dev The intent's deadline has passed.
    error IntentExpired();
    /// @dev The intent's deadline is further out than `MAX_INTENT_TTL`, even though a signer produced it.
    error IntentTtlTooLong();
    /// @dev The intent's nonce is already spent. Single-use, per buyer.
    error IntentNonceUsed();
    /// @dev The intent signature does not recover to a `SETTLEMENT_OPERATOR_ROLE` holder.
    error IntentBadSigner();
    /// @dev The buyer's own signature over the SAME intent digest is missing, malformed, or not
    ///      valid for `intent.buyer` — checked with ERC-1271 support, so a contract wallet is
    ///      accepted on the same terms as an EOA.
    ///
    ///      ⚠️ **Not redundant with `IntentBuyerMismatch`, and the difference is the whole
    ///      point.** That error proves the buyer is the ACTOR — the account the transaction
    ///      resolves to through ERC-2771. This one proves the buyer agreed to the TERMS: the
    ///      asset, the floor, the cap, the fee, the venue, the deadline. Without it the
    ///      settlement operator alone chooses every field of the intent, `minAssetOut` included,
    ///      and the executor's central guarantee ("the buyer received at least `minAssetOut`")
    ///      means nothing the moment that key is compromised, because the attacker sets the
    ///      floor to one wei and the buyer's own transaction pays for it.
    ///
    ///      A wallet cannot restore that protection on its own here: ERC-2771 means the buyer
    ///      signs a `ForwardRequest` whose `data` is opaque bytes no wallet can render as
    ///      balance changes. An EIP-712 payload with named fields is what gives the buyer back
    ///      something to read before signing.
    error BuyerConsentBadSignature();

    /// @dev `keccak256(venueCalldata)` does not equal the signed `calldataHash`.
    error CalldataHashMismatch();
    /// @dev `bytes4(venueCalldata)` does not equal the signed `selector`.
    error SelectorMismatch();

    // ⚠️ `SettlementTokenMismatch` USED TO BE DECLARED HERE and was removed (PR #58 review).
    //    A fee attested in a token other than `intent.settlementToken` now reverts with the
    //    shared `IFeeGate.FeeTokenNotALeg(feeToken)`, because `IntentGate._bindAttestations`
    //    calls `FeeGate._validateFees` with the settlement token in both leg positions rather
    //    than restating the rule. Removing the error is an ABI change: a consumer decoding this
    //    router's reverts by selector must map the new one. Do not reintroduce it — the whole
    //    point is that there is one fee-policy implementation, not two.
    /// @dev The intent and the fee attestation name different collectors.
    error FeeCollectorMismatch();
    /// @dev A non-zero `makerFeeBps` was attested on a family where we do not control the
    ///      proceeds side. Reverts rather than silently doing nothing.
    error MakerFeeNotSupported();
    /// @dev `maxSettlementIn < venueQuoteIn + buyerFee`: the buyer's own cap cannot cover the
    ///      debit the same signature authorises.
    error MaxSettlementTooLow();
    /// @dev The asset leg and the settlement leg are the same token.
    error SameToken();
    /// @dev `minAssetOut` is zero, which would make the post-call delivery assertion vacuous:
    ///      the transaction would be a pure debit with nothing owed to the buyer.
    error ZeroAmount();

    /// @dev `SETTLEMENT_OPERATOR_ROLE` and `usedIntentNonce` are deliberately NOT declared
    ///      here even though they are part of the same public surface. They are declared by
    ///      `PrimaryStorage`, which is a SIBLING base of this interface rather than the
    ///      contract that inherits it, and Solidity cannot reconcile a public constant in one
    ///      base with an external function of the same name in another — the two would have to
    ///      be overridden, and a public constant cannot be. `MAX_INTENT_TTL` is fine because
    ///      `IntentGate` itself declares it, which is the same arrangement `IKycGate` has with
    ///      `KycGate`.
    function MAX_INTENT_TTL() external view returns (uint256);
}
