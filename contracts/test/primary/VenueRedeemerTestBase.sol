// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AsseteraPrimarySales} from "../../src/primary/AsseteraPrimarySales.sol";
import {PrimaryTypes} from "../../src/primary/types/PrimaryTypes.sol";
import {XStocksLikeVenue} from "../mocks/XStocksLikeVenue.sol";
import {VenueSettlerTestBase} from "./VenueSettlerTestBase.sol";

/// @title VenueRedeemerTestBase
/// @notice The fixture the sell-back money path needs (AO-847): the same router, the same two
///         real ERC-20s and the same signing helpers the buy suites use, plus a venue that BUYS
///         rather than sells and an asset balance for the seller to sell.
///
/// @dev    It extends `VenueSettlerTestBase` rather than standing beside it, deliberately. The
///         two legs run through one proxy and share a preamble, a nonce namespace and a fee
///         derivation; a sell-back suite built on its own fixture would be proving something
///         about that fixture. `router` here is the same `CappedPrimarySalesHarness` the buy
///         suites attack.
///
///         ⚠️ The venue is `XStocksLikeVenue.executeSell`, which PULLS the asset with an ordinary
///         `transferFrom` against the approval the router grants, and pays the proceeds out of an
///         inventory the fixture seeds. That is the real shape: a venue buying an instrument back
///         does not know or care that the router measures the asset in shares.
abstract contract VenueRedeemerTestBase is VenueSettlerTestBase {
    XStocksLikeVenue internal sellVenue;

    /// What the seller hands over on the happy path.
    uint256 internal constant SELL_ASSET = 41e18;
    /// The venue's firm proceeds quote, and the number the fee is derived from.
    uint256 internal constant PROCEEDS = QUOTE;
    /// 50 bps of `PROCEEDS`, CARVED OUT of it rather than charged on top.
    uint256 internal constant SELL_FEE = FEE;
    /// The floor on what the seller actually receives, which is the quote net of the fee.
    uint256 internal constant NET_OUT = QUOTE - FEE;
    /// The venue's currency inventory. Comfortably above one settlement, so a test that fails on
    /// proceeds has failed for the reason it names.
    uint256 internal constant VENUE_CURRENCY = 100_000e6;

    function setUp() public virtual override {
        super.setUp();

        sellVenue = new XStocksLikeVenue();
        currency.mint(address(sellVenue), VENUE_CURRENCY);
        asset.mint(buyer, 1_000e18);
    }

    // -- fixtures --------------------------------------------------------------------------

    /// The opaque bytes the venue is handed. `assetToken` / `assetAmount` is what it TAKES;
    /// `paymentToken` / `paymentAmount` is what it PAYS, to `recipient`.
    function _sellCalldata(uint256 assetTaken, uint256 proceeds) internal view returns (bytes memory) {
        return abi.encodeCall(
            XStocksLikeVenue.executeSell,
            (XStocksLikeVenue.Swap({
                    paymentToken: address(currency),
                    paymentAmount: proceeds,
                    assetToken: address(asset),
                    assetAmount: assetTaken,
                    recipient: address(router)
                }))
        );
    }

    /// A redemption intent over the real fixtures, with every amount overridable so one helper
    /// covers the happy path and every revert.
    function _sellIntent(
        bytes memory venueCalldata,
        address venue_,
        bytes4 selector,
        uint256 maxAssetIn,
        uint256 quoteOut,
        uint256 sellerFee,
        uint256 minOut
    ) internal view returns (PrimaryTypes.RedemptionIntent memory) {
        return PrimaryTypes.RedemptionIntent({
            seller: buyer,
            assetToken: address(asset),
            accountingMode: uint8(PrimaryTypes.AssetAccountingMode.Erc20Balance),
            maxAssetIn: maxAssetIn,
            settlementToken: address(currency),
            venueQuoteOut: quoteOut,
            sellerFee: sellerFee,
            minSettlementOut: minOut,
            feeCollector: collector,
            venue: venue_,
            selector: selector,
            calldataHash: keccak256(venueCalldata),
            supplierReference: SUPPLIER_REF,
            nonce: INTENT_NONCE,
            deadline: block.timestamp + 3 minutes
        });
    }

    /// The default: the venue takes the whole approval and pays the whole quote.
    function _sellHappyPath() internal view returns (bytes memory data, PrimaryTypes.RedemptionIntent memory intent) {
        data = _sellCalldata(SELL_ASSET, PROCEEDS);
        intent = _sellIntent(
            data, address(sellVenue), XStocksLikeVenue.executeSell.selector, SELL_ASSET, PROCEEDS, SELL_FEE, NET_OUT
        );
    }

    // -- calls -----------------------------------------------------------------------------

    /// Approve exactly this redemption's asset ceiling and submit it. EXACT on purpose, for the
    /// reason `_approveExact` gives on the buy side: an unlimited grant would let the settler
    /// start needing more than it was signed for without any test noticing.
    function _redeemVenueWith(bytes memory data, PrimaryTypes.RedemptionIntent memory intent, uint16 takerBps)
        internal
    {
        _approveAssetExact(intent);
        _submitRedemption(data, intent, takerBps);
    }

    /// The seller's asset allowance for exactly one redemption and no more.
    function _approveAssetExact(PrimaryTypes.RedemptionIntent memory intent) internal {
        vm.prank(buyer);
        asset.approve(address(router), intent.maxAssetIn);
    }

    /// Submit without touching the seller's allowance, so allowance behaviour can be varied.
    function _submitRedemption(bytes memory data, PrimaryTypes.RedemptionIntent memory intent, uint16 takerBps)
        internal
    {
        _submitRedemptionTo(AsseteraPrimarySales(address(router)), data, intent, takerBps);
    }

    /// The same, against a router other than the mock-capped one. Every payload is signed for
    /// `target`, because the EIP-712 verifying contract is part of each digest.
    function _submitRedemptionTo(
        AsseteraPrimarySales target,
        bytes memory data,
        PrimaryTypes.RedemptionIntent memory intent,
        uint16 takerBps
    ) internal {
        bytes32 paramsHash = _paramsHash(intent);
        vm.prank(buyer);
        target.redeemPrimary(
            data,
            intent,
            _signRedemption(address(target), intent),
            _signSellerConsent(address(target), intent),
            _kycRedeem(address(target), paramsHash),
            _feeForAction(
                uint8(PrimaryTypes.Action.RedeemVenue),
                address(target),
                paramsHash,
                0,
                takerBps,
                intent.feeCollector,
                address(currency)
            )
        );
    }
}
