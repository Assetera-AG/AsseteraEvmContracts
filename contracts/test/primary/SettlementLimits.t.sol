// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {AsseteraPrimarySales} from "../../src/primary/AsseteraPrimarySales.sol";
import {PrimaryTypes} from "../../src/primary/types/PrimaryTypes.sol";
import {GateTypes} from "../../src/types/GateTypes.sol";
import {GateStorage} from "../../src/gates/GateStorage.sol";
import {ISettlementLimits} from "../../src/primary/interfaces/ISettlementLimits.sol";
import {PrimarySalesHarness} from "./mocks/PrimarySalesHarness.sol";
import {PrimarySalesTestBase} from "./PrimarySalesTestBase.sol";

/// @notice `AsseteraPrimarySales` with the settlement seam filled by a stub that moves nothing,
///         plus the internal hook exposed for direct assertion.
///
///         It does NOT extend `PrimarySalesHarness`, and that is a compiler fact rather than a
///         preference: that harness's `_settleVenue` is `internal pure override` — non-virtual,
///         so it cannot be overridden again. Everything else — the fixtures, the three signers,
///         the intent and attestation builders — comes from `PrimarySalesTestBase`.
///
/// @dev    ⚠️ **The stub deliberately does NOT charge the cap, and it used to.** The charge is
///         made once, by `SettlementLimits._authorizeSettlement`, which every settlement path
///         runs before it moves anything — a cap each path opted into was not a cap, and the
///         mint stub's documented preamble omitted it entirely. A stub that charged again
///         would be asserting a duplicate rather than the real path.
///
///         The number the preamble charges is `venueQuoteIn + buyerFee`, the full authorised
///         debit, before the settler is entered: the refund is not known until after the venue
///         has been called. These suites are about the module — what it stores, how it converts,
///         and that it refuses what exceeds the cap — plus the settlement-level assertions at
///         the end, which are now about the preamble rather than about the settler.
contract SettlementCapsHarness is AsseteraPrimarySales {
    /// Measured delivery, above `MIN_ASSET_OUT`. Nothing in this packet reads it.
    uint256 public constant STUB_ASSET_DELIVERED = 42e18;
    /// What the venue did NOT take. Refunded to the buyer, so never debited.
    uint256 public constant STUB_REFUND = 10e6;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address trustedForwarder) AsseteraPrimarySales(trustedForwarder) {}

    /// @dev Moves no tokens and charges nothing: the cap has already been charged by the shared
    ///      preamble by the time a family runs. Reports the four numbers the entry point puts
    ///      into `PrimarySettled`.
    ///
    ///      The third parameter is the attested `takerFeeBps`, which the real `VenueSettler`
    ///      cross-checks `intent.buyerFee` against. This stub REPLACES that settler wholesale,
    ///      so it deliberately ignores the parameter: these suites are about the cap arithmetic,
    ///      and the fee cross-check is pinned where it lives, in `VenueSettler.t.sol`.
    function _settleVenue(bytes calldata, SettlementIntent calldata intent, uint16)
        internal
        pure
        override
        returns (SettlementResult memory)
    {
        return SettlementResult({
            assetDelivered: STUB_ASSET_DELIVERED,
            venueIn: intent.venueQuoteIn - STUB_REFUND,
            refund: STUB_REFUND,
            fee: intent.buyerFee
        });
    }

    /// @notice Direct access to the internal hook, so the cap arithmetic can be asserted without
    ///         assembling three signatures for every case.
    function consumeSettlementLimit(address token, uint256 amountDebited) external {
        _consumeSettlementLimit(token, amountDebited);
    }
}

