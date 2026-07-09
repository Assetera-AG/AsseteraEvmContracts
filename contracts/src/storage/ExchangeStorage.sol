// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ExchangeTypes} from "../types/ExchangeTypes.sol";

/// @title ExchangeStorage
/// @notice Universal base: all exchange state, the shared OZ upgradeable bases
///         (inherited exactly once here so every derived module reaches them
///         via a single linear path — no diamond ambiguity), and the errors
///         shared by 2+ sibling modules (declaring them per-module would
///         collide with "Identifier already declared" once co-inherited).
abstract contract ExchangeStorage is
    ExchangeTypes,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    EIP712Upgradeable
{
    using SafeERC20 for IERC20;

    // --------------------------------------------------------------------- //
    //                                Roles                                   //
    // --------------------------------------------------------------------- //
    // OPERATOR_ROLE is parked (AC-246) — declared, commented, in
    // admin/OperatorFunctions.sol alongside the functions it gates.

    // --------------------------------------------------------------------- //
    //                                State                                   //
    // --------------------------------------------------------------------- //

    mapping(uint256 => Order) internal _orders;
    uint256 public totalOrders;

    /// @notice Consumed KYC attestation nonces, per account. Single-use replay guard.
    mapping(address => mapping(uint256 => bool)) public usedNonce;

    /// @notice Consumed fee attestation nonces, per account. Separate namespace
    ///         from `usedNonce` since fee attestations are signed by a different party.
    mapping(address => mapping(uint256 => bool)) public usedFeeNonce;

    /// @notice Whether each action requires a KYC attestation (and, for Place/
    ///         MakeOffer, a fee attestation too — both share this toggle).
    ///         Composable: turn gating on/off per action (admin). Defaults to all-on.
    mapping(Action => bool) public complianceRequired;

    mapping(uint256 => Offer) internal _offers;
    uint256 public totalOffers;

    /// @notice Admin-managed allowlist of permitted fee collector addresses.
    ///         A compromised KYC signer cannot route fees to an arbitrary wallet
    ///         because the collector must be in this allowlist at placement time.
    mapping(address => bool) public allowedCollectors;

    /// @dev Fresh-deploy storage layout (AC-242) — free to size/reorder; no need
    ///      to match the pre-split monolith's slot order.
    uint256[42] private __gap;

    // --------------------------------------------------------------------- //
    //                          Shared errors                                 //
    // --------------------------------------------------------------------- //
    // Used by 2+ sibling modules (OrderBook/OfferBook/FeeGate/ExchangeAdmin/
    // final AsseteraExchange.initialize) — must live in the common ancestor.

    error ZeroAddress();
    error ZeroAmount();
    error SameToken();
    error InvalidExpiry();
    error ParamsHashMismatch();
    error OrderNotOpen(uint256 id);
    error OfferNotOpen(uint256 id);
    error OfferNotFound(uint256 id);
}
