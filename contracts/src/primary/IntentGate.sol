// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {PrimaryStorage} from "./storage/PrimaryStorage.sol";
import {IIntentGate} from "./interfaces/IIntentGate.sol";

/// @title IntentGate
/// @notice The third gate on a primary settlement: a fresh, single-use EIP-712
///         `SettlementIntent` signed by a `SETTLEMENT_OPERATOR_ROLE` holder, verified
///         alongside the KYC attestation (compliance backend) and the fee attestation (fee
///         service). Same shape as `KycGate`/`FeeGate` — verify without writing, then consume
///         — so that **all three signatures are checked before any nonce is burned** and an
///         invalid third attestation cannot spend the first two.
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
    ///      attestations must carry (§4.4). One hash, three signatures: the settlement
    ///      operator signs it as a digest, and the compliance and fee signers each pin their
    ///      attestation to it, so an attestation minted for one settlement cannot be replayed
    ///      onto another with a different asset, venue or amount.
    ///
    ///      ⚠️ This is `keccak256(abi.encode(INTENT_TYPEHASH, intent))` — identical to the
    ///      EIP-712 struct hash ONLY because every member of `SettlementIntent` is a static
    ///      type. See the warning on the struct before adding a member.
    function _intentStructHash(SettlementIntent calldata intent) internal pure returns (bytes32) {
        return keccak256(abi.encode(INTENT_TYPEHASH, intent));
    }

    /// @dev Verify an intent without consuming its nonce. Pure validation, no state writes.
    /// @param intent    The settlement intent.
    /// @param signature The settlement operator's EIP-712 signature over it.
    /// @return structHash The intent's EIP-712 struct hash, reused as the `paramsHash` binding.
    function _verifyIntent(SettlementIntent calldata intent, bytes calldata signature)
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
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        if (!hasRole(SETTLEMENT_OPERATOR_ROLE, signer)) revert IntentBadSigner();
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

        // Deliberately stricter than the shared `_validateFees`, which only proves the fee
        // token is one of the two legs of a trade. That is the right check for the exchange
        // and too weak here: the primary path takes the fee from the SETTLEMENT leg by
        // construction, and a fee attested in the asset token would come out of what the
        // buyer receives.
        if (feeAtt.feeToken != intent.settlementToken) revert SettlementTokenMismatch();
        if (feeAtt.feeCollector != intent.feeCollector) revert FeeCollectorMismatch();

        if (feeAtt.makerFeeBps > MAX_FEE_BPS || feeAtt.takerFeeBps > MAX_FEE_BPS) revert InvalidFee();
        if (feeAtt.takerFeeBps > 0 || feeAtt.makerFeeBps > 0) {
            if (feeAtt.feeCollector == address(0)) revert ZeroAddress();
            if (!allowedCollectors(feeAtt.feeCollector)) revert FeeCollectorNotAllowed(feeAtt.feeCollector);
        }
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
