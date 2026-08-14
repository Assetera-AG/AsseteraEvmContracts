// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {AsseteraPrimarySales} from "../../src/primary/AsseteraPrimarySales.sol";
import {PrimaryTypes} from "../../src/primary/types/PrimaryTypes.sol";
import {GateTypes} from "../../src/types/GateTypes.sol";
import {ISettler} from "../../src/primary/interfaces/ISettler.sol";
import {ISettlementLimits} from "../../src/primary/interfaces/ISettlementLimits.sol";
import {IFeeGate} from "../../src/interfaces/IFeeGate.sol";
import {VenueSettler} from "../../src/primary/settle/VenueSettler.sol";
import {FeeMath} from "../../src/libs/FeeMath.sol";
import {FaucetToken} from "../mocks/FaucetToken.sol";
import {DinariLikeVenue} from "../mocks/DinariLikeVenue.sol";
import {CappedPrimarySalesHarness} from "./mocks/CappedPrimarySalesHarness.sol";
import {PrimarySalesTestBase} from "./PrimarySalesTestBase.sol";

/// @title VenueSettlerTestBase
/// @notice The fixture family S2 needs and `PrimarySalesTestBase` deliberately does not have:
///         two REAL ERC-20s and a real venue. The shared base uses codeless placeholder
///         addresses because the skeleton packet never reached a transfer; this packet is
///         nothing but transfers.
///
/// @dev    A THIRD proxy, alongside the base's `sales` and `harness`. It runs the real
///         `VenueSettler` with a mock `ISettlementLimits` behind it, so nothing here waits on
///         AO-517. Every signing helper comes from the shared base — this file adds fixtures,
///         not a second harness.
abstract contract VenueSettlerTestBase is PrimarySalesTestBase {
    CappedPrimarySalesHarness internal router;
    FaucetToken internal currency;
    FaucetToken internal asset;
    DinariLikeVenue internal venue;

    /// A USDC-shaped quote: six decimals, so a fee that does not divide exactly is reachable
    /// with realistic numbers rather than only with wei-sized ones.
    uint256 internal constant QUOTE = 1_000e6;
    /// 50 bps of `QUOTE`, which divides exactly. The rounding policy is pinned separately.
    uint256 internal constant FEE = 5e6;
    uint16 internal constant TAKER_BPS = 50;
    uint256 internal constant MAX_IN_VENUE = QUOTE + FEE;
    uint256 internal constant MIN_OUT = 40e18;
    /// What the venue delivers on the happy path — comfortably above the floor, so a test that
    /// fails on delivery has failed for the reason it names.
    uint256 internal constant ASSET_OUT = 41e18;

    function setUp() public virtual override {
        super.setUp();

        currency = new FaucetToken("Mock USD Coin", "mUSDC", 6);
        asset = new FaucetToken("Mock Tokenised Equity", "mEQ", 18);
        venue = new DinariLikeVenue();

        CappedPrimarySalesHarness impl = new CappedPrimarySalesHarness(address(forwarder));
        bytes memory initData =
            abi.encodeCall(AsseteraPrimarySales.initialize, (admin, kycSigner, feeSigner, settlementSigner));
        router = CappedPrimarySalesHarness(address(new ERC1967Proxy(address(impl), initData)));

        vm.prank(admin);
        router.setAllowedCollector(collector, true);

        currency.mint(buyer, 10_000e6);
    }

    // ── fixtures ──────────────────────────────────────────────────────────────────────────

    /// The opaque bytes the venue is handed. The router never interprets them; only their hash
    /// and first four bytes are ever compared to anything.
    function _venueCalldata(uint256 paymentAmount, uint256 assetAmount) internal view returns (bytes memory) {
        return abi.encodeCall(
            DinariLikeVenue.requestOrder,
            (DinariLikeVenue.Order({
                    paymentToken: address(currency),
                    paymentAmount: paymentAmount,
                    assetToken: address(asset),
                    assetAmount: assetAmount,
                    recipient: buyer
                }))
        );
    }

    /// A settlement intent over the real fixtures, with every amount overridable so a single
    /// helper covers the happy path and every revert.
    function _venueIntent(bytes memory venueCalldata, uint256 quote, uint256 buyerFee, address feeCollector)
        internal
        view
        returns (PrimaryTypes.SettlementIntent memory)
    {
        return PrimaryTypes.SettlementIntent({
            buyer: buyer,
            assetToken: address(asset),
            minAssetOut: MIN_OUT,
            settlementToken: address(currency),
            venueQuoteIn: quote,
            buyerFee: buyerFee,
            maxSettlementIn: quote + buyerFee,
            feeCollector: feeCollector,
            venue: address(venue),
            selector: DinariLikeVenue.requestOrder.selector,
            calldataHash: keccak256(venueCalldata),
            supplierReference: SUPPLIER_REF,
            nonce: INTENT_NONCE,
            deadline: block.timestamp + 3 minutes
        });
    }

    /// The default intent: the venue consumes the whole quote and delivers above the floor.
    function _happyPath() internal view returns (bytes memory data, PrimaryTypes.SettlementIntent memory intent) {
        data = _venueCalldata(QUOTE, ASSET_OUT);
        intent = _venueIntent(data, QUOTE, FEE, collector);
    }

    // ── calls ─────────────────────────────────────────────────────────────────────────────

    /// Approve exactly this settlement's debit and submit it. The approval is EXACT on purpose:
    /// every test in this file would still pass with an unlimited one, so an exact grant is the
    /// only way the suite notices if the settler ever starts needing more than it was signed
    /// for.
    function _settleVenueWith(bytes memory data, PrimaryTypes.SettlementIntent memory intent, uint16 takerBps)
        internal
    {
        _approveExact(intent);
        _submit(data, intent, takerBps);
    }

    /// The buyer's allowance for exactly one settlement and no more. Split out of
    /// `_settleVenueWith` because `vm.expectRevert` and `vm.expectEmit` apply to the NEXT call,
    /// and the `approve` must not be the call they land on.
    function _approveExact(PrimaryTypes.SettlementIntent memory intent) internal {
        _approveExactTo(address(router), intent);
    }

    /// The same, against a router other than the mock-capped one.
    function _approveExactTo(address spender, PrimaryTypes.SettlementIntent memory intent) internal {
        vm.prank(buyer);
        currency.approve(spender, intent.venueQuoteIn + intent.buyerFee);
    }

    /// Submit without touching the buyer's allowance, so allowance behaviour can be varied.
    function _submit(bytes memory data, PrimaryTypes.SettlementIntent memory intent, uint16 takerBps) internal {
        _submitTo(AsseteraPrimarySales(address(router)), data, intent, takerBps);
    }

    /// The same, against a router other than the mock-capped one. Every payload is signed for
    /// `target`, because the EIP-712 verifying contract is part of each digest — a settlement
    /// assembled for one proxy is refused by another by construction.
    function _submitTo(
        AsseteraPrimarySales target,
        bytes memory data,
        PrimaryTypes.SettlementIntent memory intent,
        uint16 takerBps
    ) internal {
        bytes32 paramsHash = _paramsHash(intent);
        vm.prank(buyer);
        target.settlePrimary(
            data,
            intent,
            _signIntent(address(target), intent),
            _kyc(address(target), paramsHash),
            _fee(address(target), paramsHash, 0, takerBps, intent.feeCollector, address(currency))
        );
    }
}

