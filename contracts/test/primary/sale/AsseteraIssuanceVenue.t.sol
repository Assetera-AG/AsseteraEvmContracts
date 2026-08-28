// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdError} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {AsseteraIssuanceVenue} from "../../../src/primary/sale/AsseteraIssuanceVenue.sol";
import {IAsseteraIssuanceVenue} from "../../../src/primary/sale/IAsseteraIssuanceVenue.sol";
import {FaucetToken} from "../../mocks/FaucetToken.sol";
import {IssuerAssetToken} from "./mocks/IssuanceVenueMocks.sol";
import {IssuanceVenueTestBase} from "./IssuanceVenueTestBase.sol";

/// @title IssuanceVenueDeploymentTest
/// @notice What a venue is born with, and what it refuses to be born with.
contract IssuanceVenueDeploymentTest is IssuanceVenueTestBase {
    function test_Deployment_FixesTheOfferingsIdentity() public view {
        assertEq(venue.ROUTER(), router, "router");
        assertEq(address(venue.SETTLEMENT_TOKEN()), address(currency), "settlement token");
        assertEq(address(venue.ASSET_TOKEN()), address(asset), "asset token");
        assertEq(venue.SETTLEMENT_DECIMALS(), 6, "settlement decimals");
        assertEq(venue.ASSET_DECIMALS(), 18, "asset decimals");
        assertEq(venue.ASSET_UNIT(), 1e18, "asset unit");
        assertEq(venue.MIN_UNIT_PRICE(), MIN_UNIT_PRICE, "min price");
        assertEq(venue.MAX_UNIT_PRICE(), MAX_UNIT_PRICE, "max price");
        assertEq(venue.unitPrice(), UNIT_PRICE, "opening price");
    }

    function test_Deployment_GrantsEachRoleToItsOwnHolder() public view {
        assertTrue(venue.hasRole(venue.DEFAULT_ADMIN_ROLE(), admin), "admin");
        assertTrue(venue.hasRole(venue.RATE_SETTER_ROLE(), rateSetter), "rate setter");
        assertTrue(venue.hasRole(venue.PAUSER_ROLE(), pauser), "pauser");
        assertTrue(venue.hasRole(venue.TREASURY_ROLE(), treasurer), "treasurer");

        // The four are separate keys, not four names for one. A test that only asserted the
        // positive would pass on a contract that granted every role to everybody.
        assertFalse(venue.hasRole(venue.DEFAULT_ADMIN_ROLE(), rateSetter), "rate setter is not admin");
        assertFalse(venue.hasRole(venue.RATE_SETTER_ROLE(), admin), "admin is not the rate setter");
        assertFalse(venue.hasRole(venue.TREASURY_ROLE(), admin), "admin is not the treasury");
        assertFalse(venue.hasRole(venue.PAUSER_ROLE(), admin), "admin is not the pauser");
    }

    function test_Deployment_ConvertsTheCapFromWholeTokens() public view {
        assertEq(venue.maxSettlementPerPurchaseWholeUnits(), CAP_WHOLE, "whole units");
        assertEq(venue.maxSettlementPerPurchase(), CAP_WHOLE * 1e6, "raw units");
    }

    function test_Deployment_StartsUnpausedAndEmpty() public view {
        assertFalse(venue.paused(), "not paused");
        assertEq(_proceeds(), 0, "no proceeds");
    }

    /// 🔴 The most consequential deployment mistake there is, and the only defence against it is
    /// that a purchase reverts rather than half-settling.
    function test_Deployment_WithoutTheMintingRightCannotSell() public {
        AsseteraIssuanceVenue ungranted = new AsseteraIssuanceVenue(_config());
        vm.prank(router);
        currency.approve(address(ungranted), SPEND);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(ungranted), asset.MINTER_ROLE()
            )
        );
        vm.prank(router);
        ungranted.purchase(buyer, SPEND, EXPECT_OUT);
    }

    function test_Deployment_RejectsAZeroRouter() public {
        IAsseteraIssuanceVenue.SaleConfig memory config = _config();
        config.router = address(0);
        vm.expectRevert(IAsseteraIssuanceVenue.ZeroAddress.selector);
        new AsseteraIssuanceVenue(config);
    }

    function test_Deployment_RejectsAZeroRoleHolder() public {
        IAsseteraIssuanceVenue.SaleConfig memory config = _config();
        config.treasurer = address(0);
        vm.expectRevert(IAsseteraIssuanceVenue.ZeroAddress.selector);
        new AsseteraIssuanceVenue(config);
    }

    function test_Deployment_RejectsOneTokenPlayingBothParts() public {
        IAsseteraIssuanceVenue.SaleConfig memory config = _config();
        config.assetToken = address(currency);
        vm.expectRevert(IAsseteraIssuanceVenue.SameToken.selector);
        new AsseteraIssuanceVenue(config);
    }

    /// A zero floor would permit a price of zero, which divides into any payment an unbounded
    /// number of times. It is refused at deployment because nothing later could refuse it.
    function test_Deployment_RejectsAZeroPriceFloor() public {
        IAsseteraIssuanceVenue.SaleConfig memory config = _config();
        config.minUnitPrice = 0;
        vm.expectRevert(abi.encodeWithSelector(IAsseteraIssuanceVenue.PriceBoundsInvalid.selector, 0, MAX_UNIT_PRICE));
        new AsseteraIssuanceVenue(config);
    }

    function test_Deployment_RejectsInvertedPriceBounds() public {
        IAsseteraIssuanceVenue.SaleConfig memory config = _config();
        config.minUnitPrice = MAX_UNIT_PRICE + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IAsseteraIssuanceVenue.PriceBoundsInvalid.selector, MAX_UNIT_PRICE + 1, MAX_UNIT_PRICE
            )
        );
        new AsseteraIssuanceVenue(config);
    }

    /// The opening price goes through the same check a repricing does, so a venue cannot be born
    /// outside the bounds it will then be held to.
    function test_Deployment_RejectsAnOpeningPriceOutsideItsOwnBounds() public {
        IAsseteraIssuanceVenue.SaleConfig memory config = _config();
        config.unitPrice = MIN_UNIT_PRICE - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IAsseteraIssuanceVenue.UnitPriceOutOfBounds.selector, MIN_UNIT_PRICE - 1, MIN_UNIT_PRICE, MAX_UNIT_PRICE
            )
        );
        new AsseteraIssuanceVenue(config);
    }

    /// A zero cap is a valid, deliberate deployment — it deploys the venue CLOSED. The test that
    /// it then cannot sell is in `IssuanceVenueCapTest`.
    function test_Deployment_AcceptsAZeroCapAndIsThenClosed() public {
        IAsseteraIssuanceVenue.SaleConfig memory config = _config();
        config.maxSettlementPerPurchaseWholeUnits = 0;
        AsseteraIssuanceVenue closed = new AsseteraIssuanceVenue(config);
        assertEq(closed.maxSettlementPerPurchase(), 0, "closed");
    }

    /// Never accepts native currency: no `receive`, no `fallback`, nothing `payable`.
    function test_Deployment_RefusesNativeCurrency() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok,) = address(venue).call{value: 1 ether}("");
        assertFalse(ok, "a bare value transfer must revert");
        assertEq(address(venue).balance, 0, "no native balance");
    }
}

