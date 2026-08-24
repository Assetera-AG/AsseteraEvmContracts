// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PrimaryTypes} from "../../src/primary/types/PrimaryTypes.sol";
import {ISettler} from "../../src/primary/interfaces/ISettler.sol";
import {BackedLikeShareToken} from "../mocks/BackedLikeShareToken.sol";
import {XStocksLikeVenue} from "../mocks/XStocksLikeVenue.sol";
import {VenueSettlerTestBase} from "./VenueSettlerTestBase.sol";

/// @title VenueSettlerSharesTest
/// @notice AO-713: settling an asset that is accounted in SHARES rather than in balances.
///
///         This suite is the on-chain half of the 2026-08-24 AAPLx mainnet-fork proof. That
///         proof got a real firm quote from xStocks, had the deployed router call the real
///         `AtomicSwap` with a pre-approved allowance, and then reverted at
///         `RouterBalanceChanged()` because a router that forwards its measured `balanceOf`
///         increase converts nominal-to-shares a SECOND time and strands the remainder.
///
///         Every number below is that proof's, at AAPLx's real multiplier. The mock reproduces
///         all three observed quantities exactly, which is what makes these tests evidence
///         rather than decoration.
abstract contract SharesFixture is VenueSettlerTestBase {
    BackedLikeShareToken internal share;
    XStocksLikeVenue internal xstocks;

    /// AAPLx's multiplier at Ethereum block `25824064`.
    uint256 internal constant MULTIPLIER = 1_003_269_012_539_818_700;
    /// The provider's nominal outgoing amount on the observed quote.
    uint256 internal constant NOMINAL_OUT = 322_180_642_304_483_388;
    /// What actually arrives as shares: `NOMINAL_OUT × 1e18 / MULTIPLIER`, rounded down.
    uint256 internal constant ARRIVING_SHARES = 321_130_861_491_345_397;
    /// Those shares back in visible units. One raw unit below the nominal amount, and the ONLY
    /// floor a signer may sign for this route.
    uint256 internal constant ONE_HOP_FLOOR = 322_180_642_304_483_387;

    function setUp() public virtual override {
        super.setUp();

        share = new BackedLikeShareToken("Mock Apple xStock", "mAAPLx", MULTIPLIER);
        xstocks = new XStocksLikeVenue();

        // The provider's inventory, seeded in shares so the fixture's own rounding cannot be
        // mistaken for the rounding under test.
        share.mintShares(address(xstocks), 100_000e18);
    }

    /// The opaque swap bytes. ⚠️ `recipient` is the ROUTER, not the buyer: xStocks quotes only
    /// to wallets registered at its API layer, and registering every Assetera customer is the
    /// dependency this whole design exists to avoid.
    function _swapCalldata(uint256 paymentAmount, uint256 nominalAssetOut) internal view returns (bytes memory) {
        return abi.encodeCall(
            XStocksLikeVenue.executeSwap,
            (XStocksLikeVenue.Swap({
                    paymentToken: address(currency),
                    paymentAmount: paymentAmount,
                    assetToken: address(share),
                    assetAmount: nominalAssetOut,
                    recipient: address(router)
                }))
        );
    }

    function _shareIntent(bytes memory data, uint8 mode, uint256 minOut)
        internal
        view
        returns (PrimaryTypes.SettlementIntent memory)
    {
        return PrimaryTypes.SettlementIntent({
            buyer: buyer,
            assetToken: address(share),
            accountingMode: mode,
            minAssetOut: minOut,
            settlementToken: address(currency),
            venueQuoteIn: QUOTE,
            buyerFee: FEE,
            maxSettlementIn: QUOTE + FEE,
            feeCollector: collector,
            venue: address(xstocks),
            selector: XStocksLikeVenue.executeSwap.selector,
            calldataHash: keccak256(data),
            supplierReference: SUPPLIER_REF,
            nonce: INTENT_NONCE,
            deadline: block.timestamp + 3 minutes
        });
    }

    /// The route as it is meant to run: share mode, and the one-hop floor.
    function _sharePath() internal view returns (bytes memory data, PrimaryTypes.SettlementIntent memory intent) {
        data = _swapCalldata(QUOTE, NOMINAL_OUT);
        intent = _shareIntent(data, uint8(PrimaryTypes.AssetAccountingMode.RebasingShares), ONE_HOP_FLOOR);
    }
}

