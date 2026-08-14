// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {GateStorage} from "../gates/GateStorage.sol";
import {ExchangeTypes} from "../types/ExchangeTypes.sol";

/// @title ExchangeStorage
/// @notice Universal base of the ORDER BOOK: its state, the OZ upgradeable bases
///         only the venue needs (inherited exactly once here so every derived
///         module reaches them via a single linear path — no diamond ambiguity),
///         and the errors shared by 2+ sibling modules (declaring them
///         per-module would collide with "Identifier already declared" once
///         co-inherited).
///
///         Gate state and the OZ bases the gates need live one level down in
///         `GateStorage` (AO-514), so a contract can use `KycGate`/`FeeGate`
///         without inheriting an order book it has no use for.
///
/// @dev    ⚠️ AO-514 moved the four gate mappings out of this contract's linear
///         layout and into `GateStorage`'s ERC-7201 namespace. That REORDERS the
///         remaining top-level slots and is therefore NOT upgrade-safe against
///         the deployed proxies. It is an accepted break, to be landed by a
///         coordinated redeploy rather than an in-place `upgradeToAndCall`; see
///         the AO-514 PR. Do not upgrade a live proxy onto this implementation.
abstract contract ExchangeStorage is ExchangeTypes, GateStorage, ReentrancyGuardUpgradeable, PausableUpgradeable {
    // --------------------------------------------------------------------- //
    //                                Roles                                   //
    // --------------------------------------------------------------------- //
    // OPERATOR_ROLE is parked (AC-246) — declared, commented, in
    // docs/parked/OperatorFunctions.sol alongside the functions it gates.

    // --------------------------------------------------------------------- //
    //                                State                                   //
    // --------------------------------------------------------------------- //

    mapping(uint256 => Order) internal _orders;
    uint256 public totalOrders;

    mapping(uint256 => Offer) internal _offers;
    uint256 public totalOffers;

    /// @dev Fresh-deploy storage layout (AC-242, re-based by AO-514) — free to
    ///      size/reorder; no need to match the pre-split monolith's slot order.
    uint256[42] private __gap;

    // --------------------------------------------------------------------- //
    //                          Shared errors                                 //
    // --------------------------------------------------------------------- //
    // Used by 2+ sibling modules (OrderBook/OfferBook/ExchangeAdmin) — must live in the common
    // ancestor. `ZeroAddress` and `ParamsHashMismatch` are raised by the gates too, so they are
    // declared one level down in `GateStorage` and inherited here.

    error ZeroAmount();
    error SameToken();
    error InvalidExpiry();
    error OrderNotOpen(uint256 id);
    error OfferNotOpen(uint256 id);
    error OfferNotFound(uint256 id);
}