/// @title IssuanceVenuePurchaseTest
/// @notice The money path with well-behaved tokens: what the buyer gets, what the offering keeps.
contract IssuanceVenuePurchaseTest is IssuanceVenueTestBase {
    /// 🔴 The worked example from the contract's units table, asserted against literals rather
    /// than against a re-derivation: 125 mUSDC at 12.50 per token must be exactly 10 mRWA.
    function test_Purchase_TheWorkedExample() public {
        (uint256 minted, uint256 charged) = _purchase(SPEND, EXPECT_OUT);

        assertEq(minted, 10e18, "ten whole mRWA");
        assertEq(charged, 125_000_000, "one hundred and twenty-five mUSDC");
        assertEq(asset.balanceOf(buyer), 10e18, "delivered to the buyer");
        assertEq(asset.totalSupply(), 10e18, "and to nobody else");
        assertEq(_proceeds(), 125_000_000, "the offering keeps the proceeds");
    }

    function test_Purchase_EmitsTheMeasurements() public {
        _approveExact(SPEND);

        vm.expectEmit(true, true, true, true, address(venue));
        emit IAsseteraIssuanceVenue.IssuanceMinted(
            buyer, address(asset), EXPECT_OUT, address(currency), SPEND, UNIT_PRICE
        );

        vm.prank(router);
        venue.purchase(buyer, SPEND, EXPECT_OUT);
    }

    /// The asset never touches this contract on its way to the buyer.
    function test_Purchase_TheVenueNeverHoldsTheAsset() public {
        _purchase(SPEND, EXPECT_OUT);
        assertEq(asset.balanceOf(address(venue)), 0, "no asset held");
    }

    /// Proceeds ACCUMULATE. Nothing is forwarded during a purchase, so no external call to an
    /// admin-controlled address sits inside the settlement window.
    function test_Purchase_ProceedsAccumulateAcrossBuyers() public {
        _purchase(SPEND, EXPECT_OUT);

        vm.prank(router);
        currency.approve(address(venue), SPEND);
        vm.prank(router);
        venue.purchase(stranger, SPEND, EXPECT_OUT);

        assertEq(_proceeds(), 2 * SPEND, "both purchases still here");
        assertEq(asset.balanceOf(buyer), EXPECT_OUT, "first buyer");
        assertEq(asset.balanceOf(stranger), EXPECT_OUT, "second buyer");
    }

    /// The venue takes the exact cost of what it minted and leaves the rest of the allowance
    /// alone, which is what makes the router's approval a ceiling rather than a payment.
    function test_Purchase_ConsumesOnlyWhatItCharged() public {
        vm.prank(router);
        currency.approve(address(venue), SPEND * 2);

        vm.prank(router);
        venue.purchase(buyer, SPEND, EXPECT_OUT);

        assertEq(currency.allowance(router, address(venue)), SPEND, "the surplus allowance is untouched");
    }

    /// A price that does not divide the payment evenly still round-trips exactly, because the
    /// settlement token has FEWER decimals than the asset. That relationship is what makes the
    /// ceiling cost of the floored quantity land back on the payment offered; see
    /// `IssuanceVenueDecimalsTest` for the configuration where it does not.
    function test_Purchase_AnUnevenPriceStillChargesTheWholeOffer() public {
        vm.prank(rateSetter);
        venue.setUnitPrice(3_000_007);

        (uint256 minted, uint256 charged) = _purchase(7, 1);

        assertGt(minted, 0, "something was minted");
        assertEq(charged, 7, "and the whole offer was charged");
        assertEq(_proceeds(), 7, "proceeds match the charge");
    }

    function test_Purchase_RejectsAZeroBuyer() public {
        _approveExact(SPEND);
        vm.expectRevert(IAsseteraIssuanceVenue.ZeroAddress.selector);
        vm.prank(router);
        venue.purchase(address(0), SPEND, EXPECT_OUT);
    }

    function test_Purchase_RejectsAZeroPayment() public {
        _approveExact(SPEND);
        vm.expectRevert(IAsseteraIssuanceVenue.ZeroAmount.selector);
        vm.prank(router);
        venue.purchase(buyer, 0, 1);
    }

    /// The delivery floor is the buyer's protection against the price moving between the intent
    /// being signed and the transaction landing.
    function test_Purchase_RejectsAFillBelowTheFloor() public {
        vm.prank(rateSetter);
        venue.setUnitPrice(UNIT_PRICE * 2);

        _approveExact(SPEND);
        vm.expectRevert(
            abi.encodeWithSelector(IAsseteraIssuanceVenue.InsufficientAssetOut.selector, EXPECT_OUT / 2, EXPECT_OUT)
        );
        vm.prank(router);
        venue.purchase(buyer, SPEND, EXPECT_OUT);
    }

    /// A better price than the intent was signed at fills better, and does not revert.
    function test_Purchase_AFloorIsAFloorNotATolerance() public {
        vm.prank(rateSetter);
        venue.setUnitPrice(UNIT_PRICE / 2);

        (uint256 minted,) = _purchase(SPEND, EXPECT_OUT);
        assertEq(minted, EXPECT_OUT * 2, "filled above the floor");
    }

    /// The router's allowance is the true ceiling on what one purchase can move, and it is an
    /// exact per-call grant rather than a standing one.
    function test_Purchase_CannotSpendBeyondItsAllowance() public {
        _approveExact(SPEND - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(venue), SPEND - 1, SPEND)
        );
        _purchaseNoApprove(SPEND, EXPECT_OUT);
    }
}