/// @title SettlementLimitsTestBase
/// @notice The caps harness on top of the shared primary-sale fixtures.
///
/// @dev    ⚠️ `CURRENCY` is a bare address in the shared base, with no code. The cap setter reads
///         `decimals()`, so every suite here mocks it. Six decimals, because the settlement
///         currency this is sized against is USDC-shaped and because the whole point of the
///         decimals handling is that six and eighteen must both work.
abstract contract SettlementLimitsTestBase is PrimarySalesTestBase {
    SettlementCapsHarness internal caps;

    /// An 18-decimal settlement currency, so the same whole-unit cap can be shown to mean two
    /// different raw numbers.
    address internal constant CURRENCY_18 = address(0xDA1);
    /// A settlement currency that does not answer `decimals()` at all.
    address internal constant CURRENCY_MUTE = address(0x3007);

    /// The debit one `_settleThrough` is charged for: the FULL authorised debit, charged by the
    /// shared preamble before any family runs. It is not net of `STUB_REFUND`, because the
    /// refund is not known until after a venue has been called.
    uint256 internal constant DEBITED = QUOTE_IN + BUYER_FEE;

    /// The cap the suites run under, in WHOLE tokens. `QUOTE_IN` is 1_000e6, so ten thousand
    /// whole units is comfortably above one settlement and nowhere near a decimals mistake.
    uint256 internal constant CAP_WHOLE = 10_000;

    function setUp() public virtual override {
        super.setUp();

        _mockDecimals(CURRENCY, 6);
        _mockDecimals(CURRENCY_18, 18);

        SettlementCapsHarness impl = new SettlementCapsHarness(address(forwarder));
        bytes memory initData =
            abi.encodeCall(AsseteraPrimarySales.initialize, (admin, kycSigner, feeSigner, settlementSigner));
        caps = SettlementCapsHarness(address(new ERC1967Proxy(address(impl), initData)));

        vm.startPrank(admin);
        caps.setAllowedCollector(collector, true);
        caps.setSettlementCap(CURRENCY, CAP_WHOLE);
        vm.stopPrank();
    }

    /// A full settlement through the frozen entry point, for `who`. Mirrors
    /// `PrimarySalesTestBase._settle`, which pins `buyer` into all four payloads.
    ///
    /// `whoPk` is a parameter rather than `buyerPk` closed over, because `who` is the intent's
    /// buyer and the buyer signs the intent: a helper that took only the address would silently
    /// build a settlement the buyer never consented to the moment anyone passed a second party.
    function _settleThrough(address who, uint256 whoPk) internal {
        PrimaryTypes.SettlementIntent memory intent = _intent();
        intent.buyer = who;
        bytes32 paramsHash = _paramsHash(intent);

        vm.prank(who);
        caps.settlePrimary(
            VENUE_CALLDATA,
            intent,
            _signIntentWith(settlementSignerPk, address(caps), intent),
            _signIntentWith(whoPk, address(caps), intent),
            _kycFor(who, paramsHash),
            _feeFor(who, paramsHash)
        );
    }

    function _kycFor(address who, bytes32 paramsHash) internal view returns (GateTypes.KycAttestation memory) {
        uint8 action = uint8(PrimaryTypes.Action.SettleVenue);
        uint256 deadline = block.timestamp + 3 minutes;
        bytes32 structHash =
            keccak256(abi.encode(KYC_TYPEHASH, who, action, uint256(0), KYC_NONCE, deadline, paramsHash));
        return GateTypes.KycAttestation({
            account: who,
            action: action,
            orderId: 0,
            nonce: KYC_NONCE,
            deadline: deadline,
            paramsHash: paramsHash,
            signature: _sign(kycSignerPk, _digest(PRIMARY_DOMAIN_NAME, address(caps), structHash))
        });
    }

    function _feeFor(address who, bytes32 paramsHash) internal view returns (GateTypes.FeeAttestation memory) {
        uint8 action = uint8(PrimaryTypes.Action.SettleVenue);
        uint256 deadline = block.timestamp + 3 minutes;
        bytes32 structHash = keccak256(
            abi.encode(
                FEE_TYPEHASH, who, action, FEE_NONCE, deadline, paramsHash, uint16(0), uint16(50), collector, CURRENCY
            )
        );
        return GateTypes.FeeAttestation({
            account: who,
            action: action,
            nonce: FEE_NONCE,
            deadline: deadline,
            paramsHash: paramsHash,
            makerFeeBps: 0,
            takerFeeBps: 50,
            feeCollector: collector,
            feeToken: CURRENCY,
            signature: _sign(feeSignerPk, _digest(PRIMARY_DOMAIN_NAME, address(caps), structHash))
        });
    }
}

