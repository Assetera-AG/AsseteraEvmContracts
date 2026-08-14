// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {AsseteraPrimarySales} from "../../src/primary/AsseteraPrimarySales.sol";
import {PrimaryTypes} from "../../src/primary/types/PrimaryTypes.sol";
import {ISettler} from "../../src/primary/interfaces/ISettler.sol";
import {ISettlementLimits} from "../../src/primary/interfaces/ISettlementLimits.sol";
import {HostileVenue} from "./mocks/HostileVenue.sol";
import {
    FeeOnTransferCurrency,
    MutableDecimalsToken,
    RebasingAsset,
    SenderSurchargeCurrency,
    SilentTransferToken
} from "./mocks/PrimaryWeirdTokens.sol";
import {VenueSettlerTestBase} from "./VenueSettlerTestBase.sol";

/// @title HostileSettlementBase
/// @notice The fixture the adversarial S2 suites share: `VenueSettlerTestBase`'s two real
///         ERC-20s and real router, plus a `HostileVenue` and the helpers needed to point a
///         settlement at an arbitrary token pair.
///
/// @dev    `VenueSettlerTestBase._submit` pins `address(currency)` into the fee attestation,
///         which is right for the suites that only ever settle in it and wrong here: half of
///         these tests swap the settlement currency for a misbehaving one. `_submitFull` is the
///         same call with the token read off the intent instead.
abstract contract HostileSettlementBase is VenueSettlerTestBase {
    HostileVenue internal hostile;

    function setUp() public virtual override {
        super.setUp();
        hostile = new HostileVenue();
    }

    // ── fixtures ──────────────────────────────────────────────────────────────────────────

    /// A venue script over the default token pair: pull this much, deliver that much, do
    /// nothing else.
    function _script(uint256 pull, uint256 deliver) internal view returns (HostileVenue.Script memory) {
        return HostileVenue.Script({
            paymentToken: address(currency),
            pullAmount: pull,
            assetToken: address(asset),
            deliverAmount: deliver,
            recipient: buyer,
            pushBackAmount: 0,
            rebaseBps: 0,
            reenterTarget: address(0),
            reenterData: ""
        });
    }

    function _encode(HostileVenue.Script memory script) internal pure returns (bytes memory) {
        return abi.encodeCall(HostileVenue.execute, (script));
    }

    /// An intent over an arbitrary settlement currency, asset and venue.
    ///
    /// The selector is derived from the calldata rather than passed in, because
    /// `IntentGate._bindCalldata` asserts the two agree and a test that got them out of step
    /// would fail on `SelectorMismatch` while claiming to be about something else.
    function _intentOver(
        address settlementToken,
        address assetToken,
        address venueAddress,
        bytes memory data,
        uint256 quote,
        uint256 buyerFee
    ) internal view returns (PrimaryTypes.SettlementIntent memory) {
        return PrimaryTypes.SettlementIntent({
            buyer: buyer,
            assetToken: assetToken,
            minAssetOut: MIN_OUT,
            settlementToken: settlementToken,
            venueQuoteIn: quote,
            buyerFee: buyerFee,
            maxSettlementIn: quote + buyerFee,
            feeCollector: collector,
            venue: venueAddress,
            selector: _selectorOf(data),
            calldataHash: keccak256(data),
            supplierReference: SUPPLIER_REF,
            nonce: INTENT_NONCE,
            deadline: block.timestamp + 3 minutes
        });
    }

    /// The default hostile intent: the shared currency and asset, the hostile venue, the
    /// standard quote and the fee 50 bps implies on it.
    function _hostileIntent(bytes memory data) internal view returns (PrimaryTypes.SettlementIntent memory) {
        return _intentOver(address(currency), address(asset), address(hostile), data, QUOTE, FEE);
    }

    /// `bytes4(data)` is only available on `calldata`, and these payloads are built in memory.
    function _selectorOf(bytes memory data) internal pure returns (bytes4 selector) {
        assembly ("memory-safe") {
            selector := mload(add(data, 32))
        }
    }

    // ── calls ─────────────────────────────────────────────────────────────────────────────

    /// The buyer's exact allowance for one settlement, in whatever currency the intent names.
    function _approveDebit(address spender, PrimaryTypes.SettlementIntent memory intent) internal {
        vm.prank(intent.buyer);
        IERC20(intent.settlementToken).approve(spender, intent.venueQuoteIn + intent.buyerFee);
    }

    function _submitFull(bytes memory data, PrimaryTypes.SettlementIntent memory intent, uint16 takerBps) internal {
        _submitFullTo(AsseteraPrimarySales(address(router)), data, intent, takerBps);
    }

    function _submitFullTo(
        AsseteraPrimarySales target,
        bytes memory data,
        PrimaryTypes.SettlementIntent memory intent,
        uint16 takerBps
    ) internal {
        bytes32 paramsHash = _paramsHash(intent);
        vm.prank(intent.buyer);
        target.settlePrimary(
            data,
            intent,
            _signIntent(address(target), intent),
            _signBuyerConsent(address(target), intent),
            _kyc(address(target), paramsHash),
            _fee(address(target), paramsHash, 0, takerBps, intent.feeCollector, intent.settlementToken)
        );
    }
}

