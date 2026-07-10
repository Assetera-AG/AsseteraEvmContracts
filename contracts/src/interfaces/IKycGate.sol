// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ExchangeTypes} from "../types/ExchangeTypes.sol";

/// @title IKycGate
/// @notice KYC-attestation errors/event, single-sourced here and inherited by
///         `KycGate` (not redeclared) so there is exactly one declaration site.
///         References `ExchangeTypes.Action` via qualified import rather than
///         inheriting `ExchangeTypes` — interfaces cannot inherit an abstract
///         contract (see ExchangeTypes.sol's doc comment for why it's a
///         contract, not an interface).
interface IKycGate {
    event KycConsumed(
        address indexed account, ExchangeTypes.Action indexed action, uint256 indexed orderId, uint256 nonce
    );

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
