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
        address feeToken,
        uint256 orderId
    );
    event OfferReplaced(
        uint256 indexed id, address indexed by, uint256 newMakerAmount, uint256 newTakerAmount, uint64 expireTs
    );
    event OfferCancelled(uint256 indexed id, address indexed by, uint256 makerAmount, uint256 takerAmount);
    /// @dev `amountReturned` includes the proposer's unconsumed escrowed fee (AC-833).
    event OfferExpired(uint256 indexed id, address indexed proposedBy, uint256 amountReturned);
    /// @dev `orderId` is the order this offer was raised against, or 0 for a standalone
    ///      offer (AO-746). It is carried on the settlement event, not only on `OfferMade`,
    ///      so a consumer projecting a single log can attribute the trade to its order
    ///      without holding the whole offer history.
    event OfferAccepted(
        uint256 indexed id, address indexed by, uint256 makerAmount, uint256 takerAmount, uint256 orderId
    );

    /// @notice An offer funded a leg out of the order it was raised against (AO-746).
    /// @param drawn             Moved OUT of the order's escrow to fund the leg. The tokens never
    ///                          leave the venue — an order's `remainingQuantity` and an offer's
    ///                          escrowed leg are two claims on one pooled balance — so this is an
    ///                          accounting move, not a transfer.
    /// @param remainingQuantity The order's remaining quantity AFTER the draw.
    event OrderEscrowDrawn(uint256 indexed orderId, uint256 indexed offerId, uint256 drawn, uint256 remainingQuantity);

    /// @notice An accepted offer consumed the order it was raised against, which is now `Filled`
    ///         and no longer fillable by anyone else (AO-746).
    /// @param refunded Everything the order still held, returned to its maker, in `sellToken`:
    ///                 the unspent quantity plus the escrowed fee no fill ever earned. The
    ///                 quantity is non-zero when the offer met the order's whole buy side at a
    ///                 better price than it listed, which leaves change (AO-746).
    event OrderClosedByOffer(uint256 indexed orderId, uint256 indexed offerId, uint256 refunded);
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
    /// @dev The named order is not owned by a party to this offer, or does not trade the
    ///      token either leg of this offer trades. Either way its escrow can never fund
    ///      this offer, so the link would be a label rather than a linkage (AO-746).
    error OrderNotLinkable(uint256 orderId);

    /// @notice Create a targeted offer. Maker escrows makerToken; only the
    ///         nominated taker can respond. KYC-gated on the maker.
    /// @param orderId The order this offer is raised against, or 0 for a standalone offer
    ///                (AO-746). When set, the order must still be `Open`, must be owned by
    ///                the maker or the taker of this offer, and must sell a token one of the
    ///                two legs trades — otherwise its escrow could never fund this offer.
    ///                Whichever party owns the order funds their leg FROM that order's escrow
    ///                rather than from their wallet, and accepting the offer closes the order
    ///                once its quantity is consumed.
    ///
    ///                ⚠️ `orderId` is deliberately NOT part of the attestation `paramsHash`.
    ///                That preimage is a frozen cross-repo vector reproduced independently by
    ///                AsseteraComplianceService and AsseteraMarketplaceAPI (see
    ///                `test/ParamsHashVectors.t.sol`), and extending it would revert every
    ///                offer until all three repos ship together. The escrow source is guarded
    ///                on chain instead: only the order's OWN maker can draw on it, and only
    ///                for the token it already holds, so a substituted `orderId` can move no
    ///                funds the caller did not already commit.
    /// @param att    KYC attestation authorising MakeOffer (no fee terms).
    /// @param feeAtt Fee attestation from the fee service, authorising the fee terms
    ///               snapshotted onto the offer. Bound to the same account/action/
    ///               paramsHash as `att` (see `_consumeKycAndFee`).
    function makeOffer(
        uint256 orderId,
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
        _requireLinkableOrder(orderId, maker, taker, makerToken, takerToken);

        _bindParamsHash(
            uint8(Action.MakeOffer),
            att,
            feeAtt,
            keccak256(abi.encodePacked(taker, makerToken, makerAmount, takerToken, takerAmount))
        );
        _validateFees(feeAtt, makerToken, takerToken);
        _consumeKycAndFee(maker, uint8(Action.MakeOffer), 0, att, feeAtt);

        id = _storeOffer(orderId, maker, taker, makerToken, makerAmount, takerToken, takerAmount, expireTs, feeAtt);
        // The maker escrows their leg, plus their own fee when that leg is the
        // settlement currency — they are then the currency payer (AC-833). When the
        // maker owns the linked order, the leg is already escrowed there (AO-746) and
        // only the shortfall and the fee come out of their wallet.
        _escrowLeg(
            orderId,
            id,
            maker,
            makerToken,
            makerAmount,
            _proposerFee(makerToken, makerAmount, feeAtt.feeToken, feeAtt.makerFeeBps)
        );
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
            feeAtt.feeToken,
            orderId
        );
    }

    /// @dev Reject a link that could never fund anything (AO-746). An order that no party to
    ///      the offer owns, or that sells a token neither leg trades, can never satisfy the draw
    ///      predicate in `_escrowLeg` — so accepting the link would record a relationship the
    ///      contract will not honour, and leave the named order Open forever.
    function _requireLinkableOrder(
        uint256 orderId,
        address maker,
        address taker,
        address makerToken,
        address takerToken
    ) private view {
        if (orderId == 0) return;
        Order storage ord = _orders[orderId];
        if (ord.status != OrderStatus.Open) revert OrderNotOpen(orderId);
        if (ord.maker != maker && ord.maker != taker) revert OrderNotLinkable(orderId);
        if (ord.sellToken != makerToken && ord.sellToken != takerToken) revert OrderNotLinkable(orderId);
    }

    /// @dev Escrow `amount` of `proposer`'s leg plus their `fee`, funding as much of the leg as
    ///      possible out of the linked order's escrow rather than their wallet (AO-746).
    ///
    ///      The venue holds ONE pooled balance per token: an order's `remainingQuantity` and an
    ///      offer's escrowed leg are two claims on it, never two piles. So a draw moves no
    ///      tokens — it only reassigns the claim, which is exactly why the maker no longer has
    ///      to fund both sides of their own negotiation.
    ///
    ///      Drawing is allowed only for the order's OWN maker and only for the token the order
    ///      already holds. Every other case escrows from the wallet as before, which covers the
    ///      counterparty proposing against someone else's listing, a standalone offer, and an
    ///      order already closed by a fill, a cancel or a sweep.
    ///
    ///      A negotiation larger than the listing draws what is there and takes the shortfall
    ///      from the wallet, so raising your price never becomes un-fundable.
    ///
    ///      The move is ONE-WAY: unwinding the offer pays the proposer's wallet rather than
    ///      restoring the listing. Restoring would have to decide what to do when the order has
    ///      since been cancelled or swept, and a listing that silently reappears is worse than
    ///      one the maker re-lists deliberately.
    function _escrowLeg(
        uint256 orderId,
        uint256 offerId,
        address proposer,
        address legToken,
        uint256 amount,
        uint256 fee
    ) private {
        uint256 drawn;
        if (orderId != 0) {
            Order storage ord = _orders[orderId];
            if (ord.status == OrderStatus.Open && ord.maker == proposer && ord.sellToken == legToken) {
                uint256 remaining = ord.remainingQuantity;
                drawn = remaining < amount ? remaining : amount;
                if (drawn != 0) {
                    unchecked {
                        remaining -= drawn;
                    }
                    ord.remainingQuantity = remaining;
                    emit OrderEscrowDrawn(orderId, offerId, drawn, remaining);
                }
            }
        }
        // The single point where a proposer's leg enters escrow. Whatever the order funded is
        // already inside the venue, so only the shortfall and the fee come out of their wallet.
        IERC20(legToken).safeTransferFrom(proposer, address(this), amount - drawn + fee);
    }

    /// @dev Close the linked order once an accepted offer has consumed it (AO-746). Leaves a
    ///      partially-consumed listing Open — negotiating three of ten does not retire the
    ///      other seven.
    ///
    ///      An order is consumed when EITHER side is exhausted, and both have to be checked:
    ///
    ///      * its BUY side is satisfied — it received everything it asked for. A negotiated
    ///        price is not the listed price, so an order that got its whole `buyAmount` more
    ///        cheaply still holds unspent `sellToken`. That leftover is CHANGE, not an unfilled
    ///        order, and leaving it listed puts the maker into a further trade they never
    ///        agreed to when they accepted the offer.
    ///      * or its SELL side is exhausted — nothing is left to pay with, whatever it bought.
    ///
    ///      `recvAmount` is the GROSS leg the order's maker receives from this settlement, in
    ///      `recvToken`; gross, because `buyAmount` is gross and `fillOrder` compares gross too.
    ///      A leg in some other token buys nothing for this order and is counted as zero.
    ///
    ///      Everything still escrowed goes back to the maker: the unspent quantity, plus the
    ///      escrowed fee no fill ever earned. The trade that happened ran under the OFFER's fee
    ///      terms, so none of it is owed to the collector.
    function _closeConsumedOrder(uint256 orderId, uint256 offerId, address recvToken, uint256 recvAmount) private {
        if (orderId == 0) return;
        Order storage ord = _orders[orderId];
        if (ord.status != OrderStatus.Open) return;

        uint256 bought = ord.boughtQuantity + (recvToken == ord.buyToken ? recvAmount : 0);
        ord.boughtQuantity = bought;
        if (bought < ord.buyAmount && ord.remainingQuantity != 0) return;

        uint256 refunded = ord.remainingQuantity + ord.escrowedFee;
        ord.status = OrderStatus.Filled;
        ord.remainingQuantity = 0;
        ord.escrowedFee = 0;
        if (refunded != 0) IERC20(ord.sellToken).safeTransfer(ord.maker, refunded);
        emit OrderClosedByOffer(orderId, offerId, refunded);
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
        uint256 orderId,
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
            escrowedFee: _proposerFee(makerToken, makerAmount, feeAtt.feeToken, feeAtt.makerFeeBps),
            orderId: orderId
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
        // A caller who owns the linked order funds their leg from it (AO-746), so countering
        // your own listing no longer needs a second copy of the asset in your wallet.
        _escrowLeg(
            o.orderId,
            offerId,
            caller,
            callerIsMaker ? o.makerToken : o.takerToken,
            callerIsMaker ? newMakerAmount : newTakerAmount,
            newEscrowedFee
        );

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

        emit OfferAccepted(offerId, caller, o.makerAmount, o.takerAmount, o.orderId);
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
        // An acceptor who owns the linked order brings their leg from it (AO-746).
        bool acceptorIsTaker = (caller == taker);
        _escrowLeg(
            o.orderId,
            offerId,
            caller,
            acceptorIsTaker ? takerToken : makerToken,
            acceptorIsTaker ? takerAmount : makerAmount,
            acceptorIsTaker ? (makerLegIsCurrency ? 0 : takerFeeAmount) : (makerLegIsCurrency ? makerFeeAmount : 0)
        );

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

        // The trade the order was listed for has now happened through the offer, so the order
        // must not stay Open and fillable by a third party (AO-746). Last, after every transfer
        // above, so a hostile token in the settlement path cannot re-enter a half-closed order.
        // The order's maker takes the OTHER party's leg, whichever side of the offer they are on.
        bool orderMakerIsOfferMaker = (_orders[o.orderId].maker == maker);
        _closeConsumedOrder(
            o.orderId,
            offerId,
            orderMakerIsOfferMaker ? takerToken : makerToken,
            orderMakerIsOfferMaker ? takerAmount : makerAmount
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