/// @title VenueSettlerHappyPathTest
/// @notice What a settlement against a Dinari-shaped venue does when everything works, asserted
///         on MEASURED balances rather than on the numbers the intent quoted.
contract VenueSettlerHappyPathTest is VenueSettlerTestBase {
    /// The whole family in one assertion set: the buyer is debited the quote plus the fee and
    /// nothing more, the venue takes the quote, the collector takes the fee, the asset lands on
    /// the BUYER (not on the router), and the router keeps nothing.
    function test_SettleVenue_DebitsTheBuyerDeliversTheAssetAndPaysTheFee() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();
        uint256 buyerCurrencyBefore = currency.balanceOf(buyer);

        _settleVenueWith(data, intent, TAKER_BPS);

        assertEq(currency.balanceOf(buyer), buyerCurrencyBefore - QUOTE - FEE, "buyer debited the quote plus the fee");
        assertEq(currency.balanceOf(address(venue)), QUOTE, "venue took the quote");
        assertEq(currency.balanceOf(collector), FEE, "collector took the fee");
        assertEq(asset.balanceOf(buyer), ASSET_OUT, "asset delivered to the buyer");
        assertEq(asset.balanceOf(address(router)), 0, "the router never holds the asset");
    }

    /// 🔴 The zero-standing-balance invariant, asserted against the router's PRE-CALL balance
    /// rather than against zero. The donation is what makes the two different: a settler that
    /// asserted "balance is zero afterwards" would revert on it, and one that swept it into the
    /// refund would hand a stranger's tokens to the buyer.
    function test_SettleVenue_LeavesThePreExistingRouterBalanceExactlyWhereItWas() public {
        currency.mint(address(router), 7e6);
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();

        _settleVenueWith(data, intent, TAKER_BPS);

        assertEq(currency.balanceOf(address(router)), 7e6, "the donation is untouched and uncounted");
    }

    /// 🔴 No standing approval survives the call, including on the path where the venue
    /// consumed everything it was approved and the allowance is already zero by arithmetic.
    function test_SettleVenue_LeavesNoStandingApprovalToTheVenue() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();

        _settleVenueWith(data, intent, TAKER_BPS);

        assertEq(currency.allowance(address(router), address(venue)), 0, "router still approves the venue");
    }

    /// The other half of the same fact, on the path where the arithmetic does NOT zero it: a
    /// venue that consumes less than approved leaves a live allowance behind unless the settler
    /// revokes it explicitly.
    function test_SettleVenue_RevokesTheApprovalEvenWhenTheVenueConsumedLessThanTheQuote() public {
        bytes memory data = _venueCalldata(900e6, ASSET_OUT);
        PrimaryTypes.SettlementIntent memory intent = _venueIntent(data, QUOTE, FEE, collector);

        _settleVenueWith(data, intent, TAKER_BPS);

        assertEq(currency.allowance(address(router), address(venue)), 0, "unconsumed approval left standing");
    }

    /// 🔴 The buyer's allowance to the router is the true ceiling on a compromised settlement
    /// signer, so it must be an exact amount for one settlement and it must be spent to zero.
    /// A path that needed `type(uint256).max` would make that ceiling a policy rather than a
    /// structure.
    function test_SettleVenue_SpendsTheBuyersExactAllowanceAndLeavesNoneStanding() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();

        _settleVenueWith(data, intent, TAKER_BPS);

        assertEq(currency.allowance(buyer, address(router)), 0, "buyer allowance left standing");
    }

    /// One wei short of the exact debit and the settlement cannot proceed. This is what proves
    /// the previous test's "exact" is exact rather than merely sufficient.
    function test_SettleVenue_RevertsWhenTheBuyerAllowanceIsOneWeiShort() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();

        vm.prank(buyer);
        currency.approve(address(router), QUOTE + FEE - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(router), QUOTE + FEE - 1, QUOTE + FEE
            )
        );
        _submit(data, intent, TAKER_BPS);
    }

    /// The event the indexer decodes carries the MEASURED numbers, which is the whole reason it
    /// needs no per-supplier decoder. Asserted on the refund path so `venueIn` and `refund` are
    /// distinguishable from the quoted ones.
    function test_SettleVenue_EmitsPrimarySettledWithTheMeasuredNumbers() public {
        bytes memory data = _venueCalldata(900e6, ASSET_OUT);
        PrimaryTypes.SettlementIntent memory intent = _venueIntent(data, QUOTE, FEE, collector);

        _approveExact(intent);
        vm.expectEmit(true, true, true, true, address(router));
        emit ISettler.PrimarySettled(
            buyer,
            address(asset),
            address(venue),
            ASSET_OUT,
            address(currency),
            900e6,
            QUOTE - 900e6,
            FEE,
            collector,
            SUPPLIER_REF,
            INTENT_NONCE
        );
        _submit(data, intent, TAKER_BPS);
    }

    /// A zero-fee settlement is legitimate — the fee service signs zero bps — and must not
    /// require a collector, transfer anything, or disturb the balance invariant.
    function test_SettleVenue_HandlesAZeroFeeSettlement() public {
        bytes memory data = _venueCalldata(QUOTE, ASSET_OUT);
        PrimaryTypes.SettlementIntent memory intent = _venueIntent(data, QUOTE, 0, address(0));
        uint256 buyerCurrencyBefore = currency.balanceOf(buyer);

        _settleVenueWith(data, intent, 0);

        assertEq(currency.balanceOf(buyer), buyerCurrencyBefore - QUOTE, "buyer debited more than the quote");
        assertEq(currency.balanceOf(address(router)), 0, "router kept something");
        assertEq(asset.balanceOf(buyer), ASSET_OUT, "asset not delivered");
    }
}

