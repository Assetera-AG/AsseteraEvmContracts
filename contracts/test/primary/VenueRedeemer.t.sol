// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PrimaryTypes} from "../../src/primary/types/PrimaryTypes.sol";
import {ISettler} from "../../src/primary/interfaces/ISettler.sol";
import {VenueRedeemer} from "../../src/primary/settle/VenueRedeemer.sol";
import {VenueSettler} from "../../src/primary/settle/VenueSettler.sol";
import {XStocksLikeVenue} from "../mocks/XStocksLikeVenue.sol";
import {HostileVenue} from "./mocks/HostileVenue.sol";
import {VenueRedeemerTestBase} from "./VenueRedeemerTestBase.sol";

/// @title VenueRedeemerTest
/// @notice AO-847: the sell-back money path. The mirror of `VenueSettler.t.sol`, test for test
///         where the two legs make the same claim, and with its own tests where they do not:
///         the fee is CARVED OUT here rather than charged on top, and the router pulls the asset
///         rather than being delivered it.
contract VenueRedeemerTest is VenueRedeemerTestBase {
    /// 🔴 THE HEADLINE. One redemption, end to end, with every party's balance checked: the
    /// seller loses the asset and gains the quote net of our fee, the collector gains the fee,
    /// the venue gains the asset and loses the quote, and the router keeps nothing at all.
    function test_Redeem_MovesEveryLegAndKeepsNothing() public {
        (bytes memory data, PrimaryTypes.RedemptionIntent memory intent) = _sellHappyPath();

        uint256 sellerAssetBefore = asset.balanceOf(buyer);
        uint256 sellerCurrencyBefore = currency.balanceOf(buyer);

        _redeemVenueWith(data, intent, TAKER_BPS);

        assertEq(asset.balanceOf(buyer), sellerAssetBefore - SELL_ASSET, "the seller gave up the whole ceiling");
        assertEq(currency.balanceOf(buyer), sellerCurrencyBefore + NET_OUT, "and received the quote net of the fee");
        assertEq(currency.balanceOf(collector), SELL_FEE, "the collector was paid the carved-out fee");
        assertEq(asset.balanceOf(address(sellVenue)), SELL_ASSET, "the venue took the asset");
        assertEq(currency.balanceOf(address(sellVenue)), VENUE_CURRENCY - PROCEEDS, "and paid the quote");
        assertEq(asset.balanceOf(address(router)), 0, "the router kept no asset");
        assertEq(currency.balanceOf(address(router)), 0, "and no currency");
    }

    /// 🔴 The fee is CARVED OUT, never charged on top. This is the one number the buy leg's model
    /// cannot be read across to, so it is asserted as arithmetic rather than only as a balance:
    /// what the seller receives plus what the collector receives is exactly the quote.
    function test_Redeem_TheFeeIsCarvedOutOfTheProceeds() public {
        (bytes memory data, PrimaryTypes.RedemptionIntent memory intent) = _sellHappyPath();
        uint256 sellerBefore = currency.balanceOf(buyer);

        _redeemVenueWith(data, intent, TAKER_BPS);

        uint256 sellerGot = currency.balanceOf(buyer) - sellerBefore;
        assertEq(sellerGot + currency.balanceOf(collector), PROCEEDS, "the two halves must sum to the quote");
        assertEq(sellerGot, PROCEEDS - SELL_FEE, "and the seller's half is the quote minus the fee");
    }

    /// The router's approval to the venue is exactly what it pulled, and nothing survives the
    /// call. A standing asset approval on a router that holds nothing is a claim on whatever
    /// lands there next.
    function test_Redeem_LeavesNoStandingApproval() public {
        (bytes memory data, PrimaryTypes.RedemptionIntent memory intent) = _sellHappyPath();

        _redeemVenueWith(data, intent, TAKER_BPS);

        assertEq(asset.allowance(address(router), address(sellVenue)), 0, "no asset approval may survive");
    }

    /// A venue that takes less than it was approved is normal, not an error. The difference goes
    /// back to the seller in the same transaction, and the event reports both numbers.
    function test_Redeem_ReturnsTheAssetTheVenueDidNotTake() public {
        uint256 taken = 40e18;
        bytes memory data = _sellCalldata(taken, PROCEEDS);
        PrimaryTypes.RedemptionIntent memory intent = _sellIntent(
            data, address(sellVenue), XStocksLikeVenue.executeSell.selector, SELL_ASSET, PROCEEDS, SELL_FEE, NET_OUT
        );

        uint256 sellerAssetBefore = asset.balanceOf(buyer);
        _redeemVenueWith(data, intent, TAKER_BPS);

        assertEq(asset.balanceOf(buyer), sellerAssetBefore - taken, "only what the venue took left the seller");
        assertEq(asset.balanceOf(address(router)), 0, "and the remainder did not stay at the router");
    }

    /// The event carries the four MEASURED numbers and the identifiers the operator signed. It is
    /// what the indexer builds an activity-ledger leg out of, so the field mapping is pinned.
    function test_Redeem_EmitsTheMeasuredNumbers() public {
        uint256 taken = 40e18;
        bytes memory data = _sellCalldata(taken, PROCEEDS);
        PrimaryTypes.RedemptionIntent memory intent = _sellIntent(
            data, address(sellVenue), XStocksLikeVenue.executeSell.selector, SELL_ASSET, PROCEEDS, SELL_FEE, NET_OUT
        );

        _approveAssetExact(intent);
        vm.expectEmit(true, true, true, true, address(router));
        emit ISettler.PrimaryRedeemed(
            buyer,
            address(asset),
            address(sellVenue),
            taken,
            address(currency),
            PROCEEDS,
            SELL_ASSET - taken,
            SELL_FEE,
            collector,
            SUPPLIER_REF,
            INTENT_NONCE
        );
        _submitRedemption(data, intent, TAKER_BPS);
    }

    /// 🔴 The venue pays less than it quoted, and the seller's floor is the quote net of the fee.
    /// A revert, never a silent bad fill.
    function test_Redeem_RevertsWhenTheVenuePaysLessThanQuoted() public {
        uint256 short = PROCEEDS - 1e6;
        bytes memory data = _sellCalldata(SELL_ASSET, short);
        PrimaryTypes.RedemptionIntent memory intent = _sellIntent(
            data, address(sellVenue), XStocksLikeVenue.executeSell.selector, SELL_ASSET, PROCEEDS, SELL_FEE, NET_OUT
        );

        _approveAssetExact(intent);
        vm.expectRevert(abi.encodeWithSelector(ISettler.InsufficientSettlementOut.selector, short - SELL_FEE, NET_OUT));
        _submitRedemption(data, intent, TAKER_BPS);
    }

    /// The floor is respected even when it is BELOW the quote: a seller who signed a loose floor
    /// gets whatever the venue paid, minus the fee, and the settlement stands.
    function test_Redeem_ALooseFloorAcceptsAShortFill() public {
        uint256 short = PROCEEDS - 1e6;
        bytes memory data = _sellCalldata(SELL_ASSET, short);
        PrimaryTypes.RedemptionIntent memory intent = _sellIntent(
            data,
            address(sellVenue),
            XStocksLikeVenue.executeSell.selector,
            SELL_ASSET,
            PROCEEDS,
            SELL_FEE,
            short - SELL_FEE
        );

        uint256 sellerBefore = currency.balanceOf(buyer);
        _redeemVenueWith(data, intent, TAKER_BPS);

        assertEq(currency.balanceOf(buyer), sellerBefore + short - SELL_FEE, "the seller got the short fill, net");
        assertEq(currency.balanceOf(address(router)), 0, "and the router kept nothing");
    }

    /// 🔴 THE HOSTILE CASE. A venue that takes the asset and pays nothing at all returns success,
    /// as a hostile venue would. Nothing the venue says is trusted, so it is the measured
    /// proceeds that refuse the settlement — and the seller's asset is untouched afterwards
    /// because the whole transaction reverted.
    function test_Redeem_RevertsWhenTheVenueTakesTheAssetAndPaysNothing() public {
        HostileVenue hostile = new HostileVenue();
        HostileVenue.Script memory script = HostileVenue.Script({
            paymentToken: address(asset), // what THIS venue pulls: the asset
            pullAmount: SELL_ASSET,
            assetToken: address(currency), // what it would pay with
            deliverAmount: 0, // and it pays nothing
            recipient: address(router),
            pushBackAmount: 0,
            rebaseBps: 0,
            reenterTarget: address(0),
            reenterData: ""
        });
        bytes memory data = abi.encodeCall(HostileVenue.execute, (script));
        PrimaryTypes.RedemptionIntent memory intent =
            _sellIntent(data, address(hostile), HostileVenue.execute.selector, SELL_ASSET, PROCEEDS, SELL_FEE, NET_OUT);

        uint256 sellerAssetBefore = asset.balanceOf(buyer);
        _approveAssetExact(intent);
        vm.expectRevert(abi.encodeWithSelector(ISettler.InsufficientSettlementOut.selector, 0, NET_OUT));
        _submitRedemption(data, intent, TAKER_BPS);

        assertEq(asset.balanceOf(buyer), sellerAssetBefore, "the seller still holds every unit");
        assertEq(asset.balanceOf(address(hostile)), 0, "and the venue kept none of it");
    }

    /// A venue that pays SOMETHING but less than our own fee lands in the same place, through the
    /// clamp rather than through an arithmetic panic.
    function test_Redeem_RevertsWhenTheVenuePaysLessThanTheFee() public {
        HostileVenue hostile = new HostileVenue();
        HostileVenue.Script memory script = HostileVenue.Script({
            paymentToken: address(asset),
            pullAmount: SELL_ASSET,
            assetToken: address(currency),
            deliverAmount: SELL_FEE - 1,
            recipient: address(router),
            pushBackAmount: 0,
            rebaseBps: 0,
            reenterTarget: address(0),
            reenterData: ""
        });
        bytes memory data = abi.encodeCall(HostileVenue.execute, (script));
        PrimaryTypes.RedemptionIntent memory intent =
            _sellIntent(data, address(hostile), HostileVenue.execute.selector, SELL_ASSET, PROCEEDS, SELL_FEE, NET_OUT);

        _approveAssetExact(intent);
        vm.expectRevert(abi.encodeWithSelector(ISettler.InsufficientSettlementOut.selector, 0, NET_OUT));
        _submitRedemption(data, intent, TAKER_BPS);
    }

    /// A venue that takes the whole approval and then hands PART of it back is a partial fill by
    /// another route, and it settles: the asset that came back goes to the seller, and the event
    /// reports what the venue actually kept rather than what it was approved.
    ///
    /// ⚠️ Asserted rather than assumed. The obvious reading of the residue bound is that any
    /// push-back is hostile, and it is not — the router cannot tell "returned the remainder by
    /// transfer" from "never pulled it" and must not punish a seller for the difference.
    function test_Redeem_AVenuePushingSomeAssetBackIsAPartialFill() public {
        uint256 pushedBack = 5e18;
        HostileVenue hostile = new HostileVenue();
        HostileVenue.Script memory script = HostileVenue.Script({
            paymentToken: address(asset),
            pullAmount: SELL_ASSET,
            assetToken: address(currency),
            deliverAmount: PROCEEDS,
            recipient: address(router),
            pushBackAmount: pushedBack,
            rebaseBps: 0,
            reenterTarget: address(0),
            reenterData: ""
        });
        bytes memory data = abi.encodeCall(HostileVenue.execute, (script));
        PrimaryTypes.RedemptionIntent memory intent =
            _sellIntent(data, address(hostile), HostileVenue.execute.selector, SELL_ASSET, PROCEEDS, SELL_FEE, NET_OUT);

        uint256 sellerAssetBefore = asset.balanceOf(buyer);
        _approveAssetExact(intent);
        vm.expectEmit(true, true, true, true, address(router));
        emit ISettler.PrimaryRedeemed(
            buyer,
            address(asset),
            address(hostile),
            SELL_ASSET - pushedBack,
            address(currency),
            PROCEEDS,
            pushedBack,
            SELL_FEE,
            collector,
            SUPPLIER_REF,
            INTENT_NONCE
        );
        _submitRedemption(data, intent, TAKER_BPS);

        assertEq(asset.balanceOf(buyer), sellerAssetBefore - SELL_ASSET + pushedBack, "the seller got it back");
        assertEq(asset.balanceOf(address(router)), 0, "and the router kept none of it");
    }

    /// 🔴 A venue that pushes back MORE asset than it took is refused. The router would otherwise
    /// hand a seller asset that belonged to somebody else, out of a balance it has no claim on,
    /// and report a consumption that never happened.
    function test_Redeem_RevertsWhenTheVenuePushesBackMoreAssetThanItTook() public {
        HostileVenue hostile = new HostileVenue();
        asset.mint(address(hostile), 5e18); // its own inventory, on top of what it will pull
        HostileVenue.Script memory script = HostileVenue.Script({
            paymentToken: address(asset),
            pullAmount: SELL_ASSET,
            assetToken: address(currency),
            deliverAmount: PROCEEDS,
            recipient: address(router),
            pushBackAmount: SELL_ASSET + 5e18,
            rebaseBps: 0,
            reenterTarget: address(0),
            reenterData: ""
        });
        bytes memory data = abi.encodeCall(HostileVenue.execute, (script));
        PrimaryTypes.RedemptionIntent memory intent =
            _sellIntent(data, address(hostile), HostileVenue.execute.selector, SELL_ASSET, PROCEEDS, SELL_FEE, NET_OUT);

        _approveAssetExact(intent);
        vm.expectRevert(ISettler.RouterBalanceChanged.selector);
        _submitRedemption(data, intent, TAKER_BPS);
    }

    /// A donation sitting at the router before the call is not this settlement's asset. The
    /// baseline is the router's PRE-CALL holding, so a stranger's transfer is neither counted as
    /// consumption nor handed to whichever seller redeems next.
    function test_Redeem_ADonationAtTheRouterIsNotPaidOut() public {
        asset.mint(address(router), 7e18);
        (bytes memory data, PrimaryTypes.RedemptionIntent memory intent) = _sellHappyPath();

        _redeemVenueWith(data, intent, TAKER_BPS);

        assertEq(asset.balanceOf(address(router)), 7e18, "the donation is exactly where it was");
    }

    /// A venue that reverts takes the whole settlement with it, under one deterministic error
    /// rather than its own attacker-controlled bytes.
    function test_Redeem_RevertsWhenTheVenueCallFails() public {
        bytes memory data = _sellCalldata(SELL_ASSET, VENUE_CURRENCY + 1); // more than its inventory
        PrimaryTypes.RedemptionIntent memory intent = _sellIntent(
            data, address(sellVenue), XStocksLikeVenue.executeSell.selector, SELL_ASSET, PROCEEDS, SELL_FEE, NET_OUT
        );

        _approveAssetExact(intent);
        vm.expectRevert(ISettler.VenueCallFailed.selector);
        _submitRedemption(data, intent, TAKER_BPS);
    }

    /// The seller's allowance is the true ceiling. A ceiling above it fails inside the token
    /// rather than settling for less than was signed.
    function test_Redeem_RevertsWhenTheSellerApprovedLessThanTheCeiling() public {
        (bytes memory data, PrimaryTypes.RedemptionIntent memory intent) = _sellHappyPath();

        vm.prank(buyer);
        asset.approve(address(router), SELL_ASSET - 1);

        vm.expectRevert();
        _submitRedemption(data, intent, TAKER_BPS);
    }

    /// 🔴 The cross-check that makes the attested basis points mean something. Two independent
    /// signers must agree on one number, and it runs before anything moves.
    function test_Redeem_RevertsWhenTheTwoSignersDisagreeAboutTheFee() public {
        bytes memory data = _sellCalldata(SELL_ASSET, PROCEEDS);
        PrimaryTypes.RedemptionIntent memory intent = _sellIntent(
            data, address(sellVenue), XStocksLikeVenue.executeSell.selector, SELL_ASSET, PROCEEDS, SELL_FEE, NET_OUT
        );

        _approveAssetExact(intent);
        // The fee attestation says 100 bps; the intent's `sellerFee` was derived from 50.
        vm.expectRevert(abi.encodeWithSelector(VenueRedeemer.SellerFeeMismatch.selector, SELL_FEE, 10e6));
        _submitRedemption(data, intent, 100);
    }

    /// The fee derivation is `FeeMath.feeAmount` on the GROSS quote, floor-rounded, which is the
    /// same helper and the same rounding the buy leg uses. Pinned by vector so the two legs
    /// cannot start rounding differently.
    function test_Redeem_SellerFeeRounding() public view {
        assertEq(router.expectedSellerFee(1_000e6, 50), 5e6, "50 bps of 1000 divides exactly");
        assertEq(router.expectedSellerFee(999, 50), 4, "4.995 rounds DOWN, in the seller's favour");
        assertEq(router.expectedSellerFee(1_000e6, 0), 0, "zero bps is a zero fee");
        assertEq(router.expectedSellerFee(1_000e6, 50), router.expectedBuyerFee(1_000e6, 50), "one derivation");
    }

    /// A zero-fee redemption pays no collector and still returns to baseline. Nothing about the
    /// zero case is special-cased in the settler, so this is what proves it.
    function test_Redeem_AZeroFeeSettlesAndPaysNoCollector() public {
        bytes memory data = _sellCalldata(SELL_ASSET, PROCEEDS);
        PrimaryTypes.RedemptionIntent memory intent = _sellIntent(
            data, address(sellVenue), XStocksLikeVenue.executeSell.selector, SELL_ASSET, PROCEEDS, 0, PROCEEDS
        );

        uint256 sellerBefore = currency.balanceOf(buyer);
        _redeemVenueWith(data, intent, 0);

        assertEq(currency.balanceOf(buyer), sellerBefore + PROCEEDS, "the seller got the whole quote");
        assertEq(currency.balanceOf(collector), 0, "and no collector was paid");
    }

    /// The venue may not be either of the two settled tokens. Two comparisons that cost nothing
    /// and remove a whole class of confusion between an approval and a settlement.
    function test_Redeem_RevertsWhenTheVenueIsASettledToken() public {
        bytes memory data = _sellCalldata(SELL_ASSET, PROCEEDS);
        PrimaryTypes.RedemptionIntent memory intent = _sellIntent(
            data, address(asset), XStocksLikeVenue.executeSell.selector, SELL_ASSET, PROCEEDS, SELL_FEE, NET_OUT
        );

        _approveAssetExact(intent);
        vm.expectRevert(VenueSettler.VenueIsASettledToken.selector);
        _submitRedemption(data, intent, TAKER_BPS);
    }

    /// An accounting ordinal this router has no implementation for is refused before the first
    /// token call, with a named error rather than the `Panic(0x21)` an enum decode would give.
    function test_Redeem_RevertsOnAnUnsupportedAccountingMode() public {
        (bytes memory data, PrimaryTypes.RedemptionIntent memory intent) = _sellHappyPath();
        intent.accountingMode = 7;

        _approveAssetExact(intent);
        vm.expectRevert(abi.encodeWithSelector(ISettler.UnsupportedAccountingMode.selector, uint8(7)));
        _submitRedemption(data, intent, TAKER_BPS);
    }

    /// The per-transaction cap is charged on `venueQuoteOut`, the GROSS proceeds, so the fee
    /// cannot shave a redemption under a cap it should have breached.
    function test_Redeem_ChargesTheCapOnTheGrossQuote() public {
        (bytes memory data, PrimaryTypes.RedemptionIntent memory intent) = _sellHappyPath();

        _redeemVenueWith(data, intent, TAKER_BPS);

        assertEq(router.lastLimitToken(), address(currency), "the cap is keyed on the settlement token");
        assertEq(router.lastLimitAmount(), PROCEEDS, "and charged on the gross quote, not the net");
        assertEq(router.limitCalls(), 1, "exactly once");
    }
}
