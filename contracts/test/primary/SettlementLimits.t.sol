// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {AsseteraPrimarySales} from "../../src/primary/AsseteraPrimarySales.sol";
import {PrimaryTypes} from "../../src/primary/types/PrimaryTypes.sol";
import {GateTypes} from "../../src/types/GateTypes.sol";
import {GateStorage} from "../../src/gates/GateStorage.sol";
import {ISettlementLimits} from "../../src/primary/interfaces/ISettlementLimits.sol";
import {PrimarySalesTestBase} from "./PrimarySalesTestBase.sol";

/// @notice `AsseteraPrimarySales` with the S2 seam filled by a stub that CHARGES THE CAPS the
///         way the constrained executor will, plus the internal hook exposed for direct
///         assertion.
///
///         It does NOT extend `PrimarySalesHarness`, and that is a compiler fact rather than a
///         preference: that harness's `_settleVenue` is `internal pure override` — non-virtual,
///         so it cannot be overridden again, and `pure`, so an override could not widen it to
///         one that writes. Charging a cap writes. Everything else — the fixtures, the three
///         signers, the intent and attestation builders — comes from `PrimarySalesTestBase`.
///
/// @dev    ⚠️ The stub's debit is `venueQuoteIn + buyerFee - refund`, which is the number
///         `VenueSettler` will hand over once the constrained-executor packet lands. It is
///         deliberately DIFFERENT from every quoted number in the intent, so a test that passes
///         here cannot also pass against an implementation that charges the quote.
contract SettlementCapsHarness is AsseteraPrimarySales {
    /// Measured delivery, above `MIN_ASSET_OUT`. Nothing in this packet reads it.
    uint256 public constant STUB_ASSET_DELIVERED = 42e18;
    /// What the venue did NOT take. Refunded to the buyer, so never debited.
    uint256 public constant STUB_REFUND = 10e6;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address trustedForwarder) AsseteraPrimarySales(trustedForwarder) {}

    /// @dev Moves no tokens. It charges the caps with the DEBITED amount and reports the four
    ///      numbers the entry point puts into `PrimarySettled`.
    function _settleVenue(bytes calldata, SettlementIntent calldata intent)
        internal
        override
        returns (SettlementResult memory)
    {
        _consumeSettlementLimit(intent.settlementToken, intent.venueQuoteIn + intent.buyerFee - STUB_REFUND);
        return SettlementResult({
            assetDelivered: STUB_ASSET_DELIVERED,
            venueIn: intent.venueQuoteIn - STUB_REFUND,
            refund: STUB_REFUND,
            fee: intent.buyerFee
        });
    }

    /// @notice Direct access to the internal hook, so the cap arithmetic can be asserted
    ///         without assembling three signatures for every case.
    function consumeSettlementLimit(address token, uint256 amountDebited) external {
        _consumeSettlementLimit(token, amountDebited);
    }
}

