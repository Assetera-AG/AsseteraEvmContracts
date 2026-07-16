// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AsseteraExchange} from "../../src/AsseteraExchange.sol";
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
    AsseteraExchange public immutable exchange;
    FaucetToken public immutable tokenA;
    FaucetToken public immutable tokenB;

    address[3] internal actors;

    uint256[] public orderIds;
    uint256[] public offerIds;

    ExchangeTypes.KycAttestation internal EMPTY_KYC;
    ExchangeTypes.FeeAttestation internal EMPTY_FEE;

    constructor(AsseteraExchange exchange_, FaucetToken tokenA_, FaucetToken tokenB_, address[3] memory actors_) {
        exchange = exchange_;
        tokenA = tokenA_;
        tokenB = tokenB_;
        actors = actors_;
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

        vm.startPrank(maker);
        sellToken.mint(maker, sellAmount);
        sellToken.approve(address(exchange), sellAmount);
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

        FaucetToken buyToken = FaucetToken(o.buyToken);
        vm.startPrank(taker);
        buyToken.mint(taker, buyAmountDue);
        buyToken.approve(address(exchange), buyAmountDue);
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

        vm.startPrank(maker);
        makerToken.mint(maker, makerAmount);
        makerToken.approve(address(exchange), makerAmount);
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

        vm.startPrank(caller);
        callerToken.mint(caller, callerAmount);
        callerToken.approve(address(exchange), callerAmount);
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

        vm.startPrank(caller);
        callerToken.mint(caller, callerAmount);
        callerToken.approve(address(exchange), callerAmount);
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
    function expectedEscrowed(address token) external view returns (uint256 total) {
        for (uint256 i = 0; i < orderIds.length; i++) {
            ExchangeTypes.Order memory o = exchange.getOrder(orderIds[i]);
            if (o.status == ExchangeTypes.OrderStatus.Open && o.sellToken == token) {
                total += o.remainingQuantity;
            }
        }
        for (uint256 i = 0; i < offerIds.length; i++) {
            ExchangeTypes.Offer memory o = exchange.getOffer(offerIds[i]);
            if (o.status == ExchangeTypes.OfferStatus.Open || o.status == ExchangeTypes.OfferStatus.Countered) {
                if (o.proposedBy == o.maker) {
                    if (o.makerToken == token) total += o.makerAmount;
                } else {
                    if (o.takerToken == token) total += o.takerAmount;
                }
            }
        }
    }
}
