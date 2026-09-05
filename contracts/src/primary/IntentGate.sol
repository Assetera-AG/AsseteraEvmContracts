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
///         It sits below the settler module rather than inside the assembled contract on
///         purpose: a settler module cannot call a function declared in the contract that
///         inherits it, and this verification has to be reachable from anything that settles.
///
/// @dev    ⚠️ **Nothing here checks `venue`, `selector`, `assetToken` or `settlementToken`
///         against any on-chain list, and that is a decision rather than an omission**
///         (2026-08-13, after three rounds of narrowing). An allowlist did not bound a
///         compromised signer's loss to the buyer — the attacker names the *genuine* venue
///         and selector with `minAssetOut = 0` — and it could not have protected the minting
///         right either, back when a mint path inside this router was still planned: such a
///         path would have had to allowlist `(ourToken, mint)` for the feature to work at all.
///         That half is now moot, because there is no mint path — our own issuance goes through
///         a per-token sale contract that mints only against payment received, and it is that
///         contract, not any list here, that bounds a compromised signer (see
///         `AsseteraPrimarySales`). What absorbs the rest of the loss: the value caps
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

    /// @dev The same shortcut for `RedemptionIntent`, valid for the same reason: all fifteen of
    ///      its members are static types, so `abi.encode` of the struct is exactly its fifteen
    ///      head words. `PrimaryIntentVectorsTest` builds the canonical EIP-712 encoding field by
    ///      field and is what notices if a dynamic member is ever introduced.
    function _redemptionStructHash(RedemptionIntent calldata intent) internal pure returns (bytes32) {
        return keccak256(abi.encode(REDEMPTION_TYPEHASH, intent));
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
        // 🔴 And the mirror image: a zero quote pays the venue nothing while the settlement
        // still asserts a delivery floor — "pay nothing, receive something". Nothing else on
        // the path catches it: the per-transaction cap only rejects a debit ABOVE the cap, so a
        // zero debit passes every value check there is, and `_settleVenue` would approve zero,
        // call the venue and judge the result purely on the asset delta.
        //
        // ⚠️ A genuinely FREE distribution — a promotional allocation, say — is exactly this
        // shape, and this check forbids it. That is the deliberate safe default for a sale
        // router rather than an oversight: the intent a giveaway signs and the intent a
        // compromised settlement signer signs are indistinguishable on-chain, so enabling one
        // should be a deliberate change with its own gate rather than something that already
        // silently works.
        //
        // Its own error rather than the `ZeroAmount` above, so the signer service and the
        // marketplace API can tell a missing floor from a missing price.
        if (intent.venueQuoteIn == 0) revert ZeroVenueQuote();
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
        // point: every settlement needs it, and a guarantee each caller has to remember to make
        // is not a guarantee. Verifying the intent and taking the buyer's consent are one call,
        // so no future entry point can acquire the first without the second.
        if (!SignatureChecker.isValidSignatureNow(intent.buyer, digest, buyerSignature)) {
            revert BuyerConsentBadSignature();
        }
    }

    /// @dev Bind the opaque venue calldata to the signed intent. The calldata itself is never
    ///      what the policy is expressed in — the signer signs typed fields and the bytes ride
    ///      along bound by hash (ADR-0020 D5 rejected a blind signing oracle by name).
    ///      ⚠️ Takes the two SIGNED FIELDS rather than an intent, so that one implementation
    ///      serves both the buy and the sell-back leg. The rule is identical on the two, and a
    ///      second copy of it is how the two silently drift apart (AO-847).
    /// @param venueCalldata The bytes that will be handed to the venue.
    /// @param calldataHash  The signed `keccak256` of those bytes.
    /// @param selector      The signed first four bytes.
    function _bindCalldata(bytes calldata venueCalldata, bytes32 calldataHash, bytes4 selector) internal pure {
        if (keccak256(venueCalldata) != calldataHash) revert CalldataHashMismatch();
        // casting to 'bytes4' is safe because the exact bytes are already pinned by the
        // `calldataHash` check on the line above. Calldata shorter than four bytes is
        // zero-padded rather than truncated, and the signer would have had to sign both that
        // padded selector and the hash of those same short bytes for it to be accepted.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (bytes4(venueCalldata) != selector) revert SelectorMismatch();
    }

    /// @dev Pin both attestations to this exact settlement, and to this settlement's currency.
    ///
    ///      Both `paramsHash` checks are UNCONDITIONAL here, unlike `FeeGate._bindParamsHash`
    ///      which makes the KYC half conditional on `complianceRequired(action)`. This router
    ///      gates every action by default — `AsseteraPrimarySales` overrides that getter so an
    ///      unset ordinal reads "required" — so the conditional buys nothing, and the
    ///      unconditional form here cannot be weakened by an admin toggle even so.
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
    /// @param settlementToken The currency leg, used in BOTH fee-leg positions.
    /// @param feeCollector    The collector the intent names.
    /// @param paramsHash The intent's struct hash, which both attestations must carry.
    /// @param kycAtt     The compliance attestation.
    /// @param feeAtt     The fee attestation.
    /// ⚠️ Takes the two signed fields it reads rather than an intent, so that the buy and the
    ///    sell-back leg share ONE implementation of the binding rule (AO-847). Nothing else about
    ///    it changed; the buy suites are unchanged and are the proof of that.
    function _bindAttestations(
        address settlementToken,
        address feeCollector,
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
        _validateFees(feeAtt, settlementToken, settlementToken);

        // Not in `_validateFees`, and not derivable there: it has no intent to compare against.
        if (feeAtt.feeCollector != feeCollector) revert FeeCollectorMismatch();
    }

    /// @dev Burn the intent's single-use nonce. Called only once every signature on the path
    ///      has been verified.
    ///      ⚠️ Takes the party and the nonce rather than an intent. The nonce namespace is keyed
    ///      on the party address and on nothing else, so the buy and the sell-back leg share it: a
    ///      nonce is spent by whichever leg presents it first, and the sell-back leg cost no new
    ///      storage (AO-847). `IntentConsumed` carries the action ordinal, which is what tells the
    ///      indexer which leg burned it.
    /// @param action The primary-sale action ordinal this settlement runs under.
    /// @param party  The actor whose nonce namespace this is: buyer or seller.
    /// @param nonce  The single-use nonce to burn.
    function _consumeIntent(uint8 action, address party, uint256 nonce) internal {
        _primary().usedIntentNonce[party][nonce] = true;
        emit IntentConsumed(party, action, nonce);
    }

    // --------------------------------------------------------------------- //
    //                    The sell-back leg (AO-847)                          //
    // --------------------------------------------------------------------- //

    /// @notice Verify a `RedemptionIntent` and the seller's consent to it, and hand back the
    ///         struct hash that is also the `paramsHash` both attestations must be bound to.
    ///
    ///         The mirror of `_verifyIntent`, check for check. Everything structural is the same
    ///         — one digest, two signers, the same TTL cap, the same nonce namespace, ERC-1271
    ///         for the party's consent — and only the AMOUNT relations differ, because the fee is
    ///         carved out of the proceeds here rather than charged on top of a quote.
    ///
    /// @dev    ⚠️ **Deliberately a separate function rather than a mode flag inside
    ///         `_verifyIntent`.** The two take different payloads with different typehashes, so a
    ///         merged implementation would have to branch on every amount line anyway, and the
    ///         audited buy path would then change shape for a leg it does not run. What IS shared
    ///         is everything below the amounts, and it is shared by calling the same helpers
    ///         rather than by copying them.
    ///
    ///         The amount relations, and why each one:
    ///           * `maxAssetIn != 0` — a zero pull makes the whole settlement vacuous;
    ///           * `venueQuoteOut != 0` — the "give something, receive nothing" shape, which no
    ///             value check downstream catches: the per-transaction cap only rejects a value
    ///             ABOVE the cap;
    ///           * `minSettlementOut != 0` — the mirror of the buy's `minAssetOut != 0`. A zero
    ///             floor makes the post-call proceeds assertion vacuous, so a hostile venue could
    ///             take the asset and pay nothing and the settlement would still succeed. The
    ///             seller signs this field, but so does the buyer sign `minAssetOut`, and the buy
    ///             refuses a zero one anyway;
    ///           * `sellerFee <= venueQuoteOut` — there is nothing to carve the fee out of
    ///             otherwise;
    ///           * `minSettlementOut <= venueQuoteOut - sellerFee` — the seller's own floor must
    ///             be reachable from the quote the same signature authorises.
    ///
    /// @param intent          The redemption intent.
    /// @param signature       The settlement operator's EIP-712 signature over it.
    /// @param sellerSignature The SELLER's signature over the SAME digest, EOA or ERC-1271.
    /// @return structHash     The EIP-712 struct hash, which is also the `paramsHash` binding.
    function _verifyRedemption(
        RedemptionIntent calldata intent,
        bytes calldata signature,
        bytes calldata sellerSignature
    ) internal view returns (bytes32 structHash) {
        // The seller is the actor, resolved through ERC-2771 exactly as the buyer is. Nobody
        // redeems on somebody else's behalf.
        if (intent.seller != _msgSender()) revert IntentSellerMismatch();

        if (intent.assetToken == address(0) || intent.settlementToken == address(0) || intent.venue == address(0)) {
            revert ZeroAddress();
        }
        if (intent.assetToken == intent.settlementToken) revert SameToken();
        if (intent.maxAssetIn == 0) revert ZeroAmount();
        if (intent.venueQuoteOut == 0) revert ZeroRedemptionQuote();
        // 🔴 See the ⚠️ above: without this a venue that takes the asset and pays nothing settles.
        if (intent.minSettlementOut == 0) revert ZeroAmount();
        if (intent.sellerFee > intent.venueQuoteOut) revert SellerFeeExceedsProceeds();
        if (intent.minSettlementOut > intent.venueQuoteOut - intent.sellerFee) revert MinSettlementTooHigh();

        if (block.timestamp > intent.deadline) revert IntentExpired();
        if (intent.deadline > block.timestamp + MAX_INTENT_TTL) revert IntentTtlTooLong();
        if (usedIntentNonce(intent.seller, intent.nonce)) revert IntentNonceUsed();

        structHash = _redemptionStructHash(intent);
        bytes32 digest = _hashTypedDataV4(structHash);

        address signer = ECDSA.recover(digest, signature);
        if (!hasRole(SETTLEMENT_OPERATOR_ROLE, signer)) revert IntentBadSigner();

        // The seller's own consent to these exact terms, taken in the same call that verifies the
        // intent for the reason `_verifyIntent` gives: a guarantee each caller has to remember to
        // make is not a guarantee.
        if (!SignatureChecker.isValidSignatureNow(intent.seller, digest, sellerSignature)) {
            revert SellerConsentBadSignature();
        }
    }
}