/// @title SettlementLimitsTestBase
/// @notice The caps harness on top of the shared primary-sale fixtures, plus the one thing the
///         shared base does not provide: signing for a buyer other than `buyer`. The per-day
///         cap's central claim is that it does NOT have a buyer dimension, and that cannot be
///         asserted with a single buyer.
abstract contract SettlementLimitsTestBase is PrimarySalesTestBase {
    SettlementCapsHarness internal caps;

    uint256 internal secondBuyerPk = 0xB0B2;
    address internal secondBuyer;

    /// The debit one `_settleThrough` produces: `QUOTE_IN + BUYER_FEE - STUB_REFUND`.
    uint256 internal constant DEBITED = QUOTE_IN + BUYER_FEE - 10e6;
    /// What a caller that charged the QUOTE instead would have produced.
    uint256 internal constant QUOTED = QUOTE_IN + BUYER_FEE;

    function setUp() public virtual override {
        super.setUp();
        secondBuyer = vm.addr(secondBuyerPk);

        SettlementCapsHarness impl = new SettlementCapsHarness(address(forwarder));
        bytes memory initData =
            abi.encodeCall(AsseteraPrimarySales.initialize, (admin, kycSigner, feeSigner, settlementSigner));
        caps = SettlementCapsHarness(address(new ERC1967Proxy(address(impl), initData)));

        vm.startPrank(admin);
        caps.setAllowedCollector(collector, true);
        caps.setSettlementCaps(CURRENCY, DEBITED, 10 * DEBITED);
        vm.stopPrank();
    }

    // ── settling as an arbitrary buyer ────────────────────────────────────────────────────

    /// A full settlement through the frozen entry point, for `who`. Mirrors
    /// `PrimarySalesTestBase._settle`, which pins `buyer` into all three payloads.
    ///
    /// The three nonces are per-buyer namespaced, so a second buyer reuses the same values. The
    /// buyer signs nothing: it submits the call itself, exactly as `_settle` does.
    function _settleThrough(address who) internal {
        PrimaryTypes.SettlementIntent memory intent = _intent();
        intent.buyer = who;
        bytes32 paramsHash = _paramsHash(intent);

        vm.prank(who);
        caps.settlePrimary(
            VENUE_CALLDATA,
            intent,
            _signIntentWith(settlementSignerPk, address(caps), intent),
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

/// @title SettlementCapsAdminTest
/// @notice The admin surface: who may move the caps, what it writes, and what it emits.
contract SettlementCapsAdminTest is SettlementLimitsTestBase {
    event SettlementCapsSet(address indexed token, uint256 perTxCap, uint256 perDayCap);

    /// 🔴 These caps are the only contract-level bound on what a compromised settlement signer
    /// can move, so the key that can raise them must not be the key they bound. Admin only.
    function test_SetSettlementCaps_RejectsANonAdminCaller() public {
        // Read the role BEFORE the prank: it is a call too, and would otherwise consume it.
        bytes32 adminRole = caps.DEFAULT_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole)
        );
        caps.setSettlementCaps(CURRENCY, 1, 1);
    }

    /// The settlement operator is not the admin, and holding the role that signs an intent must
    /// not carry the right to widen what that intent may move.
    function test_SetSettlementCaps_RejectsTheSettlementOperator() public {
        bytes32 adminRole = caps.DEFAULT_ADMIN_ROLE();
        vm.prank(settlementSigner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, settlementSigner, adminRole
            )
        );
        caps.setSettlementCaps(CURRENCY, type(uint256).max, type(uint256).max);
    }

    function test_SetSettlementCaps_StoresBothCapsAndEmits() public {
        vm.expectEmit(true, false, false, true, address(caps));
        emit SettlementCapsSet(ASSET, 111, 222);

        vm.prank(admin);
        caps.setSettlementCaps(ASSET, 111, 222);

        assertEq(caps.perTxCap(ASSET), 111, "perTxCap");
        assertEq(caps.perDayCap(ASSET), 222, "perDayCap");
    }

    function test_SetSettlementCaps_RejectsTheZeroToken() public {
        vm.prank(admin);
        vm.expectRevert(GateStorage.ZeroAddress.selector);
        caps.setSettlementCaps(address(0), 1, 1);
    }

    /// The fail-closed default, stated as a read: a token nobody configured has no allowance of
    /// any kind, and zero here means "closed" rather than "unlimited".
    function test_Caps_ReadZeroForAnUnconfiguredToken() public view {
        assertEq(caps.perTxCap(ASSET), 0, "perTxCap");
        assertEq(caps.perDayCap(ASSET), 0, "perDayCap");
        assertEq(caps.settledToday(ASSET), 0, "settledToday");
    }

    /// Lowering a cap mid-day must not hand back the allowance already spent under the old one.
    /// The accumulator survives a re-set, so an admin (or somebody who has reached the admin
    /// role) cannot double the day by rewriting the same numbers.
    function test_SetSettlementCaps_DoesNotResetTheDaysAccumulator() public {
        caps.consumeSettlementLimit(CURRENCY, DEBITED);
        assertEq(caps.settledToday(CURRENCY), DEBITED);

        vm.prank(admin);
        caps.setSettlementCaps(CURRENCY, DEBITED, 10 * DEBITED);

        assertEq(caps.settledToday(CURRENCY), DEBITED, "the day's spend was forgiven");
    }

    function test_SettlementCapWindow_IsOneUtcDay() public view {
        assertEq(caps.SETTLEMENT_CAP_WINDOW(), 1 days);
    }
}

