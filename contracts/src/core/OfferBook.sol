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
///         and accept — acceptance settles atomically in the same call, no
///         separate operator step (AC-246). Plus permissionless sweep of
///         expired offers.
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
        address feeCollector,
        address feeToken
    );
    event OfferReplaced(
        uint256 indexed id, address indexed by, uint256 newMakerAmount, uint256 newTakerAmount, uint64 expireTs
    );
    event OfferCancelled(uint256 indexed id, address indexed by, uint256 makerAmount, uint256 takerAmount);
    /// @dev `amountReturned` includes the proposer's unconsumed escrowed fee (AC-833).
    event OfferExpired(uint256 indexed id, address indexed proposedBy, uint256 amountReturned);
    event OfferAccepted(uint256 indexed id, address indexed by, uint256 makerAmount, uint256 takerAmount);
    /// @dev Amounts are GROSS (AC-833) — the agreed leg amounts, before either fee.
    ///      Both fees are denominated in `feeToken`, so net received is simply
    ///      `makerAmountGross − makerFeeAmount` / `takerAmountGross − takerFeeAmount`
    ///      on whichever leg is the currency; the asset leg moves gross and untouched.
    event OfferSettled(
        uint256 indexed id,
        address indexed by,
        uint256 makerAmountGross,
        uint256 takerAmountGross,
        uint256 makerFeeAmount,
        uint256 takerFeeAmount,
        address feeCollector,
        address feeToken
    );

    error NotOfferParty(uint256 id);
    error OfferSelfTarget();
    error AcceptorIsProposer(uint256 id);
    error OfferIsExpired(uint256 id);
    /// @dev An offer made before the AC-833 upgrade carries no settlement currency, so
    ///      its fees cannot be denominated. Unwind paths still work; accept does not.
    error LegacyOfferMustBeUnwound(uint256 id);

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

        _bindParamsHash(
            uint8(Action.MakeOffer),
            att,
            feeAtt,
            keccak256(abi.encodePacked(taker, makerToken, makerAmount, takerToken, takerAmount))
        );
        _validateFees(feeAtt, makerToken, takerToken);
        _consumeKycAndFee(maker, uint8(Action.MakeOffer), 0, att, feeAtt);

        id = _storeOffer(maker, taker, makerToken, makerAmount, takerToken, takerAmount, expireTs, feeAtt);
        // The maker escrows their leg, plus their own fee when that leg is the
        // settlement currency — they are then the currency payer (AC-833).
        uint256 escrowedFee = _proposerFee(makerToken, makerAmount, feeAtt.feeToken, feeAtt.makerFeeBps);
        IERC20(makerToken).safeTransferFrom(maker, address(this), makerAmount + escrowedFee);
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
            feeAtt.feeCollector,
            feeAtt.feeToken
        );
    }

    /// @dev The fee a proposer must escrow alongside their leg: non-zero only when the
    ///      leg they are escrowing IS the settlement currency, making them the currency
    ///      payer. When they escrow the asset, it moves gross and they owe nothing extra.
    function _proposerFee(address proposerToken, uint256 proposerAmount, address feeToken, uint16 bps)
        internal
        pure
        returns (uint256)
    {
        if (proposerToken != feeToken) return 0;
        return FeeMath.feeAmount(proposerAmount, bps);
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
            feeCollector: feeAtt.feeCollector,
            feeToken: feeAtt.feeToken,
            escrowedFee: _proposerFee(makerToken, makerAmount, feeAtt.feeToken, feeAtt.makerFeeBps)
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
        // A pre-AC-833 offer can only be unwound, never re-proposed — countering it
        // would keep an unacceptable offer alive indefinitely.
        if (o.feeToken == address(0)) revert LegacyOfferMustBeUnwound(offerId);
        if (o.expireTs != 0 && block.timestamp > o.expireTs) revert OfferIsExpired(offerId);
        if (newMakerAmount == 0 || newTakerAmount == 0) revert ZeroAmount();
        if (expireTs != 0 && expireTs <= block.timestamp) revert InvalidExpiry();

        address caller = _msgSender();
        if (caller != o.maker && caller != o.taker) revert NotOfferParty(offerId);

        if (
            complianceRequired(uint8(Action.ReplaceOffer))
                && att.paramsHash != keccak256(abi.encodePacked(offerId, newMakerAmount, newTakerAmount))
        ) {
            revert ParamsHashMismatch();
        }
        _consumeKyc(caller, uint8(Action.ReplaceOffer), offerId, att);

        // Cache before state changes (CEI).
        address prevProposedBy = o.proposedBy;
        address prevMakerToken = o.makerToken;
        uint256 prevMakerAmount = o.makerAmount;
        address prevTakerToken = o.takerToken;
        uint256 prevTakerAmount = o.takerAmount;
        // BOTH halves of the swap carry a fee (AC-833): the outgoing proposer gets their
        // unconsumed escrowed fee back, and the incoming one escrows a fee recomputed on
        // the NEW amounts — which may be a different party, side and token than before.
        uint256 prevEscrowedFee = o.escrowedFee;
        bool callerIsMaker = (caller == o.maker);
        uint256 newEscrowedFee = callerIsMaker
            ? _proposerFee(o.makerToken, newMakerAmount, o.feeToken, o.makerFeeBps)
            : _proposerFee(o.takerToken, newTakerAmount, o.feeToken, o.takerFeeBps);

        // Effects.
        o.makerAmount = newMakerAmount;
        o.takerAmount = newTakerAmount;
        o.expireTs = expireTs;
        o.proposedBy = caller;
        o.status = OfferStatus.Countered;
        o.escrowedFee = newEscrowedFee;

        // Return previous proposer's escrow — their leg plus their escrowed fee.
        if (prevProposedBy == o.maker) {
            IERC20(prevMakerToken).safeTransfer(o.maker, prevMakerAmount + prevEscrowedFee);
        } else {
            IERC20(prevTakerToken).safeTransfer(o.taker, prevTakerAmount + prevEscrowedFee);
        }

        // Escrow caller's side at the new amounts, plus their own fee if it's the currency.
        if (callerIsMaker) {
            IERC20(o.makerToken).safeTransferFrom(o.maker, address(this), newMakerAmount + newEscrowedFee);
        } else {
            IERC20(o.takerToken).safeTransferFrom(o.taker, address(this), newTakerAmount + newEscrowedFee);
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
            complianceRequired(uint8(Action.CancelOffer))
                && att.paramsHash != keccak256(abi.encodePacked(offerId, o.makerAmount, o.takerAmount))
        ) {
            revert ParamsHashMismatch();
        }
        _consumeKyc(caller, uint8(Action.CancelOffer), offerId, att);

        // Cache before state changes (CEI).
        address proposedBy = o.proposedBy;
        address makerToken = o.makerToken;
        uint256 makerAmount = o.makerAmount;
        address takerToken = o.takerToken;
        uint256 takerAmount = o.takerAmount;
        uint256 escrowedFee = o.escrowedFee;

        o.status = OfferStatus.Cancelled;
        o.escrowedFee = 0;

        // The proposer's escrowed fee rides back with their leg (AC-833), so cancelling
        // an untouched offer returns them to their exact starting balance.
        if (proposedBy == o.maker) {
            IERC20(makerToken).safeTransfer(o.maker, makerAmount + escrowedFee);
        } else {
            IERC20(takerToken).safeTransfer(o.taker, takerAmount + escrowedFee);
        }

        emit OfferCancelled(offerId, caller, makerAmount, takerAmount);
    }

    /// @notice The non-proposing party accepts current terms. Settlement is
    ///         atomic with acceptance — no separate operator step: the caller's
    ///         side is escrowed and both sides are released to their
    ///         counterparties (fees deducted) in the same transaction. Status
    ///         goes straight to Settled; `Accepted` is never a persisted state.
    ///         KYC-gated on the caller.
    /// @param offerId The offer to accept and settle.
    /// @param att     KYC attestation authorising the caller for AcceptOffer on this offerId,
    ///                with paramsHash bound to keccak256(offerId, makerAmount, takerAmount).
    function acceptOffer(uint256 offerId, KycAttestation calldata att) external whenNotPaused nonReentrant {
        Offer storage o = _offers[offerId];
        if (o.id == 0) revert OfferNotFound(offerId);
        if (o.status != OfferStatus.Open && o.status != OfferStatus.Countered) revert OfferNotOpen(offerId);
        if (o.feeToken == address(0)) revert LegacyOfferMustBeUnwound(offerId);
        if (o.expireTs != 0 && block.timestamp > o.expireTs) revert OfferIsExpired(offerId);

        address caller = _msgSender();
        if (caller != o.maker && caller != o.taker) revert NotOfferParty(offerId);
        if (caller == o.proposedBy) revert AcceptorIsProposer(offerId);

        if (
            complianceRequired(uint8(Action.AcceptOffer))
                && att.paramsHash != keccak256(abi.encodePacked(offerId, o.makerAmount, o.takerAmount))
        ) {
            revert ParamsHashMismatch();
        }
        _consumeKyc(caller, uint8(Action.AcceptOffer), offerId, att);

        emit OfferAccepted(offerId, caller, o.makerAmount, o.takerAmount);
        _settleOffer(o, offerId, caller);
    }

    /// @dev Atomic offer settlement under the AC-833 fee model. Exactly one leg is the
    ///      settlement currency `feeToken`; BOTH fees are denominated in it. The party
    ///      PAYING currency pays `cAmount + their own fee`, the party RECEIVING currency
    ///      gets `cAmount − their own fee`, and the asset leg moves gross.
    ///
    ///      The books balance exactly without any extra escrow from the asset side: the
    ///      currency receiver's own fee cancels out —
    ///      `(cAmount − receiverFee) + (makerFee + takerFee) == cAmount + payerFee`.
    ///
    ///      Split out of `acceptOffer` to keep the stack shallow.
    function _settleOffer(Offer storage o, uint256 offerId, address caller) private {
        address maker = o.maker;
        address taker = o.taker;
        address makerToken = o.makerToken;
        address takerToken = o.takerToken;
        uint256 makerAmount = o.makerAmount;
        uint256 takerAmount = o.takerAmount;
        address collector = o.feeCollector;

        // Which leg is money? That decides who pays and who receives, not maker/taker.
        bool makerLegIsCurrency = (makerToken == o.feeToken);
        uint256 cAmount = makerLegIsCurrency ? makerAmount : takerAmount;

        uint256 makerFeeAmount = FeeMath.feeAmount(cAmount, o.makerFeeBps);
        uint256 takerFeeAmount = FeeMath.feeAmount(cAmount, o.takerFeeBps);
        uint256 collectorTake = makerFeeAmount + takerFeeAmount;

        // Effects before interactions (CEI). The proposer's escrow is fully consumed
        // here — offers are all-or-nothing, so there is no remainder to carry.
        o.status = OfferStatus.Settled;
        o.escrowedFee = 0;

        // The accepting party brings in their leg — plus their OWN fee if that leg is
        // the currency. The other side is already escrowed from makeOffer/replaceOffer.
        if (caller == taker) {
            IERC20(takerToken)
                .safeTransferFrom(taker, address(this), takerAmount + (makerLegIsCurrency ? 0 : takerFeeAmount));
        } else {
            IERC20(makerToken)
                .safeTransferFrom(maker, address(this), makerAmount + (makerLegIsCurrency ? makerFeeAmount : 0));
        }

        // Release: currency net to its receiver, both fees to the collector, asset gross.
        if (makerLegIsCurrency) {
            IERC20(takerToken).safeTransfer(maker, takerAmount); // asset, gross
            IERC20(makerToken).safeTransfer(taker, cAmount - takerFeeAmount); // currency, net
            if (collectorTake > 0) IERC20(makerToken).safeTransfer(collector, collectorTake);
        } else {
            IERC20(takerToken).safeTransfer(maker, cAmount - makerFeeAmount); // currency, net
            if (collectorTake > 0) IERC20(takerToken).safeTransfer(collector, collectorTake);
            IERC20(makerToken).safeTransfer(taker, makerAmount); // asset, gross
        }

        emit OfferSettled(
            offerId, caller, makerAmount, takerAmount, makerFeeAmount, takerFeeAmount, collector, o.feeToken
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
            // Unconsumed escrowed fee goes back with the leg it was escrowed against.
            amount += o.escrowedFee;

            o.status = OfferStatus.Expired;
            o.escrowedFee = 0;

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
