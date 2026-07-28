// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ExchangeTypes} from "../types/ExchangeTypes.sol";

/// @title IFeeGate
/// @notice Fee-attestation errors/event, single-sourced here and inherited by
///         `FeeGate` (not redeclared) so there is exactly one declaration site.
///         References `ExchangeTypes.Action` via qualified import rather than
///         inheriting `ExchangeTypes` — see IKycGate.sol for why.
interface IFeeGate {
    event FeeConsumed(address indexed account, ExchangeTypes.Action indexed action, uint256 nonce);

    error FeeAccountMismatch();
    error FeeActionMismatch();
    error FeeExpired();
    error FeeTtlTooLong();
    error FeeNonceUsed();
    error FeeBadSigner();
    error InvalidFee();
    error FeeCollectorNotAllowed(address collector);
    /// @dev The attested settlement currency is not one of the two legs of this
    ///      order/offer, so both fees could not be denominated in it (AC-833).
    error FeeTokenNotALeg(address feeToken);

    function FEE_OPERATOR_ROLE() external view returns (bytes32);
    function FEE_TYPEHASH() external view returns (bytes32);
    function MAX_FEE_TTL() external view returns (uint256);
    function MAX_FEE_BPS() external view returns (uint16);
}
