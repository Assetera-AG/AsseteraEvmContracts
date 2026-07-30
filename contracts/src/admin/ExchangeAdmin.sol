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

    /// @notice "Stop the venue" lever. Moved from OPERATOR_ROLE to
    ///         DEFAULT_ADMIN_ROLE (AC-246) — OPERATOR_ROLE itself is parked, and
    ///         pausing is worth keeping as an active, admin-gated escape hatch so
    ///         `whenNotPaused` stays meaningful.
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Toggle KYC gating per action (composability). Admin only.
    /// @dev KYC ONLY. Turning this off for `Place`/`MakeOffer` does NOT disable fee
    ///      verification (AC-884) — the fee attestation is still signature-, deadline-
    ///      and nonce-checked, so the fee service must stay live. To run a market
    ///      fee-free, have the fee service sign `makerFeeBps == takerFeeBps == 0`.
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
        // Releases the FULL escrow: remaining quantity plus any unconsumed escrowed fee
        // (AC-833) — the fee is the maker's money until a fill earns it, so a frozen
        // user's exit must not leave a fraction of it stranded in the contract.
        uint256 refunded = o.remainingQuantity + o.escrowedFee;
        o.status = OrderStatus.ForceCancelled;
        o.remainingQuantity = 0;
        o.escrowedFee = 0;
        IERC20(o.sellToken).safeTransfer(recipient, refunded);
        emit OrderForceCancelled(id, o.maker, recipient, _msgSender());
    }

    /// @notice Admin (multisig) escape hatch: force-cancel any offer still in
    ///         `Open`/`Countered` and route the current proposer's escrowed
    ///         tokens to a compliance-chosen recipient. Mirrors
    ///         cancelOrderForUser for regular orders. `Accepted` is never a
    ///         reachable persisted state (AC-246) — acceptOffer settles
    ///         atomically in the same call, so there's no window where both
    ///         sides sit escrowed waiting for a separate step.
    /// @param offerId         The offer to force-cancel.
    /// @param makerRecipient  Address to receive the maker's escrowed tokens (used only if the maker is the current proposer).
    /// @param takerRecipient  Address to receive the taker's escrowed tokens (used only if the taker is the current proposer).
    function cancelOfferForUser(uint256 offerId, address makerRecipient, address takerRecipient)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (makerRecipient == address(0) || takerRecipient == address(0)) revert ZeroAddress();
        Offer storage o = _offers[offerId];
        if (o.id == 0) revert OfferNotFound(offerId);
        if (o.status != OfferStatus.Open && o.status != OfferStatus.Countered) {
            revert OfferNotOpen(offerId);
        }

        address makerToken = o.makerToken;
        uint256 makerAmount = o.makerAmount;
        address takerToken = o.takerToken;
        uint256 takerAmount = o.takerAmount;
        // The proposer's escrowed fee rides along with their escrowed side (AC-833) —
        // it is denominated in feeToken, which is the leg they escrowed when non-zero.
        uint256 escrowedFee = o.escrowedFee;

        o.status = OfferStatus.ForceCancelled;
        o.escrowedFee = 0;

        // Only the current proposer's side is held in escrow.
        if (o.proposedBy == o.maker) {
            IERC20(makerToken).safeTransfer(makerRecipient, makerAmount + escrowedFee);
        } else {
            IERC20(takerToken).safeTransfer(takerRecipient, takerAmount + escrowedFee);
        }

        emit OfferForceCancelled(offerId, o.maker, makerRecipient, takerRecipient, _msgSender());
    }
}