/// @title SettlementCapAdminTest
/// @notice The admin surface: who may move the cap, what it writes, and what it emits.
contract SettlementCapAdminTest is SettlementLimitsTestBase {
    event SettlementCapSet(address indexed token, uint256 wholeUnits, uint256 rawCap, uint8 decimals);

    /// The key that can raise the cap must not be the key the cap is checking. Admin only.
    function test_SetSettlementCap_RejectsANonAdminCaller() public {
        // Read the role BEFORE the prank: it is a call too, and would otherwise consume it.
        bytes32 adminRole = caps.DEFAULT_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole)
        );
        caps.setSettlementCap(CURRENCY, 1);
    }

    /// Holding the role that signs an intent must not carry the right to widen what that intent
    /// may move.
    function test_SetSettlementCap_RejectsTheSettlementOperator() public {
        bytes32 adminRole = caps.DEFAULT_ADMIN_ROLE();
        vm.prank(settlementSigner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, settlementSigner, adminRole
            )
        );
        caps.setSettlementCap(CURRENCY, type(uint256).max);
    }

    /// Both readings are stored, and the event carries the decimals the conversion used.
    function test_SetSettlementCap_StoresRawAndWholeAndEmits() public {
        vm.expectEmit(true, false, false, true, address(caps));
        emit SettlementCapSet(CURRENCY, 111, 111e6, 6);

        vm.prank(admin);
        caps.setSettlementCap(CURRENCY, 111);

        assertEq(caps.perTxCap(CURRENCY), 111e6, "raw");
        assertEq(caps.perTxCapWholeUnits(CURRENCY), 111, "whole");
    }

    function test_SetSettlementCap_RejectsTheZeroToken() public {
        vm.prank(admin);
        vm.expectRevert(GateStorage.ZeroAddress.selector);
        caps.setSettlementCap(address(0), 1);
    }

    /// The fail-closed default, stated as a read: a token nobody configured has no allowance, and
    /// zero means "closed" rather than "unlimited".
    function test_Cap_ReadsZeroForAnUnconfiguredToken() public view {
        assertEq(caps.perTxCap(ASSET), 0, "raw");
        assertEq(caps.perTxCapWholeUnits(ASSET), 0, "whole");
    }

    /// Closing a token must keep working even for one that has stopped answering `decimals()`,
    /// which is exactly the token you would most want to close in a hurry.
    function test_SetSettlementCap_ClosesATokenWithoutReadingItsDecimals() public {
        vm.startPrank(admin);
        caps.setSettlementCap(CURRENCY, CAP_WHOLE);
        vm.clearMockedCalls();
        vm.etch(CURRENCY, hex"00"); // code, but nothing that answers decimals()
        caps.setSettlementCap(CURRENCY, 0);
        vm.stopPrank();

        assertEq(caps.perTxCap(CURRENCY), 0, "raw");
        assertEq(caps.perTxCapWholeUnits(CURRENCY), 0, "whole");
    }
}

