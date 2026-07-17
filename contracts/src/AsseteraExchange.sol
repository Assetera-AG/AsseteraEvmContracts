// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {ERC2771ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {OrderBook} from "./core/OrderBook.sol";
import {OfferBook} from "./core/OfferBook.sol";
import {ExchangeTypes} from "./types/ExchangeTypes.sol";

/// @title AsseteraExchange
/// @notice Escrow-based limit-order venue with NO on-chain matching engine — the
///         simplified essence of the Assetera Agora order book, hardened for a
///         MiFID-style regulated venue.
///
///         Compliance is a two-sided gate:
///           * POSITIVE — every state-changing trade action requires a fresh,
///             single-use EIP-712 **KYC attestation** signed by a holder of
///             `KYC_OPERATOR_ROLE` (the centralized KYC backend). "Freezing" a
///             user is simply the backend declining to sign.
///           * NEGATIVE / escape hatch — `cancelOrderForUser` lets the admin
///             multisig force-cancel a (e.g. frozen) user's order and route the
///             escrow to a compliance-chosen recipient.
///
///         Identity is resolved via `_msgSender()` (ERC-2771), so the caller may
///         be a relayer (gasless meta-tx) or — later — an ERC-4337 smart account;
///         the contract never assumes `msg.sender == maker/taker`.
///
///         Modularised (AC-242) as: ExchangeStorage → {KycGate,FeeGate,ExchangeAdmin}
///         → {OrderBook,OfferBook} → AsseteraExchange (this file adds
///         UUPSUpgradeable/ERC2771ContextUpgradeable/Initializable, the three
///         concerns that only the final assembled contract needs).
contract AsseteraExchange is
    ExchangeTypes,
    Initializable,
    UUPSUpgradeable,
    OrderBook,
    OfferBook,
    ERC2771ContextUpgradeable
{
    /// @param trustedForwarder ERC-2771 forwarder (relayer). Immutable in impl
    ///        bytecode — proxy-safe. Set to address(0) to disable meta-tx.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address trustedForwarder) ERC2771ContextUpgradeable(trustedForwarder) {
        _disableInitializers();
    }

    /// @param admin     DEFAULT_ADMIN_ROLE (upgrade, role mgmt, pause/unpause, force-cancel). Multisig in prod.
    /// @param kycSigner Initial KYC_OPERATOR_ROLE holder (the backend signer).
    /// @param feeSigner Initial FEE_OPERATOR_ROLE holder (the fee service signer).
    function initialize(address admin, address kycSigner, address feeSigner) external initializer {
        if (admin == address(0) || kycSigner == address(0) || feeSigner == address(0)) {
            revert ZeroAddress();
        }

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __EIP712_init("AsseteraExchange", "1");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        // OPERATOR_ROLE is not granted here — the operator param was dropped from this
        // initializer (commit 78aee84). Re-enabling docs/parked/OperatorFunctions.sol requires
        // either a new initializer param (fresh deploy) or a reinitializer step to grant
        // OPERATOR_ROLE on an existing proxy — see docs/parked/OperatorFunctions.sol re-enable notes.
        _grantRole(KYC_OPERATOR_ROLE, kycSigner);
        _grantRole(FEE_OPERATOR_ROLE, feeSigner);

        // Default: every trade action is KYC-gated.
        complianceRequired[Action.Place] = true;
        complianceRequired[Action.Fill] = true;
        complianceRequired[Action.Settle] = true;
        complianceRequired[Action.MakeOffer] = true;
        complianceRequired[Action.ReplaceOffer] = true;
        complianceRequired[Action.AcceptOffer] = true;
        complianceRequired[Action.CancelOffer] = true;
        // Action.SettleOffer is unused (AC-246) — acceptOffer settles atomically
        // under Action.AcceptOffer's gate; there's no separate settle step to gate.
    }

    // --------------------------------------------------------------------- //
    //                       UUPS + ERC-2771 plumbing                         //
    // --------------------------------------------------------------------- //

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function version() external pure virtual returns (string memory) {
        return "3.1.0";
    }

    function _msgSender() internal view override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (address) {
        return ERC2771ContextUpgradeable._msgSender();
    }

    function _msgData() internal view override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (bytes calldata) {
        return ERC2771ContextUpgradeable._msgData();
    }

    function _contextSuffixLength()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (uint256)
    {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }
}