/// @title SettlementCapsPerTxTest
/// @notice The per-transaction cap, asserted against the internal hook directly.
contract SettlementCapsPerTxTest is SettlementLimitsTestBase {
    /// The boundary is inclusive: a settlement EXACTLY at the cap is a settlement at the cap,
    /// not over it. An off-by-one here breaks the largest legitimate order the operator sized
    /// the cap for.
    function test_Consume_AcceptsADebitExactlyAtThePerTxCap() public {
        caps.consumeSettlementLimit(CURRENCY, DEBITED);
        assertEq(caps.settledToday(CURRENCY), DEBITED);
    }

    function test_Consume_RejectsADebitOneAboveThePerTxCap() public {
        vm.expectRevert(
            abi.encodeWithSelector(ISettlementLimits.PerTxCapExceeded.selector, CURRENCY, DEBITED + 1, DEBITED)
        );
        caps.consumeSettlementLimit(CURRENCY, DEBITED + 1);
    }

    /// A rejected settlement consumes no allowance.
    function test_Consume_ChargesNothingWhenItReverts() public {
        vm.expectRevert();
        caps.consumeSettlementLimit(CURRENCY, DEBITED + 1);
        assertEq(caps.settledToday(CURRENCY), 0);
    }

    /// 🔴 A zero `perTxCap` means "no settlement in this token AT ALL", which is the
    /// fail-closed default for a token nobody configured. The per-transaction check is what
    /// enforces it, so it is reported as `PerTxCapExceeded` with a cap of zero.
    function test_Consume_RejectsAnUnconfiguredToken() public {
        vm.expectRevert(abi.encodeWithSelector(ISettlementLimits.PerTxCapExceeded.selector, ASSET, 1, 0));
        caps.consumeSettlementLimit(ASSET, 1);
    }

    /// The case a bare `amountDebited > perTxCap` would wave through: zero is not below a cap
    /// of zero, it is a settlement in a currency that must not settle. A venue that consumed
    /// exactly nothing with a zero fee produces one.
    function test_Consume_RejectsAZeroDebitOnAnUnconfiguredToken() public {
        vm.expectRevert(abi.encodeWithSelector(ISettlementLimits.PerTxCapExceeded.selector, ASSET, 0, 0));
        caps.consumeSettlementLimit(ASSET, 0);
    }

    /// Closing a token is the same setter, not a separate lever, and it takes effect at once.
    function test_Consume_RejectsATokenWhoseCapsWereSetBackToZero() public {
        vm.prank(admin);
        caps.setSettlementCaps(CURRENCY, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(ISettlementLimits.PerTxCapExceeded.selector, CURRENCY, 1, 0));
        caps.consumeSettlementLimit(CURRENCY, 1);
    }
}

/// @title SettlementCapsPerDayTest
/// @notice The per-day cap: it accumulates, it is keyed by token alone, and it rolls over.
contract SettlementCapsPerDayTest is SettlementLimitsTestBase {
    function test_Consume_AccumulatesAcrossSettlements() public {
        caps.consumeSettlementLimit(CURRENCY, DEBITED);
        caps.consumeSettlementLimit(CURRENCY, DEBITED);
        caps.consumeSettlementLimit(CURRENCY, 1);

        assertEq(caps.settledToday(CURRENCY), 2 * DEBITED + 1);
    }

    /// The per-day boundary is inclusive too: the debit that lands exactly ON the cap fits, the
    /// next wei does not, and the error carries the debit rather than the running total.
    function test_Consume_RejectsTheDebitThatWouldCrossThePerDayCap() public {
        vm.prank(admin);
        caps.setSettlementCaps(CURRENCY, DEBITED, 2 * DEBITED);

        caps.consumeSettlementLimit(CURRENCY, DEBITED);
        caps.consumeSettlementLimit(CURRENCY, DEBITED);
        assertEq(caps.settledToday(CURRENCY), 2 * DEBITED);

        vm.expectRevert(abi.encodeWithSelector(ISettlementLimits.PerDayCapExceeded.selector, CURRENCY, 1, 2 * DEBITED));
        caps.consumeSettlementLimit(CURRENCY, 1);
    }

    /// The per-transaction cap is checked FIRST, so an oversized single settlement is reported
    /// as `PerTxCapExceeded` rather than as having exhausted the day.
    function test_Consume_ReportsThePerTxCapFirstWhenBothWouldFail() public {
        vm.prank(admin);
        caps.setSettlementCaps(CURRENCY, 10, 5);

        vm.expectRevert(abi.encodeWithSelector(ISettlementLimits.PerTxCapExceeded.selector, CURRENCY, 11, 10));
        caps.consumeSettlementLimit(CURRENCY, 11);
    }

    /// Caps are per settlement token. Spending USDC's day must not touch another currency's.
    function test_Consume_KeepsASeparateAccumulatorPerToken() public {
        vm.prank(admin);
        caps.setSettlementCaps(ASSET, DEBITED, 10 * DEBITED);

        caps.consumeSettlementLimit(CURRENCY, DEBITED);

        assertEq(caps.settledToday(CURRENCY), DEBITED, "settled token");
        assertEq(caps.settledToday(ASSET), 0, "the other token's day was consumed");
    }
}

