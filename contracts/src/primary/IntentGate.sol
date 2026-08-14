// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {PrimaryStorage} from "./storage/PrimaryStorage.sol";
import {IIntentGate} from "./interfaces/IIntentGate.sol";

/// @title IntentGate
/// @notice The third gate on a primary settlement: a fresh, single-use EIP-712
///         `SettlementIntent` signed by a `SETTLEMENT_OPERATOR_ROLE` holder AND, over the very
///         same digest, by the buyer. Verified alongside the KYC attestation (compliance
///         backend) and the fee attestation (fee service). Same shape as `KycGate`/`FeeGate` —
///         verify without writing, then consume — so that **every signature is checked before
///         any nonce is burned** and an invalid one cannot spend the others.
///
///         The buyer's signature is what makes the terms the buyer's own. See `_verifyIntent`
///         for why it is the same payload rather than a separate consent struct, why it is
///         checked with ERC-1271 support, and why `INTENT_TYPEHASH` did not move when it landed.
///
///         It sits below the settler families rather than inside the assembled contract on
///         purpose: both families need exactly this verification, and a family module cannot
///         call a function declared in the contract that inherits it.
///
/// @dev    ⚠️ **Nothing here checks `venue`, `selector`, `assetToken` or `settlementToken`
///         against any on-chain list, and that is a decision rather than an omission**
///         (2026-08-13, after three rounds of narrowing). An allowlist did not bound a
///         compromised signer's loss to the buyer — the attacker names the *genuine* venue
///         and selector with `minAssetOut = 0` — and it could not have protected the minting
///         right, because a generic mint path would have had to allowlist `(ourToken, mint)`
///         for the feature to work at all. What absorbs the loss instead: the value caps
///         (`ISettlementLimits`), never asking the buyer for an unlimited allowance, and
///         signer hardening with a durable audit log of every intent signed.
///
///         `venue` and `selector` stay in the signed intent regardless. They make the intent
///         legible ("this authorises `executeSwap` on address X") for the signer, the audit
///         log and a human reviewer, and `selector` is still asserted against the calldata,
///         which catches a malformed or mismatched call.
abstract contract IntentGate is PrimaryStorage, IIntentGate {
    /// @notice Hard cap on intent freshness, mirroring `MAX_KYC_TTL` / `MAX_FEE_TTL`. Rejects
    ///         an over-long deadline even if a signer produced one, so a leaked intent has a
    ///         bounded life regardless of what the signer service was configured to emit.
    uint256 public constant MAX_INTENT_TTL = 15 minutes;

    /// @dev The EIP-712 struct hash of an intent, which is ALSO the `paramsHash` both
    ///      attestations must carry (§4.4). One hash, four signatures: the settlement operator
    ///      and the buyer each sign it as a digest, and the compliance and fee signers each pin
    ///      their attestation to it, so an attestation minted for one settlement cannot be
    ///      replayed onto another with a different asset, venue or amount.
    ///
    ///      ⚠️ This is `keccak256(abi.encode(INTENT_TYPEHASH, intent))` — identical to the
    ///      EIP-712 struct hash ONLY because every member of `SettlementIntent` is a static
    ///      type. See the warning on the struct before adding a member.
    function _intentStructHash(SettlementIntent calldata intent) internal pure returns (bytes32) {
        return keccak256(abi.encode(INTENT_TYPEHASH, intent));
    }

    /// @dev Verify an intent without consuming its nonce. Pure validation, no state writes.
    ///
    ///      **TWO signatures over ONE digest, and they are not interchangeable.** The settlement
    ///      operator's is accepted only if it recovers to a `SETTLEMENT_OPERATOR_ROLE` holder;
    ///      the buyer's only if it validates for `intent.buyer`. Presenting either in the
    ///      other's slot fails, and the errors say which.
    ///
    ///      ⚠️ **The buyer signs the same `SettlementIntent` digest rather than a smaller
    ///      "consent" struct of its own, and that is a decision.** A parallel struct would need
    ///      a field-by-field cross-check against this one, and the day somebody appends a member
    ///      to `SettlementIntent` and forgets the mirror, the buyer's protection silently
    ///      narrows while every test still passes. One payload cannot drift from itself. It also
    ///      means `AsseteraMarketplaceAPI` hands the buyer's wallet exactly the typed data it
    ///      hands `AsseteraSignerService` — one EIP-712 shape, two signers.
    ///
    ///      ⚠️ **`INTENT_TYPEHASH` did NOT change when this was added**, and neither did any
    ///      signed payload: the struct is untouched, so every digest, every `paramsHash` binding
    ///      and every attestation in flight is unaffected. What changed is the `settlePrimary`
    ///      SELECTOR, which gained one parameter. Read the frozen-payload warnings in
    ///      `PrimaryTypes` with that in mind before concluding the typehash moved.
    ///
    ///      ⚠️ `SignatureChecker.isValidSignatureNow`, deliberately, **not** `ECDSA.recover`.
    ///      This is the one signature on the path produced by a CUSTOMER rather than by one of
    ///      our own services, and an EOA-only check would exclude Safe and embedded
    ///      smart-account wallets — which is exactly what a regulated brokerage's larger clients
    ///      use. ERC-1271 signatures are revocable, so validity is asserted at settlement time
    ///      and nowhere else; the intent's own TTL keeps that window short.
    ///
    /// @param intent         The settlement intent.
    /// @param signature      The settlement operator's EIP-712 signature over it.
    /// @param buyerSignature The BUYER's EIP-712 signature over the same digest, EOA or
    ///                       ERC-1271. It is what makes `minAssetOut` a floor the buyer chose
    ///                       rather than a number the settlement operator chose for them.
    /// @return structHash The intent's EIP-712 struct hash, reused as the `paramsHash` binding.
    function _verifyIntent(SettlementIntent calldata intent, bytes calldata signature, bytes calldata buyerSignature)
        internal
        view
        returns (bytes32 structHash)
    {
        // The buyer is the actor, resolved through ERC-2771 so a gasless primary sale works
        // the same way a gasless order does. Nobody settles on somebody else's behalf.
        if (intent.buyer != _msgSender()) revert IntentBuyerMismatch();

        if (intent.assetToken == address(0) || intent.settlementToken == address(0) || intent.venue == address(0)) {
            revert ZeroAddress();
        }
        if (intent.assetToken == intent.settlementToken) revert SameToken();
        // A zero delivery floor makes the post-call assertion vacuous — the transaction would
        // be a pure debit with nothing owed to the buyer. No honest settlement produces one.
        if (intent.minAssetOut == 0) revert ZeroAmount();
        // The buyer's own cap must cover the debit the same signature authorises, or the
        // number shown in the UI as "you pay at most" is not the number being authorised.
        if (intent.maxSettlementIn < intent.venueQuoteIn + intent.buyerFee) revert MaxSettlementTooLow();

        if (block.timestamp > intent.deadline) revert IntentExpired();
        if (intent.deadline > block.timestamp + MAX_INTENT_TTL) revert IntentTtlTooLong();
        if (usedIntentNonce(intent.buyer, intent.nonce)) revert IntentNonceUsed();

        structHash = _intentStructHash(intent);
        bytes32 digest = _hashTypedDataV4(structHash);

        address signer = ECDSA.recover(digest, signature);
        if (!hasRole(SETTLEMENT_OPERATOR_ROLE, signer)) revert IntentBadSigner();

        // The buyer's own consent to these exact terms, checked HERE rather than in the entry
        // point because both settler families need it and the mint family has no entry point
        // yet. A guarantee the caller has to remember to make is not a guarantee.
        if (!SignatureChecker.isValidSignatureNow(intent.buyer, digest, buyerSignature)) {
            revert BuyerConsentBadSignature();
        }
    }

    /// @dev Bind the opaque venue calldata to the signed intent. The calldata itself is never
    ///      what the policy is expressed in — the signer signs typed fields and the bytes ride
    ///      along bound by hash (ADR-0020 D5 rejected a blind signing oracle by name).
    /// @param venueCalldata The bytes that will be handed to the venue.
    /// @param intent        The signed intent carrying `calldataHash` and `selector`.
    function _bindCalldata(bytes calldata venueCalldata, SettlementIntent calldata intent) internal pure {
        if (keccak256(venueCalldata) != intent.calldataHash) revert CalldataHashMismatch();
        // casting to 'bytes4' is safe because the exact bytes are already pinned by the
        // `calldataHash` check on the line above. Calldata shorter than four bytes is
        // zero-padded rather than truncated, and the signer would have had to sign both that
        // padded selector and the hash of those same short bytes for it to be accepted.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (bytes4(venueCalldata) != intent.selector) revert SelectorMismatch();
    }

    /// @dev Pin both attestations to this exact settlement, and to this settlement's currency.
    ///
    ///      Both `paramsHash` checks are UNCONDITIONAL here, unlike `FeeGate._bindParamsHash`
    ///      which makes the KYC half conditional on `complianceRequired[action]`. This router
    ///      gates every action it declares in its initializer and asserts it in a test, so the
    ///      conditional buys nothing and the unconditional form cannot be weakened by an admin
    ///      toggle.
    ///
    ///      The fee TERMS go through the shared `FeeGate._validateFees`, with the settlement
    ///      token passed as BOTH legs. An earlier revision hand-rolled the same checks here and
    ///      justified it by calling the shared one "too weak"; that was simply wrong. Its leg
    ///      test is `feeToken != legA && feeToken != legB`, so one token in both positions
    ///      collapses it to exactly the strict "the fee must be denominated in the settlement
    ///      currency" rule this path wants, and the bounds and collector-allowlist checks were
    ///      being restated verbatim.
    ///
    ///      ⚠️ Calling it rather than restating it is STRUCTURAL, not tidiness: `_validateFees`
    ///      is the one place the estate tightens fee policy, and a copy here means the next
    ///      tightening silently applies to the exchange only while primary sales — the path
    ///      where a single signer can cause a transfer — keeps the older, weaker rule.
    ///
    ///      ⚠️ The revert for a fee attested in the ASSET token is therefore
    ///      `FeeTokenNotALeg(feeToken)`. The `SettlementTokenMismatch` error this used to raise
    ///      is gone from the ABI.
    ///
    ///      What stays here is only what the shared function cannot know: the two `paramsHash`
    ///      bindings, and that the fee attestation and the intent must name the SAME collector.
    ///      `_validateFees` proves the collector is allowlisted; it has no intent to compare it
    ///      against, so without the cross-check the fee could be routed to any other listed
    ///      collector than the one the buyer signed for.
    ///
    /// @param intent     The signed intent.
    /// @param paramsHash The intent's struct hash, which both attestations must carry.
    /// @param kycAtt     The compliance attestation.
    /// @param feeAtt     The fee attestation.
    function _bindAttestations(
        SettlementIntent calldata intent,
        bytes32 paramsHash,
        KycAttestation calldata kycAtt,
        FeeAttestation calldata feeAtt
    ) internal view {
        if (kycAtt.paramsHash != paramsHash) revert ParamsHashMismatch();
        if (feeAtt.paramsHash != paramsHash) revert ParamsHashMismatch();

        // The settlement token in BOTH leg positions. A primary sale has one currency leg, so
        // the shared leg test becomes the strict denomination check: a fee attested in the
        // asset token would come out of what the buyer receives, and is refused as
        // `FeeTokenNotALeg`.
        _validateFees(feeAtt, intent.settlementToken, intent.settlementToken);

        // Not in `_validateFees`, and not derivable there: it has no intent to compare against.
        if (feeAtt.feeCollector != intent.feeCollector) revert FeeCollectorMismatch();
    }

    /// @dev Burn the intent's single-use nonce. Called only once every signature on the path
    ///      has been verified.
    /// @param action The primary-sale action ordinal this settlement runs under.
    /// @param intent The signed intent.
    function _consumeIntent(uint8 action, SettlementIntent calldata intent) internal {
        _primary().usedIntentNonce[intent.buyer][intent.nonce] = true;
        emit IntentConsumed(intent.buyer, action, intent.nonce);
    }
}
