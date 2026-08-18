// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AsseteraIssuanceVenue} from "../../../src/primary/sale/AsseteraIssuanceVenue.sol";
import {IAsseteraIssuanceVenue} from "../../../src/primary/sale/IAsseteraIssuanceVenue.sol";
import {FeeOnTransferCurrency, SenderSurchargeCurrency, RebasingAsset} from "../mocks/PrimaryWeirdTokens.sol";
import {
    ShortMintAssetToken,
    OverMintAssetToken,
    LegacyMintAssetToken,
    ReentrantCurrency,
    ForwardingRouter
} from "./mocks/IssuanceVenueMocks.sol";
import {AlternateMintIssuanceVenue} from "./mocks/AlternateMintIssuanceVenue.sol";
import {IssuanceVenueTestBase} from "./IssuanceVenueTestBase.sol";

/// @title IssuanceVenueHostileCurrencyTest
/// @notice Settlement currencies that do not move what they were asked to move.
///
/// @dev    The venue measures its own balance across the pull for one reason: a currency that
///         debits the payer in full and credits the venue less would otherwise have the venue
///         minting the FULL quantity against a SHORT payment, every purchase, silently. The
///         shortfall would sit in the offering's proceeds and nobody would find it until a
///         reconciliation ran.
contract IssuanceVenueHostileCurrencyTest is IssuanceVenueTestBase {
    /// A venue whose settlement currency is `weird`, built with the standard asset and roles.
    function _venueOn(address weirdCurrency) internal returns (AsseteraIssuanceVenue v) {
        IAsseteraIssuanceVenue.SaleConfig memory config = _config();
        config.settlementToken = weirdCurrency;
        v = new AsseteraIssuanceVenue(config);

        bytes32 minter = asset.MINTER_ROLE();
        vm.prank(issuer);
        asset.grantRole(minter, address(v));
    }

    /// 🔴 A deflationary settlement currency cannot be sold in AT ALL, and that is a listing
    /// decision taken at the line that moves the money rather than discovered in the ledger.
    function test_FeeOnTransferCurrency_CannotBeSoldIn() public {
        FeeOnTransferCurrency lossy = new FeeOnTransferCurrency("Lossy USD", "lUSD", 100); // 1 %
        AsseteraIssuanceVenue v = _venueOn(address(lossy));

        lossy.mint(router, SPEND);
        vm.prank(router);
        lossy.approve(address(v), SPEND);

        uint256 expectedReceipt = SPEND - (SPEND * 100) / 10_000;
        vm.expectRevert(
            abi.encodeWithSelector(IAsseteraIssuanceVenue.SettlementPullMismatch.selector, SPEND, expectedReceipt)
        );
        vm.prank(router);
        v.purchase(buyer, SPEND, EXPECT_OUT);

        assertEq(asset.totalSupply(), 0, "nothing was minted against a short payment");
    }

    /// The mirror shape, and the honest limit of what a venue can see. A currency that surcharges
    /// the SENDER credits the venue in full, so nothing here can tell it from an ordinary one —
    /// the loss lands entirely on the caller. The router's own zero-standing-balance invariant is
    /// what catches this (`VenueSettlerHostile.t.sol`); reported here rather than defended
    /// against, because a recipient cannot observe a sender's debit.
    function test_SenderSurchargeCurrency_LooksNormalFromInsideTheVenue() public {
        SenderSurchargeCurrency surcharging = new SenderSurchargeCurrency("Surcharge USD", "sUSD", 100);
        AsseteraIssuanceVenue v = _venueOn(address(surcharging));

        surcharging.mint(router, SPEND * 2);
        vm.prank(router);
        surcharging.approve(address(v), SPEND);
        vm.prank(router);
        (uint256 minted, uint256 charged) = v.purchase(buyer, SPEND, EXPECT_OUT);

        assertEq(minted, EXPECT_OUT, "the buyer got what they paid for");
        assertEq(charged, SPEND, "and the venue was credited in full");
        assertLt(surcharging.balanceOf(router), SPEND, "while the caller paid more than it moved");
    }

    /// 🔴 A settlement currency that re-enters mid-pull is trying to get a second mint out of one
    /// payment. It gets exactly one — and the check that stops it is the CALLER ALLOWLIST, not
    /// the reentrancy guard, because the token is not the router. Worth pinning as the specific
    /// error rather than as "it failed": the caller allowlist is the outer line of defence and a
    /// change that relaxed it would still leave this test green if it only asserted a revert.
    function test_ReentrantCurrency_CannotMintTwiceFromOnePayment() public {
        ReentrantCurrency hostile = new ReentrantCurrency("Reentrant USD", "rUSD");
        AsseteraIssuanceVenue v = _venueOn(address(hostile));

        hostile.mint(router, SPEND * 4);
        vm.prank(router);
        hostile.approve(address(v), SPEND * 4);
        hostile.arm(address(v), abi.encodeCall(AsseteraIssuanceVenue.purchase, (buyer, SPEND, EXPECT_OUT)));

        vm.prank(router);
        (uint256 minted,) = v.purchase(buyer, SPEND, EXPECT_OUT);

        assertEq(hostile.reentryAttempts(), 1, "the token did try");
        assertFalse(hostile.reentrySucceeded(), "and was refused");
        assertEq(
            bytes4(hostile.lastReentryError()),
            IAsseteraIssuanceVenue.CallerNotRouter.selector,
            "refused because a token is not the router"
        );
        assertEq(minted, EXPECT_OUT, "the outer purchase completed");
        assertEq(asset.balanceOf(buyer), EXPECT_OUT, "exactly one purchase reached the buyer");
        assertEq(asset.totalSupply(), EXPECT_OUT, "and exactly one was ever minted");
    }

    /// 🔴 And the inner line of defence, asked directly: what if the TRUSTED caller re-enters?
    ///
    /// The real router holds its own `nonReentrant` for the whole settlement, so this cannot
    /// happen in production — which is exactly why it has to be tested against a router mock that
    /// has no guard at all. The venue's guarantee must not be a property of its caller's
    /// implementation.
    function test_ReentrantCurrency_EvenTheRouterCannotReEnter() public {
        ReentrantCurrency hostile = new ReentrantCurrency("Reentrant USD", "rUSD");
        ForwardingRouter guardlessRouter = new ForwardingRouter();

        IAsseteraIssuanceVenue.SaleConfig memory config = _config();
        config.settlementToken = address(hostile);
        config.router = address(guardlessRouter);
        AsseteraIssuanceVenue v = new AsseteraIssuanceVenue(config);

        bytes32 minter = asset.MINTER_ROLE();
        vm.prank(issuer);
        asset.grantRole(minter, address(v));

        // Four purchases' worth of balance and allowance, so nothing but the guard is scarce.
        hostile.mint(address(guardlessRouter), SPEND * 4);
        guardlessRouter.approve(address(hostile), address(v), SPEND * 4);
        hostile.arm(
            address(guardlessRouter), abi.encodeCall(ForwardingRouter.forward, (address(v), buyer, SPEND, EXPECT_OUT))
        );

        guardlessRouter.forward(address(v), buyer, SPEND, EXPECT_OUT);

        assertEq(hostile.reentryAttempts(), 1, "the reentrant call was made from the trusted caller");
        assertEq(
            bytes4(hostile.lastReentryError()),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector,
            "and the venue's own guard refused it"
        );
        assertEq(asset.totalSupply(), EXPECT_OUT, "one payment, one issuance");
    }
}