/// @title IssuanceVenueAccessTest
/// @notice The single whitelisted caller, the four roles, and the pause.
contract IssuanceVenueAccessTest is IssuanceVenueTestBase {
    /// 🔴 The whole access model of the money path: one caller, named at deployment.
    function test_Purchase_RefusesEveryCallerButTheRouter() public {
        vm.prank(stranger);
        currency.approve(address(venue), SPEND);
        currency.mint(stranger, SPEND);

        vm.expectRevert(abi.encodeWithSelector(IAsseteraIssuanceVenue.CallerNotRouter.selector, stranger));
        vm.prank(stranger);
        venue.purchase(stranger, SPEND, EXPECT_OUT);
    }

    /// Not even the admin, and this is the point rather than an oversight. The router address is
    /// immutable, so there is no key on this contract that can make itself the caller.
    function test_Purchase_RefusesTheAdminToo() public {
        vm.expectRevert(abi.encodeWithSelector(IAsseteraIssuanceVenue.CallerNotRouter.selector, admin));
        vm.prank(admin);
        venue.purchase(buyer, SPEND, EXPECT_OUT);
    }

    /// The caller check runs BEFORE the pause check, so a stranger is told the durable fact
    /// rather than the transient one.
    function test_Purchase_TheCallerCheckOutranksThePause() public {
        vm.prank(pauser);
        venue.pause();

        vm.expectRevert(abi.encodeWithSelector(IAsseteraIssuanceVenue.CallerNotRouter.selector, stranger));
        vm.prank(stranger);
        venue.purchase(buyer, SPEND, EXPECT_OUT);
    }

    function test_Pause_StopsPurchases() public {
        vm.prank(pauser);
        venue.pause();

        _approveExact(SPEND);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _purchaseNoApprove(SPEND, EXPECT_OUT);
    }

    function test_Pause_IsPauserOnly() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, venue.PAUSER_ROLE()
            )
        );
        vm.prank(stranger);
        venue.pause();
    }

    /// 🔴 The asymmetry: whoever can stop the sale cannot restart it.
    function test_Unpause_IsAdminOnlyAndThePauserCannot() public {
        vm.prank(pauser);
        venue.pause();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, venue.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(pauser);
        venue.unpause();

        vm.prank(admin);
        venue.unpause();
        assertFalse(venue.paused(), "the admin can");
    }

    function test_Pause_ThenUnpause_RestoresTheSale() public {
        vm.prank(pauser);
        venue.pause();
        vm.prank(admin);
        venue.unpause();

        (uint256 minted,) = _purchase(SPEND, EXPECT_OUT);
        assertEq(minted, EXPECT_OUT, "selling again");
    }

    function test_SetUnitPrice_IsRateSetterOnly() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, admin, venue.RATE_SETTER_ROLE()
            )
        );
        vm.prank(admin);
        venue.setUnitPrice(UNIT_PRICE + 1);
    }

    /// 🔴 The cap is a check on what a mis-set price can do, so the key that sets the price must
    /// not be the key that raises the ceiling.
    function test_SetCap_IsAdminOnlyAndNotTheRateSetter() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, rateSetter, venue.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(rateSetter);
        venue.setMaxSettlementPerPurchase(CAP_WHOLE * 10);
    }

    function test_Withdraw_IsTreasuryOnly() public {
        _purchase(SPEND, EXPECT_OUT);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, admin, venue.TREASURY_ROLE()
            )
        );
        vm.prank(admin);
        venue.withdraw(admin, 1);
    }
}

