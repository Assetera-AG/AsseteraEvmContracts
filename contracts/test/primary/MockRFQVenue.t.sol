// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GateTypes} from "../../src/types/GateTypes.sol";
import {PrimaryTypes} from "../../src/primary/types/PrimaryTypes.sol";
import {ISettler} from "../../src/primary/interfaces/ISettler.sol";
import {FaucetToken} from "../mocks/FaucetToken.sol";
import {MockRFQVenue} from "../mocks/MockRFQVenue.sol";
import {VenueRedeemerTestBase} from "./VenueRedeemerTestBase.sol";

/// @title MockRFQVenueTest
/// @notice The mock RFQ venue, driven through the REAL router on BOTH legs. The point is not the
///         fixture: it is that `AsseteraPrimarySales` can buy and sell against an issuer-agnostic
///         testnet venue with no router change, and that every way a quote can be wrong is
///         refused rather than settled at a surprising price.
///
/// @dev    It extends `VenueRedeemerTestBase` (and therefore `VenueSettlerTestBase`), so the
///         router, the two real ERC-20s and every signing helper are the ones the production
///         suites use. The venue is the only new fixture.
contract MockRFQVenueTest is VenueRedeemerTestBase {
    MockRFQVenue internal rfq;
    /// A second asset the venue has never heard of at construction time, to prove the quote —
    /// not the deployment — decides which token an asset is.
    FaucetToken internal aapl;

    uint256 internal quoteSignerPk = 0x0F0F;
    address internal quoteSigner;

    uint8 internal constant BUY = 0;
    uint8 internal constant SELL = 1;

    bytes32 internal constant BUY_QUOTE_ID = keccak256("rfq:buy:1");
    bytes32 internal constant SELL_QUOTE_ID = keccak256("rfq:sell:1");

    /// Restated here rather than read from the contract, so the digest this suite signs is derived
    /// independently of the code under test. `test_Quote_HashMatchesAnIndependentlyBuiltDigest`
    /// proves the two agree.
    string internal constant QUOTE_TYPE_STRING =
        "Quote(uint8 side,address paymentToken,uint256 paymentAmount,address assetToken,uint256 assetAmount,address recipient,bytes32 quoteId,uint256 expiry)";

    function setUp() public override {
        super.setUp();

        quoteSigner = vm.addr(quoteSignerPk);
        rfq = new MockRFQVenue(quoteSigner);
        aapl = new FaucetToken("Mock Apple", "mAAPL", 18);
    }

    // ── fixtures ──────────────────────────────────────────────────────────────────────────

    function _quote(
        uint8 side,
        address paymentToken,
        uint256 paymentAmount,
        address assetToken,
        uint256 assetAmount,
        address recipient,
        bytes32 quoteId,
        uint256 expiry
    ) internal pure returns (MockRFQVenue.Quote memory) {
        return MockRFQVenue.Quote({
            side: side,
            paymentToken: paymentToken,
            paymentAmount: paymentAmount,
            assetToken: assetToken,
            assetAmount: assetAmount,
            recipient: recipient,
            quoteId: quoteId,
            expiry: expiry
        });
    }

    function _signQuote(MockRFQVenue.Quote memory quote) internal view returns (bytes memory) {
        return _signQuoteWith(quoteSignerPk, quote);
    }

    function _signQuoteWith(uint256 pk, MockRFQVenue.Quote memory quote) internal view returns (bytes memory) {
        return _sign(pk, rfq.hashQuote(quote));
    }

    /// A settlement intent over the mock venue. The base's `_venueIntent` hardcodes the Dinari
    /// fixture, so the venue and selector are overwritten here; everything else is the real
    /// intent the production suites submit.
    function _buyIntent(bytes memory venueCalldata, uint256 quoteIn, uint256 minOut)
        internal
        view
        returns (PrimaryTypes.SettlementIntent memory intent)
    {
        intent = _venueIntent(venueCalldata, quoteIn, FEE, collector);
        intent.venue = address(rfq);
        intent.selector = MockRFQVenue.buy.selector;
        intent.minAssetOut = minOut;
    }

    function _buyHappyPath() internal view returns (bytes memory data, PrimaryTypes.SettlementIntent memory intent) {
        MockRFQVenue.Quote memory quote = _quote(
            BUY, address(currency), QUOTE, address(asset), ASSET_OUT, buyer, BUY_QUOTE_ID, block.timestamp + 5 minutes
        );
        data = abi.encodeCall(MockRFQVenue.buy, (quote, _signQuote(quote)));
        intent = _buyIntent(data, QUOTE, ASSET_OUT);
    }

    function _rfqSellHappyPath()
        internal
        view
        returns (bytes memory data, PrimaryTypes.RedemptionIntent memory intent)
    {
        MockRFQVenue.Quote memory quote = _quote(
            SELL,
            address(currency),
            PROCEEDS,
            address(asset),
            SELL_ASSET,
            address(router),
            SELL_QUOTE_ID,
            block.timestamp + 5 minutes
        );
        data = abi.encodeCall(MockRFQVenue.sell, (quote, _signQuote(quote)));
        intent = _sellIntent(data, address(rfq), MockRFQVenue.sell.selector, SELL_ASSET, PROCEEDS, SELL_FEE, NET_OUT);
    }

    // ── BUY through the router ───────────────────────────────────────────────────────────

    /// 🔴 The headline buy: the buyer pays the quote plus our fee, the venue takes exactly the
    /// quote, the asset is minted straight to the buyer, and the router keeps nothing.
    function test_Buy_SettlesThroughTheRouterAndDeliversToTheBuyer() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _buyHappyPath();
        uint256 buyerCurrencyBefore = currency.balanceOf(buyer);
        uint256 buyerAssetBefore = asset.balanceOf(buyer);

        _settleVenueWith(data, intent, TAKER_BPS);

        assertEq(currency.balanceOf(buyer), buyerCurrencyBefore - QUOTE - FEE, "buyer debited quote plus fee");
        assertEq(currency.balanceOf(address(rfq)), QUOTE, "the venue took the quote");
        assertEq(currency.balanceOf(collector), FEE, "the collector took the fee");
        assertEq(
            asset.balanceOf(buyer), buyerAssetBefore + ASSET_OUT, "the asset went to the buyer the router measures"
        );
        assertEq(asset.balanceOf(address(router)), 0, "the router never holds the asset");
        assertEq(currency.balanceOf(address(router)), 0, "the router never holds the currency");
        assertTrue(rfq.quoteUsed(BUY_QUOTE_ID), "the quote id was consumed");
    }

    /// The venue is issuer-agnostic: the same deployment fills a quote for an asset that did not
    /// exist when it was constructed.
    function test_Buy_DeliversWhicheverAssetTheQuoteNames() public {
        MockRFQVenue.Quote memory quote = _quote(
            BUY,
            address(currency),
            QUOTE,
            address(aapl),
            7e18,
            buyer,
            keccak256("rfq:buy:aapl"),
            block.timestamp + 5 minutes
        );
        bytes memory data = abi.encodeCall(MockRFQVenue.buy, (quote, _signQuote(quote)));
        PrimaryTypes.SettlementIntent memory intent = _buyIntent(data, QUOTE, 7e18);
        intent.assetToken = address(aapl);

        uint256 eqBefore = asset.balanceOf(buyer);
        _settleVenueWith(data, intent, TAKER_BPS);

        assertEq(aapl.balanceOf(buyer), 7e18, "the quoted asset was minted");
        assertEq(asset.balanceOf(buyer), eqBefore, "an unrelated asset was not touched");
    }

    /// A quote the provider did not sign is refused. The router collapses the venue's revert, so
    /// the outer error is `VenueCallFailed`; the named venue error is asserted directly below.
    function test_Buy_RevertsWhenTheQuoteIsSignedByAnotherKey() public {
        MockRFQVenue.Quote memory quote = _quote(
            BUY, address(currency), QUOTE, address(asset), ASSET_OUT, buyer, BUY_QUOTE_ID, block.timestamp + 5 minutes
        );
        bytes memory data = abi.encodeCall(MockRFQVenue.buy, (quote, _signQuoteWith(0xBADBAD, quote)));
        PrimaryTypes.SettlementIntent memory intent = _buyIntent(data, QUOTE, ASSET_OUT);

        _approveExact(intent);
        vm.expectRevert(ISettler.VenueCallFailed.selector);
        _submit(data, intent, TAKER_BPS);
    }

    /// An expired quote is refused. The expiry is inclusive, so `block.timestamp - 1` is stale.
    function test_Buy_RevertsWhenTheQuoteHasExpired() public {
        MockRFQVenue.Quote memory quote =
            _quote(BUY, address(currency), QUOTE, address(asset), ASSET_OUT, buyer, BUY_QUOTE_ID, block.timestamp - 1);
        bytes memory data = abi.encodeCall(MockRFQVenue.buy, (quote, _signQuote(quote)));
        PrimaryTypes.SettlementIntent memory intent = _buyIntent(data, QUOTE, ASSET_OUT);

        _approveExact(intent);
        vm.expectRevert(ISettler.VenueCallFailed.selector);
        _submit(data, intent, TAKER_BPS);
    }

    /// 🔴 A filled quote id cannot be filled again, even by a second, entirely valid settlement
    /// with fresh nonces. The router's own nonce namespace does not protect the venue's quote id;
    /// this is the venue's own replay guard doing it.
    function test_Buy_RevertsWhenTheQuoteIdWasAlreadyUsed() public {
        (bytes memory firstData, PrimaryTypes.SettlementIntent memory first) = _buyHappyPath();
        _settleVenueWith(firstData, first, TAKER_BPS);

        // A new intent over the SAME calldata: the router accepts it (new nonces, new signatures)
        // and the venue refuses it because the quote id is spent.
        PrimaryTypes.SettlementIntent memory second = _buyIntent(firstData, QUOTE, ASSET_OUT);
        second.nonce = INTENT_NONCE + 1;
        _approveExact(second);

        vm.expectRevert(ISettler.VenueCallFailed.selector);
        _submitSecondSettlement(firstData, second);

        assertTrue(rfq.quoteUsed(BUY_QUOTE_ID), "the id is still the one that was consumed");
    }

    /// The router judges delivery on the delta it measured, so a quote that mints less than the
    /// buyer signed for is a revert, not a cheap fill.
    function test_Buy_RevertsWhenTheVenueDeliversLessThanTheFloor() public {
        MockRFQVenue.Quote memory quote = _quote(
            BUY,
            address(currency),
            QUOTE,
            address(asset),
            MIN_OUT - 1e18,
            buyer,
            BUY_QUOTE_ID,
            block.timestamp + 5 minutes
        );
        bytes memory data = abi.encodeCall(MockRFQVenue.buy, (quote, _signQuote(quote)));
        PrimaryTypes.SettlementIntent memory intent = _buyIntent(data, QUOTE, MIN_OUT);

        _approveExact(intent);
        vm.expectRevert(abi.encodeWithSelector(ISettler.InsufficientAssetDelivered.selector, MIN_OUT - 1e18, MIN_OUT));
        _submit(data, intent, TAKER_BPS);
    }

    /// The venue consumes less than the intent quoted. That is a normal fill, and the router's
    /// measured delta — not the quoted number — decides what the buyer actually paid. This is the
    /// buy-side amount mismatch the router is designed to absorb.
    function test_Buy_RefundsWhatTheQuoteDidNotConsume() public {
        MockRFQVenue.Quote memory quote = _quote(
            BUY, address(currency), 900e6, address(asset), ASSET_OUT, buyer, BUY_QUOTE_ID, block.timestamp + 5 minutes
        );
        bytes memory data = abi.encodeCall(MockRFQVenue.buy, (quote, _signQuote(quote)));
        PrimaryTypes.SettlementIntent memory intent = _buyIntent(data, QUOTE, ASSET_OUT);
        uint256 buyerBefore = currency.balanceOf(buyer);

        _settleVenueWith(data, intent, TAKER_BPS);

        assertEq(currency.balanceOf(address(rfq)), 900e6, "the venue took only its quote");
        assertEq(currency.balanceOf(buyer), buyerBefore - 900e6 - FEE, "the buyer paid the fill plus the fee");
        assertEq(currency.balanceOf(address(router)), 0, "the unconsumed quote was not left in the router");
    }

    /// The other direction: a quote that asks for more than the router approved cannot be filled.
    /// The router approves exactly `venueQuoteIn`, so the venue's pull runs out of allowance and
    /// the settlement is refused rather than paying more than the buyer signed for.
    function test_Buy_RevertsWhenTheQuoteAsksForMoreThanTheRouterApproved() public {
        MockRFQVenue.Quote memory quote = _quote(
            BUY,
            address(currency),
            QUOTE + 1,
            address(asset),
            ASSET_OUT,
            buyer,
            BUY_QUOTE_ID,
            block.timestamp + 5 minutes
        );
        bytes memory data = abi.encodeCall(MockRFQVenue.buy, (quote, _signQuote(quote)));
        PrimaryTypes.SettlementIntent memory intent = _buyIntent(data, QUOTE, ASSET_OUT);

        _approveExact(intent);
        vm.expectRevert(ISettler.VenueCallFailed.selector);
        _submit(data, intent, TAKER_BPS);
    }

    // ── SELL through the router ──────────────────────────────────────────────────────────

    /// 🔴 The headline sell: the seller gives up the asset, the venue keeps it (there is no burn),
    /// the venue mints the proceeds to the ROUTER, and the router pays the seller net of the fee.
    function test_Sell_SettlesThroughTheRouterAndPaysTheSeller() public {
        (bytes memory data, PrimaryTypes.RedemptionIntent memory intent) = _rfqSellHappyPath();
        uint256 sellerAssetBefore = asset.balanceOf(buyer);
        uint256 sellerCurrencyBefore = currency.balanceOf(buyer);

        _redeemVenueWith(data, intent, TAKER_BPS);

        assertEq(asset.balanceOf(buyer), sellerAssetBefore - SELL_ASSET, "the seller gave up the asset");
        assertEq(currency.balanceOf(buyer), sellerCurrencyBefore + NET_OUT, "and received the proceeds net of the fee");
        assertEq(currency.balanceOf(collector), SELL_FEE, "the collector was paid the carved-out fee");
        assertEq(asset.balanceOf(address(rfq)), SELL_ASSET, "the venue kept the asset it bought");
        assertEq(currency.balanceOf(address(router)), 0, "the router kept no currency");
        assertEq(asset.balanceOf(address(router)), 0, "and no asset");
        assertTrue(rfq.quoteUsed(SELL_QUOTE_ID), "the quote id was consumed");
    }

    /// The sell side is issuer-agnostic too: the seller sells an asset the venue was never
    /// configured with, and the quote names it.
    function test_Sell_TakesWhicheverAssetTheQuoteNames() public {
        aapl.mint(buyer, 10e18);
        MockRFQVenue.Quote memory quote = _quote(
            SELL,
            address(currency),
            PROCEEDS,
            address(aapl),
            10e18,
            address(router),
            keccak256("rfq:sell:aapl"),
            block.timestamp + 5 minutes
        );
        bytes memory data = abi.encodeCall(MockRFQVenue.sell, (quote, _signQuote(quote)));
        PrimaryTypes.RedemptionIntent memory intent =
            _sellIntent(data, address(rfq), MockRFQVenue.sell.selector, 10e18, PROCEEDS, SELL_FEE, NET_OUT);
        intent.assetToken = address(aapl);

        vm.prank(buyer);
        aapl.approve(address(router), 10e18);
        _submitRedemption(data, intent, TAKER_BPS);

        assertEq(aapl.balanceOf(address(rfq)), 10e18, "the venue kept the quoted asset");
        assertEq(aapl.balanceOf(buyer), 0, "the seller gave it up");
    }

    function test_Sell_RevertsWhenTheQuoteIsSignedByAnotherKey() public {
        MockRFQVenue.Quote memory quote = _quote(
            SELL,
            address(currency),
            PROCEEDS,
            address(asset),
            SELL_ASSET,
            address(router),
            SELL_QUOTE_ID,
            block.timestamp + 5 minutes
        );
        bytes memory data = abi.encodeCall(MockRFQVenue.sell, (quote, _signQuoteWith(0xBADBAD, quote)));
        PrimaryTypes.RedemptionIntent memory intent =
            _sellIntent(data, address(rfq), MockRFQVenue.sell.selector, SELL_ASSET, PROCEEDS, SELL_FEE, NET_OUT);

        _approveAssetExact(intent);
        vm.expectRevert(ISettler.VenueCallFailed.selector);
        _submitRedemption(data, intent, TAKER_BPS);
    }

    function test_Sell_RevertsWhenTheQuoteHasExpired() public {
        MockRFQVenue.Quote memory quote = _quote(
            SELL,
            address(currency),
            PROCEEDS,
            address(asset),
            SELL_ASSET,
            address(router),
            SELL_QUOTE_ID,
            block.timestamp - 1
        );
        bytes memory data = abi.encodeCall(MockRFQVenue.sell, (quote, _signQuote(quote)));
        PrimaryTypes.RedemptionIntent memory intent =
            _sellIntent(data, address(rfq), MockRFQVenue.sell.selector, SELL_ASSET, PROCEEDS, SELL_FEE, NET_OUT);

        _approveAssetExact(intent);
        vm.expectRevert(ISettler.VenueCallFailed.selector);
        _submitRedemption(data, intent, TAKER_BPS);
    }

    function test_Sell_RevertsWhenTheQuoteIdWasAlreadyUsed() public {
        (bytes memory firstData, PrimaryTypes.RedemptionIntent memory first) = _rfqSellHappyPath();
        _redeemVenueWith(firstData, first, TAKER_BPS);

        PrimaryTypes.RedemptionIntent memory second =
            _sellIntent(firstData, address(rfq), MockRFQVenue.sell.selector, SELL_ASSET, PROCEEDS, SELL_FEE, NET_OUT);
        second.nonce = INTENT_NONCE + 1;
        _approveAssetExact(second);

        vm.expectRevert(ISettler.VenueCallFailed.selector);
        _submitSecondRedemption(firstData, second);

        assertTrue(rfq.quoteUsed(SELL_QUOTE_ID), "the id is still the one that was consumed");
    }

    /// A quote that pays less than the seller's signed floor is refused, on the proceeds the
    /// router measured.
    function test_Sell_RevertsWhenTheVenuePaysLessThanTheFloor() public {
        uint256 short = PROCEEDS - 1e6;
        MockRFQVenue.Quote memory quote = _quote(
            SELL,
            address(currency),
            short,
            address(asset),
            SELL_ASSET,
            address(router),
            SELL_QUOTE_ID,
            block.timestamp + 5 minutes
        );
        bytes memory data = abi.encodeCall(MockRFQVenue.sell, (quote, _signQuote(quote)));
        PrimaryTypes.RedemptionIntent memory intent =
            _sellIntent(data, address(rfq), MockRFQVenue.sell.selector, SELL_ASSET, PROCEEDS, SELL_FEE, NET_OUT);

        _approveAssetExact(intent);
        vm.expectRevert(abi.encodeWithSelector(ISettler.InsufficientSettlementOut.selector, short - SELL_FEE, NET_OUT));
        _submitRedemption(data, intent, TAKER_BPS);
    }

    /// The venue takes less asset than the seller approved. The router returns the remainder and
    /// reports only what was actually sold, which is the sell-side amount mismatch.
    function test_Sell_ReturnsTheAssetTheQuoteDidNotTake() public {
        uint256 taken = SELL_ASSET - 1e18;
        MockRFQVenue.Quote memory quote = _quote(
            SELL,
            address(currency),
            PROCEEDS,
            address(asset),
            taken,
            address(router),
            SELL_QUOTE_ID,
            block.timestamp + 5 minutes
        );
        bytes memory data = abi.encodeCall(MockRFQVenue.sell, (quote, _signQuote(quote)));
        PrimaryTypes.RedemptionIntent memory intent =
            _sellIntent(data, address(rfq), MockRFQVenue.sell.selector, SELL_ASSET, PROCEEDS, SELL_FEE, NET_OUT);
        uint256 sellerAssetBefore = asset.balanceOf(buyer);

        _redeemVenueWith(data, intent, TAKER_BPS);

        assertEq(asset.balanceOf(buyer), sellerAssetBefore - taken, "only the filled amount left the seller");
        assertEq(asset.balanceOf(address(rfq)), taken, "the venue kept exactly what it bought");
        assertEq(asset.balanceOf(address(router)), 0, "the remainder did not stay at the router");
    }

    // ── the venue's own named errors ─────────────────────────────────────────────────────

    function test_Quote_RefusesAWrongSignerWithANamedError() public {
        MockRFQVenue.Quote memory quote = _quote(
            BUY, address(currency), QUOTE, address(asset), ASSET_OUT, buyer, BUY_QUOTE_ID, block.timestamp + 5 minutes
        );

        bytes memory badSignature = _signQuoteWith(0xBADBAD, quote);

        vm.prank(buyer);
        currency.approve(address(rfq), QUOTE);
        vm.prank(buyer);
        vm.expectRevert(MockRFQVenue.InvalidQuoteSignature.selector);
        rfq.buy(quote, badSignature);
    }

    function test_Quote_RefusesAMalformedSignatureWithTheSameNamedError() public {
        MockRFQVenue.Quote memory quote = _quote(
            BUY, address(currency), QUOTE, address(asset), ASSET_OUT, buyer, BUY_QUOTE_ID, block.timestamp + 5 minutes
        );

        vm.prank(buyer);
        currency.approve(address(rfq), QUOTE);
        vm.prank(buyer);
        vm.expectRevert(MockRFQVenue.InvalidQuoteSignature.selector);
        rfq.buy(quote, hex"deadbeef");
    }

    function test_Quote_RefusesAnExpiredQuoteWithANamedError() public {
        MockRFQVenue.Quote memory quote =
            _quote(BUY, address(currency), QUOTE, address(asset), ASSET_OUT, buyer, BUY_QUOTE_ID, block.timestamp - 1);

        bytes memory signature = _signQuote(quote);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(MockRFQVenue.QuoteExpired.selector, block.timestamp - 1));
        rfq.buy(quote, signature);
    }

    function test_Quote_RefusesAReusedIdWithANamedError() public {
        MockRFQVenue.Quote memory quote = _quote(
            BUY, address(currency), QUOTE, address(asset), ASSET_OUT, buyer, BUY_QUOTE_ID, block.timestamp + 5 minutes
        );
        bytes memory signature = _signQuote(quote);

        vm.prank(buyer);
        currency.approve(address(rfq), type(uint256).max);
        vm.prank(buyer);
        rfq.buy(quote, signature);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(MockRFQVenue.QuoteAlreadyUsed.selector, BUY_QUOTE_ID));
        rfq.buy(quote, signature);
    }

    /// A BUY quote handed to `sell` is refused on its signed side, so the two router legs cannot
    /// be confused even though both are just venue calldata.
    function test_Quote_RefusesTheOtherSide() public {
        MockRFQVenue.Quote memory quote = _quote(
            BUY, address(currency), QUOTE, address(asset), ASSET_OUT, buyer, BUY_QUOTE_ID, block.timestamp + 5 minutes
        );

        bytes memory signature = _signQuote(quote);

        vm.expectRevert(abi.encodeWithSelector(MockRFQVenue.WrongQuoteSide.selector, SELL, BUY));
        rfq.sell(quote, signature);
    }

    // ── EIP-712 shape and configuration ──────────────────────────────────────────────────

    /// Pins the exact type string and the domain, so an off-chain signer that copies the string
    /// from the contract cannot silently diverge from what the contract verifies.
    function test_Quote_HashMatchesAnIndependentlyBuiltDigest() public view {
        MockRFQVenue.Quote memory quote =
            _quote(BUY, address(currency), QUOTE, address(asset), ASSET_OUT, buyer, BUY_QUOTE_ID, 1_700_000_000);

        assertEq(rfq.QUOTE_TYPE(), QUOTE_TYPE_STRING, "the published type string");
        assertEq(rfq.QUOTE_TYPEHASH(), keccak256(bytes(QUOTE_TYPE_STRING)), "the published type hash");

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(bytes(QUOTE_TYPE_STRING)),
                quote.side,
                quote.paymentToken,
                quote.paymentAmount,
                quote.assetToken,
                quote.assetAmount,
                quote.recipient,
                quote.quoteId,
                quote.expiry
            )
        );
        bytes32 expected = _digest("MockRFQVenue", address(rfq), structHash);
        assertEq(rfq.hashQuote(quote), expected, "the digest an off-chain signer would produce");
    }

    /// The owner may rotate the provider, and the old key stops working immediately.
    function test_Owner_CanRotateTheQuoteSigner() public {
        uint256 newSignerPk = 0xABCD;
        address newSigner = vm.addr(newSignerPk);
        MockRFQVenue.Quote memory quote = _quote(
            BUY, address(currency), QUOTE, address(asset), ASSET_OUT, buyer, BUY_QUOTE_ID, block.timestamp + 5 minutes
        );
        bytes memory oldSignature = _signQuote(quote);

        rfq.setQuoteSigner(newSigner);

        assertEq(rfq.quoteSigner(), newSigner, "the signer was rotated");
        vm.prank(buyer);
        vm.expectRevert(MockRFQVenue.InvalidQuoteSignature.selector);
        rfq.buy(quote, oldSignature);

        bytes memory newSignature = _signQuoteWith(newSignerPk, quote);
        uint256 assetBefore = asset.balanceOf(buyer);

        vm.prank(buyer);
        currency.approve(address(rfq), QUOTE);
        vm.prank(buyer);
        rfq.buy(quote, newSignature);
        assertEq(asset.balanceOf(buyer), assetBefore + ASSET_OUT, "the new signer's quote filled");
    }

    /// Nothing else is configurable: a non-owner cannot rotate the signer.
    function test_Owner_OnlyTheOwnerCanRotateTheQuoteSigner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        rfq.setQuoteSigner(stranger);
    }

    // ── second settlements with fresh attestation nonces ─────────────────────────────────
    //
    // The shared base signs every attestation with fixed nonces, which is exactly right for a
    // suite that submits one settlement per test. The replay tests need a SECOND settlement the
    // router accepts, so these two helpers vary only the nonces the router burns.

    function _submitSecondSettlement(bytes memory data, PrimaryTypes.SettlementIntent memory intent) internal {
        bytes32 paramsHash = _paramsHash(intent);
        vm.prank(buyer);
        router.settlePrimary(
            data,
            intent,
            _signIntent(address(router), intent),
            _signBuyerConsent(address(router), intent),
            _kycSettleWithNonce(address(router), paramsHash, 4),
            _feeSettleWithNonce(address(router), paramsHash, 5)
        );
    }

    function _submitSecondRedemption(bytes memory data, PrimaryTypes.RedemptionIntent memory intent) internal {
        bytes32 paramsHash = _paramsHash(intent);
        vm.prank(buyer);
        router.redeemPrimary(
            data,
            intent,
            _signRedemption(address(router), intent),
            _signSellerConsent(address(router), intent),
            _kycActionWithNonce(address(router), paramsHash, uint8(PrimaryTypes.Action.RedeemVenue), 4),
            _feeActionWithNonce(address(router), paramsHash, uint8(PrimaryTypes.Action.RedeemVenue), 5)
        );
    }

    function _kycSettleWithNonce(address target, bytes32 paramsHash, uint256 nonce)
        internal
        view
        returns (GateTypes.KycAttestation memory)
    {
        return _kycActionWithNonce(target, paramsHash, uint8(PrimaryTypes.Action.SettleVenue), nonce);
    }

    function _kycActionWithNonce(address target, bytes32 paramsHash, uint8 action, uint256 nonce)
        internal
        view
        returns (GateTypes.KycAttestation memory)
    {
        uint256 deadline = block.timestamp + 3 minutes;
        bytes32 structHash = keccak256(abi.encode(KYC_TYPEHASH, buyer, action, 0, nonce, deadline, paramsHash));
        return GateTypes.KycAttestation({
            account: buyer,
            action: action,
            orderId: 0,
            nonce: nonce,
            deadline: deadline,
            paramsHash: paramsHash,
            signature: _sign(kycSignerPk, _digest(PRIMARY_DOMAIN_NAME, target, structHash))
        });
    }

    function _feeSettleWithNonce(address target, bytes32 paramsHash, uint256 nonce)
        internal
        view
        returns (GateTypes.FeeAttestation memory)
    {
        return _feeActionWithNonce(target, paramsHash, uint8(PrimaryTypes.Action.SettleVenue), nonce);
    }

    function _feeActionWithNonce(address target, bytes32 paramsHash, uint8 action, uint256 nonce)
        internal
        view
        returns (GateTypes.FeeAttestation memory)
    {
        uint256 deadline = block.timestamp + 3 minutes;
        bytes32 structHash = keccak256(
            abi.encode(
                FEE_TYPEHASH, buyer, action, nonce, deadline, paramsHash, 0, TAKER_BPS, collector, address(currency)
            )
        );
        return GateTypes.FeeAttestation({
            account: buyer,
            action: action,
            nonce: nonce,
            deadline: deadline,
            paramsHash: paramsHash,
            makerFeeBps: 0,
            takerFeeBps: TAKER_BPS,
            feeCollector: collector,
            feeToken: address(currency),
            signature: _sign(feeSignerPk, _digest(PRIMARY_DOMAIN_NAME, target, structHash))
        });
    }
}
