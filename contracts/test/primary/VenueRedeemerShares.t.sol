// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PrimaryTypes} from "../../src/primary/types/PrimaryTypes.sol";
import {ISettler} from "../../src/primary/interfaces/ISettler.sol";
import {BackedLikeShareToken} from "../mocks/BackedLikeShareToken.sol";
import {XStocksLikeVenue} from "../mocks/XStocksLikeVenue.sol";
import {VenueRedeemerTestBase} from "./VenueRedeemerTestBase.sol";

/// @title VenueRedeemerSharesTest
/// @notice The sell-back leg against a share-accounted asset: selling AAPLx-shaped stock back
///         to a venue.
///
///         The sell-side mirror of `VenueSettlerShares.t.sol`, and the rounding trap arrives from
///         the other direction. On the buy leg the provider's ONE nominal hop into the router was
///         what rounded. Here the router pulls an exact SHARE count and it is the VENUE's nominal
///         `transferFrom` off the router that rounds, so the remainder is a share the router
///         would otherwise be left holding.
///
///         Every number is derived from the token at the live multiplier rather than hardcoded.
///         A pinned literal would pass while the router and the fixture rounded the same way in
///         the same wrong direction.
contract VenueRedeemerSharesTest is VenueRedeemerTestBase {
    BackedLikeShareToken internal share;

    /// AAPLx's multiplier at Ethereum block `25824064`, the same one the buy-side suite uses.
    uint256 internal constant MULTIPLIER = 1_003_269_012_539_818_700;
    /// What the seller offers up, in VISIBLE units. The provider's own observed quote size.
    uint256 internal constant SELL_CEILING = 322_180_642_304_483_388;

    function setUp() public virtual override {
        super.setUp();

        share = new BackedLikeShareToken("Mock Apple xStock", "mAAPLx", MULTIPLIER);
        // The seller's holding, seeded in shares so the fixture's own rounding cannot be mistaken
        // for the rounding under test.
        share.mintShares(buyer, 10_000e18);
    }

    // -- fixtures --------------------------------------------------------------------------

    /// The opaque bytes. `assetAmount` is what the venue TAKES, nominally, and a signer must set
    /// it to the one-hop floor of the ceiling rather than to the ceiling itself.
    function _shareSellCalldata(uint256 nominalTaken, uint256 proceeds) internal view returns (bytes memory) {
        return abi.encodeCall(
            XStocksLikeVenue.executeSell,
            (XStocksLikeVenue.Swap({
                    paymentToken: address(currency),
                    paymentAmount: proceeds,
                    assetToken: address(share),
                    assetAmount: nominalTaken,
                    recipient: address(router)
                }))
        );
    }

    function _shareSellIntent(bytes memory data, uint8 mode, uint256 ceiling)
        internal
        view
        returns (PrimaryTypes.RedemptionIntent memory)
    {
        return PrimaryTypes.RedemptionIntent({
            seller: buyer,
            assetToken: address(share),
            accountingMode: mode,
            maxAssetIn: ceiling,
            settlementToken: address(currency),
            venueQuoteOut: PROCEEDS,
            sellerFee: SELL_FEE,
            minSettlementOut: NET_OUT,
            feeCollector: collector,
            venue: address(sellVenue),
            selector: XStocksLikeVenue.executeSell.selector,
            calldataHash: keccak256(data),
            supplierReference: SUPPLIER_REF,
            nonce: INTENT_NONCE,
            deadline: block.timestamp + 3 minutes
        });
    }

    /// The seller approves the router in VISIBLE units, which is the number a wallet renders.
    function _approveShareCeiling(uint256 ceiling) internal {
        vm.prank(buyer);
        share.approve(address(router), ceiling);
    }

    // -- the tests -------------------------------------------------------------------------

    /// 🔴 THE HEADLINE. The router pulls an EXACT share count derived from the visible ceiling,
    /// the venue takes what it was approved, the remainder goes back to the seller as shares, and
    /// the router's own share count returns to zero.
    function test_ShareRedeem_PullsExactSharesAndReturnsToBaseline() public {
        uint256 pulledShares = share.getSharesByUnderlyingAmount(SELL_CEILING);
        uint256 approvalNominal = share.getUnderlyingAmountByShares(pulledShares);

        bytes memory data = _shareSellCalldata(approvalNominal, PROCEEDS);
        PrimaryTypes.RedemptionIntent memory intent =
            _shareSellIntent(data, uint8(PrimaryTypes.AssetAccountingMode.RebasingShares), SELL_CEILING);

        uint256 sellerSharesBefore = share.sharesOf(buyer);
        uint256 sellerCurrencyBefore = currency.balanceOf(buyer);

        _approveShareCeiling(SELL_CEILING);
        _submitRedemption(data, intent, TAKER_BPS);

        uint256 venueShares = share.sharesOf(address(sellVenue));
        assertGt(venueShares, 0, "the venue took shares");
        assertEq(share.sharesOf(address(router)), 0, "the router kept no share, not even one");
        assertEq(share.sharesOf(buyer), sellerSharesBefore - venueShares, "the seller lost exactly what moved");
        assertEq(currency.balanceOf(buyer), sellerCurrencyBefore + NET_OUT, "and was paid the quote, net of the fee");
        assertEq(currency.balanceOf(address(router)), 0, "no currency stayed either");
    }

    /// 🔴 The remainder is real and it is returned. The venue's nominal `transferFrom` off the
    /// router converts to shares a second time and rounds down, so the router is left holding
    /// whatever that rounding did not move. Forwarding it as an exact SHARE count is what keeps
    /// the residue assertion satisfiable; converting back to nominal first would strand it again.
    function test_ShareRedeem_TheVenuesNominalPullLeavesARemainderTheSellerGetsBack() public {
        uint256 pulledShares = share.getSharesByUnderlyingAmount(SELL_CEILING);
        // The venue is asked for slightly LESS than the router pulled, which is what a firm quote
        // and a partial fill look like together, so the remainder is unambiguous.
        uint256 nominalTaken = share.getUnderlyingAmountByShares(pulledShares) - 1_000;

        bytes memory data = _shareSellCalldata(nominalTaken, PROCEEDS);
        PrimaryTypes.RedemptionIntent memory intent =
            _shareSellIntent(data, uint8(PrimaryTypes.AssetAccountingMode.RebasingShares), SELL_CEILING);

        uint256 sellerSharesBefore = share.sharesOf(buyer);

        _approveShareCeiling(SELL_CEILING);
        _submitRedemption(data, intent, TAKER_BPS);

        uint256 venueShares = share.sharesOf(address(sellVenue));
        assertLt(venueShares, pulledShares, "the venue's nominal pull took fewer shares than were pulled");
        assertEq(share.sharesOf(address(router)), 0, "and the difference did not stay at the router");
        assertEq(share.sharesOf(buyer), sellerSharesBefore - venueShares, "it went back to the seller, as shares");
    }

    /// 🔴 THE CONTROL. The same route signed under `Erc20Balance` fails, which is what proves the
    /// mode is the thing that made the test above pass. A nominal pull of the ceiling converts to
    /// shares once and the router measures back fewer visible units than it asked for, so the
    /// pull is refused at the first line that moved anything.
    function test_ShareRedeem_TheSameRouteUnderErc20ModeIsRefusedAtThePull() public {
        uint256 pulledShares = share.getSharesByUnderlyingAmount(SELL_CEILING);
        uint256 arrived = share.getUnderlyingAmountByShares(pulledShares);
        assertLt(arrived, SELL_CEILING, "one nominal hop must lose at least one raw unit");

        bytes memory data = _shareSellCalldata(arrived, PROCEEDS);
        PrimaryTypes.RedemptionIntent memory intent =
            _shareSellIntent(data, uint8(PrimaryTypes.AssetAccountingMode.Erc20Balance), SELL_CEILING);

        _approveShareCeiling(SELL_CEILING);
        vm.expectRevert(abi.encodeWithSelector(ISettler.AssetPullMismatch.selector, SELL_CEILING, arrived));
        _submitRedemption(data, intent, TAKER_BPS);
    }

    /// 🔴 A multiplier change DURING the venue call — a split, a dividend, a fee accrual — must
    /// not break the settlement. The router measures and returns in shares, which do not move
    /// when the multiplier does, so its own share count still lands on its baseline. A settler
    /// that also asserted `balanceOf` would revert here and only here.
    function test_ShareRedeem_AMultiplierChangeDuringTheCallStillReturnsToBaseline() public {
        share.mintShares(address(router), 7e18); // a stranger's donation, in shares
        uint256 donated = share.sharesOf(address(router));

        uint256 pulledShares = share.getSharesByUnderlyingAmount(SELL_CEILING);
        uint256 nominalTaken = share.getUnderlyingAmountByShares(pulledShares) - 1_000;

        sellVenue.setMultiplierDuringCall(MULTIPLIER * 2); // a 2:1 split, mid-settlement

        bytes memory data = _shareSellCalldata(nominalTaken, PROCEEDS);
        PrimaryTypes.RedemptionIntent memory intent =
            _shareSellIntent(data, uint8(PrimaryTypes.AssetAccountingMode.RebasingShares), SELL_CEILING);

        _approveShareCeiling(SELL_CEILING);
        _submitRedemption(data, intent, TAKER_BPS);

        assertEq(share.sharesOf(address(router)), donated, "the router is back on its share baseline");
    }

    /// A ceiling below one share converts to zero, which would approve the venue nothing and
    /// judge the settlement on a pull that never happened. Named, at the first line that moves.
    function test_ShareRedeem_RevertsWhenTheCeilingIsBelowOneShare() public {
        bytes memory data = _shareSellCalldata(0, PROCEEDS);
        PrimaryTypes.RedemptionIntent memory intent =
            _shareSellIntent(data, uint8(PrimaryTypes.AssetAccountingMode.RebasingShares), 1);

        // At a multiplier above 1e18 one visible unit is less than one share.
        _approveShareCeiling(1);
        vm.expectRevert(abi.encodeWithSelector(ISettler.AssetPullMismatch.selector, 0, 0));
        _submitRedemption(data, intent, TAKER_BPS);
    }

    /// A share token that reports failure by RETURNING FALSE rather than reverting must not read
    /// as a successful pull. There is no SafeERC20 equivalent for the share surface, so the
    /// return is checked by hand at the call site and this is what proves it.
    function test_ShareRedeem_RevertsWhenTransferSharesFromReportsFailure() public {
        uint256 pulledShares = share.getSharesByUnderlyingAmount(SELL_CEILING);
        bytes memory data = _shareSellCalldata(share.getUnderlyingAmountByShares(pulledShares), PROCEEDS);
        PrimaryTypes.RedemptionIntent memory intent =
            _shareSellIntent(data, uint8(PrimaryTypes.AssetAccountingMode.RebasingShares), SELL_CEILING);

        share.setShareTransfersReturnFalse(true);

        _approveShareCeiling(SELL_CEILING);
        vm.expectRevert(ISettler.ShareTransferFailed.selector);
        _submitRedemption(data, intent, TAKER_BPS);
    }

    /// 🔴 The seller approves in VISIBLE units and that is enough. Backed spends the allowance on
    /// `getUnderlyingAmountByShares(shares)`, and the router derived those shares by rounding the
    /// ceiling DOWN, so the double rounding can never demand more than the seller approved. This
    /// is what makes "approve the number in the UI" correct advice.
    function test_ShareRedeem_ApprovingExactlyTheVisibleCeilingIsEnough() public {
        uint256 pulledShares = share.getSharesByUnderlyingAmount(SELL_CEILING);
        bytes memory data = _shareSellCalldata(share.getUnderlyingAmountByShares(pulledShares), PROCEEDS);
        PrimaryTypes.RedemptionIntent memory intent =
            _shareSellIntent(data, uint8(PrimaryTypes.AssetAccountingMode.RebasingShares), SELL_CEILING);

        _approveShareCeiling(SELL_CEILING); // not one unit more
        _submitRedemption(data, intent, TAKER_BPS);

        assertEq(share.sharesOf(address(router)), 0, "the settlement completed and left nothing");
        assertLe(share.allowance(buyer, address(router)), SELL_CEILING, "the allowance was never overspent");
    }
}