/// @title SettlementCapDecimalsTest
/// @notice 🔴 The heart of this module: one setter, one unit, currencies with different decimals.
///
///         The cap is set in WHOLE TOKENS and converted once, so an operator types the same
///         number for a six-decimal currency and an eighteen-decimal one. Getting this wrong in
///         the other direction — a cap typed in raw units — is how a cap ends up a trillion times
///         too large, which is the exact bug the cap exists to catch.
contract SettlementCapDecimalsTest is SettlementLimitsTestBase {
    /// The same whole-unit number means two different raw numbers, and both are right.
    function test_TheSameWholeCapMeansDifferentRawCapsPerCurrency() public {
        vm.startPrank(admin);
        caps.setSettlementCap(CURRENCY, 1_000_000);
        caps.setSettlementCap(CURRENCY_18, 1_000_000);
        vm.stopPrank();

        assertEq(caps.perTxCap(CURRENCY), 1_000_000e6, "six-decimal raw cap");
        assertEq(caps.perTxCap(CURRENCY_18), 1_000_000e18, "eighteen-decimal raw cap");
        assertEq(caps.perTxCapWholeUnits(CURRENCY), caps.perTxCapWholeUnits(CURRENCY_18), "same number typed");
    }

    /// A million of a six-decimal currency settles; one raw unit more does not.
    function test_TheBoundaryIsExactOnASixDecimalCurrency() public {
        vm.prank(admin);
        caps.setSettlementCap(CURRENCY, 1_000_000);

        caps.consumeSettlementLimit(CURRENCY, 1_000_000e6);
        vm.expectRevert(
            abi.encodeWithSelector(ISettlementLimits.PerTxCapExceeded.selector, CURRENCY, 1_000_000e6 + 1, 1_000_000e6)
        );
        caps.consumeSettlementLimit(CURRENCY, 1_000_000e6 + 1);
    }

    /// And the same holds at eighteen decimals, where the raw numbers are a trillion times larger.
    function test_TheBoundaryIsExactOnAnEighteenDecimalCurrency() public {
        vm.prank(admin);
        caps.setSettlementCap(CURRENCY_18, 1_000_000);

        caps.consumeSettlementLimit(CURRENCY_18, 1_000_000e18);
        vm.expectRevert();
        caps.consumeSettlementLimit(CURRENCY_18, 1_000_000e18 + 1);
    }

    /// 🔴 The failure this module actually exists for. An amount computed as though six-decimal
    /// USDC had eighteen decimals is off by a factor of a trillion. A cap sized a hundred times
    /// above the largest plausible order still catches it, which is why sizing it generously
    /// costs nothing.
    function test_ADecimalsBugIsCaughtEvenByAVeryGenerousCap() public {
        vm.prank(admin);
        caps.setSettlementCap(CURRENCY, 100 * 1_000_000); // a hundred million, far above any order

        uint256 intended = 1_000e6; // one thousand USDC
        uint256 asIf18Decimals = 1_000e18; // the same order, with the wrong decimals

        caps.consumeSettlementLimit(CURRENCY, intended);
        vm.expectRevert();
        caps.consumeSettlementLimit(CURRENCY, asIf18Decimals);
    }

    /// A token that does not answer `decimals()` cannot be given a cap, so it cannot be settled
    /// in either. Fails closed, and names the token rather than reverting anonymously.
    function test_ATokenThatDoesNotReportDecimalsCannotBeCapped() public {
        vm.etch(CURRENCY_MUTE, hex"00");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISettlementLimits.TokenDecimalsUnavailable.selector, CURRENCY_MUTE));
        caps.setSettlementCap(CURRENCY_MUTE, 1);
    }

    /// So does an address with no code at all, which is the fat-fingered-address case.
    function test_AnAddressWithNoCodeCannotBeCapped() public {
        address notAToken = makeAddr("notAToken");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISettlementLimits.TokenDecimalsUnavailable.selector, notAToken));
        caps.setSettlementCap(notAToken, 1);
    }

    /// And a token reporting more decimals than any real currency is refused rather than having
    /// its cap converted at a scale nobody intended.
    function test_ImplausibleDecimalsAreRefused() public {
        address weird = address(0xBAD);
        _mockDecimals(weird, 77);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISettlementLimits.TokenDecimalsImplausible.selector, weird, uint256(77)));
        caps.setSettlementCap(weird, 1);
    }
}

/// @title SettlementCapEnforcementTest
/// @notice The cap itself, asserted against the internal hook directly.
contract SettlementCapEnforcementTest is SettlementLimitsTestBase {
    /// The boundary is inclusive: a settlement EXACTLY at the cap is at the cap, not over it. An
    /// off-by-one here breaks the largest order the operator sized the cap for.
    function test_Consume_AcceptsADebitExactlyAtTheCap() public {
        caps.consumeSettlementLimit(CURRENCY, CAP_WHOLE * 1e6);
    }

    function test_Consume_RejectsADebitOneAboveTheCap() public {
        uint256 cap = CAP_WHOLE * 1e6;
        vm.expectRevert(abi.encodeWithSelector(ISettlementLimits.PerTxCapExceeded.selector, CURRENCY, cap + 1, cap));
        caps.consumeSettlementLimit(CURRENCY, cap + 1);
    }

    /// An unconfigured token is closed, not unlimited.
    function test_Consume_RejectsAnUnconfiguredToken() public {
        vm.expectRevert(abi.encodeWithSelector(ISettlementLimits.PerTxCapExceeded.selector, ASSET, DEBITED, 0));
        caps.consumeSettlementLimit(ASSET, DEBITED);
    }

    /// 🔴 The zero-debit case, which is the one a naive `amountDebited > cap` would wave through:
    /// a venue that consumed exactly nothing, with a zero fee, against a currency nobody
    /// configured. It must still be refused.
    function test_Consume_RejectsAZeroDebitOnAnUnconfiguredToken() public {
        vm.expectRevert(abi.encodeWithSelector(ISettlementLimits.PerTxCapExceeded.selector, ASSET, 0, 0));
        caps.consumeSettlementLimit(ASSET, 0);
    }

    /// A token whose cap was set back to zero is closed again.
    function test_Consume_RejectsATokenWhoseCapWasSetBackToZero() public {
        vm.prank(admin);
        caps.setSettlementCap(CURRENCY, 0);

        vm.expectRevert(abi.encodeWithSelector(ISettlementLimits.PerTxCapExceeded.selector, CURRENCY, DEBITED, 0));
        caps.consumeSettlementLimit(CURRENCY, DEBITED);
    }
}