/// @title IssuanceVenuePricingTest
/// @notice The price, its bounds, and the quotes an off-chain caller must be able to reproduce.
contract IssuanceVenuePricingTest is IssuanceVenueTestBase {
    function test_SetUnitPrice_MovesThePriceAndEmits() public {
        vm.expectEmit(true, true, true, true, address(venue));
        emit IAsseteraIssuanceVenue.UnitPriceSet(UNIT_PRICE, MIN_UNIT_PRICE);

        vm.prank(rateSetter);
        venue.setUnitPrice(MIN_UNIT_PRICE);
        assertEq(venue.unitPrice(), MIN_UNIT_PRICE, "repriced");
    }

    /// Both bounds are INCLUSIVE, and both are reachable.
    function test_SetUnitPrice_AcceptsExactlyTheBounds() public {
        vm.prank(rateSetter);
        venue.setUnitPrice(MIN_UNIT_PRICE);
        assertEq(venue.unitPrice(), MIN_UNIT_PRICE, "floor");

        vm.prank(rateSetter);
        venue.setUnitPrice(MAX_UNIT_PRICE);
        assertEq(venue.unitPrice(), MAX_UNIT_PRICE, "ceiling");
    }

    function test_SetUnitPrice_RejectsOneBelowTheFloor() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAsseteraIssuanceVenue.UnitPriceOutOfBounds.selector, MIN_UNIT_PRICE - 1, MIN_UNIT_PRICE, MAX_UNIT_PRICE
            )
        );
        vm.prank(rateSetter);
        venue.setUnitPrice(MIN_UNIT_PRICE - 1);
    }

    function test_SetUnitPrice_RejectsOneAboveTheCeiling() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAsseteraIssuanceVenue.UnitPriceOutOfBounds.selector, MAX_UNIT_PRICE + 1, MIN_UNIT_PRICE, MAX_UNIT_PRICE
            )
        );
        vm.prank(rateSetter);
        venue.setUnitPrice(MAX_UNIT_PRICE + 1);
    }

    /// 🔴 Zero is not a way to close the offering. The floor forbids it, so no repricing can make
    /// a payment buy an unbounded quantity.
    function test_SetUnitPrice_RejectsZero() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAsseteraIssuanceVenue.UnitPriceOutOfBounds.selector, 0, MIN_UNIT_PRICE, MAX_UNIT_PRICE
            )
        );
        vm.prank(rateSetter);
        venue.setUnitPrice(0);
    }

    /// Repricing a stopped offering is how it gets ready to restart.
    function test_SetUnitPrice_WorksWhilePaused() public {
        vm.prank(pauser);
        venue.pause();
        vm.prank(rateSetter);
        venue.setUnitPrice(MIN_UNIT_PRICE);
        assertEq(venue.unitPrice(), MIN_UNIT_PRICE, "repriced while stopped");
    }

    /// The two extremes of the price range, priced against literals. At one cent per token, 125
    /// mUSDC buys 12,500 whole tokens; at ten thousand, it buys 0.0125.
    function test_Quote_AtBothEndsOfThePriceRange() public {
        vm.prank(rateSetter);
        venue.setUnitPrice(MIN_UNIT_PRICE);
        (uint256 cheap,) = venue.quoteAssetOut(SPEND);
        assertEq(cheap, 12_500e18, "one cent a token");

        vm.prank(rateSetter);
        venue.setUnitPrice(MAX_UNIT_PRICE);
        (uint256 dear,) = venue.quoteAssetOut(SPEND);
        assertEq(dear, 12_500_000_000_000_000, "ten thousand a token");
    }

    /// 🔴 The quote view and the purchase must agree exactly, or every off-chain caller that
    /// sizes an intent from the view produces intents that revert at the floor.
    function testFuzz_Quote_AgreesWithThePurchase(uint256 settlementIn, uint256 price) public {
        price = bound(price, MIN_UNIT_PRICE, MAX_UNIT_PRICE);
        settlementIn = bound(settlementIn, 1, CAP_WHOLE * 1e6);

        vm.prank(rateSetter);
        venue.setUnitPrice(price);

        (uint256 quotedOut, uint256 quotedIn) = venue.quoteAssetOut(settlementIn);
        currency.mint(router, settlementIn);
        (uint256 minted, uint256 charged) = _purchase(settlementIn, quotedOut);

        assertEq(minted, quotedOut, "quantity");
        assertEq(charged, quotedIn, "cost");
    }

    /// The inverse view, used by an "I want N units" front end.
    function test_QuoteSettlementIn_IsTheCostOfAQuantity() public view {
        assertEq(venue.quoteSettlementIn(10e18), 125_000_000, "ten tokens cost 125 mUSDC");
        assertEq(venue.quoteSettlementIn(1e18), 12_500_000, "one token costs 12.50");
    }

    /// Both directions round in the offering's favour, so a quantity fed back through the cost
    /// view can buy marginally more than it started with. That is why `purchase` prices the
    /// quantity it derived rather than one it was handed.
    function test_QuoteSettlementIn_RoundsUp() public {
        vm.prank(rateSetter);
        venue.setUnitPrice(3_000_001);
        // One wei of an 18-decimal asset costs a fraction of one raw mUSDC unit; the offering is
        // never short-paid, so that fraction is charged as one.
        assertEq(venue.quoteSettlementIn(1), 1, "rounded up, never down");
    }

    function test_Quote_RejectsZero() public {
        vm.expectRevert(IAsseteraIssuanceVenue.ZeroAmount.selector);
        venue.quoteAssetOut(0);

        vm.expectRevert(IAsseteraIssuanceVenue.ZeroAmount.selector);
        venue.quoteSettlementIn(0);
    }
}

