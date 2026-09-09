// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {GateTypes} from "../types/GateTypes.sol";
import {IKycGate} from "../interfaces/IKycGate.sol";
import {GateStorage} from "../gates/GateStorage.sol";
import {IFeeGate} from "../interfaces/IFeeGate.sol";

/// @title AttestationSig
/// @notice Stateless validation of the KYC and fee attestations: field checks, EIP-712
///         struct hash, digest and signer recovery. Kept in an external library so this
///         code lives in its own deployed contract instead of in every implementation
///         that verifies attestations.
/// @dev External (DELEGATECALL-linked) on purpose: an internal library inlines and saves
///      no implementation bytecode. The functions read `block.timestamp` and nothing
///      else; no storage is read or written, so the storage layout of any linking
///      implementation is unaffected. Storage-backed facts (nonce spent, role held,
///      gating enabled) stay in the gate.
library AttestationSig {
    bytes32 internal constant KYC_TYPEHASH = keccak256(
        "KycAttestation(address account,uint8 action,uint256 orderId,uint256 nonce,uint256 deadline,bytes32 paramsHash)"
    );
    bytes32 internal constant FEE_TYPEHASH = keccak256(
        "FeeAttestation(address account,uint8 action,uint256 nonce,uint256 deadline,bytes32 paramsHash,uint16 makerFeeBps,uint16 takerFeeBps,address feeCollector,address feeToken)"
    );

    /// @notice Check a KYC attestation's fields against the call and recover its signer.
    /// @param domainSeparator The verifying contract's EIP-712 domain separator.
    /// @param paramsHashAllowed Whether `action` may carry a non-zero `paramsHash`.
    /// @param maxTtl Hard cap on attestation freshness.
    function verifyKyc(
        bytes32 domainSeparator,
        address account,
        uint8 action,
        uint256 orderId,
        bool paramsHashAllowed,
        uint256 maxTtl,
        GateTypes.KycAttestation calldata att
    ) external view returns (address signer) {
        if (att.account != account) revert IKycGate.KycAccountMismatch();
        if (att.action != action) revert IKycGate.KycActionMismatch();
        if (att.orderId != orderId) revert IKycGate.KycOrderMismatch();
        if (!paramsHashAllowed && att.paramsHash != bytes32(0)) revert GateStorage.ParamsHashMismatch();
        if (block.timestamp > att.deadline) revert IKycGate.KycExpired();
        if (att.deadline > block.timestamp + maxTtl) revert IKycGate.KycTtlTooLong();
        bytes32 structHash = keccak256(
            abi.encode(KYC_TYPEHASH, att.account, att.action, att.orderId, att.nonce, att.deadline, att.paramsHash)
        );
        return ECDSA.recover(MessageHashUtils.toTypedDataHash(domainSeparator, structHash), att.signature);
    }

    /// @notice Check a fee attestation's fields against the call and recover its signer.
    function verifyFee(
        bytes32 domainSeparator,
        address account,
        uint8 action,
        uint256 maxTtl,
        GateTypes.FeeAttestation calldata att
    ) external view returns (address signer) {
        if (att.account != account) revert IFeeGate.FeeAccountMismatch();
        if (att.action != action) revert IFeeGate.FeeActionMismatch();
        if (block.timestamp > att.deadline) revert IFeeGate.FeeExpired();
        if (att.deadline > block.timestamp + maxTtl) revert IFeeGate.FeeTtlTooLong();
        bytes32 structHash = keccak256(
            abi.encode(
                FEE_TYPEHASH,
                att.account,
                att.action,
                att.nonce,
                att.deadline,
                att.paramsHash,
                att.makerFeeBps,
                att.takerFeeBps,
                att.feeCollector,
                att.feeToken
            )
        );
        return ECDSA.recover(MessageHashUtils.toTypedDataHash(domainSeparator, structHash), att.signature);
    }
}