/// @title VenueSettlerRefundTest
/// @notice A venue that consumes less than it was approved. Normal supplier behaviour — Dinari
///         rounds a share quantity down — so the difference must come back to the buyer in the
///         same transaction rather than revert or sit in the router.
contract VenueSettlerRefundTest is VenueSettlerTestBase {
    /// 🔴 Reverting instead of refunding would break every venue that rounds down, and leaving
    /// the dust in the router would contradict the zero-standing-balance invariant. Both
    /// failure modes are asserted against here at once.
    function test_SettleVenue_RefundsWhatTheVenueDidNotConsume() public {
        uint256 consumed = 987_654_321; // an amount with no round relationship to the quote
        bytes memory data = _venueCalldata(consumed, ASSET_OUT);
        PrimaryTypes.SettlementIntent memory intent = _venueIntent(data, QUOTE, FEE, collector);
        uint256 buyerCurrencyBefore = currency.balanceOf(buyer);

        _settleVenueWith(data, intent, TAKER_BPS);

        assertEq(currency.balanceOf(address(venue)), consumed, "venue consumption");
        assertEq(
            currency.balanceOf(buyer), buyerCurrencyBefore - consumed - FEE, "buyer net debit is consumption plus fee"
        );
        assertEq(currency.balanceOf(address(router)), 0, "refund left as dust in the router");
        assertEq(currency.balanceOf(collector), FEE, "the fee is charged in full regardless of the fill");
    }

    /// The degenerate end of the same behaviour: a venue that pulls nothing at all but still
    /// delivers. The whole quote comes back and only the fee is spent.
    function test_SettleVenue_RefundsTheWholeQuoteWhenTheVenueConsumesNothing() public {
        bytes memory data = _venueCalldata(0, ASSET_OUT);
        PrimaryTypes.SettlementIntent memory intent = _venueIntent(data, QUOTE, FEE, collector);
        uint256 buyerCurrencyBefore = currency.balanceOf(buyer);

        _settleVenueWith(data, intent, TAKER_BPS);

        assertEq(currency.balanceOf(buyer), buyerCurrencyBefore - FEE, "the whole quote was not refunded");
        assertEq(currency.balanceOf(address(router)), 0, "router kept something");
    }
}

