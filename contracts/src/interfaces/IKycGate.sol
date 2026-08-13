// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IKycGate
/// @notice KYC-attestation errors/event, single-sourced here and inherited by
///         `KycGate` (not redeclared) so there is exactly one declaration site.
interface IKycGate {
    /// @dev `action` is the gate's opaque `uint8`, not the exchange's `Action` enum (AO-514):
    ///      the gate is shared by venues with different action sets. The event signature — and
    ///      therefore `topic0` and the indexed topic bytes — is unchanged, because an enum is
    ///      already `uint8` in the ABI and in the canonical signature.
    event KycConsumed(address indexed account, uint8 indexed action, uint256 indexed orderId, uint256 nonce);

    error KycAccountMismatch();
    error KycActionMismatch();
    error KycOrderMismatch();
    error KycExpired();
    error KycTtlTooLong();
    error KycNonceUsed();
    error KycBadSigner();

    function KYC_OPERATOR_ROLE() external view returns (bytes32);
    function KYC_TYPEHASH() external view returns (bytes32);
    function MAX_KYC_TTL() external view returns (uint256);
}