/// @title IssuanceVenueCapTest
/// @notice The per-purchase cap: a bound on bugs, at its boundary values.
contract IssuanceVenueCapTest is IssuanceVenueTestBase {
    function test_Cap_AcceptsExactlyTheCap() public {
        uint256 cap = venue.maxSettlementPerPurchase();
        currency.mint(router, cap);
        (uint256 minted,) = _purchase(cap, 1);
        assertGt(minted, 0, "a purchase at exactly the cap succeeds");
    }

    function test_Cap_RefusesOneUnitAboveIt() public {
        uint256 cap = venue.maxSettlementPerPurchase();
        currency.mint(router, cap + 1);
        _approveExact(cap + 1);

        vm.expectRevert(abi.encodeWithSelector(IAsseteraIssuanceVenue.PurchaseCapExceeded.selector, cap + 1, cap));
        _purchaseNoApprove(cap + 1, 1);
    }

    /// 🔴 A zero cap means "this venue cannot sell", not "unlimited" — the same fail-closed
    /// reading the router gives an unset settlement cap.
    function test_Cap_ZeroClosesTheVenue() public {
        vm.prank(admin);
        venue.setMaxSettlementPerPurchase(0);

        _approveExact(SPEND);
        vm.expectRevert(abi.encodeWithSelector(IAsseteraIssuanceVenue.PurchaseCapExceeded.selector, SPEND, 0));
        _purchaseNoApprove(SPEND, EXPECT_OUT);
    }

    /// The cap is charged against what the caller AUTHORISED, before any external call, so an
    /// oversized purchase never reaches a token.
    function test_Cap_IsChargedBeforeAnyTokenIsTouched() public {
        vm.prank(admin);
        venue.setMaxSettlementPerPurchase(1);

        // No allowance at all: if the cap were charged after the pull, this would fail on the
        // allowance instead and the test would be asserting the wrong thing.
        vm.expectRevert(abi.encodeWithSelector(IAsseteraIssuanceVenue.PurchaseCapExceeded.selector, SPEND, 1e6));
        _purchaseNoApprove(SPEND, EXPECT_OUT);
    }

    function test_SetCap_EmitsBothFormsAndTheDecimals() public {
        vm.expectEmit(true, true, true, true, address(venue));
        emit IAsseteraIssuanceVenue.PurchaseCapSet(250, 250e6, 6);

        vm.prank(admin);
        venue.setMaxSettlementPerPurchase(250);
        assertEq(venue.maxSettlementPerPurchase(), 250e6, "raw");
        assertEq(venue.maxSettlementPerPurchaseWholeUnits(), 250, "whole");
    }

    /// A cap large enough to overflow the conversion panics rather than wrapping to something
    /// small — or, worse, to something enormous.
    function test_SetCap_OverflowingWholeUnitsPanics() public {
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(admin);
        venue.setMaxSettlementPerPurchase(type(uint256).max);
    }
}