/// @title VenueSettlerRevertTest
/// @notice The core reverts. The adversarial suite — a lying venue, reentrancy, rebasing and
///         fee-on-transfer tokens, replay, over-delivery — is AO-551 and is not here.
contract VenueSettlerRevertTest is VenueSettlerTestBase {
    /// 🔴 A venue delivering less than the buyer signed for reverts the whole transaction.
    /// Never a silent bad fill: the buyer's debit and the buyer's delivery stand or fall
    /// together.
    function test_SettleVenue_RevertsWhenTheVenueDeliversLessThanMinAssetOut() public {
        bytes memory data = _venueCalldata(QUOTE, MIN_OUT - 1);
        PrimaryTypes.SettlementIntent memory intent = _venueIntent(data, QUOTE, FEE, collector);

        _approveExact(intent);
        vm.expectRevert(abi.encodeWithSelector(ISettler.InsufficientAssetDelivered.selector, MIN_OUT - 1, MIN_OUT));
        _submit(data, intent, TAKER_BPS);
    }

    /// A venue that took the money and delivered nothing is the same failure with the delta at
    /// zero, and it is the one an EOA "venue" or a no-op selector produces.
    function test_SettleVenue_RevertsWhenTheVenueDeliversNothing() public {
        bytes memory data = _venueCalldata(QUOTE, 0);
        PrimaryTypes.SettlementIntent memory intent = _venueIntent(data, QUOTE, FEE, collector);

        _approveExact(intent);
        vm.expectRevert(abi.encodeWithSelector(ISettler.InsufficientAssetDelivered.selector, 0, MIN_OUT));
        _submit(data, intent, TAKER_BPS);
    }

    /// 🔴 The approval is EXACTLY the quote, so a venue reaching for one wei more fails inside
    /// its own `transferFrom` and takes the settlement down with it. This is the test that
    /// proves the approval is a ceiling rather than a suggestion.
    function test_SettleVenue_ApprovesExactlyTheQuoteSoAGreedierVenueFails() public {
        bytes memory data = _venueCalldata(QUOTE + 1, ASSET_OUT);
        PrimaryTypes.SettlementIntent memory intent = _venueIntent(data, QUOTE, FEE, collector);

        _approveExact(intent);
        vm.expectRevert(ISettler.VenueCallFailed.selector);
        _submit(data, intent, TAKER_BPS);
    }

    /// The buyer's fee is never inside the approval, so a venue cannot reach it even though the
    /// router is holding it when the call is made.
    function test_SettleVenue_DoesNotApproveTheFeeToTheVenue() public {
        bytes memory data = _venueCalldata(QUOTE + FEE, ASSET_OUT);
        PrimaryTypes.SettlementIntent memory intent = _venueIntent(data, QUOTE, FEE, collector);

        _approveExact(intent);
        vm.expectRevert(ISettler.VenueCallFailed.selector);
        _submit(data, intent, TAKER_BPS);
    }

    /// A venue that rejects the order — a stale quote, a closed market — surfaces as one
    /// deterministic error rather than as the venue's own attacker-controlled revert data.
    function test_SettleVenue_RevertsWhenTheVenueRejectsTheOrder() public {
        venue.setRejectsOrders(true);
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();

        _approveExact(intent);
        vm.expectRevert(ISettler.VenueCallFailed.selector);
        _submit(data, intent, TAKER_BPS);
    }

    /// The venue is called with bytes we did not author, so it must not be either of the two
    /// tokens this settlement moves — otherwise those bytes are a token call this contract
    /// makes with this contract's own allowances. A structural comparison against fields of the
    /// same intent, not a list.
    function test_SettleVenue_RevertsWhenTheVenueIsTheSettlementToken() public {
        (bytes memory data,) = _happyPath();
        PrimaryTypes.SettlementIntent memory intent = _venueIntent(data, QUOTE, FEE, collector);
        intent.venue = address(currency);

        _approveExact(intent);
        vm.expectRevert(VenueSettler.VenueIsASettledToken.selector);
        _submit(data, intent, TAKER_BPS);
    }

    function test_SettleVenue_RevertsWhenTheVenueIsTheAssetToken() public {
        (bytes memory data,) = _happyPath();
        PrimaryTypes.SettlementIntent memory intent = _venueIntent(data, QUOTE, FEE, collector);
        intent.venue = address(asset);

        _approveExact(intent);
        vm.expectRevert(VenueSettler.VenueIsASettledToken.selector);
        _submit(data, intent, TAKER_BPS);
    }

    /// 🔴 The hole `IntentGate` leaves open: its collector allowlist check only fires when the
    /// ATTESTED basis points are non-zero, so a settlement signer who puts a `buyerFee` on an
    /// intent whose fee attestation says zero bps would otherwise pay an arbitrary address.
    ///
    /// @dev It is now the buyer-fee cross-check that refuses it, one step earlier than the
    ///      settler's own collector guard: zero attested bps imply a zero fee, so the invented
    ///      `buyerFee` fails `BuyerFeeMismatch` before the recipient is ever considered. The
    ///      test asserts the guarantee (an invented fee to an unlisted address is refused, and
    ///      nothing moves) rather than which line refuses it.
    function test_SettleVenue_RefusesABuyerFeeInventedForAnUnlistedCollector() public {
        address unlisted = makeAddr("unlisted");
        bytes memory data = _venueCalldata(QUOTE, ASSET_OUT);
        PrimaryTypes.SettlementIntent memory intent = _venueIntent(data, QUOTE, FEE, unlisted);

        _approveExact(intent);
        vm.expectRevert(abi.encodeWithSelector(VenueSettler.BuyerFeeMismatch.selector, FEE, 0));
        _submit(data, intent, 0);

        assertEq(currency.balanceOf(unlisted), 0, "the unlisted collector must be paid nothing");
    }
}