/// @title VenueSettlerFeeOnTransferTest
/// @notice 🔴 A DEFLATIONARY settlement currency: the router is debited in full and credited
///         less, on every leg — the buyer's pull, the venue's pull, the refund and the fee.
///
///         This is the single most likely way a constrained executor strands value or misreports
///         one, because every number `VenueSettler` reasons about after the venue call is a
///         difference of the ROUTER's own balances, and on a token like this those differences
///         are not the amounts anybody received.
///
///         **The headline result, and it changed on review of PR #58: such a currency cannot
///         settle at all, and it is refused at the PULL.** Step 3 measures what the router
///         actually received and compares it against `venueQuoteIn + buyerFee`; a burn on the
///         way in makes the two differ, so `SettlementPullMismatch` fires before the venue is
///         approved, before it is called, and before anything else can be measured wrongly.
///
/// @dev    What these tests used to pin, and why it was not good enough: the router's own
///         solvency invariants held — nothing stranded, no standing approval, the buyer never
///         debited beyond their allowance — but the settlement went THROUGH and the numbers it
///         reported were not the amounts anybody received. `venueIn` counted the token's burn as
///         venue consumption and the collector was credited below the fee both signers had
///         attested. Neither was visible to anyone reading `PrimarySettled`. Failing closed at
///         the pull replaces a silent misreport with a named revert, and the tests below assert
///         the absence of every effect rather than the shape of a wrong one.
///
///         Listing a deflationary settlement currency is therefore a decision that now shows up
///         as "no primary sale in this token succeeds", which is a thing an operator finds out
///         immediately, instead of as a slow divergence in the activity ledger.
contract VenueSettlerFeeOnTransferTest is HostileSettlementBase {
    /// One per cent burned on every transfer. Large enough that the arithmetic is legible in
    /// the assertions and small enough to be a plausible real token.
    FeeOnTransferCurrency internal fot;

    uint256 internal constant BUYER_START = 10_000e6;
    /// What the router is actually left holding after the 1 % burn on a 1 005.000000 pull.
    uint256 internal constant HELD_AFTER_PULL = 994_950_000;

    function setUp() public virtual override {
        super.setUp();
        fot = new FeeOnTransferCurrency("Deflationary USD", "dUSD", 100);
        fot.mint(buyer, BUYER_START);
    }

    function _fotIntent(bytes memory data) internal view returns (PrimaryTypes.SettlementIntent memory) {
        return _intentOver(address(fot), address(asset), address(hostile), data, QUOTE, FEE);
    }

    function _fotScript(uint256 pull, uint256 deliver) internal view returns (HostileVenue.Script memory) {
        HostileVenue.Script memory script = _script(pull, deliver);
        script.paymentToken = address(fot);
        return script;
    }

    /// 🔴 The acceptance criterion for the measured pull. The router asked the currency for
    /// 1 005.000000 and was credited 994.950000, so the settlement is refused right there —
    /// with the two numbers in the error, which is what tells an operator it is the token and
    /// not the venue.
    ///
    /// The venue is never approved and never called, so what it would have done is irrelevant.
    function test_FeeOnTransfer_RefusesTheSettlementAtThePull() public {
        bytes memory data = _encode(_fotScript(QUOTE, ASSET_OUT));
        PrimaryTypes.SettlementIntent memory intent = _fotIntent(data);

        _approveDebit(address(router), intent);
        vm.expectRevert(abi.encodeWithSelector(ISettler.SettlementPullMismatch.selector, QUOTE + FEE, HELD_AFTER_PULL));
        _submitFull(data, intent, TAKER_BPS);

        assertEq(fot.balanceOf(buyer), BUYER_START, "the buyer was debited by a settlement that failed");
        assertEq(fot.balanceOf(address(router)), 0, "the router kept something");
        assertEq(fot.allowance(address(router), address(hostile)), 0, "the venue was approved before the pull");
    }

    /// 🔴 The mutation that shows the fix is not merely the old failure under a new name. This
    /// is the case that USED to settle — a venue taking 900.000000, less than the 994.950000 the
    /// burn left the router holding — and it was the dangerous one, because it went through and
    /// reported numbers nobody had sent or received.
    ///
    /// It is now refused at the pull like every other settlement in this currency, and the
    /// assertions are about the ABSENCE of effects: no delivery, no venue credit, no fee.
    function test_FeeOnTransfer_RefusesEvenWhenTheVenueWouldTakeLessThanTheRouterHolds() public {
        bytes memory data = _encode(_fotScript(900e6, ASSET_OUT));
        PrimaryTypes.SettlementIntent memory intent = _fotIntent(data);

        _approveDebit(address(router), intent);
        vm.expectRevert(abi.encodeWithSelector(ISettler.SettlementPullMismatch.selector, QUOTE + FEE, HELD_AFTER_PULL));
        _submitFull(data, intent, TAKER_BPS);

        assertEq(fot.balanceOf(buyer), BUYER_START, "the buyer was debited by a settlement that failed");
        assertEq(fot.balanceOf(address(hostile)), 0, "the venue was paid by a settlement that failed");
        assertEq(fot.balanceOf(address(router)), 0, "the router stranded value");
        assertEq(fot.allowance(address(router), address(hostile)), 0, "a standing approval survived");
        assertEq(asset.balanceOf(buyer), 0, "the asset was delivered by a settlement that failed");
        assertFalse(router.usedIntentNonce(buyer, INTENT_NONCE), "a failed settlement burned the intent nonce");
    }

    /// 🔴 The first of the two silent misreports this fix removes. The venue consumed NOTHING,
    /// and `PrimarySettled` used to say it consumed 10.050000 — the burn on the buyer's pull,
    /// which the router could only measure as "settlement token that left".
    ///
    /// The assertion is that NO settlement event is emitted at all. Measuring the venue's own
    /// balance delta instead was and remains the wrong alternative — a venue that routes through
    /// an intermediary receives nothing at its own address, and the router would refuse honest
    /// fills — so the answer is to refuse the currency, not to change what is measured.
    function test_FeeOnTransfer_CannotReportTheBurnAsVenueConsumption() public {
        bytes memory data = _encode(_fotScript(0, ASSET_OUT));
        PrimaryTypes.SettlementIntent memory intent = _fotIntent(data);

        _approveDebit(address(router), intent);
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(ISettler.SettlementPullMismatch.selector, QUOTE + FEE, HELD_AFTER_PULL));
        _submitFull(data, intent, TAKER_BPS);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != ISettler.PrimarySettled.selector, "a refused settlement was reported");
        }
        assertEq(fot.balanceOf(address(hostile)), 0, "the venue took nothing and was told nothing");
        assertEq(fot.balanceOf(address(router)), 0, "the router stranded value");
    }

    /// 🔴 The second silent misreport. The collector used to be credited 4.950000 against an
    /// attested fee of 5.000000 — a revenue shortfall that appeared nowhere, because `fee` in
    /// the event is what LEFT the router rather than what reached the collector.
    ///
    /// The fee is now the attested fee or there is no settlement. Nothing in between.
    function test_FeeOnTransfer_CannotCreditTheCollectorLessThanTheAttestedFee() public {
        bytes memory data = _encode(_fotScript(0, ASSET_OUT));
        PrimaryTypes.SettlementIntent memory intent = _fotIntent(data);

        _approveDebit(address(router), intent);
        vm.expectRevert(abi.encodeWithSelector(ISettler.SettlementPullMismatch.selector, QUOTE + FEE, HELD_AFTER_PULL));
        _submitFull(data, intent, TAKER_BPS);

        assertEq(fot.balanceOf(collector), 0, "the collector was credited by a settlement that failed");
    }

    /// The buyer's allowance is not consumed either, so a failed settlement leaves no standing
    /// grant behind for the next one to spend.
    function test_FeeOnTransfer_LeavesTheBuyerAllowanceIntact() public {
        bytes memory data = _encode(_fotScript(0, ASSET_OUT));
        PrimaryTypes.SettlementIntent memory intent = _fotIntent(data);

        _approveDebit(address(router), intent);
        vm.expectRevert(abi.encodeWithSelector(ISettler.SettlementPullMismatch.selector, QUOTE + FEE, HELD_AFTER_PULL));
        _submitFull(data, intent, TAKER_BPS);

        assertEq(fot.allowance(buyer, address(router)), QUOTE + FEE, "the failed pull spent part of the allowance");
        assertEq(fot.totalSupply(), BUYER_START, "the token burned something on a settlement that failed");
    }
}

