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

    bytes32 public constant FEE_TYPEHASH = keccak256(
        "FeeAttestation(address account,uint8 action,uint256 nonce,uint256 deadline,bytes32 paramsHash,uint16 makerFeeBps,uint16 takerFeeBps,address feeCollector)"
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
    ///      paired KycAttestation against — that transitively enforces
    ///      `fee.paramsHash == kyc.paramsHash` without a separate cross-check here.
    function _verifyFee(address account, Action action, FeeAttestation calldata att) internal view {
        if (!complianceRequired[action]) return;
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
                att.feeCollector
            )
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), att.signature);
        if (!hasRole(FEE_OPERATOR_ROLE, signer)) revert FeeBadSigner();
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
            usedFeeNonce[account][feeAtt.nonce] = true;
            emit FeeConsumed(account, action, feeAtt.nonce);
        }
    }

    /// @dev Fee bounds — always enforced (defence in depth) so a compromised fee
    ///      signer cannot set extreme fees or route to an unlisted collector.
    function _validateFees(uint16 makerFeeBps, uint16 takerFeeBps, address feeCollector) internal view {
        if (makerFeeBps > MAX_FEE_BPS || takerFeeBps > MAX_FEE_BPS) revert InvalidFee();
        if (makerFeeBps > 0 || takerFeeBps > 0) {
            if (feeCollector == address(0)) revert ZeroAddress();
            if (!allowedCollectors[feeCollector]) revert FeeCollectorNotAllowed(feeCollector);
        }
    }
}
