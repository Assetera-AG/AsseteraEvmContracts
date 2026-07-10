// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {KycGate} from "../gates/KycGate.sol";
import {FeeGate} from "../gates/FeeGate.sol";
import {ExchangeAdmin} from "../admin/ExchangeAdmin.sol";
import {FeeMath} from "../libs/FeeMath.sol";

/// @title OfferBook
/// @notice Targeted offer / counter-offer lifecycle: make, replace, cancel,
///         accept, operator-settle, and permissionless sweep of expired offers.
abstract contract OfferBook is KycGate, FeeGate, ExchangeAdmin {
    using SafeERC20 for IERC20;

    event OfferMade(
        uint256 indexed id,
        address indexed maker,
        address indexed taker,
        address makerToken,
        uint256 makerAmount,
        address takerToken,
        uint256 takerAmount,
        uint64 expireTs,
        uint16 makerFeeBps,
        uint16 takerFeeBps,
        address feeCollector
    );
    event OfferReplaced(
        uint256 indexed id, address indexed by, uint256 newMakerAmount, uint256 newTakerAmount, uint64 expireTs
    );
    event OfferCancelled(uint256 indexed id, address indexed by, uint256 makerAmount, uint256 takerAmount);
    event OfferExpired(uint256 indexed id, address indexed proposedBy, uint256 amountReturned);
    event OfferAccepted(uint256 indexed id, address indexed by, uint256 makerAmount, uint256 takerAmount);
    event OfferSettled(
        uint256 indexed id,
        address indexed operator,
        uint256 makerReceived,
        uint256 takerReceived,
        uint256 makerFeeAmount,
        uint256 takerFeeAmount,
        address feeCollector
    );

    error OfferNotAccepted(uint256 id);
    error NotOfferParty(uint256 id);
    error OfferSelfTarget();
    error AcceptorIsProposer(uint256 id);
    error OfferIsExpired(uint256 id);

    /// @notice Create a targeted offer. Maker escrows makerToken; only the
    ///         nominated taker can respond. KYC-gated on the maker.
    /// @param att    KYC attestation authorising MakeOffer (no fee terms).
    /// @param feeAtt Fee attestation from the fee service, authorising the fee terms
    ///               snapshotted onto the offer. Bound to the same account/action/
    ///               paramsHash as `att` (see `_consumeKycAndFee`).
    function makeOffer(
        address taker,
        address makerToken,
        uint256 makerAmount,
        address takerToken,
        uint256 takerAmount,
        uint64 expireTs,
        KycAttestation calldata att,
        FeeAttestation calldata feeAtt
    ) external whenNotPaused nonReentrant returns (uint256 id) {
        address maker = _msgSender();
        if (taker == address(0) || makerToken == address(0) || takerToken == address(0)) revert ZeroAddress();
        if (makerAmount == 0 || takerAmount == 0) revert ZeroAmount();
        if (makerToken == takerToken) revert SameToken();
        if (taker == maker) revert OfferSelfTarget();
        if (expireTs != 0 && expireTs <= block.timestamp) revert InvalidExpiry();

        if (complianceRequired[Action.MakeOffer]) {
            bytes32 paramsHash = keccak256(abi.encodePacked(taker, makerToken, makerAmount, takerToken, takerAmount));
            if (att.paramsHash != paramsHash) revert ParamsHashMismatch();
            if (feeAtt.paramsHash != paramsHash) revert ParamsHashMismatch();
        }
        _validateFees(feeAtt.makerFeeBps, feeAtt.takerFeeBps, feeAtt.feeCollector);
        _consumeKycAndFee(maker, Action.MakeOffer, 0, att, feeAtt);

        id = _storeOffer(maker, taker, makerToken, makerAmount, takerToken, takerAmount, expireTs, feeAtt);
        IERC20(makerToken).safeTransferFrom(maker, address(this), makerAmount);
        emit OfferMade(
            id,
            maker,
            taker,
            makerToken,
            makerAmount,
            takerToken,
            takerAmount,
            expireTs,
            feeAtt.makerFeeBps,
            feeAtt.takerFeeBps,
            feeAtt.feeCollector
        );
    }

    function _storeOffer(
        address maker,
        address taker,
        address makerToken,
        uint256 makerAmount,
        address takerToken,
        uint256 takerAmount,
        uint64 expireTs,
        FeeAttestation calldata feeAtt
    ) internal returns (uint256 id) {
        id = ++totalOffers;
        _offers[id] = Offer({
            id: id,
            maker: maker,
            taker: taker,
            makerToken: makerToken,
            makerAmount: makerAmount,
            takerToken: takerToken,
            takerAmount: takerAmount,
            status: OfferStatus.Open,
            createdAt: uint64(block.timestamp),
            expireTs: expireTs,
            proposedBy: maker,
            makerFeeBps: feeAtt.makerFeeBps,
            takerFeeBps: feeAtt.takerFeeBps,
            feeCollector: feeAtt.feeCollector
        });
    }

    /// @notice Either party revises the offer terms. The previous proposer's
    ///         escrow is returned; the caller escrows their side at the new amounts.
    ///         KYC-gated on the caller.
    function replaceOffer(
        uint256 offerId,
        uint256 newMakerAmount,
        uint256 newTakerAmount,
        uint64 expireTs,
        KycAttestation calldata att
    ) external whenNotPaused nonReentrant {
        Offer storage o = _offers[offerId];
        if (o.id == 0) revert OfferNotFound(offerId);
        if (o.status != OfferStatus.Open && o.status != OfferStatus.Countered) revert OfferNotOpen(offerId);
        if (o.expireTs != 0 && block.timestamp > o.expireTs) revert OfferIsExpired(offerId);
        if (newMakerAmount == 0 || newTakerAmount == 0) revert ZeroAmount();
        if (expireTs != 0 && expireTs <= block.timestamp) revert InvalidExpiry();

        address caller = _msgSender();
        if (caller != o.maker && caller != o.taker) revert NotOfferParty(offerId);

        if (
            complianceRequired[Action.ReplaceOffer]
                && att.paramsHash != keccak256(abi.encodePacked(offerId, newMakerAmount, newTakerAmount))
        ) {
            revert ParamsHashMismatch();
        }
        _consumeKyc(caller, Action.ReplaceOffer, offerId, att);

        // Cache before state changes (CEI).
        address prevProposedBy = o.proposedBy;
        address prevMakerToken = o.makerToken;
        uint256 prevMakerAmount = o.makerAmount;
        address prevTakerToken = o.takerToken;
        uint256 prevTakerAmount = o.takerAmount;

        // Effects.
        o.makerAmount = newMakerAmount;
        o.takerAmount = newTakerAmount;
        o.expireTs = expireTs;
        o.proposedBy = caller;
        o.status = OfferStatus.Countered;

        // Return previous proposer's escrow.
        if (prevProposedBy == o.maker) {
            IERC20(prevMakerToken).safeTransfer(o.maker, prevMakerAmount);
        } else {
            IERC20(prevTakerToken).safeTransfer(o.taker, prevTakerAmount);
        }

        // Escrow caller's side at the new amounts.
        if (caller == o.maker) {
            IERC20(o.makerToken).safeTransferFrom(o.maker, address(this), newMakerAmount);
        } else {
            IERC20(o.takerToken).safeTransferFrom(o.taker, address(this), newTakerAmount);
        }

        emit OfferReplaced(offerId, caller, newMakerAmount, newTakerAmount, expireTs);
    }

    /// @notice Either party cancels the offer while it is Open or Countered.
    ///         The current proposer's escrowed tokens are returned. KYC-gated.
    /// @param offerId The offer to cancel.
    /// @param att     KYC attestation authorising the caller for CancelOffer on this offerId.
    function cancelOffer(uint256 offerId, KycAttestation calldata att) external nonReentrant {
        Offer storage o = _offers[offerId];
        if (o.id == 0) revert OfferNotFound(offerId);
        if (o.status != OfferStatus.Open && o.status != OfferStatus.Countered) revert OfferNotOpen(offerId);

        address caller = _msgSender();
        if (caller != o.maker && caller != o.taker) revert NotOfferParty(offerId);

        if (
            complianceRequired[Action.CancelOffer]
                && att.paramsHash != keccak256(abi.encodePacked(offerId, o.makerAmount, o.takerAmount))
        ) {
            revert ParamsHashMismatch();
        }
        _consumeKyc(caller, Action.CancelOffer, offerId, att);

        // Cache before state changes (CEI).
        address proposedBy = o.proposedBy;
        address makerToken = o.makerToken;
        uint256 makerAmount = o.makerAmount;
        address takerToken = o.takerToken;
        uint256 takerAmount = o.takerAmount;

        o.status = OfferStatus.Cancelled;

        if (proposedBy == o.maker) {
            IERC20(makerToken).safeTransfer(o.maker, makerAmount);
        } else {
            IERC20(takerToken).safeTransfer(o.taker, takerAmount);
        }

        emit OfferCancelled(offerId, caller, makerAmount, takerAmount);
    }

    /// @notice The non-proposing party accepts current terms and escrows their
    ///         side. Status transitions to Accepted, enabling settleOffer.
    ///         KYC-gated on the caller.
    /// @param offerId The offer to accept.
    /// @param att     KYC attestation authorising the caller for AcceptOffer on this offerId,
    ///                with paramsHash bound to keccak256(offerId, makerAmount, takerAmount).
    function acceptOffer(uint256 offerId, KycAttestation calldata att) external whenNotPaused nonReentrant {
        Offer storage o = _offers[offerId];
        if (o.id == 0) revert OfferNotFound(offerId);
        if (o.status != OfferStatus.Open && o.status != OfferStatus.Countered) revert OfferNotOpen(offerId);
        if (o.expireTs != 0 && block.timestamp > o.expireTs) revert OfferIsExpired(offerId);

        address caller = _msgSender();
        if (caller != o.maker && caller != o.taker) revert NotOfferParty(offerId);
        if (caller == o.proposedBy) revert AcceptorIsProposer(offerId);

        if (
            complianceRequired[Action.AcceptOffer]
                && att.paramsHash != keccak256(abi.encodePacked(offerId, o.makerAmount, o.takerAmount))
        ) {
            revert ParamsHashMismatch();
        }
        _consumeKyc(caller, Action.AcceptOffer, offerId, att);

        // Cache terms before state change so the event carries the agreed amounts.
        uint256 makerAmount = o.makerAmount;
        uint256 takerAmount = o.takerAmount;

        // Effects before interaction (CEI).
        o.status = OfferStatus.Accepted;

        // Escrow the accepting party's tokens. By Accepted, both sides are held.
        if (caller == o.taker) {
            IERC20(o.takerToken).safeTransferFrom(o.taker, address(this), takerAmount);
        } else {
            IERC20(o.makerToken).safeTransferFrom(o.maker, address(this), makerAmount);
        }

        emit OfferAccepted(offerId, caller, makerAmount, takerAmount);
    }

    /// @notice Operator settles an Accepted offer. Both parties must provide a
    ///         fresh Settle attestation.
    function settleOffer(uint256 offerId, KycAttestation calldata makerAtt, KycAttestation calldata takerAtt)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
    {
        Offer storage o = _offers[offerId];
        if (o.id == 0) revert OfferNotFound(offerId);
        if (o.status != OfferStatus.Accepted) revert OfferNotAccepted(offerId);

        // Verify both signatures before consuming either nonce.
        _verifyKyc(o.maker, Action.SettleOffer, offerId, makerAtt);
        _verifyKyc(o.taker, Action.SettleOffer, offerId, takerAtt);
        if (complianceRequired[Action.SettleOffer]) {
            bytes32 ph = keccak256(abi.encodePacked(offerId, o.makerAmount, o.takerAmount));
            if (makerAtt.paramsHash != ph) revert ParamsHashMismatch();
            if (takerAtt.paramsHash != ph) revert ParamsHashMismatch();
            usedNonce[o.maker][makerAtt.nonce] = true;
            emit KycConsumed(o.maker, Action.SettleOffer, offerId, makerAtt.nonce);
            usedNonce[o.taker][takerAtt.nonce] = true;
            emit KycConsumed(o.taker, Action.SettleOffer, offerId, takerAtt.nonce);
        }

        // Fees deducted from what each party receives at settlement.
        uint256 makerFeeAmount = FeeMath.feeAmount(o.takerAmount, o.makerFeeBps);
        uint256 takerFeeAmount = FeeMath.feeAmount(o.makerAmount, o.takerFeeBps);
        uint256 makerReceived = o.takerAmount - makerFeeAmount;
        uint256 takerReceived = o.makerAmount - takerFeeAmount;
        address collector = o.feeCollector;

        // Effects before transfers (CEI).
        o.status = OfferStatus.Settled;

        IERC20(o.takerToken).safeTransfer(o.maker, makerReceived);
        if (makerFeeAmount > 0) IERC20(o.takerToken).safeTransfer(collector, makerFeeAmount);
        IERC20(o.makerToken).safeTransfer(o.taker, takerReceived);
        if (takerFeeAmount > 0) IERC20(o.makerToken).safeTransfer(collector, takerFeeAmount);

        emit OfferSettled(
            offerId, _msgSender(), makerReceived, takerReceived, makerFeeAmount, takerFeeAmount, collector
        );
    }

    /// @notice Anyone can sweep a batch of expired offers, returning the current
    ///         proposer's escrowed tokens to them. Only Open/Countered offers with
    ///         a non-zero expireTs that has passed are swept; all other states are
    ///         silently skipped.
    ///         Callers should batch `ids` in chunks of at most 100 to avoid out-of-gas reverts.
    /// @param ids Offer IDs to sweep. Non-expired and non-Open/Countered entries
    ///            are silently skipped without reverting.
    function sweepExpiredOffers(uint256[] calldata ids) external nonReentrant {
        for (uint256 i = 0; i < ids.length; i++) {
            Offer storage o = _offers[ids[i]];
            if (o.status != OfferStatus.Open && o.status != OfferStatus.Countered) continue;
            if (o.expireTs == 0 || block.timestamp <= o.expireTs) continue;

            address proposedBy = o.proposedBy;
            address token;
            uint256 amount;
            if (proposedBy == o.maker) {
                token = o.makerToken;
                amount = o.makerAmount;
            } else {
                token = o.takerToken;
                amount = o.takerAmount;
            }

            o.status = OfferStatus.Expired;

            IERC20(token).safeTransfer(proposedBy, amount);
            emit OfferExpired(ids[i], proposedBy, amount);
        }
    }

    // --------------------------------------------------------------------- //
    //                                 Views                                  //
    // --------------------------------------------------------------------- //

    function getOffer(uint256 id) external view returns (Offer memory) {
        return _offers[id];
    }
}