/// @title VenueSettlerLimitsTest
/// @notice What the settler hands to `ISettlementLimits`, and that it hands it over BEFORE any
///         money moves. The caps themselves are AO-517; which number reaches them is this
///         packet's claim, so it is asserted against a mock rather than against that packet.
contract VenueSettlerLimitsTest is VenueSettlerTestBase {
    /// A FOURTH proxy: the real `VenueSettler` behind the REAL `SettlementLimits`, over the same
    /// real tokens. `router` mocks the caps (zero means uncapped there) and the shared `sales`
    /// fixture uses bare placeholder addresses that cannot carry a balance, so neither can show
    /// what an unconfigured currency does to a settlement that would otherwise succeed.
    AsseteraPrimarySales internal realCaps;

    function setUp() public virtual override {
        super.setUp();

        AsseteraPrimarySales impl = new AsseteraPrimarySales(address(forwarder));
        bytes memory initData =
            abi.encodeCall(AsseteraPrimarySales.initialize, (admin, kycSigner, feeSigner, settlementSigner));
        realCaps = AsseteraPrimarySales(address(new ERC1967Proxy(address(impl), initData)));

        // Deliberately NO `setSettlementCap` here: the unset cap is the fixture.
        vm.prank(admin);
        realCaps.setAllowedCollector(collector, true);
    }

    /// Charged once, with the settlement token and the full debit the buyer is asked for.
    function test_SettleVenue_ChargesTheCapsOnceWithTheFullDebit() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();

        _settleVenueWith(data, intent, TAKER_BPS);

        assertEq(router.limitCalls(), 1, "the caps must be charged exactly once");
        assertEq(router.lastLimitToken(), address(currency), "charged against the wrong token");
        assertEq(router.lastLimitAmount(), QUOTE + FEE, "charged the wrong amount");
    }

    /// A cap breach takes the whole settlement down, and it does so before the first external
    /// call: nothing was pulled, nothing was approved, nothing was delivered.
    function test_SettleVenue_RevertsAndMovesNothingWhenThePerTxCapIsExceeded() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();
        router.setMockPerTxCap(address(currency), QUOTE + FEE - 1);

        _approveExact(intent);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISettlementLimits.PerTxCapExceeded.selector, address(currency), QUOTE + FEE, QUOTE + FEE - 1
            )
        );
        _submit(data, intent, TAKER_BPS);

        assertEq(asset.balanceOf(buyer), 0, "asset delivered under a breached cap");
        assertEq(currency.balanceOf(address(venue)), 0, "venue paid under a breached cap");
    }

    /// 🔴 An UNSET cap is closed, not unlimited — asserted through the real settler and the real
    /// caps module rather than through the mock above, which reads zero the opposite way so that
    /// every other test in this file does not need a setter call.
    ///
    /// This is the deployment trap the pair exists to catch: `settlementPerTxCap` is a
    /// `mapping(address => uint256)`, so a currency nobody sized reads zero, and if zero meant
    /// "unlimited" the first primary sale in a newly listed currency would run uncapped. The
    /// precondition is asserted explicitly, because a test that only checked the revert would
    /// still pass if the fixture had quietly acquired a very small cap instead of none.
    function test_SettleVenue_FailsClosedWhenTheSettlementCurrencyHasNoCap() public {
        assertEq(realCaps.perTxCap(address(currency)), 0, "fixture: the currency must be unconfigured");
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();
        uint256 buyerCurrencyBefore = currency.balanceOf(buyer);

        _approveExactTo(address(realCaps), intent);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISettlementLimits.PerTxCapExceeded.selector, address(currency), QUOTE + FEE, uint256(0)
            )
        );
        _submitTo(AsseteraPrimarySales(address(realCaps)), data, intent, TAKER_BPS);

        assertEq(currency.balanceOf(buyer), buyerCurrencyBefore, "the buyer was debited under an unset cap");
        assertEq(currency.balanceOf(address(venue)), 0, "the venue was paid under an unset cap");
        assertEq(asset.balanceOf(buyer), 0, "the asset was delivered under an unset cap");
    }

    /// The mutation that proves the test above fails for the reason it names: size the SAME
    /// currency and the SAME settlement goes through. Without this pair, an unrelated breakage
    /// anywhere upstream would read as "the cap failed closed".
    function test_SettleVenue_SucceedsOnceTheAdminSizesTheCurrency() public {
        vm.prank(admin);
        realCaps.setSettlementCap(address(currency), 10_000);

        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();
        _approveExactTo(address(realCaps), intent);
        _submitTo(AsseteraPrimarySales(address(realCaps)), data, intent, TAKER_BPS);

        assertEq(asset.balanceOf(buyer), ASSET_OUT, "the asset was not delivered under a sized cap");
        assertEq(currency.balanceOf(address(venue)), QUOTE, "the venue was not paid under a sized cap");
    }
}