/// @title IssuanceVenueHostileAssetTest
/// @notice Asset tokens whose `mint` does not do what it says.
contract IssuanceVenueHostileAssetTest is IssuanceVenueTestBase {
    function _venueMinting(address weirdAsset) internal returns (AsseteraIssuanceVenue v) {
        IAsseteraIssuanceVenue.SaleConfig memory config = _config();
        config.assetToken = weirdAsset;
        v = new AsseteraIssuanceVenue(config);
    }

    /// 🔴 A token that takes a cut of every issuance. Nothing reverts on its own, so the only
    /// thing that catches it is the venue measuring what the buyer actually received.
    function test_ShortMint_IsRefused() public {
        ShortMintAssetToken lossy = new ShortMintAssetToken("Lossy RWA", "lRWA", 100); // 1 %
        AsseteraIssuanceVenue v = _venueMinting(address(lossy));

        vm.prank(router);
        currency.approve(address(v), SPEND);

        uint256 delivered = EXPECT_OUT - (EXPECT_OUT * 100) / 10_000;
        vm.expectRevert(
            abi.encodeWithSelector(IAsseteraIssuanceVenue.AssetDeliveryShortfall.selector, delivered, EXPECT_OUT)
        );
        vm.prank(router);
        v.purchase(buyer, SPEND, EXPECT_OUT);
    }

    /// 🔴 The worst shape of all, because it is the quietest: a `mint` that returns without
    /// reverting and creates nothing. A venue that trusted the call would take the payment and
    /// deliver nothing, and the router's own floor would be the only thing left between the buyer
    /// and a pure debit.
    function test_SilentMint_IsRefused() public {
        ShortMintAssetToken silent = new ShortMintAssetToken("Silent RWA", "sRWA", 10_000); // 100 %
        AsseteraIssuanceVenue v = _venueMinting(address(silent));

        vm.prank(router);
        currency.approve(address(v), SPEND);

        vm.expectRevert(abi.encodeWithSelector(IAsseteraIssuanceVenue.AssetDeliveryShortfall.selector, 0, EXPECT_OUT));
        vm.prank(router);
        v.purchase(buyer, SPEND, EXPECT_OUT);
    }

    /// 🔴 Over-delivery is ACCEPTED — a floor is not a ceiling — but it is not reported as
    /// issuance. The event carries the quantity the venue created, so an inflation that has
    /// nothing to do with this sale does not enter the offering's record.
    function test_OverMint_SucceedsAndStillReportsWhatWasIssued() public {
        OverMintAssetToken generous = new OverMintAssetToken("Generous RWA", "gRWA", 1_000); // +10 %
        AsseteraIssuanceVenue v = _venueMinting(address(generous));

        vm.prank(router);
        currency.approve(address(v), SPEND);

        vm.expectEmit(true, true, true, true, address(v));
        emit IAsseteraIssuanceVenue.IssuanceMinted(
            buyer, address(generous), EXPECT_OUT, address(currency), SPEND, UNIT_PRICE
        );

        vm.prank(router);
        (uint256 minted,) = v.purchase(buyer, SPEND, EXPECT_OUT);

        assertEq(minted, EXPECT_OUT, "the return value is the issuance, not the delta");
        assertEq(generous.balanceOf(buyer), EXPECT_OUT + EXPECT_OUT / 10, "the buyer kept the surplus");
    }

    /// A rebase BEFORE the purchase is outside the measurement, because the snapshot is taken
    /// inside the call rather than carried across blocks. A buyer who already holds a position
    /// therefore gets the same fill as one who does not.
    function test_RebasingAsset_ARebaseBeforeTheCallIsOutsideTheMeasurement() public {
        RebasingAsset rebasing = new RebasingAsset("Rebasing RWA", "rRWA");
        AsseteraIssuanceVenue v = _venueMinting(address(rebasing));

        rebasing.mint(buyer, 100e18);
        rebasing.rebase(buyer, 5_000); // +50 %, before anything is bought
        uint256 before = rebasing.balanceOf(buyer);

        vm.prank(router);
        currency.approve(address(v), SPEND);
        vm.prank(router);
        (uint256 minted,) = v.purchase(buyer, SPEND, EXPECT_OUT);

        assertEq(minted, EXPECT_OUT, "the fill is unaffected by the buyer's existing position");
        assertEq(rebasing.balanceOf(buyer), before + EXPECT_OUT, "and the position simply grew by it");
    }
}