/// @title VenueSettlerSenderSurchargeTest
/// @notice A settlement currency that charges the SENDER on top of every transfer: the recipient
///         is credited in full, so the router's measured pull is EXACT and the settlement gets
///         past step 3 — and then the venue's own pull debits the router more than it hands
///         over.
///
/// @dev    This suite exists to keep the LOWER half of `VenueSettler`'s post-call bounds check
///         (`held < routerBefore + buyerFee`) evidenced. It used to be reached by the
///         deflationary currency, which can no longer get that far now that the pull is
///         measured. Deleting the coverage instead of relocating it would have left a guard on
///         the money path with no test behind it.
contract VenueSettlerSenderSurchargeTest is HostileSettlementBase {
    /// One per cent charged to the sender, on top.
    SenderSurchargeCurrency internal surcharge;

    uint256 internal constant BUYER_START = 10_000e6;
    /// What the venue pulls. Chosen so the router's debit for it (995 + 1 % = 1 004.950000)
    /// leaves the router holding 0.050000 — below the 5.000000 fee it still owes the collector,
    /// which is exactly the lower bound. Anything much larger reverts inside the token instead,
    /// on a balance the router does not have.
    uint256 internal constant VENUE_PULL = 995e6;

    function setUp() public virtual override {
        super.setUp();
        surcharge = new SenderSurchargeCurrency("Surcharge USD", "sUSD", 100);
        surcharge.mint(buyer, BUYER_START);
    }

    /// 🔴 The lower bound. The pull is exact — the router is credited all 1 005.000000 — so the
    /// settlement proceeds, and the venue then legitimately takes less than it costs the router
    /// to send. Without the bound, `held` would be below the fee still owed and the collector
    /// transfer would fail on an empty router with a bare ERC-20 error instead of the named one.
    function test_SenderSurcharge_TheLowerBoundCatchesARouterLeftBelowItsOwnFee() public {
        HostileVenue.Script memory script = _script(VENUE_PULL, ASSET_OUT);
        script.paymentToken = address(surcharge);
        bytes memory data = _encode(script);
        PrimaryTypes.SettlementIntent memory intent =
            _intentOver(address(surcharge), address(asset), address(hostile), data, QUOTE, FEE);

        _approveDebit(address(router), intent);
        vm.expectRevert(ISettler.RouterBalanceChanged.selector);
        _submitFull(data, intent, TAKER_BPS);

        assertEq(surcharge.balanceOf(address(router)), 0, "the router stranded value");
        assertEq(surcharge.balanceOf(address(hostile)), 0, "the venue kept a pull from a failed settlement");
        assertEq(asset.balanceOf(buyer), 0, "the asset was delivered by a settlement that failed");
    }

    /// ⚠️ Said plainly rather than left implied: this currency cannot settle EITHER, whatever
    /// the venue takes. The router's outflows — the refund and the fee — each cost more than
    /// their face value, so the zero-standing-balance invariant can never be met and the call
    /// fails somewhere on the way out. A smaller venue pull simply moves the failure past the
    /// lower bound to the fee transfer, where the token itself reverts on a balance the router
    /// no longer has.
    ///
    /// The point of the suite above is therefore that the NAMED bound fires in the case that
    /// would otherwise have taken our fee, not that this token is usable.
    function test_SenderSurcharge_CannotSettleAtAllBecauseEveryOutflowCostsMoreThanItMoves() public {
        HostileVenue.Script memory script = _script(500e6, ASSET_OUT);
        script.paymentToken = address(surcharge);
        bytes memory data = _encode(script);
        PrimaryTypes.SettlementIntent memory intent =
            _intentOver(address(surcharge), address(asset), address(hostile), data, QUOTE, FEE);

        _approveDebit(address(router), intent);
        vm.expectRevert();
        _submitFull(data, intent, TAKER_BPS);

        assertEq(surcharge.balanceOf(address(router)), 0, "the router stranded value");
        assertEq(surcharge.balanceOf(collector), 0, "the collector was credited by a settlement that failed");
        assertEq(asset.balanceOf(buyer), 0, "the asset was delivered by a settlement that failed");
    }
}