/// @title VenueSettlerFeeVectorsTest
/// @notice 🔴 The buyer-fee cross-check: `intent.buyerFee` (settlement operator) against the
///         `takerFeeBps` on the fee attestation (fee service) applied to the same intent's
///         `venueQuoteIn`. Two independent signers must agree on one number, or the basis
///         points are decorative.
///
/// @dev    ⚠️ An earlier revision of this file said `_settleVenue` did not call the cross-check
///         yet. It does: the seam takes `takerFeeBps` as a third parameter, and
///         `_assertBuyerFee` runs in step 0, before anything moves. What these tests add on top
///         of that wiring is the ARITHMETIC and the ROUNDING POLICY, as hardcoded vectors
///         driven straight through the harness, the way the exchange pins its own fee maths —
///         a formula change then shows up as a failing literal rather than as two expressions
///         agreeing with each other. `test_SettleVenue_RefusesABuyerFeeInventedForAnUnlistedCollector`
///         is the one that proves the wiring.
contract VenueSettlerFeeVectorsTest is VenueSettlerTestBase {
    /// The exact vector. 50 bps of 1 000.000000 USDC is 5.000000 USDC, hardcoded rather than
    /// recomputed, so a change to the formula shows up as a failing literal rather than as two
    /// expressions agreeing with each other.
    function test_ExpectedBuyerFee_MatchesTheExactVector() public view {
        assertEq(router.expectedBuyerFee(1_000_000_000, 50), 5_000_000);
    }

    /// 🔴 The rounding policy, on a vector that does NOT divide exactly.
    /// 1.234567 USDC × 37 bps = 4 567.8979, so the FLOOR is 4 567 and the ceiling would be
    /// 4 568. The two literals are one apart on purpose: this is the only test that can tell
    /// the two roundings apart, and it asserts the floor.
    ///
    /// ⚠️ The rounding direction is an interop contract, not a revenue decision. Every fee in
    /// this system floors, so this one must too: the signer service and the marketplace API
    /// derive the same number off-chain, and a one-wei disagreement reverts every settlement
    /// whose fee does not divide exactly. This vector is chosen to be one the two roundings
    /// disagree about, so the test fails if anybody switches it back to a ceiling.
    function test_ExpectedBuyerFee_FloorsExactlyAsEveryOtherFeeInTheSystemDoes() public view {
        assertEq(router.expectedBuyerFee(1_234_567, 37), 4_567, "the fee must floor");
        assertEq(router.expectedBuyerFee(1_234_567, 37), FeeMath.feeAmount(1_234_567, 37), "must match FeeMath");
        assertEq(uint256(4_568), FeeMath.ceilDiv(1_234_567 * 37, FeeMath.BPS_DENOMINATOR), "ceiling differs here");
    }

    /// A fee too small to reach one wei is zero, and that is the same answer the exchange gives
    /// on a dust trade. The signer must attest zero for it, and the cross-check then agrees.
    function test_ExpectedBuyerFee_IsZeroWhenTheFeeCannotReachOneWei() public view {
        assertEq(router.expectedBuyerFee(1, 1), 0);
    }

    /// Zero bps is zero fee, not one wei. The ceiling must not manufacture a fee the fee service
    /// did not attest.
    function test_ExpectedBuyerFee_IsZeroWhenNoFeeIsAttested() public view {
        assertEq(router.expectedBuyerFee(1_000_000_000, 0), 0);
        assertEq(router.expectedBuyerFee(0, 50), 0);
    }

    /// The cross-check accepts the intent the fee service's basis points imply.
    function test_AssertBuyerFee_AcceptsTheDerivedFee() public view {
        (bytes memory data,) = _happyPath();
        router.assertBuyerFee(_venueIntent(data, QUOTE, FEE, collector), TAKER_BPS);
    }

    /// 🔴 And rejects one the settlement operator simply typed. Without this line `buyerFee` is
    /// whatever that signer chose and the attested basis points mean nothing.
    function test_AssertBuyerFee_RejectsAFeeTheSettlementSignerInvented() public {
        (bytes memory data,) = _happyPath();
        PrimaryTypes.SettlementIntent memory intent = _venueIntent(data, QUOTE, 50e6, collector);

        vm.expectRevert(abi.encodeWithSelector(VenueSettler.BuyerFeeMismatch.selector, 50e6, 5e6));
        router.assertBuyerFee(intent, TAKER_BPS);
    }

    /// One wei below the derived fee is also a mismatch: the check is equality, not a ceiling,
    /// so a signer cannot quietly under-charge either.
    function test_AssertBuyerFee_RejectsAFeeOneWeiBelowTheDerivedOne() public {
        (bytes memory data,) = _happyPath();
        PrimaryTypes.SettlementIntent memory intent = _venueIntent(data, QUOTE, FEE - 1, collector);

        vm.expectRevert(abi.encodeWithSelector(VenueSettler.BuyerFeeMismatch.selector, FEE - 1, FEE));
        router.assertBuyerFee(intent, TAKER_BPS);
    }
}