/// @title SettlementCapThroughTheEntryPointTest
/// @notice The same claims through a whole settlement rather than through the hook alone: the cap
///         is charged on the number the FAMILY hands over, and a cap that refuses leaves nothing
///         behind.
contract SettlementCapThroughTheEntryPointTest is SettlementLimitsTestBase {
    /// 🔴 The number a settlement is charged, and WHERE it is charged. The stub settler charges
    /// nothing at all, so a settlement that is still refused proves the charge comes from the
    /// shared preamble rather than from the settler — which is the whole property, since
    /// `VenueSettler` is the only settler there is and a second one would otherwise have
    /// shipped uncapped, as the deleted mint stub was on course to.
    ///
    /// The amount in the error is the FULL authorised debit rather than anything net of the
    /// stub's refund, because the refund is not known before the venue is called.
    function test_Settlement_IsChargedByTheSharedPreambleNotByTheFamily() public {
        // A raw cap strictly under the debit, set directly so no rounding to whole units can
        // blur the boundary this test depends on.
        vm.prank(admin);
        caps.setSettlementCap(CURRENCY, 1); // 1e6 raw
        assertLt(caps.perTxCap(CURRENCY), DEBITED, "fixture: the cap must bite");

        vm.expectRevert(abi.encodeWithSelector(ISettlementLimits.PerTxCapExceeded.selector, CURRENCY, DEBITED, 1e6));
        _settleThrough(buyer, buyerPk);
    }

    /// A settlement inside the cap goes through and burns its nonce.
    function test_Settlement_SucceedsWithinTheCap() public {
        _settleThrough(buyer, buyerPk);
        assertTrue(caps.usedIntentNonce(buyer, INTENT_NONCE), "the intent nonce must be burned");
    }

    /// 🔴 A settlement the cap refuses must leave NOTHING behind, the nonce included. Otherwise a
    /// cap rejection would burn a buyer's nonce and turn a bounded refusal into a stuck order.
    function test_Settlement_BurnsNoNonceWhenTheCapRefusesIt() public {
        vm.prank(admin);
        caps.setSettlementCap(CURRENCY, 1);

        vm.expectRevert();
        _settleThrough(buyer, buyerPk);

        assertFalse(caps.usedIntentNonce(buyer, INTENT_NONCE), "a refused settlement burned a nonce");
    }

    /// A currency with no cap cannot be settled in at all, however well-formed the intent.
    function test_Settlement_RefusesACurrencyWithNoCap() public {
        vm.prank(admin);
        caps.setSettlementCap(CURRENCY, 0);

        vm.expectRevert(abi.encodeWithSelector(ISettlementLimits.PerTxCapExceeded.selector, CURRENCY, DEBITED, 0));
        _settleThrough(buyer, buyerPk);
    }
}

