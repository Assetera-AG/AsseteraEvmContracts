// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ExchangeStorage} from "../storage/ExchangeStorage.sol";
import {IKycGate} from "../interfaces/IKycGate.sol";

/// @title KycGate
/// @notice Positive compliance gate: every state-changing trade action requires
///         a fresh, single-use EIP-712 KYC attestation signed by a
///         `KYC_OPERATOR_ROLE` holder. "Freezing" a user is simply the backend
///         declining to sign.
abstract contract KycGate is ExchangeStorage, IKycGate {
    /// @notice Whitelisted KYC signers. Any attestation whose recovered signer
    ///         holds this role is accepted. Managed by the admin multisig.
    bytes32 public constant KYC_OPERATOR_ROLE = keccak256("KYC_OPERATOR_ROLE");

    bytes32 public constant KYC_TYPEHASH = keccak256(
        "KycAttestation(address account,uint8 action,uint256 orderId,uint256 nonce,uint256 deadline,bytes32 paramsHash)"
    );

    /// @notice Hard cap on attestation freshness; rejects over-long deadlines
    ///         even if a signer produced one. Backend uses ~3 min.
    uint256 public constant MAX_KYC_TTL = 15 minutes;

    /// @dev Verify a KYC attestation without consuming the nonce. Pure validation;
    ///      no state writes. Used by _consumeKyc and directly by settle() so both
    ///      attestations can be verified before either nonce is burned.
    function _verifyKyc(address account, Action action, uint256 orderId, KycAttestation calldata att) internal view {
        if (!complianceRequired[action]) return;
        if (att.account != account) revert KycAccountMismatch();
        if (att.action != action) revert KycActionMismatch();
        if (att.orderId != orderId) revert KycOrderMismatch();
        // paramsHash is only allowed for actions that bind extra parameters; content is checked by callers.
        // CancelOffer and SettleOffer are intentionally separate from Cancel and Settle to prevent
        // cross-function attestation replay between order-level and offer-level operations.
        bool paramsAllowed = action == Action.Place || action == Action.MakeOffer || action == Action.ReplaceOffer
            || action == Action.AcceptOffer || action == Action.CancelOffer || action == Action.SettleOffer;
        if (!paramsAllowed && att.paramsHash != bytes32(0)) revert ParamsHashMismatch();
        if (block.timestamp > att.deadline) revert KycExpired();
        if (att.deadline > block.timestamp + MAX_KYC_TTL) revert KycTtlTooLong();
        if (usedNonce[account][att.nonce]) revert KycNonceUsed();

        bytes32 structHash = keccak256(
            abi.encode(
                KYC_TYPEHASH, att.account, uint8(att.action), att.orderId, att.nonce, att.deadline, att.paramsHash
            )
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), att.signature);
        if (!hasRole(KYC_OPERATOR_ROLE, signer)) revert KycBadSigner();
    }

    /// @dev Verify + consume a single-use KYC attestation for `account`/`action`.
    ///      No-op if gating for `action` is disabled.
    function _consumeKyc(address account, Action action, uint256 orderId, KycAttestation calldata att) internal {
        _verifyKyc(account, action, orderId, att);
        if (complianceRequired[action]) {
            usedNonce[account][att.nonce] = true;
            emit KycConsumed(account, action, orderId, att.nonce);
        }
    }
}