/// @title SettlementCapsWindowTest
/// @notice The daily window mechanism: a FIXED UTC-day bucket (`block.timestamp / 1 days`),
///         cleared lazily by the settlement that discovers the roll.
contract SettlementCapsWindowTest is SettlementLimitsTestBase {
    /// Warping to the start of a UTC day makes every assertion below about the boundary rather
    /// than about wherever the test clock happened to start.
    function _warpToDayStart() internal returns (uint256 dayStart) {
        dayStart = (block.timestamp / 1 days + 1) * 1 days;
        vm.warp(dayStart);
    }

    function test_Window_DoesNotResetWithinTheSameDay() public {
        uint256 dayStart = _warpToDayStart();
        caps.consumeSettlementLimit(CURRENCY, DEBITED);

        vm.warp(dayStart + 1 days - 1);
        assertEq(caps.settledToday(CURRENCY), DEBITED, "the day reset one second early");
    }

    /// 🔴 The rollover. One second later the bucket is a different bucket, and the full
    /// allowance is available again without anybody having to run a reset transaction.
    function test_Window_RollsOverAtTheUtcDayBoundary() public {
        uint256 dayStart = _warpToDayStart();
        vm.prank(admin);
        caps.setSettlementCaps(CURRENCY, DEBITED, DEBITED);

        caps.consumeSettlementLimit(CURRENCY, DEBITED);
        vm.expectRevert(abi.encodeWithSelector(ISettlementLimits.PerDayCapExceeded.selector, CURRENCY, 1, DEBITED));
        caps.consumeSettlementLimit(CURRENCY, 1);

        vm.warp(dayStart + 1 days);
        assertEq(caps.settledToday(CURRENCY), 0, "the accumulator survived the boundary");
        caps.consumeSettlementLimit(CURRENCY, DEBITED);
        assertEq(caps.settledToday(CURRENCY), DEBITED);
    }

    /// The accumulator is cleared LAZILY, on the settlement that discovers the roll, so the
    /// getter has to do the same arithmetic. Returning the raw stored number would report
    /// yesterday's total as today's to every off-chain consumer.
    function test_SettledToday_ReadsZeroAfterTheRollWithNoInterveningWrite() public {
        uint256 dayStart = _warpToDayStart();
        caps.consumeSettlementLimit(CURRENCY, DEBITED);

        vm.warp(dayStart + 3 days);
        assertEq(caps.settledToday(CURRENCY), 0);
    }

    /// ⚠️ The KNOWN price of a fixed bucket over a sliding window, pinned as a property rather
    /// than left as a surprise: up to `2 * perDayCap` can move across a single UTC midnight, by
    /// filling the cap just before it and again just after. Size the cap at half the true
    /// 24-hour exposure if that matters. A sliding window would need per-settlement timestamps
    /// and unbounded pruning gas on the settlement path, which is not a trade this router makes.
    function test_Window_AllowsTwiceThePerDayCapAcrossABoundary() public {
        uint256 dayStart = _warpToDayStart();
        vm.prank(admin);
        caps.setSettlementCaps(CURRENCY, DEBITED, DEBITED);

        vm.warp(dayStart + 1 days - 1);
        caps.consumeSettlementLimit(CURRENCY, DEBITED);

        vm.warp(dayStart + 1 days);
        caps.consumeSettlementLimit(CURRENCY, DEBITED);

        assertEq(caps.settledToday(CURRENCY), DEBITED, "the second day's bucket");
    }
}