/// @title VenueSettlerRebasingAssetTest
/// @notice 🔴 What `VenueSettler`'s balance-delta assertion survives, under test. These tests are
///         what its warning cites, and they are the reason that warning no longer says a rebase
///         "cannot occur mid-call" — it can, and one of the tests below does it:
///
///           * A rebase that happened BEFORE the settlement contributes nothing, because the
///             snapshot is taken inside the call rather than carried across blocks. That is the
///             half of the original claim that holds, and it holds exactly.
///           * A rebase DURING the call is possible, because the venue is arbitrary code and
///             can call the asset token. It is then counted as delivery.
///
/// @dev    ⚠️ **Reported rather than patched.** A venue that can rebase the buyer's holding
///         upward could equally mint to the buyer directly, and minting to the buyer is what
///         honest delivery IS — so the mid-call rebase grants a malicious venue no capability
///         it did not already have over a token it controls. Where it bites is a genuinely
///         rebasing asset the venue does NOT control but can trigger: the buyer pays the quote
///         and the delivery floor is satisfied by a rebase they would have received anyway. The
///         defence is that the venue and the asset are both named in an intent the buyer signed;
///         there is no on-chain check that could tell the two cases apart.
contract VenueSettlerRebasingAssetTest is HostileSettlementBase {
    RebasingAsset internal rebasing;

    /// A pre-existing position, so a proportional rebase has something to act on. A buyer
    /// holding nothing is the case where none of this is reachable, and it is the mutation at
    /// the end of this suite.
    uint256 internal constant EXISTING_POSITION = 1_000e18;

    function setUp() public virtual override {
        super.setUp();
        rebasing = new RebasingAsset("Rebasing Equity", "rEQ");
    }

    function _rebasingScript(uint256 pull, uint256 deliver, int256 bps)
        internal
        view
        returns (HostileVenue.Script memory)
    {
        HostileVenue.Script memory script = _script(pull, deliver);
        script.assetToken = address(rebasing);
        script.rebaseBps = bps;
        return script;
    }

    function _rebasingIntent(bytes memory data) internal view returns (PrimaryTypes.SettlementIntent memory) {
        return _intentOver(address(currency), address(rebasing), address(hostile), data, QUOTE, FEE);
    }

    /// 🔴 The half of the claim that HOLDS. The buyer's position is rebased upward by 50 % in an
    /// earlier block; the settlement then delivers exactly the floor and reports exactly the
    /// floor. Nothing that happened before the call is inside the measurement.
    ///
    /// This is the property that makes the assertion safe here and unsafe anywhere that holds a
    /// rebasing balance across blocks.
    function test_Rebasing_ARebaseBeforeTheCallIsOutsideTheMeasurement() public {
        rebasing.mint(buyer, EXISTING_POSITION);
        rebasing.rebase(buyer, 5_000);
        assertEq(rebasing.balanceOf(buyer), 1_500e18, "fixture: the pre-call rebase must have happened");

        bytes memory data = _encode(_rebasingScript(QUOTE, MIN_OUT, 0));
        PrimaryTypes.SettlementIntent memory intent = _rebasingIntent(data);

        _approveDebit(address(router), intent);
        vm.expectEmit(true, true, true, true, address(router));
        emit ISettler.PrimarySettled(
            buyer,
            address(rebasing),
            address(hostile),
            MIN_OUT, // exactly what the venue delivered, not the 500e18 the rebase added
            address(currency),
            QUOTE,
            0,
            FEE,
            collector,
            SUPPLIER_REF,
            INTENT_NONCE
        );
        _submitFull(data, intent, TAKER_BPS);
    }

    /// 🔴 The half that does NOT hold. The venue delivers nothing at all, takes the whole quote,
    /// and satisfies the delivery floor by rebasing the buyer's EXISTING position upward by
    /// 10 %. `delivered` is 100e18 against a floor of 40e18, and the settlement succeeds.
    ///
    /// Reported, not patched — see the note on this contract. The measurement is honest about
    /// what it measures (the buyer really does hold 100e18 more asset than before the call);
    /// what it cannot tell is whether the increase came from this settlement.
    function test_Rebasing_ARebaseDuringTheCallIsCountedAsDelivery() public {
        rebasing.mint(buyer, EXISTING_POSITION);

        bytes memory data = _encode(_rebasingScript(QUOTE, 0, 1_000));
        PrimaryTypes.SettlementIntent memory intent = _rebasingIntent(data);

        _approveDebit(address(router), intent);
        _submitFull(data, intent, TAKER_BPS);

        assertEq(rebasing.balanceOf(buyer), 1_100e18, "the rebase is the only thing that moved the balance");
        assertEq(currency.balanceOf(address(hostile)), QUOTE, "the venue took the whole quote regardless");
    }

    /// The mutation that bounds the case above: with no pre-existing position a proportional
    /// rebase moves nothing, the measured delta is zero, and the same venue is refused. The
    /// attack needs a buyer who already holds the asset, which a PRIMARY sale by definition
    /// usually does not.
    function test_Rebasing_TheSameVenueIsRefusedWhenTheBuyerHoldsNoPosition() public {
        bytes memory data = _encode(_rebasingScript(QUOTE, 0, 1_000));
        PrimaryTypes.SettlementIntent memory intent = _rebasingIntent(data);

        _approveDebit(address(router), intent);
        vm.expectRevert(abi.encodeWithSelector(ISettler.InsufficientAssetDelivered.selector, 0, MIN_OUT));
        _submitFull(data, intent, TAKER_BPS);
    }

    /// 🔴 A DOWNWARD rebase inside the call takes the buyer's balance below where it started,
    /// even though the venue delivered. The clamp in `VenueSettler` is what turns that into the
    /// named settlement error instead of an arithmetic panic out of a checked subtraction — an
    /// `InsufficientAssetDelivered(0, floor)` an operator can read, rather than `0x11`.
    function test_Rebasing_ADownwardRebaseIsClampedToZeroRatherThanPanicking() public {
        rebasing.mint(buyer, EXISTING_POSITION);

        // Wipes the position, then delivers the floor: 1000e18 → 0 → 40e18, which is BELOW the
        // 1000e18 the delta is measured against.
        bytes memory data = _encode(_rebasingScript(QUOTE, MIN_OUT, -10_000));
        PrimaryTypes.SettlementIntent memory intent = _rebasingIntent(data);

        _approveDebit(address(router), intent);
        vm.expectRevert(abi.encodeWithSelector(ISettler.InsufficientAssetDelivered.selector, 0, MIN_OUT));
        _submitFull(data, intent, TAKER_BPS);
    }
}

/// @title VenueSettlerSilentTransferTest
/// @notice A settlement token whose `transfer` returns `true` and moves nothing.
///
///         🔴 This is the one non-conformance `SafeERC20` cannot catch — the call succeeds and
///         the return value is truthy — and it is exactly what `VenueSettler`'s step 9 is for.
///         The comment on that step says the assertion is made LAST so that it "also catches a
///         fee transfer that silently moved nothing". These are the tests behind that sentence.
contract VenueSettlerSilentTransferTest is HostileSettlementBase {
    SilentTransferToken internal silent;

    function setUp() public virtual override {
        super.setUp();
        silent = new SilentTransferToken("Silent USD", "sUSD");
        silent.mint(buyer, 10_000e6);
    }

    function _silentScript(uint256 pull, uint256 deliver) internal view returns (HostileVenue.Script memory) {
        HostileVenue.Script memory script = _script(pull, deliver);
        script.paymentToken = address(silent);
        return script;
    }

    function _silentIntent(bytes memory data) internal view returns (PrimaryTypes.SettlementIntent memory) {
        return _intentOver(address(silent), address(asset), address(hostile), data, QUOTE, FEE);
    }

    /// 🔴 The venue consumes the whole quote, so there is no refund and the fee transfer is the
    /// only `transfer` on the path. It reports success and moves nothing, the router is left
    /// holding the fee, and the final assertion refuses the settlement.
    function test_SilentTransfer_AFeeTransferThatMovedNothingIsCaught() public {
        silent.setSilent(true);
        bytes memory data = _encode(_silentScript(QUOTE, ASSET_OUT));
        PrimaryTypes.SettlementIntent memory intent = _silentIntent(data);

        _approveDebit(address(router), intent);
        vm.expectRevert(ISettler.RouterBalanceChanged.selector);
        _submitFull(data, intent, TAKER_BPS);
    }

    /// The same for the refund leg: a venue that consumes part of the quote, on a token where
    /// the refund silently does not reach the buyer.
    function test_SilentTransfer_ARefundThatMovedNothingIsCaught() public {
        silent.setSilent(true);
        bytes memory data = _encode(_silentScript(900e6, ASSET_OUT));
        PrimaryTypes.SettlementIntent memory intent = _silentIntent(data);

        _approveDebit(address(router), intent);
        vm.expectRevert(ISettler.RouterBalanceChanged.selector);
        _submitFull(data, intent, TAKER_BPS);
    }

    /// The mutation: the SAME token, the SAME settlement, with the silence switched off. Without
    /// this the two tests above would also pass if the fixture were broken for an unrelated
    /// reason.
    function test_SilentTransfer_TheSameSettlementGoesThroughWhenTransfersActuallyMove() public {
        silent.setSilent(false);
        bytes memory data = _encode(_silentScript(900e6, ASSET_OUT));
        PrimaryTypes.SettlementIntent memory intent = _silentIntent(data);

        _approveDebit(address(router), intent);
        _submitFull(data, intent, TAKER_BPS);

        assertEq(silent.balanceOf(collector), FEE, "the collector was not paid");
        assertEq(silent.balanceOf(address(router)), 0, "the router kept something");
    }
}

