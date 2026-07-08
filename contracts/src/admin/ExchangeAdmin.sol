// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ExchangeStorage} from "../storage/ExchangeStorage.sol";

/// @title ExchangeAdmin
/// @notice Active admin surface: pause/unpause, per-action KYC gating toggle,
///         fee collector allowlist management, and the negative/escape-hatch
///         functions that let the admin multisig force-cancel a frozen user's
///         order/offer and route escrow to a compliance-chosen recipient.
abstract contract ExchangeAdmin is ExchangeStorage {
    using SafeERC20 for IERC20;

    event CollectorAllowed(address indexed collector, bool allowed);
    event ComplianceRequiredSet(Action indexed action, bool required);
    event OrderForceCancelled(uint256 indexed id, address indexed maker, address recipient, address indexed admin);
    event OfferForceCancelled(
        uint256 indexed id, address indexed maker, address makerRecipient, address takerRecipient, address indexed admin
    );

    /// @notice Add or remove an address from the fee collector allowlist.
    ///         Only DEFAULT_ADMIN_ROLE (the Safe multisig in prod) can manage this,
    ///         preventing a compromised KYC signer from redirecting fees arbitrarily.
    function setAllowedCollector(address collector, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        allowedCollectors[collector] = allowed;
        emit CollectorAllowed(collector, allowed);
    }

    function pause() external onlyRole(OPERATOR_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(OPERATOR_ROLE) {
        _unpause();
    }

    /// @notice Toggle KYC gating per action (composability). Admin only.
    function setComplianceRequired(Action action, bool required) external onlyRole(DEFAULT_ADMIN_ROLE) {
        complianceRequired[action] = required;
        emit ComplianceRequiredSet(action, required);
    }

    /// @notice Admin (multisig) escape hatch: force-cancel any open order and
    ///         route the escrow to `recipient` (the maker, or a
    ///         compliance-directed address). Resolves funds for frozen users who
    ///         can no longer obtain a KYC signature to self-cancel.
    function cancelOrderForUser(uint256 id, address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();
        Order storage o = _orders[id];
        if (o.status != OrderStatus.Open) revert OrderNotOpen(id);
        o.status = OrderStatus.ForceCancelled;
        IERC20(o.sellToken).safeTransfer(recipient, o.remainingQuantity);
        emit OrderForceCancelled(id, o.maker, recipient, _msgSender());
    }

    /// @notice Admin (multisig) escape hatch: force-cancel any non-settled offer
    ///         and route each party's escrowed tokens to compliance-chosen recipients.
    ///         Works in all non-terminal states including Accepted (both sides escrowed).
    ///         Mirrors cancelOrderForUser for regular orders — needed when a party is
    ///         frozen after acceptOffer, which otherwise permanently locks both escrows.
    /// @param offerId         The offer to force-cancel.
    /// @param makerRecipient  Address to receive the maker's escrowed tokens.
    /// @param takerRecipient  Address to receive the taker's escrowed tokens (only used when Accepted).
    function cancelOfferForUser(uint256 offerId, address makerRecipient, address takerRecipient)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (makerRecipient == address(0) || takerRecipient == address(0)) revert ZeroAddress();
        Offer storage o = _offers[offerId];
        if (o.id == 0) revert OfferNotFound(offerId);
        if (
            o.status == OfferStatus.Settled || o.status == OfferStatus.Cancelled
                || o.status == OfferStatus.ForceCancelled || o.status == OfferStatus.Expired
        ) {
            revert OfferNotOpen(offerId);
        }

        address makerToken = o.makerToken;
        uint256 makerAmount = o.makerAmount;
        address takerToken = o.takerToken;
        uint256 takerAmount = o.takerAmount;
        OfferStatus prevStatus = o.status;

        o.status = OfferStatus.ForceCancelled;

        if (prevStatus == OfferStatus.Accepted) {
            // Both sides escrowed — return each to their designated recipient.
            IERC20(makerToken).safeTransfer(makerRecipient, makerAmount);
            IERC20(takerToken).safeTransfer(takerRecipient, takerAmount);
        } else {
            // Only the current proposer's side is held in escrow.
            if (o.proposedBy == o.maker) {
                IERC20(makerToken).safeTransfer(makerRecipient, makerAmount);
            } else {
                IERC20(takerToken).safeTransfer(takerRecipient, takerAmount);
            }
        }

        emit OfferForceCancelled(offerId, o.maker, makerRecipient, takerRecipient, _msgSender());
    }
}