/// @title SettlementCapsThroughTheEntryPointTest
/// @notice The caps as a settlement actually meets them: charged by the settler family, on the
///         amount debited, with the buyer out of the picture entirely.
contract SettlementCapsThroughTheEntryPointTest is SettlementLimitsTestBase {
    /// 🔴 The acceptance criterion that the numbers cannot fake. The cap is set to the DEBITED
    /// amount, which is strictly below the quoted one, and the settlement succeeds — so the
    /// charge cannot have been the quote. The mirror-image case below shows the same fact from
    /// the failing side.
    function test_Settlement_ChargesTheDebitedAmountNotTheQuotedOne() public {
        assertLt(DEBITED, QUOTED, "the fixture must make the two numbers differ");

        vm.prank(admin);
        caps.setSettlementCaps(CURRENCY, DEBITED, QUOTED);

        _settleThrough(buyer);

        assertEq(caps.settledToday(CURRENCY), DEBITED, "the quote was charged, not the debit");
    }

    /// The other half: one wei below the debit and the settlement is refused, with the revert
    /// naming the debited amount. A caller that charged the quote would report `QUOTED` here.
    function test_Settlement_RevertsWhenTheDebitedAmountExceedsThePerTxCap() public {
        vm.prank(admin);
        caps.setSettlementCaps(CURRENCY, DEBITED - 1, QUOTED);

        vm.expectRevert(
            abi.encodeWithSelector(ISettlementLimits.PerTxCapExceeded.selector, CURRENCY, DEBITED, DEBITED - 1)
        );
        _settleThrough(buyer);
    }

    /// 🔴 The per-day cap is rolling across EVERY buyer, not per buyer. A per-buyer cap would
    /// bound nothing: the settlement operator names the buyer in the intent it signs, so a
    /// compromised signer would use a fresh buyer per settlement and get a fresh allowance
    /// each time. Two distinct buyers, one accumulator.
    function test_Settlement_AccumulatesAcrossDifferentBuyers() public {
        assertTrue(buyer != secondBuyer, "the two buyers must be distinct");

        _settleThrough(buyer);
        assertEq(caps.settledToday(CURRENCY), DEBITED, "first buyer");

        _settleThrough(secondBuyer);
        assertEq(caps.settledToday(CURRENCY), 2 * DEBITED, "the second buyer got a fresh allowance");
    }

    /// The day binds even when every individual settlement fits the per-transaction cap.
    function test_Settlement_RefusesTheBuyerWhoWouldCrossThePerDayCap() public {
        vm.prank(admin);
        caps.setSettlementCaps(CURRENCY, DEBITED, DEBITED);

        _settleThrough(buyer);

        vm.expectRevert(
            abi.encodeWithSelector(ISettlementLimits.PerDayCapExceeded.selector, CURRENCY, DEBITED, DEBITED)
        );
        _settleThrough(secondBuyer);
    }

    /// 🔴 A currency nobody configured cannot be settled in, through the real entry point and
    /// with every signature valid. This is what makes the caps the fail-closed default rather
    /// than a hardening pass somebody has to remember to run.
    function test_Settlement_RefusesATokenWithNoCaps() public {
        vm.prank(admin);
        caps.setSettlementCaps(CURRENCY, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(ISettlementLimits.PerTxCapExceeded.selector, CURRENCY, DEBITED, 0));
        _settleThrough(buyer);
    }

    /// A refused settlement leaves no trace: the cap check reverts the whole transaction, so
    /// the intent nonce it would have burned is still spendable once the caps are widened.
    function test_Settlement_BurnsNoNonceWhenTheCapRefusesIt() public {
        vm.prank(admin);
        caps.setSettlementCaps(CURRENCY, DEBITED - 1, QUOTED);

        vm.expectRevert();
        _settleThrough(buyer);
        assertFalse(caps.usedIntentNonce(buyer, INTENT_NONCE), "the intent nonce was burned by a refused settlement");

        vm.prank(admin);
        caps.setSettlementCaps(CURRENCY, DEBITED, QUOTED);
        _settleThrough(buyer);
        assertTrue(caps.usedIntentNonce(buyer, INTENT_NONCE));
    }
}