/// @title SettlementCapAppliesToEveryFamilyTest
/// @notice 🔴 The acceptance criterion for making the cap unskippable: it holds for a caller of
///         the shared preamble that is NOT `settlePrimary`.
///
///         Every other cap test in this repo goes through `settlePrimary`, which is the venue
///         settler's entry point — and the venue settler is the only one that exists. That is
///         precisely why the old arrangement was unsafe: `_consumeSettlementLimit` was called
///         from `VenueSettler` and from nowhere else, the `MintSettler` stub that then stood
///         beside it documented a preamble that OMITTED the cap, and every test in the suite
///         would still have passed with that second family shipping uncapped.
///
///         ⚠️ That stub has since been deleted — our own issuance goes through the venue path,
///         against a per-token sale contract — so `settlePrimary` is once again the only caller
///         of `_authorizeSettlement` in `src/`. This test is what stops "charged centrally" from
///         quietly decaying back into "charged by the one caller there happens to be".
///
///         `PrimarySalesHarness.settleAsAnotherFamily` is that second caller: the shared
///         preamble, then straight into a money path of its own. It charges nothing itself.
///
/// @dev    The pair below is the whole test. Uncapped, the call stops at `PerTxCapExceeded` and
///         never reaches the money path; capped, it reaches it and stops at the harness's own
///         `AnotherFamilyMoneyPathReached`. Take the charge out of `_authorizeSettlement` and
///         the first becomes the second.
contract SettlementCapAppliesToEveryFamilyTest is PrimarySalesTestBase {
    /// The action the second caller runs under. Not `SettleVenue`: the attestations carry the
    /// ordinal and the gates compare it, so this cannot accidentally be `settlePrimary`'s path.
    uint8 internal constant MINT_ACTION = uint8(PrimaryTypes.Action.SettleMint);

    function _submitAsAnotherFamily() internal {
        PrimaryTypes.SettlementIntent memory intent = _intent();
        bytes32 paramsHash = _paramsHash(intent);
        vm.prank(buyer);
        harness.settleAsAnotherFamily(
            intent,
            _signIntent(address(harness), intent),
            _signBuyerConsent(address(harness), intent),
            _kycForAction(MINT_ACTION, PRIMARY_DOMAIN_NAME, address(harness), 0, paramsHash),
            _feeForAction(MINT_ACTION, address(harness), paramsHash, 0, 50, collector, CURRENCY)
        );
    }

    /// 🔴 A caller that never touches the caps module is capped anyway, because the preamble it
    /// cannot skip does the charging. This is the test that fails if the charge is moved back
    /// into a settler module.
    function test_AFamilyThatChargesNothingIsStillCharged() public {
        vm.prank(admin);
        harness.setSettlementCap(CURRENCY, 0); // closed, which is also the unconfigured default

        vm.expectRevert(
            abi.encodeWithSelector(
                ISettlementLimits.PerTxCapExceeded.selector, CURRENCY, QUOTE_IN + BUYER_FEE, uint256(0)
            )
        );
        _submitAsAnotherFamily();
    }

    /// The mutation of the test above: with a cap open, the same call gets past the preamble and
    /// stops inside the family's own body. Without this, "it reverted" would prove nothing about
    /// WHERE it reverted.
    function test_TheSameFamilyReachesItsOwnBodyOnceTheCapIsOpen() public {
        vm.expectRevert(PrimarySalesHarness.AnotherFamilyMoneyPathReached.selector);
        _submitAsAnotherFamily();
    }

    /// And the charge is against the settlement token named in the intent, for the full
    /// authorised debit — the same number `settlePrimary` is charged, because the intent's
    /// amount model does not depend on who the venue is.
    function test_TheFamilyIsChargedTheFullAuthorisedDebit() public {
        vm.prank(admin);
        harness.setSettlementCap(CURRENCY, 1); // 1e6 raw, under the debit

        vm.expectRevert(
            abi.encodeWithSelector(
                ISettlementLimits.PerTxCapExceeded.selector, CURRENCY, QUOTE_IN + BUYER_FEE, uint256(1e6)
            )
        );
        _submitAsAnotherFamily();
    }
}

/// @title SettlementCapStorageTest
/// @notice That the appended state lives inside the primary-sale ERC-7201 namespace at the
///         offsets it claims, and nowhere near the low linear slots a proxy would use.
contract SettlementCapStorageTest is SettlementLimitsTestBase {
    bytes32 internal constant PRIMARY_STORAGE_LOCATION =
        0xc3c7d533132905df5cacdace21b89e3afb4b7188f583ae32f30e0a7379982700;

    uint256 internal constant SLOT_PER_TX_CAP = 1;
    uint256 internal constant SLOT_PER_TX_CAP_WHOLE = 2;

    function test_TheCapStateLandsAtItsAppendedOffsetsInsideTheNamespace() public {
        vm.prank(admin);
        caps.setSettlementCap(CURRENCY, 777);

        bytes32 rawSlot = keccak256(abi.encode(CURRENCY, uint256(PRIMARY_STORAGE_LOCATION) + SLOT_PER_TX_CAP));
        bytes32 wholeSlot = keccak256(abi.encode(CURRENCY, uint256(PRIMARY_STORAGE_LOCATION) + SLOT_PER_TX_CAP_WHOLE));

        assertEq(uint256(vm.load(address(caps), rawSlot)), 777e6, "raw cap slot");
        assertEq(uint256(vm.load(address(caps), wholeSlot)), 777, "whole-unit cap slot");
    }

    /// The proxy's low linear slots stay untouched, which is what makes the namespace claim mean
    /// something rather than being a comment.
    function test_SettingACapDoesNotTouchTheLowLinearSlots() public {
        vm.prank(admin);
        caps.setSettlementCap(CURRENCY, 777);

        for (uint256 i = 0; i < 8; i++) {
            assertEq(uint256(vm.load(address(caps), bytes32(i))), 0, "a linear slot was written");
        }
    }
}
