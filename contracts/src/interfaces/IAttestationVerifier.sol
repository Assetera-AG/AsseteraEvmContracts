// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GateTypes} from "../types/GateTypes.sol";

/// @title IAttestationVerifier
/// @notice Stateless validation of the KYC and fee attestations, implemented by a separate
///         contract that a gate reaches through an immutable address (see `GateStorage`).
interface IAttestationVerifier {
    /// @notice Check a KYC attestation's fields against the call and recover its signer.
    /// @param domainSeparator The verifying contract's EIP-712 domain separator.
    /// @param account The party being authorized; must equal `att.account`.
    /// @param action The action being taken; must equal `att.action`.
    /// @param orderId The bound order; must equal `att.orderId`.
    /// @param paramsHashAllowed Whether `action` may carry a non-zero `paramsHash`.
    /// @param maxTtl Hard cap on attestation freshness.
    /// @return signer The recovered signer. Role membership is the caller's check.
    function verifyKyc(
        bytes32 domainSeparator,
        address account,
        uint8 action,
        uint256 orderId,
        bool paramsHashAllowed,
        uint256 maxTtl,
        GateTypes.KycAttestation calldata att
    ) external view returns (address signer);

    /// @notice Check a fee attestation's fields against the call and recover its signer.
    /// @return signer The recovered signer. Role membership is the caller's check.
    function verifyFee(
        bytes32 domainSeparator,
        address account,
        uint8 action,
        uint256 maxTtl,
        GateTypes.FeeAttestation calldata att
    ) external view returns (address signer);

    /// @notice Fee bounds and denomination: both fees within the cap, the fee token one of the two
    ///         legs, and a non-zero fee routed to a non-zero, allowlisted collector.
    /// @param collectorAllowed Whether `att.feeCollector` is on the caller's collector allowlist.
    function validateFees(GateTypes.FeeAttestation calldata att, address legA, address legB, bool collectorAllowed)
        external
        pure;

    /// @notice `validateFees` followed by `verifyFee`, in one call.
    function verifyFeeTerms(
        bytes32 domainSeparator,
        address account,
        uint8 action,
        uint256 maxTtl,
        GateTypes.FeeAttestation calldata att,
        address legA,
        address legB,
        bool collectorAllowed
    ) external view returns (address signer);
}