/// @title SettlementCapsStorageTest
/// @notice Where the appended cap state lives. `PrimaryData` is an ERC-7201 namespaced struct,
///         so appending to it is upgrade-safe — but only if the append really landed in the
///         namespace and really is an append. A wrong offset does not fail to compile and does
///         not fail a behavioural test; the state would simply live somewhere else and keep
///         agreeing with itself.
contract SettlementCapsStorageTest is SettlementLimitsTestBase {
    /// keccak256(abi.encode(uint256(keccak256("assetera.storage.PrimarySales")) - 1)) & ~bytes32(uint256(0xff))
    /// Repeated as a literal, as `PrimaryStorageNamespace.t.sol` does, so this test fails if the
    /// constant moves rather than moving with it.
    bytes32 internal constant PRIMARY_STORAGE_LOCATION =
        0xc3c7d533132905df5cacdace21b89e3afb4b7188f583ae32f30e0a7379982700;

    // Field order inside `PrimaryData`. The caps were APPENDED, so `usedIntentNonce` keeps
    // offset 0 and everything below is new ground.
    uint256 internal constant SLOT_USED_INTENT_NONCE = 0;
    uint256 internal constant SLOT_PER_TX_CAP = 1;
    uint256 internal constant SLOT_PER_DAY_CAP = 2;
    uint256 internal constant SLOT_CAP_WINDOW = 3;
    uint256 internal constant SLOT_SETTLED_IN_WINDOW = 4;

    /// 🔴 The append is an APPEND: the pre-existing member did not move, and each new mapping
    /// derives from its own offset inside the same namespace.
    function test_TheCapStateLandsAtItsAppendedOffsetsInsideTheNamespace() public {
        vm.prank(admin);
        caps.setSettlementCaps(ASSET, 111, 222);

        assertEq(uint256(vm.load(address(caps), _slot(ASSET, SLOT_PER_TX_CAP))), 111, "perTxCap");
        assertEq(uint256(vm.load(address(caps), _slot(ASSET, SLOT_PER_DAY_CAP))), 222, "perDayCap");

        // Offset 0 is still the nonce mapping, and setting caps did not write into it.
        bytes32 nonceOuter = _slot(buyer, SLOT_USED_INTENT_NONCE);
        assertEq(vm.load(address(caps), keccak256(abi.encode(INTENT_NONCE, nonceOuter))), bytes32(0));
    }

    function test_TheDailyAccumulatorLandsAtItsAppendedOffsets() public {
        caps.consumeSettlementLimit(CURRENCY, DEBITED);

        assertEq(
            uint256(vm.load(address(caps), _slot(CURRENCY, SLOT_CAP_WINDOW))),
            block.timestamp / 1 days,
            "the window index"
        );
        assertEq(uint256(vm.load(address(caps), _slot(CURRENCY, SLOT_SETTLED_IN_WINDOW))), DEBITED, "the accumulator");
    }

    /// `AsseteraPrimarySales` declares no linear storage at all, and the append must not have
    /// changed that.
    function test_SettingCapsDoesNotTouchTheLowLinearSlots() public {
        vm.prank(admin);
        caps.setSettlementCaps(ASSET, 111, 222);
        caps.consumeSettlementLimit(ASSET, 111);

        for (uint256 i = 0; i < 8; i++) {
            assertEq(vm.load(address(caps), bytes32(i)), bytes32(0), "a namespaced write hit a linear slot");
        }
    }

    function _slot(address token, uint256 fieldOffset) internal pure returns (bytes32) {
        return keccak256(abi.encode(token, uint256(PRIMARY_STORAGE_LOCATION) + fieldOffset));
    }
}