/// @title VenueSettlerLyingVenueTest
/// @notice A venue that returns success while doing something other than what it was paid for.
///         `VenueSettler.t.sol` already pins the two obvious lies — delivering nothing and
///         delivering below the floor. These are the ones that are not obvious: over-delivery,
///         delivery to the wrong address, and settlement token pushed back AT the router.
contract VenueSettlerLyingVenueTest is HostileSettlementBase {
    /// A venue that does nothing whatsoever and reports success. Distinct from the covered
    /// "took the money and delivered nothing": this one does not even take the money, which is
    /// what an EOA at the venue address or a no-op fallback produces.
    function test_LyingVenue_DoingNothingAtAllIsRefused() public {
        bytes memory data = _encode(_script(0, 0));
        PrimaryTypes.SettlementIntent memory intent = _hostileIntent(data);

        _approveDebit(address(router), intent);
        vm.expectRevert(abi.encodeWithSelector(ISettler.InsufficientAssetDelivered.selector, 0, MIN_OUT));
        _submitFull(data, intent, TAKER_BPS);
    }

    /// 🔴 OVER-delivery must not break the arithmetic. `delivered` is measured, not quoted, so a
    /// venue that fills better than the floor simply reports a bigger number — there is no
    /// second comparison against `minAssetOut` from above, and nothing subtracts the floor from
    /// the delta.
    function test_LyingVenue_OverDeliveryIsMeasuredInFullAndAllOfItReachesTheBuyer() public {
        uint256 generous = MIN_OUT * 1_000;
        bytes memory data = _encode(_script(QUOTE, generous));
        PrimaryTypes.SettlementIntent memory intent = _hostileIntent(data);

        _approveDebit(address(router), intent);
        vm.expectEmit(true, true, true, true, address(router));
        emit ISettler.PrimarySettled(
            buyer,
            address(asset),
            address(hostile),
            generous,
            address(currency),
            QUOTE,
            0,
            FEE,
            collector,
            SUPPLIER_REF,
            INTENT_NONCE
        );
        _submitFull(data, intent, TAKER_BPS);

        assertEq(asset.balanceOf(buyer), generous, "the buyer must keep every unit delivered");
    }

    /// 🔴 And nobody else can claim the excess, because the asset never passes through this
    /// contract: the venue delivers to a recipient named in ITS calldata and the router only
    /// ever reads the buyer's balance. The router holds no asset before, during or after.
    function test_LyingVenue_OverDeliveryLeavesNothingForAnyoneElseToClaim() public {
        bytes memory data = _encode(_script(QUOTE, MIN_OUT * 1_000));
        PrimaryTypes.SettlementIntent memory intent = _hostileIntent(data);

        _approveDebit(address(router), intent);
        _submitFull(data, intent, TAKER_BPS);

        assertEq(asset.balanceOf(address(router)), 0, "the router holds asset a stranger could sweep");
        assertEq(currency.balanceOf(address(router)), 0, "the router holds settlement token");
        assertEq(asset.balanceOf(address(hostile)), 0, "the venue kept part of the delivery");
    }

    /// Delivering to the ROUTER instead of the buyer is not delivery. This is what makes the
    /// measurement the buyer's balance rather than a transfer the router observed, and it is
    /// also what stops the router being usable as a delivery sink an operator could later sweep.
    function test_LyingVenue_DeliveringToTheRouterIsNotDelivery() public {
        HostileVenue.Script memory script = _script(QUOTE, ASSET_OUT);
        script.recipient = address(router);
        bytes memory data = _encode(script);
        PrimaryTypes.SettlementIntent memory intent = _hostileIntent(data);

        _approveDebit(address(router), intent);
        vm.expectRevert(abi.encodeWithSelector(ISettler.InsufficientAssetDelivered.selector, 0, MIN_OUT));
        _submitFull(data, intent, TAKER_BPS);
    }

    /// The delivery boundary is inclusive: exactly `minAssetOut` settles.
    function test_LyingVenue_DeliveringExactlyTheFloorIsAccepted() public {
        bytes memory data = _encode(_script(QUOTE, MIN_OUT));
        PrimaryTypes.SettlementIntent memory intent = _hostileIntent(data);

        _approveDebit(address(router), intent);
        _submitFull(data, intent, TAKER_BPS);

        assertEq(asset.balanceOf(buyer), MIN_OUT, "the floor itself must be a valid fill");
    }

    /// And one wei below it does not. The pair is what makes "at least" exact rather than
    /// approximately right.
    function test_LyingVenue_DeliveringOneWeiBelowTheFloorIsRefused() public {
        bytes memory data = _encode(_script(QUOTE, MIN_OUT - 1));
        PrimaryTypes.SettlementIntent memory intent = _hostileIntent(data);

        _approveDebit(address(router), intent);
        vm.expectRevert(abi.encodeWithSelector(ISettler.InsufficientAssetDelivered.selector, MIN_OUT - 1, MIN_OUT));
        _submitFull(data, intent, TAKER_BPS);
    }

    /// A venue that pushes settlement token back at the router out of its OWN balance, in an
    /// amount that keeps the router inside the post-call bounds. The router cannot tell it apart
    /// from an unconsumed approval, so it goes out as refund — to the BUYER, which is the only
    /// party it could sensibly go to and is certainly better than being stranded here.
    ///
    /// ⚠️ Pinned as behaviour rather than asserted as desirable. It is the reason step 9 checks
    /// the router's balance against its PRE-CALL value: whatever a venue pushes at us leaves
    /// again in the same transaction.
    function test_LyingVenue_ASmallPushBackLeavesWithTheRefundRatherThanBeingStranded() public {
        currency.mint(address(hostile), 500e6);
        HostileVenue.Script memory script = _script(QUOTE, ASSET_OUT);
        script.pushBackAmount = 1e6;
        bytes memory data = _encode(script);
        PrimaryTypes.SettlementIntent memory intent = _hostileIntent(data);
        uint256 buyerBefore = currency.balanceOf(buyer);

        _approveDebit(address(router), intent);
        _submitFull(data, intent, TAKER_BPS);

        assertEq(currency.balanceOf(address(router)), 0, "the push-back was stranded in the router");
        assertEq(currency.balanceOf(buyer), buyerBefore - QUOTE - FEE + 1e6, "the push-back reached the buyer");
    }

    /// 🔴 A push-back big enough to take the router ABOVE its pre-call balance plus the whole
    /// authorised debit is refused outright. That is the upper half of the post-call bounds
    /// check, and it is what stops a venue inflating the refund arithmetic into an underflow or
    /// handing the router a balance it would then have to reason about.
    function test_LyingVenue_APushBackBeyondTheWholeDebitIsRefused() public {
        currency.mint(address(hostile), 2_000e6);
        HostileVenue.Script memory script = _script(0, ASSET_OUT);
        script.pushBackAmount = QUOTE + FEE + 1;
        bytes memory data = _encode(script);
        PrimaryTypes.SettlementIntent memory intent = _hostileIntent(data);

        _approveDebit(address(router), intent);
        vm.expectRevert(ISettler.RouterBalanceChanged.selector);
        _submitFull(data, intent, TAKER_BPS);
    }
}

