// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AsseteraECS} from "../../src/AsseteraECS.sol";
import {ExchangeTypes} from "../../src/types/ExchangeTypes.sol";
import {FaucetToken} from "../mocks/FaucetToken.sol";

/// @notice Bounded-random driver for the I-2(b) escrow-conservation invariant
///         suite. KYC/fee gating is disabled on the target exchange (see
///         EscrowConservation.t.sol setUp) so every action here can use an
///         empty attestation — this handler exercises pure token-custody
///         accounting, not the attestation gate (which has its own dedicated
///         unit-test coverage elsewhere).
///
///         `expectedEscrowed` recomputes the "should hold" balance from
///         ground truth (iterating every order/offer this handler ever
///         created via the real `getOrder`/`getOffer` getters) rather than
///         mirroring the contract's internal arithmetic in a ghost variable —
///         so it actually exercises the contract's own accounting logic
///         instead of just replaying it.
contract EscrowHandler is Test {
    AsseteraECS public immutable exchange;
    FaucetToken public immutable tokenA;
    FaucetToken public immutable tokenB;

    address[3] internal actors;

    uint256[] public orderIds;
    uint256[] public offerIds;

    ExchangeTypes.KycAttestation internal EMPTY_KYC;
    ExchangeTypes.FeeAttestation internal EMPTY_FEE;

    /// @dev AC-833: tokenB is the settlement currency for every order/offer this handler
    ///      drives, and fees are NON-ZERO — otherwise the escrowed-fee path (which is the
    ///      whole reason the invariant had to change) would never be exercised. Attestation
    ///      signatures are still skipped: gating is off, so `_verifyFee` returns early while
    ///      `_validateFees` — which enforces the denomination — still runs.
    uint16 internal constant MAKER_BPS = 100; // 1 %
    uint16 internal constant TAKER_BPS = 50; // 0.5 %
    address public immutable collector;

    constructor(
        AsseteraECS exchange_,
        FaucetToken tokenA_,
        FaucetToken tokenB_,
        address[3] memory actors_,
        address collector_
    ) {
        exchange = exchange_;
        tokenA = tokenA_;
        tokenB = tokenB_;
        actors = actors_;
        collector = collector_;
        EMPTY_FEE.feeToken = address(tokenB_);
        EMPTY_FEE.makerFeeBps = MAKER_BPS;
        EMPTY_FEE.takerFeeBps = TAKER_BPS;
        EMPTY_FEE.feeCollector = collector_;
    }

    /// @dev What a maker/proposer must escrow on top of their leg: their own fee, but
    ///      only when the leg they escrow IS the settlement currency.
    function _ownFee(address token, uint256 amount, uint16 bps) internal view returns (uint256) {
        if (token != address(tokenB)) return 0;
        return (amount * bps) / 10_000;
    }

    // --------------------------------------------------------------------- //
    //                              actions                                   //
    // --------------------------------------------------------------------- //

    function placeOrder(
        uint256 makerSeed,
        bool sellIsA,
        uint256 sellAmount,
        uint256 buyAmount,
        bool withExpiry,
        uint256 expiryOffsetSeed
    ) external {
        address maker = actors[makerSeed % 3];
        sellAmount = bound(sellAmount, 1, 1_000e18);
        buyAmount = bound(buyAmount, 1, 1_000e18);
        FaucetToken sellToken = sellIsA ? tokenA : tokenB;
        FaucetToken buyToken = sellIsA ? tokenB : tokenA;
        uint64 expireTs = withExpiry ? uint64(block.timestamp + bound(expiryOffsetSeed, 1, 7 days)) : 0;

        uint256 escrow = sellAmount + _ownFee(address(sellToken), sellAmount, MAKER_BPS);
        vm.startPrank(maker);
        sellToken.mint(maker, escrow);
        sellToken.approve(address(exchange), escrow);
        try exchange.placeOrder(
            address(sellToken), sellAmount, address(buyToken), buyAmount, expireTs, EMPTY_KYC, EMPTY_FEE
        ) returns (
            uint256 id
        ) {
            orderIds.push(id);
        } catch {}
        vm.stopPrank();
    }

    function fillOrder(uint256 idSeed, uint256 takerSeed, uint256 fillSeed) external {
        if (orderIds.length == 0) return;
        ExchangeTypes.Order memory o = exchange.getOrder(orderIds[idSeed % orderIds.length]);
        if (o.status != ExchangeTypes.OrderStatus.Open) return;
        if (o.expireTs != 0 && block.timestamp > o.expireTs) return;

        address taker = actors[takerSeed % 3];
        if (taker == o.maker) taker = actors[(takerSeed + 1) % 3];
        if (taker == o.maker) return; // only 2 distinct actors somehow — skip

        uint256 fillAmt = bound(fillSeed, 1, o.remainingQuantity);
        uint256 buyAmountDue = (fillAmt * o.buyAmount + o.sellAmount - 1) / o.sellAmount; // ceil-div, mirrors FeeMath

        // AC-833: when the taker pays the currency leg they owe notional + their own fee.
        uint256 takerOutlay = buyAmountDue + _ownFee(o.buyToken, buyAmountDue, TAKER_BPS);
        FaucetToken buyToken = FaucetToken(o.buyToken);
        vm.startPrank(taker);
        buyToken.mint(taker, takerOutlay);
        buyToken.approve(address(exchange), takerOutlay);
        try exchange.fillOrder(o.id, fillAmt, EMPTY_KYC) {} catch {}
        vm.stopPrank();
    }

    function cancelOrder(uint256 idSeed) external {
        if (orderIds.length == 0) return;
        ExchangeTypes.Order memory o = exchange.getOrder(orderIds[idSeed % orderIds.length]);
        if (o.status != ExchangeTypes.OrderStatus.Open) return;
        vm.prank(o.maker);
        try exchange.cancelOrder(o.id) {} catch {}
    }

    function sweepExpired(uint256 idSeed) external {
        if (orderIds.length == 0) return;
        uint256[] memory ids = new uint256[](1);
        ids[0] = orderIds[idSeed % orderIds.length];
        try exchange.sweepExpired(ids) {} catch {}
    }

    function makeOffer(
        uint256 makerSeed,
        uint256 takerSeed,
        bool makerIsA,
        uint256 makerAmount,
        uint256 takerAmount,
        bool withExpiry,
        uint256 expiryOffsetSeed
    ) external {
        address maker = actors[makerSeed % 3];
        address taker = actors[takerSeed % 3];
        if (taker == maker) taker = actors[(takerSeed + 1) % 3];
        if (taker == maker) return;

        makerAmount = bound(makerAmount, 1, 1_000e18);
        takerAmount = bound(takerAmount, 1, 1_000e18);
        FaucetToken makerToken = makerIsA ? tokenA : tokenB;
        FaucetToken takerToken = makerIsA ? tokenB : tokenA;
        uint64 expireTs = withExpiry ? uint64(block.timestamp + bound(expiryOffsetSeed, 1, 7 days)) : 0;

        uint256 offerEscrow = makerAmount + _ownFee(address(makerToken), makerAmount, MAKER_BPS);
        vm.startPrank(maker);
        makerToken.mint(maker, offerEscrow);
        makerToken.approve(address(exchange), offerEscrow);
        try exchange.makeOffer(
            taker, address(makerToken), makerAmount, address(takerToken), takerAmount, expireTs, EMPTY_KYC, EMPTY_FEE
        ) returns (
            uint256 id
        ) {
            offerIds.push(id);
        } catch {}
        vm.stopPrank();
    }

    function replaceOffer(uint256 idSeed, uint256 callerSeed, uint256 newMakerAmount, uint256 newTakerAmount) external {
        if (offerIds.length == 0) return;
        ExchangeTypes.Offer memory o = exchange.getOffer(offerIds[idSeed % offerIds.length]);
        if (o.status != ExchangeTypes.OfferStatus.Open && o.status != ExchangeTypes.OfferStatus.Countered) return;
        if (o.expireTs != 0 && block.timestamp > o.expireTs) return;

        address caller = (callerSeed % 2 == 0) ? o.maker : o.taker;
        newMakerAmount = bound(newMakerAmount, 1, 1_000e18);
        newTakerAmount = bound(newTakerAmount, 1, 1_000e18);

        bool callerIsMaker = caller == o.maker;
        FaucetToken callerToken = FaucetToken(callerIsMaker ? o.makerToken : o.takerToken);
        uint256 callerAmount = callerIsMaker ? newMakerAmount : newTakerAmount;

        // The incoming proposer escrows their leg plus their OWN fee at the NEW amounts.
        uint256 callerEscrow =
            callerAmount + _ownFee(address(callerToken), callerAmount, callerIsMaker ? MAKER_BPS : TAKER_BPS);
        vm.startPrank(caller);
        callerToken.mint(caller, callerEscrow);
        callerToken.approve(address(exchange), callerEscrow);
        try exchange.replaceOffer(o.id, newMakerAmount, newTakerAmount, o.expireTs, EMPTY_KYC) {} catch {}
        vm.stopPrank();
    }

    function cancelOffer(uint256 idSeed, uint256 callerSeed) external {
        if (offerIds.length == 0) return;
        ExchangeTypes.Offer memory o = exchange.getOffer(offerIds[idSeed % offerIds.length]);
        if (o.status != ExchangeTypes.OfferStatus.Open && o.status != ExchangeTypes.OfferStatus.Countered) return;
        address caller = (callerSeed % 2 == 0) ? o.maker : o.taker;
        vm.prank(caller);
        try exchange.cancelOffer(o.id, EMPTY_KYC) {} catch {}
    }

    function acceptOffer(uint256 idSeed) external {
        if (offerIds.length == 0) return;
        ExchangeTypes.Offer memory o = exchange.getOffer(offerIds[idSeed % offerIds.length]);
        if (o.status != ExchangeTypes.OfferStatus.Open && o.status != ExchangeTypes.OfferStatus.Countered) return;
        if (o.expireTs != 0 && block.timestamp > o.expireTs) return;

        address caller = o.proposedBy == o.maker ? o.taker : o.maker; // must not be the proposer
        bool callerIsTaker = caller == o.taker;
        FaucetToken callerToken = FaucetToken(callerIsTaker ? o.takerToken : o.makerToken);
        uint256 callerAmount = callerIsTaker ? o.takerAmount : o.makerAmount;

        // The acceptor brings their leg plus their own fee when that leg is the currency.
        uint256 acceptorOutlay =
            callerAmount + _ownFee(address(callerToken), callerAmount, callerIsTaker ? TAKER_BPS : MAKER_BPS);
        vm.startPrank(caller);
        callerToken.mint(caller, acceptorOutlay);
        callerToken.approve(address(exchange), acceptorOutlay);
        try exchange.acceptOffer(o.id, EMPTY_KYC) {} catch {}
        vm.stopPrank();
    }

    function sweepExpiredOffers(uint256 idSeed) external {
        if (offerIds.length == 0) return;
        uint256[] memory ids = new uint256[](1);
        ids[0] = offerIds[idSeed % offerIds.length];
        try exchange.sweepExpiredOffers(ids) {} catch {}
    }

    function warp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 3 days));
    }

    // --------------------------------------------------------------------- //
    //                        ground-truth invariant                          //
    // --------------------------------------------------------------------- //

    /// @notice Independently recomputes "how much of `token` the exchange
    ///         should be holding right now" by summing every still-escrowed
    ///         order/offer this handler ever created, read fresh via the
    ///         real getters — not a ghost counter mirroring the contract's
    ///         own bookkeeping.
    ///
    ///         AC-833: escrow is no longer just the traded leg. A maker/proposer
    ///         who escrows the SETTLEMENT CURRENCY also escrows their own fee,
    ///         held as `escrowedFee` in the same token, and owed back to them on
    ///         every unwind path. Omitting it here would make the invariant pass
    ///         while the contract silently retained (or under-refunded) the fee —
    ///         precisely the failure this suite exists to rule out.
    function expectedEscrowed(address token) external view returns (uint256 total) {
        for (uint256 i = 0; i < orderIds.length; i++) {
            ExchangeTypes.Order memory o = exchange.getOrder(orderIds[i]);
            if (o.status == ExchangeTypes.OrderStatus.Open && o.sellToken == token) {
                total += o.remainingQuantity + o.escrowedFee;
            }
        }
        for (uint256 i = 0; i < offerIds.length; i++) {
            ExchangeTypes.Offer memory o = exchange.getOffer(offerIds[i]);
            if (o.status == ExchangeTypes.OfferStatus.Open || o.status == ExchangeTypes.OfferStatus.Countered) {
                // escrowedFee is denominated in feeToken, which is the proposer's own
                // leg whenever it is non-zero — so it always rides with that leg.
                if (o.proposedBy == o.maker) {
                    if (o.makerToken == token) total += o.makerAmount + o.escrowedFee;
                } else {
                    if (o.takerToken == token) total += o.takerAmount + o.escrowedFee;
                }
            }
        }
    }
}