/// @title IssuanceVenueMintSeamTest
/// @notice The claim that the OpenZeppelin mint shape is isolated behind one internal function,
///         run as evidence rather than asserted in a comment.
contract IssuanceVenueMintSeamTest is IssuanceVenueTestBase {
    bytes32 internal constant PARTITION = keccak256("SERIES-A");

    LegacyMintAssetToken internal legacy;
    AlternateMintIssuanceVenue internal alt;

    function setUp() public override {
        super.setUp();

        legacy = new LegacyMintAssetToken("Partitioned RWA", "pRWA");
        IAsseteraIssuanceVenue.SaleConfig memory config = _config();
        config.assetToken = address(legacy);
        alt = new AlternateMintIssuanceVenue(config, PARTITION);
    }

    /// 🔴 A token whose mint is `issue(address,uint256,bytes32)` sells through the same money
    /// path, with the same numbers, having changed one internal function and nothing else.
    function test_AlternateMint_SellsIdenticallyToTheStandardVenue() public {
        vm.prank(router);
        currency.approve(address(alt), SPEND);

        vm.expectEmit(true, true, true, true, address(alt));
        emit IAsseteraIssuanceVenue.IssuanceMinted(
            buyer, address(legacy), EXPECT_OUT, address(currency), SPEND, UNIT_PRICE
        );

        vm.prank(router);
        (uint256 minted, uint256 charged) = alt.purchase(buyer, SPEND, EXPECT_OUT);

        assertEq(minted, EXPECT_OUT, "same quantity");
        assertEq(charged, SPEND, "same charge");
        assertEq(legacy.balanceOf(buyer), EXPECT_OUT, "delivered through the other signature");
        assertEq(legacy.lastPartition(), PARTITION, "and the extra argument really was passed");
    }

    /// Everything the base class enforces is still enforced through the override: the caller, the
    /// cap, the floor and the measured delivery are not things a subclass can weaken by
    /// forgetting them.
    function test_AlternateMint_InheritsEveryGuard() public {
        vm.expectRevert(abi.encodeWithSelector(IAsseteraIssuanceVenue.CallerNotRouter.selector, stranger));
        vm.prank(stranger);
        alt.purchase(buyer, SPEND, EXPECT_OUT);

        vm.prank(admin);
        alt.setMaxSettlementPerPurchase(0);
        vm.expectRevert(abi.encodeWithSelector(IAsseteraIssuanceVenue.PurchaseCapExceeded.selector, SPEND, 0));
        vm.prank(router);
        alt.purchase(buyer, SPEND, EXPECT_OUT);
    }
}