/// @title VenueSettlerReentrancyTest
/// @notice 🔴 A venue that calls back into the router. `settlePrimary` holds `nonReentrant` for
///         the whole of the settler's call, and the intent nonce is burned BEFORE the money
///         path runs — two independent reasons a venue cannot replay the settlement it is
///         inside. Both are asserted, because either alone would be a single point of failure.
///
/// @dev    ⚠️ The reentrant call is made through `HostileVenue`, which RECORDS the outcome
///         rather than bubbling it. `VenueSettler` collapses every venue failure into one
///         `VenueCallFailed`, so a bubbling venue would leave every test here asserting the same
///         opaque error and unable to say which guard fired. Recording lets the outer settlement
///         finish honestly and the assertion name the exact selector.
contract VenueSettlerReentrancyTest is HostileSettlementBase {
    /// A complete, well-formed second settlement — different intent nonce, honest venue, all
    /// four signatures valid — encoded as calldata for the reentrant call. Nothing about it is
    /// malformed: the only reason it fails is the guard.
    function _secondSettlementCalldata() internal view returns (bytes memory) {
        bytes memory innerData = _venueCalldata(QUOTE, ASSET_OUT);
        PrimaryTypes.SettlementIntent memory second = _venueIntent(innerData, QUOTE, FEE, collector);
        second.nonce = INTENT_NONCE + 1;
        bytes32 paramsHash = _paramsHash(second);

        return abi.encodeCall(
            AsseteraPrimarySales.settlePrimary,
            (
                innerData,
                second,
                _signIntent(address(router), second),
                _signBuyerConsent(address(router), second),
                _kyc(address(router), paramsHash),
                _fee(address(router), paramsHash, 0, TAKER_BPS, collector, address(currency))
            )
        );
    }

    /// Run one honest settlement whose venue also makes `reentrantCall` against `target`, with
    /// the buyer's allowance to the router set to `allowance`.
    ///
    /// The allowance is a parameter rather than the exact debit, because half of these tests are
    /// about what a callback can reach and the exact debit would answer that question by
    /// accident: a reentrant settlement that failed for want of an allowance would prove nothing
    /// about the guard.
    function _settleWithCallback(address target, bytes memory reentrantCall, uint256 allowance) internal {
        HostileVenue.Script memory script = _script(QUOTE, ASSET_OUT);
        script.reenterTarget = target;
        script.reenterData = reentrantCall;
        bytes memory data = _encode(script);
        PrimaryTypes.SettlementIntent memory intent = _hostileIntent(data);

        vm.prank(intent.buyer);
        currency.approve(address(router), allowance);
        _submitFull(data, intent, TAKER_BPS);
    }

    /// The same with only this settlement's debit approved.
    function _settleWithCallback(address target, bytes memory reentrantCall) internal {
        _settleWithCallback(target, reentrantCall, QUOTE + FEE);
    }

    /// 🔴 The guard is on the path that matters. A second, entirely valid settlement submitted
    /// from inside the venue call is refused by `ReentrancyGuardUpgradeable`, and the outer
    /// settlement completes normally.
    function test_Reentrancy_ASecondSettlementFromInsideTheVenueCallIsRefused() public {
        // An unlimited allowance, so that a refusal cannot be blamed on the buyer's approval:
        // the reentrant settlement has everything it needs except a way past the guard.
        _settleWithCallback(address(router), _secondSettlementCalldata(), type(uint256).max);

        assertTrue(hostile.reenterAttempted(), "fixture: the venue must have tried");
        assertFalse(hostile.reenterOk(), "the reentrant settlement succeeded");
        assertEq(
            hostile.reenterErrorSelector(),
            ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector,
            "refused by something other than the reentrancy guard"
        );
        assertFalse(router.usedIntentNonce(buyer, INTENT_NONCE + 1), "the second intent was consumed");
    }

    /// 🔴 The second, independent reason the same intent cannot be replayed from inside: its
    /// nonce is already burned by the time the venue runs. A reentrancy guard that was ever
    /// removed or scoped differently would not silently reopen this.
    function test_Reentrancy_TheIntentNonceIsAlreadyBurnedWhenTheVenueRuns() public {
        _settleWithCallback(address(router), abi.encodeCall(router.usedIntentNonce, (buyer, INTENT_NONCE)));

        assertTrue(hostile.reenterOk(), "fixture: the view call must have succeeded");
        assertTrue(abi.decode(hostile.reenterReturnData(), (bool)), "the nonce was not burned before the money moved");
    }

    /// 🔴 The buyer's STANDING allowance is the loss ceiling, and a venue callback cannot spend
    /// a wei of it beyond the one settlement it is inside. The buyer here has approved far more
    /// than this settlement needs, which is the shape a careless integration produces.
    function test_Reentrancy_AStandingBuyerAllowanceIsNotReachableFromAVenueCallback() public {
        uint256 standing = 10_000e6;
        uint256 buyerBefore = currency.balanceOf(buyer);

        _settleWithCallback(address(router), _secondSettlementCalldata(), standing);

        assertEq(currency.balanceOf(buyer), buyerBefore - QUOTE - FEE, "more than one settlement was debited");
        assertEq(currency.allowance(buyer, address(router)), standing - QUOTE - FEE, "the allowance was over-spent");
    }

    /// The admin surface is not reachable from a venue callback, and the thing that stops it is
    /// access control rather than the reentrancy guard — the venue simply holds no role. Asserted
    /// on the lever that would do the most damage.
    function test_Reentrancy_AVenueCannotPauseOrUnpauseTheRouter() public {
        _settleWithCallback(address(router), abi.encodeCall(AsseteraPrimarySales.pause, ()));

        assertFalse(hostile.reenterOk(), "the venue paused the router");
        assertEq(
            hostile.reenterErrorSelector(),
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            "refused by something other than access control"
        );
        assertFalse(router.paused(), "the router was paused from inside a venue call");
    }

    /// The same for the fee-collector allowlist, which is the admin write a venue would most
    /// want: listing itself would let a later settlement route our fee to it.
    function test_Reentrancy_AVenueCannotAllowlistItselfAsAFeeCollector() public {
        _settleWithCallback(
            address(router), abi.encodeCall(AsseteraPrimarySales.setAllowedCollector, (address(hostile), true))
        );

        assertFalse(hostile.reenterOk(), "the venue allowlisted itself");
        assertFalse(router.allowedCollectors(address(hostile)), "the venue is on the collector allowlist");
    }

    /// And for the value cap, which is the check on the settlement operator: a venue that could
    /// raise it would remove the only bound on a decimals or arithmetic mistake.
    function test_Reentrancy_AVenueCannotRaiseTheSettlementCap() public {
        _settleWithCallback(
            address(router), abi.encodeCall(router.setSettlementCap, (address(currency), type(uint128).max))
        );

        assertFalse(hostile.reenterOk(), "the venue moved the settlement cap");
        assertEq(router.perTxCap(address(currency)), 0, "the cap was written from inside a venue call");
    }

    /// The native-currency pass-through is admin-only for the same reason, and a venue callback
    /// is the exact caller it has to refuse: the router holds no native balance, but a venue
    /// that could call it during a settlement funded with `msg.value` would.
    function test_Reentrancy_AVenueCannotTriggerTheWhitelistHandshake() public {
        _settleWithCallback(
            address(router), abi.encodeCall(AsseteraPrimarySales.whitelistHandshake, (address(hostile)))
        );

        assertFalse(hostile.reenterOk(), "the venue triggered the handshake");
        assertEq(
            hostile.reenterErrorSelector(),
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            "refused by something other than access control"
        );
    }
}

