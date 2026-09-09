// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {GateTypes} from "../types/GateTypes.sol";
import {IAttestationVerifier} from "../interfaces/IAttestationVerifier.sol";
import {IKycGate} from "../interfaces/IKycGate.sol";
import {IFeeGate} from "../interfaces/IFeeGate.sol";
import {GateStorage} from "./GateStorage.sol";

/// @title AttestationVerifier
/// @notice Stateless validation of the KYC and fee attestations: field checks, EIP-712
///         struct hash, digest and signer recovery. A separate deployed contract, so this
///         code no longer counts against the runtime size of the implementations that
///         verify attestations (the exchange sits at the EIP-170 limit).
/// @dev Reached by STATICCALL through an immutable address that each implementation takes
///      in its constructor (`GateStorage`), the same way the ERC-2771 forwarder is wired.
///      Chosen over an external library on purpose: a linked library address is part of
///      the implementation's initcode, and the deploy scripts key implementations on that
///      initcode with CREATE2, so a library would have to be address-stable across chains
///      through a separate linking step. An immutable is a plain constructor argument.
///
///      Holds no storage and reads none. The functions read `block.timestamp` and nothing
///      else, so the storage layout of a calling implementation is unaffected.
///      Storage-backed facts (gating enabled, nonce spent, role held) stay in the gate.
///      Errors raised here carry the gates' own selectors and propagate to the caller
///      unchanged, so a consumer decoding a revert sees no difference.
contract AttestationVerifier is IAttestationVerifier {
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
    ) external view override returns (address signer) {
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
    ) external view override returns (address signer) {
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