/// @title IssuanceVenueTreasuryTest
/// @notice Getting the proceeds out, which is the reason the treasury role exists.
contract IssuanceVenueTreasuryTest is IssuanceVenueTestBase {
    function test_Withdraw_MovesProceedsToANamedDestination() public {
        _purchase(SPEND, EXPECT_OUT);

        vm.expectEmit(true, true, true, true, address(venue));
        emit IAsseteraIssuanceVenue.ProceedsWithdrawn(issuer, SPEND);

        vm.prank(treasurer);
        venue.withdraw(issuer, SPEND);

        assertEq(currency.balanceOf(issuer), SPEND, "the issuer has the money");
        assertEq(_proceeds(), 0, "and the venue has none");
    }

    function test_Withdraw_CanBePartial() public {
        _purchase(SPEND, EXPECT_OUT);
        vm.prank(treasurer);
        venue.withdraw(issuer, SPEND / 2);
        assertEq(_proceeds(), SPEND / 2, "the rest stays");
    }

    /// 🔴 A stopped offering is exactly when an issuer most needs to reach the money.
    function test_Withdraw_WorksWhilePaused() public {
        _purchase(SPEND, EXPECT_OUT);
        vm.prank(pauser);
        venue.pause();

        vm.prank(treasurer);
        venue.withdraw(issuer, SPEND);
        assertEq(currency.balanceOf(issuer), SPEND, "withdrawable while stopped");
    }

    function test_Withdraw_RejectsZeroArguments() public {
        _purchase(SPEND, EXPECT_OUT);

        vm.expectRevert(IAsseteraIssuanceVenue.ZeroAddress.selector);
        vm.prank(treasurer);
        venue.withdraw(address(0), 1);

        vm.expectRevert(IAsseteraIssuanceVenue.ZeroAmount.selector);
        vm.prank(treasurer);
        venue.withdraw(issuer, 0);
    }

    /// The destination is per call. Nothing is stored, so no key can pre-set where the proceeds
    /// will go and wait for a different key to send them.
    function test_Withdraw_HasNoStoredDestination() public {
        _purchase(SPEND, EXPECT_OUT);
        vm.prank(treasurer);
        venue.withdraw(stranger, SPEND);
        assertEq(currency.balanceOf(stranger), SPEND, "wherever this call said");
    }

    function test_Rescue_SweepsAStrayToken() public {
        FaucetToken stray = new FaucetToken("Stray", "STRAY", 18);
        stray.mint(address(venue), 5e18);

        vm.expectEmit(true, true, true, true, address(venue));
        emit IAsseteraIssuanceVenue.TokensRescued(address(stray), issuer, 5e18);

        vm.prank(treasurer);
        venue.rescue(address(stray), issuer, 5e18);
        assertEq(stray.balanceOf(issuer), 5e18, "swept");
    }

    /// 🔴 Proceeds leave through `withdraw` and nowhere else, so one event means one thing.
    function test_Rescue_RefusesTheSettlementCurrency() public {
        _purchase(SPEND, EXPECT_OUT);
        vm.expectRevert(IAsseteraIssuanceVenue.RescueOfSettlementToken.selector);
        vm.prank(treasurer);
        venue.rescue(address(currency), issuer, SPEND);
    }

    function test_Rescue_IsTreasuryOnly() public {
        FaucetToken stray = new FaucetToken("Stray", "STRAY", 18);
        stray.mint(address(venue), 1e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, venue.TREASURY_ROLE()
            )
        );
        vm.prank(stranger);
        venue.rescue(address(stray), stranger, 1e18);
    }
}