/// @title VenueSettlerVenueIdentityTest
/// @notice 🔴 The structural guard — the venue may not be either of the settlement's two tokens
///         — and the question it raises: the venue is called with bytes we did not author, so
///         what ELSE could those bytes reach?
///
///         The answer is nothing, and the reason is structural rather than a list. This router
///         holds exactly one allowance at any moment (`settlementToken` → `intent.venue`, set
///         and revoked inside one call), holds no token balance between settlements, and holds
///         no role on itself. `VenueSettler.t.sol` pins the two comparisons; this suite pins the
///         surface those comparisons are protecting.
contract VenueSettlerVenueIdentityTest is HostileSettlementBase {
    /// A THIRD token — neither leg of this settlement — is not reachable, because the router has
    /// never approved anybody on it. The venue's `transferFrom` fails inside the token and takes
    /// the settlement with it.
    ///
    /// The script's `paymentToken` is repointed at the ASSET while the intent still settles in
    /// `currency`, which is precisely "the venue reaches for a token that is not the one it was
    /// approved on".
    function test_VenueIdentity_AVenueCannotSpendATokenTheRouterNeverApproved() public {
        asset.mint(address(router), 5e18); // give the reach somewhere to land, so a zero balance is not the reason
        HostileVenue.Script memory script = _script(1, ASSET_OUT);
        script.paymentToken = address(asset);
        bytes memory data = _encode(script);
        PrimaryTypes.SettlementIntent memory intent = _hostileIntent(data);

        _approveDebit(address(router), intent);
        vm.expectRevert(ISettler.VenueCallFailed.selector);
        _submitFull(data, intent, TAKER_BPS);
    }

    /// 🔴 After a settlement the router approves nobody, on either leg. The in-flight approval is
    /// the only one that ever exists and it does not outlive the transaction that created it —
    /// which is what makes "a third token the router has an allowance on" an empty set rather
    /// than a list somebody has to keep short.
    function test_VenueIdentity_NoAllowanceOnAnyTokenSurvivesASettlement() public {
        bytes memory data = _encode(_script(900e6, ASSET_OUT));
        PrimaryTypes.SettlementIntent memory intent = _hostileIntent(data);

        _approveDebit(address(router), intent);
        _submitFull(data, intent, TAKER_BPS);

        assertEq(currency.allowance(address(router), address(hostile)), 0, "settlement leg, to the venue");
        assertEq(currency.allowance(address(router), address(venue)), 0, "settlement leg, to another venue");
        assertEq(currency.allowance(address(router), stranger), 0, "settlement leg, to a stranger");
        assertEq(asset.allowance(address(router), address(hostile)), 0, "asset leg, to the venue");
        assertEq(asset.allowance(address(router), stranger), 0, "asset leg, to a stranger");
    }

    /// The router as its own venue is not blocked by the structural guard — it is neither token
    /// — and gets nothing for it. The self-call carries `msg.sender == address(this)`, which
    /// holds no role, so the admin surface answers the same way it does to anybody else.
    function test_VenueIdentity_TheRouterAsItsOwnVenueCannotReachItsOwnAdminSurface() public {
        bytes memory data = abi.encodeCall(AsseteraPrimarySales.pause, ());
        PrimaryTypes.SettlementIntent memory intent =
            _intentOver(address(currency), address(asset), address(router), data, QUOTE, FEE);

        _approveDebit(address(router), intent);
        vm.expectRevert(ISettler.VenueCallFailed.selector);
        _submitFull(data, intent, TAKER_BPS);

        assertFalse(router.paused(), "the router paused itself through a self-call venue");
    }

    /// And the reentrancy guard is what answers a self-call that tries to settle again, so the
    /// two defences overlap rather than depend on each other.
    function test_VenueIdentity_TheRouterAsItsOwnVenueCannotSettleAgain() public {
        bytes memory inner = _venueCalldata(QUOTE, ASSET_OUT);
        PrimaryTypes.SettlementIntent memory second = _venueIntent(inner, QUOTE, FEE, collector);
        second.nonce = INTENT_NONCE + 1;
        bytes32 secondHash = _paramsHash(second);
        bytes memory data = abi.encodeCall(
            AsseteraPrimarySales.settlePrimary,
            (
                inner,
                second,
                _signIntent(address(router), second),
                _signBuyerConsent(address(router), second),
                _kyc(address(router), secondHash),
                _fee(address(router), secondHash, 0, TAKER_BPS, collector, address(currency))
            )
        );
        PrimaryTypes.SettlementIntent memory intent =
            _intentOver(address(currency), address(asset), address(router), data, QUOTE, FEE);

        _approveDebit(address(router), intent);
        vm.expectRevert(ISettler.VenueCallFailed.selector);
        _submitFull(data, intent, TAKER_BPS);
    }
}