/// @title IssuanceVenueCapCatchesTheDecimalsBugTest
/// @notice The specific failure the per-purchase cap exists for, written down as a test so the
///         cap's justification is not only a paragraph.
///
/// @dev    A caller that means "125 mUSDC" and passes an 18-decimal number instead of a
///         6-decimal one is off by a factor of a trillion. Nothing about the arithmetic is
///         invalid — it is a perfectly well-formed purchase of an absurd size — so the price
///         bounds do not catch it, the delivery floor does not catch it and the buyer's own
///         signature would have been produced by the same mistaken code. The cap does.
contract IssuanceVenueCapCatchesTheDecimalsBugTest is IssuanceVenueTestBase {
    function test_Cap_CatchesASettlementAmountSizedInTheWrongDecimals() public {
        uint256 meant = 125_000_000; // 125 mUSDC, six decimals
        uint256 typoed = 125e18; // the same number, sized as if mUSDC had eighteen

        currency.mint(router, typoed);
        _approveExact(typoed);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAsseteraIssuanceVenue.PurchaseCapExceeded.selector, typoed, venue.maxSettlementPerPurchase()
            )
        );
        _purchaseNoApprove(typoed, 1);

        // And the number that was actually meant goes through, so the cap is bounding the bug
        // rather than the business.
        (uint256 minted,) = _purchase(meant, EXPECT_OUT);
        assertEq(minted, EXPECT_OUT, "the intended purchase is unaffected");
    }
}