contract VenueSettlerSharesTest is SharesFixture {
    /// 🔴 THE HEADLINE. The exact route that reverted on the fork now settles: the provider
    /// delivers nominally to the router, the router forwards the exact SHARE delta, and its own
    /// share count returns to its baseline.
    function test_Shares_ForwardsTheExactShareDeltaAndReturnsToBaseline() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _sharePath();

        _settleVenueWith(data, intent, TAKER_BPS);

        assertEq(share.sharesOf(buyer), ARRIVING_SHARES, "the buyer holds every share that arrived");
        assertEq(share.sharesOf(address(router)), 0, "the router kept no share, not even one");
        assertEq(share.balanceOf(buyer), ONE_HOP_FLOOR, "and the visible amount is the one-hop floor");
    }

    /// The same route under `Erc20Balance` still reverts, exactly as the deployed router did.
    ///
    /// 🔴 This is the control. Without it the test above only shows that SOMETHING changed; with
    /// it, the mode is proven to be the thing that changed. It also pins the fail-closed
    /// direction: signing the wrong mode costs a settlement, never a loss.
    function test_Shares_TheSameRouteUnderErc20ModeStillReverts() public {
        bytes memory data = _swapCalldata(QUOTE, NOMINAL_OUT);
        PrimaryTypes.SettlementIntent memory intent =
            _shareIntent(data, uint8(PrimaryTypes.AssetAccountingMode.Erc20Balance), ONE_HOP_FLOOR - 10);

        _approveExact(intent);
        vm.expectRevert(ISettler.RouterBalanceChanged.selector);
        _submit(data, intent, TAKER_BPS);
    }

    /// 🔴 The trap this change is most likely to be undone by. Under share mode the asset-side
    /// residue assertion must REPLACE the `balanceOf` one, not stand beside it.
    ///
    /// The router holds a donation, so its baseline is non-zero in both units. The venue then
    /// moves the multiplier during the call, as a split or a dividend would. Afterwards the
    /// router's SHARE count is exactly its baseline while its BALANCE is not, so a settler that
    /// kept both assertions would revert here and only here — never in an ordinary test, never
    /// on a fork run with a still multiplier.
    function test_Shares_AMultiplierChangeDuringTheCallStillReturnsToBaseline() public {
        share.mintShares(address(router), 7e18); // a stranger's donation, in shares
        uint256 donatedShares = share.sharesOf(address(router));
        uint256 routerBalanceBefore = share.balanceOf(address(router));

        xstocks.setMultiplierDuringCall(MULTIPLIER * 2); // a 2:1 split, mid-settlement
        bytes memory data = _swapCalldata(QUOTE, NOMINAL_OUT);
        PrimaryTypes.SettlementIntent memory intent =
            _shareIntent(data, uint8(PrimaryTypes.AssetAccountingMode.RebasingShares), 1);

        _settleVenueWith(data, intent, TAKER_BPS);

        assertEq(share.sharesOf(address(router)), donatedShares, "the share baseline is restored exactly");
        assertTrue(
            share.balanceOf(address(router)) != routerBalanceBefore,
            "and the BALANCE baseline is not, which is why asserting on it would revert"
        );
        assertGt(share.sharesOf(buyer), 0, "the buyer was still delivered");
    }

    /// 🔴 The open finding this closes. `VenueSettler` documents that a rebase during the venue
    /// call is counted as delivery, because both an honest transfer and a revaluation of the
    /// buyer's EXISTING position are only a balance delta. Under share accounting they are not:
    /// a multiplier change moves no share count.
    ///
    /// The venue here takes the whole quote, delivers NOTHING, and rebases the buyer's existing
    /// position up. Before AO-713 that cleared the floor. Now the measured delivery is zero.
    function test_Shares_ARebaseDuringTheCallIsNotCountedAsDelivery() public {
        share.mintShares(buyer, 1_000e18); // the buyer already holds a position

        xstocks.setMultiplierDuringCall(MULTIPLIER * 2);
        bytes memory data = _swapCalldata(QUOTE, 0); // takes the money, delivers nothing
        PrimaryTypes.SettlementIntent memory intent =
            _shareIntent(data, uint8(PrimaryTypes.AssetAccountingMode.RebasingShares), ONE_HOP_FLOOR);

        _approveExact(intent);
        vm.expectRevert(abi.encodeWithSelector(ISettler.InsufficientAssetDelivered.selector, 0, ONE_HOP_FLOOR));
        _submit(data, intent, TAKER_BPS);
    }

    /// The floor is denominated in the INSTRUMENT, not in shares, so the buyer's consent stays
    /// meaningful. The measured delivery is the share delta converted once.
    function test_Shares_DeliveryIsMeasuredInSharesButJudgedInUnderlying() public {
        bytes memory data = _swapCalldata(QUOTE, NOMINAL_OUT);
        // One raw unit above what a single conversion can produce.
        PrimaryTypes.SettlementIntent memory intent =
            _shareIntent(data, uint8(PrimaryTypes.AssetAccountingMode.RebasingShares), ONE_HOP_FLOOR + 1);

        _approveExact(intent);
        vm.expectRevert(
            abi.encodeWithSelector(ISettler.InsufficientAssetDelivered.selector, ONE_HOP_FLOOR, ONE_HOP_FLOOR + 1)
        );
        _submit(data, intent, TAKER_BPS);
    }

    /// ⚠️ The signer's job, pinned here so nobody re-derives it wrongly: signing the provider's
    /// RAW nominal amount as the floor reverts, because one nominal hop cannot deliver it. The
    /// signable floor is that amount converted to shares and back.
    function test_Shares_SigningTheProvidersRawNominalAmountReverts() public {
        bytes memory data = _swapCalldata(QUOTE, NOMINAL_OUT);
        PrimaryTypes.SettlementIntent memory intent =
            _shareIntent(data, uint8(PrimaryTypes.AssetAccountingMode.RebasingShares), NOMINAL_OUT);

        _approveExact(intent);
        vm.expectRevert(
            abi.encodeWithSelector(ISettler.InsufficientAssetDelivered.selector, ONE_HOP_FLOOR, NOMINAL_OUT)
        );
        _submit(data, intent, TAKER_BPS);
    }

    /// A donation in shares is not this settlement's money and is not handed to the buyer. The
    /// same statement the `Erc20Balance` path already makes, in the other unit of account.
    function test_Shares_ADonationIsNeitherForwardedNorCounted() public {
        share.mintShares(address(router), 7e18);
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _sharePath();

        _settleVenueWith(data, intent, TAKER_BPS);

        assertEq(share.sharesOf(address(router)), 7e18, "the donation is untouched and uncounted");
        assertEq(share.sharesOf(buyer), ARRIVING_SHARES, "the buyer got this settlement's shares and no more");
    }

    /// 🔴 `transferShares` returns `bool` and has no SafeERC20 wrapper, so an unchecked return
    /// would read a silent no-op as delivery.
    function test_Shares_RejectsAFalseTransferSharesReturn() public {
        share.setShareTransfersReturnFalse(true);
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _sharePath();

        _approveExact(intent);
        vm.expectRevert(ISettler.ShareTransferFailed.selector);
        _submit(data, intent, TAKER_BPS);
    }

    /// An ordinal with no implementation is refused before anything moves, with a named error
    /// rather than the `Panic(0x21)` an out-of-range enum decode would produce.
    function test_Shares_RejectsAnUnknownAccountingMode() public {
        bytes memory data = _swapCalldata(QUOTE, NOMINAL_OUT);
        PrimaryTypes.SettlementIntent memory intent = _shareIntent(data, 2, ONE_HOP_FLOOR);

        _approveExact(intent);
        vm.expectRevert(abi.encodeWithSelector(ISettler.UnsupportedAccountingMode.selector, uint8(2)));
        _submit(data, intent, TAKER_BPS);
    }

    /// The other fail-closed direction: share mode against an ordinary ERC-20 has no `sharesOf`
    /// to call, so the settlement is refused rather than mismeasured.
    function test_Shares_RebasingModeAgainstAPlainErc20Reverts() public {
        bytes memory data = _venueCalldata(QUOTE, ASSET_OUT);
        PrimaryTypes.SettlementIntent memory intent = _venueIntent(data, QUOTE, FEE, collector);
        intent.accountingMode = uint8(PrimaryTypes.AssetAccountingMode.RebasingShares);

        _approveExact(intent);
        vm.expectRevert();
        _submit(data, intent, TAKER_BPS);
    }

    /// The settlement leg is untouched by any of this: the money still moves exactly as before.
    function test_Shares_TheMoneyLegIsUnchanged() public {
        uint256 buyerCurrencyBefore = currency.balanceOf(buyer);
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _sharePath();

        _settleVenueWith(data, intent, TAKER_BPS);

        assertEq(currency.balanceOf(buyer), buyerCurrencyBefore - QUOTE - FEE, "buyer debited quote plus fee");
        assertEq(currency.balanceOf(address(xstocks)), QUOTE, "the venue took the quote");
        assertEq(currency.balanceOf(collector), FEE, "the collector took the fee");
        assertEq(currency.allowance(address(router), address(xstocks)), 0, "no standing approval survives");
    }
}