/// @title VenueSettlerCapBoundaryTest
/// @notice 🔴 The per-transaction cap at its edges, through the REAL `SettlementLimits` rather
///         than the mock the other suites run on, and with real money moving.
///
///         The design point pinned here, which is deliberate and is not to be changed: the cap
///         is charged on `venueQuoteIn + buyerFee` — the FULL authorised debit — as step 1,
///         BEFORE the venue is called. Charging the net amount after the refund is known would
///         put an external call before the value limit, and the cap exists to catch decimals and
///         arithmetic mistakes, which is only useful if it fires before money moves.
contract VenueSettlerCapBoundaryTest is HostileSettlementBase {
    AsseteraPrimarySales internal realCaps;
    MutableDecimalsToken internal mutableCurrency;

    /// `QUOTE + FEE` is 1 005.000000, which is exactly 1 005 whole units of a six-decimal
    /// currency — so the cap boundary can be hit to the wei from a whole-unit setter.
    uint256 internal constant CAP_WHOLE_EXACT = 1_005;

    function setUp() public virtual override {
        super.setUp();

        AsseteraPrimarySales impl = new AsseteraPrimarySales(address(forwarder));
        bytes memory initData =
            abi.encodeCall(AsseteraPrimarySales.initialize, (admin, kycSigner, feeSigner, settlementSigner));
        realCaps = AsseteraPrimarySales(address(new ERC1967Proxy(address(impl), initData)));

        mutableCurrency = new MutableDecimalsToken("Mutable USD", "muUSD", 18);
        mutableCurrency.mint(buyer, 100_000e18);

        vm.prank(admin);
        realCaps.setAllowedCollector(collector, true);
    }

    /// 🔴 Exactly at the cap settles. `amountDebited > cap` is the comparison, so the boundary
    /// is inclusive, and a cap sized to the largest expected order must not refuse that order.
    function test_Cap_ADebitExactlyAtTheCapSettles() public {
        vm.prank(admin);
        realCaps.setSettlementCap(address(currency), CAP_WHOLE_EXACT);

        bytes memory data = _encode(_script(QUOTE, ASSET_OUT));
        PrimaryTypes.SettlementIntent memory intent = _hostileIntent(data);

        _approveDebit(address(realCaps), intent);
        _submitFullTo(realCaps, data, intent, TAKER_BPS);

        assertEq(asset.balanceOf(buyer), ASSET_OUT, "a debit exactly at the cap was refused");
        assertEq(currency.balanceOf(address(hostile)), QUOTE, "the venue was not paid");
    }

    /// 🔴 One wei over is refused, and nothing moves. The extra wei is on the quote, which leaves
    /// the derived fee unchanged (50 bps of 1 000.000001 still floors to 5.000000), so the ONLY
    /// difference between this test and the one above is a single unit of the debit.
    function test_Cap_ADebitOneWeiOverTheCapIsRefusedAndNothingMoves() public {
        vm.prank(admin);
        realCaps.setSettlementCap(address(currency), CAP_WHOLE_EXACT);

        uint256 quote = QUOTE + 1;
        bytes memory data = _encode(_script(quote, ASSET_OUT));
        PrimaryTypes.SettlementIntent memory intent =
            _intentOver(address(currency), address(asset), address(hostile), data, quote, FEE);
        uint256 buyerBefore = currency.balanceOf(buyer);

        _approveDebit(address(realCaps), intent);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISettlementLimits.PerTxCapExceeded.selector, address(currency), QUOTE + FEE + 1, uint256(1_005e6)
            )
        );
        _submitFullTo(realCaps, data, intent, TAKER_BPS);

        assertEq(currency.balanceOf(buyer), buyerBefore, "the buyer was debited over the cap");
        assertEq(currency.balanceOf(address(hostile)), 0, "the venue was paid over the cap");
        assertEq(asset.balanceOf(buyer), 0, "the asset was delivered over the cap");
    }

    /// 🔴 **The design point, pinned.** The venue here consumes one single unit, so the amount
    /// the buyer NETS out is 6.000000 — three orders of magnitude below the cap. The settlement
    /// is refused anyway, because the cap is charged on what the buyer AUTHORISED before the
    /// venue is called, not on what turned out to be spent.
    ///
    /// Do not "fix" this by moving the charge below the money: a value limit that runs after an
    /// external call is a limit on a number the external call already had the chance to change.
    function test_Cap_IsChargedOnTheFullAuthorisedDebitNotOnTheNetOne() public {
        vm.prank(admin);
        realCaps.setSettlementCap(address(currency), CAP_WHOLE_EXACT - 1);

        bytes memory data = _encode(_script(1, ASSET_OUT));
        PrimaryTypes.SettlementIntent memory intent = _hostileIntent(data);

        _approveDebit(address(realCaps), intent);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISettlementLimits.PerTxCapExceeded.selector, address(currency), QUOTE + FEE, uint256(1_004e6)
            )
        );
        _submitFullTo(realCaps, data, intent, TAKER_BPS);
    }

    /// 🔴 A settlement currency that changes its `decimals()` AFTER a cap was sized against it.
    /// `setSettlementCap` reads decimals once, in the admin call, deliberately — so the stored
    /// raw cap keeps meaning what it meant at set time while the token means something else.
    ///
    /// The direction asserted here is the dangerous one: decimals fall, so the frozen raw cap
    /// now permits a TRILLION times the whole-unit value a human signed off. The cap exists to
    /// catch exactly that class of magnitude error, which is why this is worth an executable
    /// statement rather than a sentence in a comment.
    function test_Cap_ADecimalsChangeSilentlyRepricesTheStoredCap() public {
        vm.prank(admin);
        realCaps.setSettlementCap(address(mutableCurrency), CAP_WHOLE_EXACT);
        assertEq(realCaps.perTxCap(address(mutableCurrency)), 1_005e18, "fixture: converted at eighteen decimals");

        mutableCurrency.setDecimals(6);

        assertEq(realCaps.perTxCap(address(mutableCurrency)), 1_005e18, "the raw cap must not follow the token");
        assertEq(realCaps.perTxCapWholeUnits(address(mutableCurrency)), CAP_WHOLE_EXACT, "the stored whole units");
        assertEq(mutableCurrency.decimals(), 6, "fixture: the token now reports six");

        // The pair no longer describes the same number: 1005e18 raw units of a six-decimal
        // token is 1 005 000 000 000 000 whole units, not 1 005.
        uint256 quote = 1_000e18;
        uint256 buyerFee = 5e18; // 50 bps of the quote, floored — unchanged by the decimals
        HostileVenue.Script memory script = _script(quote, ASSET_OUT);
        script.paymentToken = address(mutableCurrency);
        bytes memory data = _encode(script);
        PrimaryTypes.SettlementIntent memory intent =
            _intentOver(address(mutableCurrency), address(asset), address(hostile), data, quote, buyerFee);

        _approveDebit(address(realCaps), intent);
        _submitFullTo(realCaps, data, intent, TAKER_BPS);

        assertEq(
            mutableCurrency.balanceOf(address(hostile)), quote, "a debit a trillion times the sized cap was let through"
        );
    }

    /// The remedy, and the mutation that proves the test above was about the stale conversion
    /// rather than about anything else: re-set the same whole-unit cap and it is converted
    /// against the decimals now in force, at which point the same settlement is refused.
    function test_Cap_ResettingTheCapAfterADecimalsChangeRestoresTheIntendedBound() public {
        vm.startPrank(admin);
        realCaps.setSettlementCap(address(mutableCurrency), CAP_WHOLE_EXACT);
        vm.stopPrank();

        mutableCurrency.setDecimals(6);

        vm.prank(admin);
        realCaps.setSettlementCap(address(mutableCurrency), CAP_WHOLE_EXACT);
        assertEq(realCaps.perTxCap(address(mutableCurrency)), 1_005e6, "the cap was not reconverted");

        uint256 quote = 1_000e18;
        HostileVenue.Script memory script = _script(quote, ASSET_OUT);
        script.paymentToken = address(mutableCurrency);
        bytes memory data = _encode(script);
        PrimaryTypes.SettlementIntent memory intent =
            _intentOver(address(mutableCurrency), address(asset), address(hostile), data, quote, 5e18);

        _approveDebit(address(realCaps), intent);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISettlementLimits.PerTxCapExceeded.selector, address(mutableCurrency), quote + 5e18, uint256(1_005e6)
            )
        );
        _submitFullTo(realCaps, data, intent, TAKER_BPS);
    }
}