/// @title IssuanceVenueDecimalsTest
/// @notice The decimals question from both sides, because the pair this contract is built for
///         (6-decimal currency, 18-decimal asset) exercises only one of them.
///
/// @dev    ⚠️ **The relationship between the two decimal counts decides which code paths are
///         reachable at all**, and that is worth having written down rather than rediscovered:
///
///         * With `unitPrice < assetUnit` — the mUSDC/mRWA case, where the price of one whole
///           token in a 6-decimal currency is nowhere near `1e18` — the ceiling cost of the
///           floored quantity always lands back on the payment offered. So the venue always
///           charges the full offer, `NothingToMint` is unreachable for any non-zero payment, and
///           the router's refund path never fires for this venue.
///         * Reverse the decimals — an 18-decimal currency buying a 6-decimal asset — and both
///           become reachable: a payment can round down to a strictly smaller charge, and a
///           payment below the price of one asset unit buys nothing at all.
///
///         Both are asserted below. A suite that only ever ran the first configuration would be
///         claiming coverage of arithmetic it never executed.
contract IssuanceVenueDecimalsTest is IssuanceVenueTestBase {
    FaucetToken internal bigCurrency;

    /// 12.50 of an 18-decimal currency, per one whole asset token.
    uint256 internal constant REVERSED_PRICE = 12_500_000_000_000_000_000;
    uint256 internal constant REVERSED_MIN = 1e16;
    uint256 internal constant REVERSED_MAX = 10_000e18;

    function setUp() public override {
        super.setUp();
        bigCurrency = new FaucetToken("Mock Euro", "mEUR", 18);
        bigCurrency.mint(router, 1_000_000e18);
    }

    /// An 18-decimal currency buying a 6-decimal asset — the configuration in which the price of
    /// one whole token EXCEEDS `assetUnit`, which is what makes the two paths below reachable.
    function _reversedVenue() internal returns (AsseteraIssuanceVenue v, SixDecimalAssetToken t) {
        t = new SixDecimalAssetToken("Mock Six", "mSIX", issuer);
        v = new AsseteraIssuanceVenue(
            IAsseteraIssuanceVenue.SaleConfig({
                admin: admin,
                rateSetter: rateSetter,
                pauser: pauser,
                treasurer: treasurer,
                router: router,
                settlementToken: address(bigCurrency),
                assetToken: address(t),
                unitPrice: REVERSED_PRICE,
                minUnitPrice: REVERSED_MIN,
                maxUnitPrice: REVERSED_MAX,
                maxSettlementPerPurchaseWholeUnits: CAP_WHOLE
            })
        );
        bytes32 minter = t.MINTER_ROLE();
        vm.prank(issuer);
        t.grantRole(minter, address(v));
    }

    /// Both decimals counts come from the tokens themselves, and both are used: the asset's for
    /// the quote scale, the currency's for the cap conversion.
    function test_Reversed_ReadsBothDecimalsFromTheTokens() public {
        (AsseteraIssuanceVenue v,) = _reversedVenue();
        assertEq(v.SETTLEMENT_DECIMALS(), 18, "currency decimals");
        assertEq(v.ASSET_DECIMALS(), 6, "asset decimals");
        assertEq(v.ASSET_UNIT(), 1e6, "asset unit");
        assertEq(v.maxSettlementPerPurchase(), CAP_WHOLE * 1e18, "cap converted at eighteen, not six");
    }

    /// 🔴 The refund path, reachable only when the price of one whole token exceeds `assetUnit`.
    /// The router treats a venue that consumed less than it approved as ordinary and refunds the
    /// difference to the buyer; this is the venue behaviour that produces one.
    function test_Reversed_ChargesLessThanOfferedWhenTheQuantityRoundsDown() public {
        (AsseteraIssuanceVenue v,) = _reversedVenue();

        uint256 offered = 125e18 + 1;
        vm.prank(router);
        bigCurrency.approve(address(v), offered);
        vm.prank(router);
        (uint256 minted, uint256 charged) = v.purchase(buyer, offered, 1);

        assertEq(minted, 10e6, "ten whole tokens, at six decimals");
        assertEq(charged, 125e18, "the odd wei bought nothing and was not charged for");
        assertLt(charged, offered, "the venue consumed less than it was offered");
        assertEq(bigCurrency.balanceOf(address(v)), charged, "and kept only what it charged");
    }

    /// 🔴 A payment too small to buy a single unit reverts rather than becoming a pure debit:
    /// money taken, nothing minted, no error.
    function test_Reversed_RefusesAPaymentThatBuysNothing() public {
        (AsseteraIssuanceVenue v,) = _reversedVenue();

        // One unit of the six-decimal asset costs 12.5e12 wei of an 18-decimal currency; anything
        // below that rounds to a quantity of zero.
        uint256 tooLittle = 12_499_999_999_999;
        vm.prank(router);
        bigCurrency.approve(address(v), tooLittle);

        vm.expectRevert(
            abi.encodeWithSelector(IAsseteraIssuanceVenue.NothingToMint.selector, tooLittle, REVERSED_PRICE)
        );
        vm.prank(router);
        v.purchase(buyer, tooLittle, 0);
    }

    /// And one unit up, the same payment buys exactly one unit.
    function test_Reversed_TheSmallestPaymentThatBuysSomething() public {
        (AsseteraIssuanceVenue v,) = _reversedVenue();

        uint256 justEnough = 12_500_000_000_000;
        vm.prank(router);
        bigCurrency.approve(address(v), justEnough);
        vm.prank(router);
        (uint256 minted, uint256 charged) = v.purchase(buyer, justEnough, 1);

        assertEq(minted, 1, "one smallest unit of the asset");
        assertEq(charged, justEnough, "priced exactly");
    }

    /// 🔴 The primary configuration (fewer decimals on the currency than on the asset), stated as
    /// the property it actually has: no payment is ever partly unspent, at any price in range.
    function testFuzz_Primary_AlwaysChargesTheWholeOffer(uint256 settlementIn, uint256 price) public {
        price = bound(price, MIN_UNIT_PRICE, MAX_UNIT_PRICE);
        settlementIn = bound(settlementIn, 1, CAP_WHOLE * 1e6);

        vm.prank(rateSetter);
        venue.setUnitPrice(price);

        currency.mint(router, settlementIn);
        (, uint256 charged) = _purchase(settlementIn, 0);
        assertEq(charged, settlementIn, "no residue is possible in this configuration");
    }

    /// A decimals count no real token reports is refused at deployment, because `10 ** decimals`
    /// is an immutable of this contract and a nonsense one makes every quote nonsense.
    function test_Deployment_RejectsAbsurdDecimals() public {
        FaucetToken absurd = new FaucetToken("Absurd", "ABS", 200);
        IAsseteraIssuanceVenue.SaleConfig memory config = _config();
        config.assetToken = address(absurd);
        vm.expectRevert(
            abi.encodeWithSelector(IAsseteraIssuanceVenue.TokenDecimalsImplausible.selector, address(absurd), 200)
        );
        new AsseteraIssuanceVenue(config);
    }

    /// An address with no code cannot answer `decimals()`, so the deployment aborts in front of
    /// whoever typed the address rather than producing a venue that quotes nonsense.
    function test_Deployment_RejectsATokenWithNoCode() public {
        IAsseteraIssuanceVenue.SaleConfig memory config = _config();
        config.assetToken = makeAddr("notAToken");
        vm.expectRevert();
        new AsseteraIssuanceVenue(config);
    }
}

/// @notice A six-decimal asset token. Declared here rather than in the shared mocks because it
///         exists only to make the reversed-decimals arithmetic reachable, and putting it beside
///         the tests that need it keeps the shared fixture honest about the pair it models.
contract SixDecimalAssetToken is IssuerAssetToken {
    constructor(string memory name_, string memory symbol_, address issuer_)
        IssuerAssetToken(name_, symbol_, issuer_)
    {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
