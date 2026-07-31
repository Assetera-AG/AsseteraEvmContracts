// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {KycGate} from "./KycGate.sol";
import {IFeeGate} from "../interfaces/IFeeGate.sol";

/// @title FeeGate
/// @notice Fee-setting actions (`placeOrder`, `placeOrderWithPermit`, `makeOffer`)
///         require a second, independent attestation signed by a distinct
///         `FEE_OPERATOR_ROLE` holder (the fee service), not the KYC backend.
///         `_consumeKycAndFee` pairs a fee attestation with its KYC attestation,
///         so `FeeGate` inherits `KycGate` directly (not just via a sibling —
///         see AC-242 plan notes on why identifiers must resolve within a
///         contract's own `is` list).
abstract contract FeeGate is KycGate, IFeeGate {
    /// @notice Whitelisted fee signers (the fee service — separate from KYC).
    ///         Any fee attestation whose recovered signer holds this role is
    ///         accepted. Managed by the admin multisig.
    bytes32 public constant FEE_OPERATOR_ROLE = keccak256("FEE_OPERATOR_ROLE");

    /// @dev `feeToken` is the final field (AC-833). Adding it CHANGES the digest, so the
    ///      fee service must sign the new type — an attestation signed under the old
    ///      typehash recovers to a different signer and is rejected by `FeeBadSigner`.
    bytes32 public constant FEE_TYPEHASH = keccak256(
        "FeeAttestation(address account,uint8 action,uint256 nonce,uint256 deadline,bytes32 paramsHash,uint16 makerFeeBps,uint16 takerFeeBps,address feeCollector,address feeToken)"
    );

    /// @notice Hard cap on fee attestation freshness, mirroring MAX_KYC_TTL for
    ///         the separate fee-service signing flow.
    uint256 public constant MAX_FEE_TTL = 15 minutes;

    /// @notice Absolute upper bound on fee basis points (100 % = 10 000 bps).
    ///         Practical configs will be well below this.
    uint16 public constant MAX_FEE_BPS = 10_000;

    /// @dev Verify a fee attestation without consuming the nonce. Pure validation;
    ///      no state writes. Fee attestations only exist for fee-setting actions
    ///      (Place, MakeOffer); the caller is responsible for checking
    ///      `att.paramsHash` against the same on-chain-computed hash it checks the
    ///      paired KycAttestation against (see `_bindParamsHash`) — that transitively
    ///      enforces `fee.paramsHash == kyc.paramsHash` without a separate cross-check here.
    ///
    ///      UNCONDITIONAL — deliberately NOT behind `complianceRequired[action]` (AC-884).
    ///      That toggle is a KYC control; coupling fee verification to it meant an admin
    ///      disabling KYC gating for an action silently disabled signature, deadline and
    ///      nonce checking on the fee terms too, letting any caller hand-craft an unsigned
    ///      zero-fee attestation and place a permanently fee-free order. Fee-free trading
    ///      remains reachable the honest way: the fee service signs `makerFeeBps ==
    ///      takerFeeBps == 0` (`_validateFees` explicitly permits that, collector included).
    function _verifyFee(address account, Action action, FeeAttestation calldata att) internal view {
        if (att.account != account) revert FeeAccountMismatch();
        if (att.action != action) revert FeeActionMismatch();
        if (block.timestamp > att.deadline) revert FeeExpired();
        if (att.deadline > block.timestamp + MAX_FEE_TTL) revert FeeTtlTooLong();
        if (usedFeeNonce[account][att.nonce]) revert FeeNonceUsed();

        bytes32 structHash = keccak256(
            abi.encode(
                FEE_TYPEHASH,
                att.account,
                uint8(att.action),
                att.nonce,
                att.deadline,
                att.paramsHash,
                att.makerFeeBps,
                att.takerFeeBps,
                att.feeCollector,
                att.feeToken
            )
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), att.signature);
        if (!hasRole(FEE_OPERATOR_ROLE, signer)) revert FeeBadSigner();
    }

    /// @dev Binds both attestations of a fee-setting action to the on-chain-computed
    ///      `paramsHash` for this call. The FEE binding is unconditional, matching
    ///      `_verifyFee` (AC-884): a fee attestation is always signature-checked, so it
    ///      must always be pinned to these exact params or one signed for a different
    ///      order/offer could be replayed onto this one. The KYC binding stays behind
    ///      `complianceRequired[action]`, the gate it actually belongs to.
    function _bindParamsHash(
        Action action,
        KycAttestation calldata kycAtt,
        FeeAttestation calldata feeAtt,
        bytes32 paramsHash
    ) internal view {
        if (complianceRequired[action] && kycAtt.paramsHash != paramsHash) {
            revert ParamsHashMismatch();
        }
        if (feeAtt.paramsHash != paramsHash) revert ParamsHashMismatch();
    }

    /// @dev Verifies both the KYC and fee attestations for a fee-setting action
    ///      (Place, MakeOffer) before burning either nonce — an invalid second
    ///      attestation must not consume the first attestation's nonce on a
    ///      reverted call. Both are checked against the same `account`/`action`,
    ///      which transitively binds `fee.account == kyc.account == account` and
    ///      `fee.action == kyc.action == action`.
    function _consumeKycAndFee(
        address account,
        Action action,
        uint256 orderId,
        KycAttestation calldata kycAtt,
        FeeAttestation calldata feeAtt
    ) internal {
        _verifyKyc(account, action, orderId, kycAtt);
        _verifyFee(account, action, feeAtt);
        if (complianceRequired[action]) {
            usedNonce[account][kycAtt.nonce] = true;
            emit KycConsumed(account, action, orderId, kycAtt.nonce);
        }
        // The fee nonce burns unconditionally, mirroring the now-unconditional
        // `_verifyFee` (AC-884) — a single-use attestation whose nonce is only burned
        // when KYC gating happens to be on would be replayable while it is off.
        usedFeeNonce[account][feeAtt.nonce] = true;
        emit FeeConsumed(account, action, feeAtt.nonce);
    }

    /// @dev Fee bounds + denomination — always enforced (defence in depth) so a
    ///      compromised fee signer cannot set extreme fees, route to an unlisted
    ///      collector, or denominate fees in a token that isn't part of the trade.
    /// @param legA One of the two legs (sellToken / makerToken).
    /// @param legB The other leg (buyToken / takerToken).
    function _validateFees(FeeAttestation calldata att, address legA, address legB) internal view {
        if (att.makerFeeBps > MAX_FEE_BPS || att.takerFeeBps > MAX_FEE_BPS) revert InvalidFee();
        // Required even for a zero-fee order (AC-833): it pins the settlement currency
        // for the order's whole lifetime, and keeps `feeToken == address(0)` meaning
        // exactly one thing — a legacy order placed before this upgrade.
        if (att.feeToken != legA && att.feeToken != legB) revert FeeTokenNotALeg(att.feeToken);
        if (att.makerFeeBps > 0 || att.takerFeeBps > 0) {
            if (att.feeCollector == address(0)) revert ZeroAddress();
            if (!allowedCollectors[att.feeCollector]) revert FeeCollectorNotAllowed(att.feeCollector);
        }
    }
}
