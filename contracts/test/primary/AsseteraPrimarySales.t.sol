// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AsseteraPrimarySales} from "../../src/primary/AsseteraPrimarySales.sol";
import {PrimaryTypes} from "../../src/primary/types/PrimaryTypes.sol";
import {GateTypes} from "../../src/types/GateTypes.sol";
import {GateStorage} from "../../src/gates/GateStorage.sol";
import {IKycGate} from "../../src/interfaces/IKycGate.sol";
import {IFeeGate} from "../../src/interfaces/IFeeGate.sol";
import {IIntentGate} from "../../src/primary/interfaces/IIntentGate.sol";
import {AsseteraECS} from "../../src/AsseteraECS.sol";
import {ContractWalletBuyer} from "./mocks/ContractWalletBuyer.sol";
import {PrimarySalesTestBase} from "./PrimarySalesTestBase.sol";

/// @title PrimarySalesInitTest
/// @notice What the initializer must have done before a single settlement is possible.
contract PrimarySalesInitTest is PrimarySalesTestBase {
    /// 🔴 **The one that matters most.** `GateStorage.complianceRequired` is a
    /// `mapping(uint8 => bool)` and is therefore fail-OPEN: an action nobody enables reads
    /// `false`, `KycGate._verifyKyc` returns on its first line, and the settlement runs with a
    /// KYC attestation that was never checked. So the safety of this contract comes from the
    /// initializer enumerating EVERY member of `PrimaryTypes.Action`, and from this test
    /// asserting it action by action rather than trusting a comment.
    ///
    /// Mirrors `test_Initialize_GatesEveryDeclaredAction` in `AsseteraECS.t.sol`. Appending a
    /// member to the enum without adding a line here AND a line in the initializer is the bug
    /// this test exists to catch.
    function test_Initialize_GatesEveryDeclaredAction() public view {
        assertTrue(sales.complianceRequired(uint8(PrimaryTypes.Action.SettleVenue)), "SettleVenue");
        assertTrue(sales.complianceRequired(uint8(PrimaryTypes.Action.SettleMint)), "SettleMint");
    }

    /// The enum's members and the initializer's lines must be the SAME set, not merely
    /// overlapping: an ordinal beyond the declared set must stay ungated, or the enumeration
    /// above proves nothing about completeness. Ordinal 0 is `Action.None`, an unset field
    /// rather than a real action; 3 is the first unallocated ordinal.
    function test_Initialize_GatesNothingBeyondTheDeclaredActions() public view {
        assertFalse(sales.complianceRequired(uint8(PrimaryTypes.Action.None)), "None");
        for (uint8 action = 3; action < 16; action++) {
            assertFalse(sales.complianceRequired(action), "an undeclared ordinal must not be gated");
        }
    }

    function test_Initialize_GrantsAllFourRoles() public view {
        assertTrue(sales.hasRole(sales.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(sales.hasRole(sales.KYC_OPERATOR_ROLE(), kycSigner));
        assertTrue(sales.hasRole(sales.FEE_OPERATOR_ROLE(), feeSigner));
        assertTrue(sales.hasRole(sales.SETTLEMENT_OPERATOR_ROLE(), settlementSigner));
    }

    /// The settlement operator is the only one of the three signers whose key can cause a
    /// transfer, so it must be a role of its own rather than the fee role wearing a second
    /// hat. Distinct role IDs, and no signer holding a role it was not granted.
    function test_SettlementOperatorRole_IsDistinctFromKycAndFee() public view {
        bytes32 settlementRole = sales.SETTLEMENT_OPERATOR_ROLE();
        bytes32 kycRole = sales.KYC_OPERATOR_ROLE();
        bytes32 feeRole = sales.FEE_OPERATOR_ROLE();

        assertTrue(settlementRole != kycRole, "settlement role collides with KYC");
        assertTrue(settlementRole != feeRole, "settlement role collides with fee");
        assertTrue(settlementRole != sales.DEFAULT_ADMIN_ROLE(), "settlement role collides with admin");
        assertEq(settlementRole, keccak256("SETTLEMENT_OPERATOR_ROLE"));
    }

    function test_SettlementSigner_HoldsNeitherOfTheOtherTwoRoles() public view {
        assertFalse(sales.hasRole(sales.KYC_OPERATOR_ROLE(), settlementSigner));
        assertFalse(sales.hasRole(sales.FEE_OPERATOR_ROLE(), settlementSigner));
        assertFalse(sales.hasRole(sales.SETTLEMENT_OPERATOR_ROLE(), kycSigner));
        assertFalse(sales.hasRole(sales.SETTLEMENT_OPERATOR_ROLE(), feeSigner));
    }

    function test_Initialize_RevertsOnAnyZeroSigner() public {
        AsseteraPrimarySales impl = new AsseteraPrimarySales(address(forwarder));

        vm.expectRevert(GateStorage.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(AsseteraPrimarySales.initialize, (address(0), kycSigner, feeSigner, settlementSigner))
        );

        vm.expectRevert(GateStorage.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(AsseteraPrimarySales.initialize, (admin, address(0), feeSigner, settlementSigner))
        );

        vm.expectRevert(GateStorage.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(AsseteraPrimarySales.initialize, (admin, kycSigner, address(0), settlementSigner))
        );

        vm.expectRevert(GateStorage.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(AsseteraPrimarySales.initialize, (admin, kycSigner, feeSigner, address(0)))
        );
    }

    function test_Initialize_CannotReinitialize() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        sales.initialize(stranger, stranger, stranger, stranger);
    }

    /// `KycGate._paramsHashAllowed` defaults to "no action binds parameters", the restrictive
    /// answer, which would reject every settlement here — every primary-sale action binds an
    /// intent and carries its struct hash. So the override is load-bearing, and it must cover
    /// every declared action, not just the one with an entry point today.
    function test_ParamsHashAllowed_IsTrueForEveryDeclaredAction() public view {
        assertTrue(harness.paramsHashAllowed(uint8(PrimaryTypes.Action.SettleVenue)), "SettleVenue");
        assertTrue(harness.paramsHashAllowed(uint8(PrimaryTypes.Action.SettleMint)), "SettleMint");
    }

    /// Ordinal zero is an unset field, never a real action, and must not be able to carry a
    /// bound `paramsHash`.
    function test_ParamsHashAllowed_IsFalseForTheZeroAndUndeclaredActions() public view {
        assertFalse(harness.paramsHashAllowed(uint8(PrimaryTypes.Action.None)), "None");
        assertFalse(harness.paramsHashAllowed(3), "first unallocated ordinal");
        assertFalse(harness.paramsHashAllowed(type(uint8).max), "255");
    }

    function test_TrustedForwarderIsTheConstructorArgument() public view {
        assertEq(sales.trustedForwarder(), address(forwarder));
    }

    function test_Version() public view {
        assertEq(sales.version(), "1.0.0");
    }
}

/// @title PrimarySalesDomainTest
/// @notice The separate EIP-712 domain, and the cross-contract replay it makes impossible.
contract PrimarySalesDomainTest is PrimarySalesTestBase {
    function test_Domain_IsAsseteraPrimarySalesVersionOne() public view {
        (, string memory name, string memory version,, address verifyingContract,,) = sales.eip712Domain();
        assertEq(name, PRIMARY_DOMAIN_NAME);
        assertEq(version, "1");
        assertEq(verifyingContract, address(sales));
    }

    /// Two things differ from the exchange's domain — the name AND the verifying contract —
    /// and either alone would be enough. The name is the deliberate one: it is what the signer
    /// service keys its per-chain allowlist on, so the two domains cannot be confused in
    /// configuration either.
    function test_Domain_DiffersFromTheExchanges() public {
        AsseteraECS exchange = _deployExchange();
        (, string memory exchangeName,,,,,) = exchange.eip712Domain();
        (, string memory primaryName,,,,,) = sales.eip712Domain();

        assertTrue(keccak256(bytes(primaryName)) != keccak256(bytes(exchangeName)), "domain names collide");
        assertEq(exchangeName, EXCHANGE_DOMAIN_NAME);
        assertTrue(
            _domainSeparator(PRIMARY_DOMAIN_NAME, address(sales))
                != _domainSeparator(EXCHANGE_DOMAIN_NAME, address(exchange)),
            "domain separators collide"
        );
    }

    /// 🔴 The acceptance criterion, as an executable statement rather than an argument.
    ///
    /// The attestation below is genuine: minted by the SAME compliance key, for the SAME
    /// account, under action ordinal 1 — which happens to be `Place` on the exchange and
    /// `SettleVenue` here — and bound to this settlement's `paramsHash`. The ONLY difference
    /// from an attestation this contract would accept is the domain it was signed under. It is
    /// refused, because the domain is part of the digest and the recovered address is
    /// therefore not the compliance signer at all.
    function test_ExchangeAttestation_CannotBeReplayedHere() public {
        AsseteraECS exchange = _deployExchange();
        PrimaryTypes.SettlementIntent memory intent = _intent();
        bytes32 paramsHash = _paramsHash(intent);

        GateTypes.KycAttestation memory stolen = _kyc(EXCHANGE_DOMAIN_NAME, address(exchange), 0, paramsHash);

        vm.prank(buyer);
        vm.expectRevert(IKycGate.KycBadSigner.selector);
        sales.settlePrimary(
            VENUE_CALLDATA,
            intent,
            _signIntent(address(sales), intent),
            _signBuyerConsent(address(sales), intent),
            stolen,
            _fee(address(sales), paramsHash)
        );
    }

    /// The other half of the same fact: swap ONLY the domain back and the identical attestation
    /// sails through the gate and into the settler's money path. Without this the test above
    /// would also pass if the attestation were malformed for some unrelated reason.
    function test_TheSameAttestationUnderThisDomainIsAccepted() public {
        PrimaryTypes.SettlementIntent memory intent = _intent();
        bytes32 paramsHash = _paramsHash(intent);

        GateTypes.KycAttestation memory att = _kyc(PRIMARY_DOMAIN_NAME, address(sales), 0, paramsHash);

        vm.prank(buyer);
        _expectReachesTheMoneyPath();
        sales.settlePrimary(
            VENUE_CALLDATA,
            intent,
            _signIntent(address(sales), intent),
            _signBuyerConsent(address(sales), intent),
            att,
            _fee(address(sales), paramsHash)
        );
    }

    function _deployExchange() internal returns (AsseteraECS) {
        AsseteraECS impl = new AsseteraECS(address(forwarder));
        bytes memory initData = abi.encodeCall(AsseteraECS.initialize, (admin, kycSigner, feeSigner));
        return AsseteraECS(address(new ERC1967Proxy(address(impl), initData)));
    }
}

/// @title PrimarySalesEntryPointTest
/// @notice Everything the frozen entry point checks, asserted against `sales` — the real
///         contract, in a settlement currency no admin has ever sized. `PerTxCapExceeded` with
///         a zero cap is the signal that every check upstream of the money passed; see
///         `_expectReachesTheMoneyPath`.
///
/// @dev    ⚠️ This marker has moved twice and the CLAIM has not moved at all. It was
///         `SettlerNotImplemented` while the S2 seam was empty, then
///         `SettlementLimitsNotImplemented` while the caps were a stub, and it is now the real
///         caps module refusing an unconfigured currency. Each time the assertion is the same
///         one: a well-formed settlement runs the whole verification path and is then stopped
///         by the FIRST thing on the money path that is not satisfied. Re-point the marker when
///         it moves again; do not weaken a module to keep it still.
contract PrimarySalesEntryPointTest is PrimarySalesTestBase {
    /// 🔴 The packet's central claim: the proxy deploys, initialises and runs a full
    /// settlement's worth of verification — three signatures, both attestation bindings, the
    /// calldata binding, three nonce burns — and only then hands over to the settler, which
    /// stops it at the value cap. The seam is a real boundary rather than a comment, and every
    /// unsatisfied precondition on it fails CLOSED.
    function test_SettlePrimary_ReachesTheMoneyPathWithEveryGatePassed() public {
        _expectReachesTheMoneyPath();
        _settle(sales);
    }

    /// `orderId` is passed to the gate as a literal zero, which is how a non-zero one is
    /// rejected: there is no order book on this path, and leaving the field free would be a
    /// second, unchecked degree of freedom inside a signature the compliance signer produces.
    function test_SettlePrimary_RejectsANonZeroOrderIdOnTheKycAttestation() public {
        PrimaryTypes.SettlementIntent memory intent = _intent();
        bytes32 paramsHash = _paramsHash(intent);

        vm.prank(buyer);
        vm.expectRevert(IKycGate.KycOrderMismatch.selector);
        sales.settlePrimary(
            VENUE_CALLDATA,
            intent,
            _signIntent(address(sales), intent),
            _signBuyerConsent(address(sales), intent),
            _kyc(PRIMARY_DOMAIN_NAME, address(sales), 7, paramsHash),
            _fee(address(sales), paramsHash)
        );
    }

    function test_SettlePrimary_RejectsAKycParamsHashThatIsNotTheIntentHash() public {
        PrimaryTypes.SettlementIntent memory intent = _intent();
        bytes32 paramsHash = _paramsHash(intent);

        vm.prank(buyer);
        vm.expectRevert(GateStorage.ParamsHashMismatch.selector);
        sales.settlePrimary(
            VENUE_CALLDATA,
            intent,
            _signIntent(address(sales), intent),
            _signBuyerConsent(address(sales), intent),
            _kyc(PRIMARY_DOMAIN_NAME, address(sales), 0, keccak256("some other settlement")),
            _fee(address(sales), paramsHash)
        );
    }

    function test_SettlePrimary_RejectsAFeeParamsHashThatIsNotTheIntentHash() public {
        PrimaryTypes.SettlementIntent memory intent = _intent();
        bytes32 paramsHash = _paramsHash(intent);

        vm.prank(buyer);
        vm.expectRevert(GateStorage.ParamsHashMismatch.selector);
        sales.settlePrimary(
            VENUE_CALLDATA,
            intent,
            _signIntent(address(sales), intent),
            _signBuyerConsent(address(sales), intent),
            _kyc(address(sales), paramsHash),
            _fee(address(sales), keccak256("some other settlement"))
        );
    }

    /// The `paramsHash` on both attestations is exactly the intent's EIP-712 struct hash, so
    /// an attestation minted for one settlement cannot be moved onto another with a different
    /// asset, venue or amount. Changing ONE field of the intent invalidates both bindings.
    function test_SettlePrimary_RejectsAnAttestationBoundToADifferentIntent() public {
        PrimaryTypes.SettlementIntent memory signedIntent = _intent();
        PrimaryTypes.SettlementIntent memory tampered = _intent();
        tampered.venue = address(0xDEAD);

        vm.prank(buyer);
        vm.expectRevert(IIntentGate.IntentBadSigner.selector);
        sales.settlePrimary(
            VENUE_CALLDATA,
            tampered,
            _signIntent(address(sales), signedIntent),
            _signBuyerConsent(address(sales), signedIntent),
            _kyc(address(sales), _paramsHash(signedIntent)),
            _fee(address(sales), _paramsHash(signedIntent))
        );
    }

    function test_SettlePrimary_RejectsACallerWhoIsNotTheBuyer() public {
        PrimaryTypes.SettlementIntent memory intent = _intent();
        bytes32 paramsHash = _paramsHash(intent);

        vm.prank(stranger);
        vm.expectRevert(IIntentGate.IntentBuyerMismatch.selector);
        sales.settlePrimary(
            VENUE_CALLDATA,
            intent,
            _signIntent(address(sales), intent),
            _signBuyerConsent(address(sales), intent),
            _kyc(address(sales), paramsHash),
            _fee(address(sales), paramsHash)
        );
    }

    function test_SettlePrimary_RejectsCalldataThatDoesNotHashToTheSignedValue() public {
        PrimaryTypes.SettlementIntent memory intent = _intent();
        bytes32 paramsHash = _paramsHash(intent);

        vm.prank(buyer);
        vm.expectRevert(IIntentGate.CalldataHashMismatch.selector);
        sales.settlePrimary(
            hex"a9059cbb0000000000000000000000000000000000000000000000000000000000000002",
            intent,
            _signIntent(address(sales), intent),
            _signBuyerConsent(address(sales), intent),
            _kyc(address(sales), paramsHash),
            _fee(address(sales), paramsHash)
        );
    }

    /// `selector` is checked against the calldata even though it is checked against no
    /// allowlist. It is what catches a malformed or mismatched call.
    function test_SettlePrimary_RejectsASelectorThatDoesNotMatchTheCalldata() public {
        PrimaryTypes.SettlementIntent memory intent = _intent();
        intent.selector = 0xdeadbeef;
        intent.calldataHash = keccak256(VENUE_CALLDATA);
        bytes32 paramsHash = _paramsHash(intent);

        vm.prank(buyer);
        vm.expectRevert(IIntentGate.SelectorMismatch.selector);
        sales.settlePrimary(
            VENUE_CALLDATA,
            intent,
            _signIntent(address(sales), intent),
            _signBuyerConsent(address(sales), intent),
            _kyc(address(sales), paramsHash),
            _fee(address(sales), paramsHash)
        );
    }

    /// The shared `_validateFees` only proves the fee token is one of the two legs, which is
    /// too weak here: a fee attested in the ASSET token would come out of what the buyer
    /// receives rather than out of the settlement leg.
    function test_SettlePrimary_RejectsAFeeDenominatedInTheAssetToken() public {
        PrimaryTypes.SettlementIntent memory intent = _intent();
        bytes32 paramsHash = _paramsHash(intent);

        vm.prank(buyer);
        vm.expectRevert(IIntentGate.SettlementTokenMismatch.selector);
        sales.settlePrimary(
            VENUE_CALLDATA,
            intent,
            _signIntent(address(sales), intent),
            _signBuyerConsent(address(sales), intent),
            _kyc(address(sales), paramsHash),
            _fee(address(sales), paramsHash, 0, 50, collector, ASSET)
        );
    }

    function test_SettlePrimary_RejectsACollectorThatDisagreesWithTheIntent() public {
        PrimaryTypes.SettlementIntent memory intent = _intent();
        bytes32 paramsHash = _paramsHash(intent);
        address other = makeAddr("otherCollector");
        vm.prank(admin);
        sales.setAllowedCollector(other, true);

        vm.prank(buyer);
        vm.expectRevert(IIntentGate.FeeCollectorMismatch.selector);
        sales.settlePrimary(
            VENUE_CALLDATA,
            intent,
            _signIntent(address(sales), intent),
            _signBuyerConsent(address(sales), intent),
            _kyc(address(sales), paramsHash),
            _fee(address(sales), paramsHash, 0, 50, other, CURRENCY)
        );
    }

    /// The collector allowlist is this proxy's own and starts empty; the exchange's entries do
    /// not carry over.
    function test_SettlePrimary_RejectsAnUnlistedCollector() public {
        PrimaryTypes.SettlementIntent memory intent = _intent();
        intent.feeCollector = stranger;
        bytes32 paramsHash = _paramsHash(intent);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IFeeGate.FeeCollectorNotAllowed.selector, stranger));
        sales.settlePrimary(
            VENUE_CALLDATA,
            intent,
            _signIntent(address(sales), intent),
            _signBuyerConsent(address(sales), intent),
            _kyc(address(sales), paramsHash),
            _fee(address(sales), paramsHash, 0, 50, stranger, CURRENCY)
        );
    }

    /// On a third-party venue we do not control the proceeds side, so an issuer-side fee
    /// cannot be charged. Attesting one must revert rather than silently do nothing.
    function test_SettlePrimary_RejectsANonZeroMakerFee() public {
        PrimaryTypes.SettlementIntent memory intent = _intent();
        bytes32 paramsHash = _paramsHash(intent);

        vm.prank(buyer);
        vm.expectRevert(IIntentGate.MakerFeeNotSupported.selector);
        sales.settlePrimary(
            VENUE_CALLDATA,
            intent,
            _signIntent(address(sales), intent),
            _signBuyerConsent(address(sales), intent),
            _kyc(address(sales), paramsHash),
            _fee(address(sales), paramsHash, 25, 50, collector, CURRENCY)
        );
    }

    function test_SettlePrimary_RejectsAnIntentSignedByTheFeeOperator() public {
        PrimaryTypes.SettlementIntent memory intent = _intent();
        bytes32 paramsHash = _paramsHash(intent);

        vm.prank(buyer);
        vm.expectRevert(IIntentGate.IntentBadSigner.selector);
        sales.settlePrimary(
            VENUE_CALLDATA,
            intent,
            _signIntentWith(feeSignerPk, address(sales), intent),
            _signBuyerConsent(address(sales), intent),
            _kyc(address(sales), paramsHash),
            _fee(address(sales), paramsHash)
        );
    }

    function test_SettlePrimary_RejectsAnIntentSignedByTheKycOperator() public {
        PrimaryTypes.SettlementIntent memory intent = _intent();
        bytes32 paramsHash = _paramsHash(intent);

        vm.prank(buyer);
        vm.expectRevert(IIntentGate.IntentBadSigner.selector);
        sales.settlePrimary(
            VENUE_CALLDATA,
            intent,
            _signIntentWith(kycSignerPk, address(sales), intent),
            _signBuyerConsent(address(sales), intent),
            _kyc(address(sales), paramsHash),
            _fee(address(sales), paramsHash)
        );
    }

    function test_SettlePrimary_RejectsAnExpiredIntent() public {
        PrimaryTypes.SettlementIntent memory intent = _intent();
        bytes32 paramsHash = _paramsHash(intent);
        bytes memory sig = _signIntent(address(sales), intent);
        bytes memory buyerSig = _signBuyerConsent(address(sales), intent);
        GateTypes.KycAttestation memory kyc = _kyc(address(sales), paramsHash);
        GateTypes.FeeAttestation memory fee = _fee(address(sales), paramsHash);

        vm.warp(intent.deadline + 1);
        vm.prank(buyer);
        vm.expectRevert(IIntentGate.IntentExpired.selector);
        sales.settlePrimary(VENUE_CALLDATA, intent, sig, buyerSig, kyc, fee);
    }

    /// A hard cap on freshness, mirroring `MAX_KYC_TTL`, so a leaked intent has a bounded life
    /// even if the signer service was configured to emit a long one.
    function test_SettlePrimary_RejectsAnOverLongIntentTtl() public {
        PrimaryTypes.SettlementIntent memory intent = _intent();
        intent.deadline = block.timestamp + sales.MAX_INTENT_TTL() + 1;
        bytes32 paramsHash = _paramsHash(intent);

        vm.prank(buyer);
        vm.expectRevert(IIntentGate.IntentTtlTooLong.selector);
        sales.settlePrimary(
            VENUE_CALLDATA,
            intent,
            _signIntent(address(sales), intent),
            _signBuyerConsent(address(sales), intent),
            _kyc(address(sales), paramsHash),
            _fee(address(sales), paramsHash)
        );
    }

    /// `maxSettlementIn` is the only number the buyer reads. It must cover the debit the same
    /// signature authorises, or it is not a cap on anything.
    function test_SettlePrimary_RejectsMaxSettlementBelowQuotePlusFee() public {
        PrimaryTypes.SettlementIntent memory intent = _intent();
        intent.maxSettlementIn = QUOTE_IN + BUYER_FEE - 1;
        bytes32 paramsHash = _paramsHash(intent);

        vm.prank(buyer);
        vm.expectRevert(IIntentGate.MaxSettlementTooLow.selector);
        sales.settlePrimary(
            VENUE_CALLDATA,
            intent,
            _signIntent(address(sales), intent),
            _signBuyerConsent(address(sales), intent),
            _kyc(address(sales), paramsHash),
            _fee(address(sales), paramsHash)
        );
    }

    /// A zero delivery floor makes the post-call assertion vacuous: the transaction becomes a
    /// pure debit with nothing owed to the buyer. It does not stop a compromised signer (who
    /// would sign 1 wei instead) but it removes the case where the assertion is not an
    /// assertion at all.
    function test_SettlePrimary_RejectsAZeroMinAssetOut() public {
        PrimaryTypes.SettlementIntent memory intent = _intent();
        intent.minAssetOut = 0;
        bytes32 paramsHash = _paramsHash(intent);

        vm.prank(buyer);
        vm.expectRevert(IIntentGate.ZeroAmount.selector);
        sales.settlePrimary(
            VENUE_CALLDATA,
            intent,
            _signIntent(address(sales), intent),
            _signBuyerConsent(address(sales), intent),
            _kyc(address(sales), paramsHash),
            _fee(address(sales), paramsHash)
        );
    }

    function test_SettlePrimary_RejectsAnAssetLegEqualToTheSettlementLeg() public {
        PrimaryTypes.SettlementIntent memory intent = _intent();
        intent.settlementToken = ASSET;
        bytes32 paramsHash = _paramsHash(intent);

        vm.prank(buyer);
        vm.expectRevert(IIntentGate.SameToken.selector);
        sales.settlePrimary(
            VENUE_CALLDATA,
            intent,
            _signIntent(address(sales), intent),
            _signBuyerConsent(address(sales), intent),
            _kyc(address(sales), paramsHash),
            _fee(address(sales), paramsHash, 0, 50, collector, ASSET)
        );
    }

    function test_SettlePrimary_RejectsAZeroVenue() public {
        PrimaryTypes.SettlementIntent memory intent = _intent();
        intent.venue = address(0);
        bytes32 paramsHash = _paramsHash(intent);

        vm.prank(buyer);
        vm.expectRevert(GateStorage.ZeroAddress.selector);
        sales.settlePrimary(
            VENUE_CALLDATA,
            intent,
            _signIntent(address(sales), intent),
            _signBuyerConsent(address(sales), intent),
            _kyc(address(sales), paramsHash),
            _fee(address(sales), paramsHash)
        );
    }

    /// A pause lever of this router's own, independent of the exchange's — one of the reasons
    /// primary settlement is a separate proxy rather than a module inside `AsseteraECS`.
    function test_SettlePrimary_RejectsWhenPaused() public {
        vm.prank(admin);
        sales.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        _settle(sales);
    }
}

/// @title PrimarySalesBuyerConsentTest
/// @notice 🔴 The buyer's own signature over the settlement intent — the one signature on the
///         path that is not ours.
///
///         What it defends against: a compromised `SETTLEMENT_OPERATOR_ROLE` key. That signer
///         chooses every field of the intent, `minAssetOut` included, so without the buyer's
///         countersignature the executor's central guarantee ("the buyer received at least
///         `minAssetOut`") is a guarantee about a number the attacker picked. Setting it to one
///         wei satisfies every check in the contract and drains the buyer's allowance.
///
///         Why the buyer's wallet cannot supply this protection by itself: ERC-2771. The buyer
///         signs a `ForwardRequest` whose `data` is opaque bytes, and no wallet renders opaque
///         bytes as balance changes. An EIP-712 payload with named fields is the only thing on
///         this path a wallet can put in front of a human.
///
/// @dev    ⚠️ Both signatures are over ONE digest and are NOT interchangeable: the operator's
///         is accepted only if it recovers to a `SETTLEMENT_OPERATOR_ROLE` holder, the buyer's
///         only if it validates for `intent.buyer`. Both directions of the swap are pinned
///         below, because "one digest" is exactly the shape that invites the assumption that
///         either signature will do.
contract PrimarySalesBuyerConsentTest is PrimarySalesTestBase {
    /// The buyer as a contract wallet, and the EOA that wallet answers for. A separate key from
    /// `buyerPk` on purpose: an ERC-1271 test that reused it could pass on the EOA branch of
    /// `SignatureChecker` without ever calling `isValidSignature`.
    uint256 internal walletOwnerPk = 0x5AFE;

    /// Submit a settlement to `harness` — whose settler seam is stubbed, so a valid one actually
    /// completes — with `buyerSignature` supplied verbatim. Everything else is well-formed, so a
    /// revert here is about consent and nothing else.
    function _settleWithBuyerSignature(bytes memory buyerSignature) internal {
        PrimaryTypes.SettlementIntent memory intent = _intent();
        bytes32 paramsHash = _paramsHash(intent);
        vm.prank(intent.buyer);
        harness.settlePrimary(
            VENUE_CALLDATA,
            intent,
            _signIntent(address(harness), intent),
            buyerSignature,
            _kyc(address(harness), paramsHash),
            _fee(address(harness), paramsHash)
        );
    }

    /// 🔴 The happy path: the buyer signed these exact terms and the settlement completes.
    function test_BuyerConsent_AcceptsTheBuyersSignatureOverTheSameIntent() public {
        _settleWithBuyerSignature(_signBuyerConsent(address(harness), _intent()));

        assertTrue(harness.usedIntentNonce(buyer, INTENT_NONCE), "the settlement did not complete");
    }

    /// An omitted signature is the shape a caller written against the old five-argument selector
    /// produces, so it must fail loudly rather than be treated as "no objection".
    function test_BuyerConsent_RejectsAnEmptySignature() public {
        vm.expectRevert(IIntentGate.BuyerConsentBadSignature.selector);
        _settleWithBuyerSignature("");
    }

    /// Malformed bytes of the right length are refused the same way — through the named error,
    /// not through a bare panic out of the recovery library.
    function test_BuyerConsent_RejectsAMalformedSignature() public {
        vm.expectRevert(IIntentGate.BuyerConsentBadSignature.selector);
        _settleWithBuyerSignature(new bytes(65));
    }

    /// Somebody else's valid signature over the right intent is still not the buyer's.
    function test_BuyerConsent_RejectsASignatureFromTheWrongKey() public {
        uint256 strangerPk = 0xDECAF;
        vm.expectRevert(IIntentGate.BuyerConsentBadSignature.selector);
        _settleWithBuyerSignature(_signIntentWith(strangerPk, address(harness), _intent()));
    }

    /// 🔴 **The attack this whole mechanism exists to stop.** The buyer signed an intent with a
    /// real delivery floor; the compromised settlement operator submits one with the floor at a
    /// single wei, correctly signed by itself. Every other check in the contract passes — the
    /// buyer is the actor, both attestations are bound to the submitted intent's hash, the
    /// nonces are fresh — and the settlement is refused only because the buyer's signature is
    /// over different terms.
    function test_BuyerConsent_RejectsASignatureOverADifferentIntent() public {
        PrimaryTypes.SettlementIntent memory consented = _intent();

        PrimaryTypes.SettlementIntent memory submitted = _intent();
        submitted.minAssetOut = 1;
        assertTrue(consented.minAssetOut != submitted.minAssetOut, "fixture: the two intents must differ");
        bytes32 paramsHash = _paramsHash(submitted);

        vm.prank(buyer);
        vm.expectRevert(IIntentGate.BuyerConsentBadSignature.selector);
        harness.settlePrimary(
            VENUE_CALLDATA,
            submitted,
            _signIntent(address(harness), submitted),
            _signBuyerConsent(address(harness), consented),
            _kyc(address(harness), paramsHash),
            _fee(address(harness), paramsHash)
        );
    }

    /// One digest, two slots, and the slots are not interchangeable. The operator's signature is
    /// perfectly valid — it is simply not the buyer's.
    function test_BuyerConsent_RejectsTheOperatorsSignatureInTheBuyerSlot() public {
        vm.expectRevert(IIntentGate.BuyerConsentBadSignature.selector);
        _settleWithBuyerSignature(_signIntent(address(harness), _intent()));
    }

    /// And the other direction: the buyer's signature does not authorise a settlement, because
    /// the buyer holds no role. `IntentBadSigner` rather than `BuyerConsentBadSignature`, which
    /// is what tells an operator which of the two went wrong.
    function test_BuyerConsent_RejectsTheBuyersSignatureInTheOperatorSlot() public {
        PrimaryTypes.SettlementIntent memory intent = _intent();
        bytes32 paramsHash = _paramsHash(intent);

        vm.prank(buyer);
        vm.expectRevert(IIntentGate.IntentBadSigner.selector);
        harness.settlePrimary(
            VENUE_CALLDATA,
            intent,
            _signBuyerConsent(address(harness), intent),
            _signBuyerConsent(address(harness), intent),
            _kyc(address(harness), paramsHash),
            _fee(address(harness), paramsHash)
        );
    }

    /// 🔴 An ERC-1271 contract wallet is a first-class buyer. This is why the check is
    /// `SignatureChecker.isValidSignatureNow` and not `ECDSA.recover`: a Safe or an embedded
    /// smart account has no private key of its own, so an EOA-only check would refuse exactly
    /// the clients a regulated brokerage most wants to serve.
    ///
    /// The fixture's `buyer` is repointed at the wallet so that every helper — the intent, both
    /// attestations, the prank — is built for it, which is what makes the wallet the ACTOR as
    /// well as the signer.
    function test_BuyerConsent_AcceptsAnErc1271ContractWallet() public {
        ContractWalletBuyer wallet = new ContractWalletBuyer(vm.addr(walletOwnerPk));
        buyer = address(wallet);

        PrimaryTypes.SettlementIntent memory intent = _intent();
        _settleWithBuyerSignature(_signIntentWith(walletOwnerPk, address(harness), intent));

        assertTrue(harness.usedIntentNonce(address(wallet), INTENT_NONCE), "the wallet's settlement did not complete");
    }

    /// The mutation that proves the test above exercised the ERC-1271 branch rather than passing
    /// for some unrelated reason: the same wallet, the same owner signature, refused the moment
    /// the wallet stops returning the magic value. Contract signatures are revocable in a way
    /// ECDSA ones are not, which is why validity is asserted at settlement time and nowhere
    /// else.
    function test_BuyerConsent_RejectsARevokedErc1271Signature() public {
        ContractWalletBuyer wallet = new ContractWalletBuyer(vm.addr(walletOwnerPk));
        buyer = address(wallet);
        wallet.setRevoked(true);

        vm.expectRevert(IIntentGate.BuyerConsentBadSignature.selector);
        _settleWithBuyerSignature(_signIntentWith(walletOwnerPk, address(harness), _intent()));
    }

    /// A contract that is not a wallet at all — no `isValidSignature` to call — is refused
    /// rather than reverting undecodably out of the staticcall. `intent.buyer` is chosen by the
    /// settlement operator, so "the buyer has code but no ERC-1271 support" is a case that
    /// reaches this line in production.
    ///
    /// ⚠️ The stand-in is the OTHER primary-sale proxy rather than the forwarder, which would
    /// have been the obvious pick and is the wrong one: pranking as the trusted forwarder makes
    /// ERC-2771 read the actor out of the calldata suffix, so the test would be about
    /// meta-transaction decoding instead of about consent.
    function test_BuyerConsent_RejectsABuyerContractThatIsNotAWallet() public {
        buyer = address(sales);

        vm.expectRevert(IIntentGate.BuyerConsentBadSignature.selector);
        _settleWithBuyerSignature(_signBuyerConsent(address(harness), _intent()));
    }
}

/// @title PrimarySalesSettledTest
/// @notice What happens AFTER the seam, observed through a harness whose S2 family is stubbed
///         from outside `src/`. Stubbing it there rather than in `src/primary/settle/**` keeps
///         the claim honest: no line of a settlement family exists yet.
contract PrimarySalesSettledTest is PrimarySalesTestBase {
    event PrimarySettled(
        address indexed buyer,
        address indexed assetToken,
        address indexed venue,
        uint256 assetDelivered,
        address settlementToken,
        uint256 venueIn,
        uint256 refund,
        uint256 fee,
        address feeCollector,
        bytes32 supplierReference,
        uint256 nonce
    );

    /// Three independent single-use payloads from three independent signers, in three
    /// namespaces that cannot invalidate one another.
    function test_SettlePrimary_BurnsAllThreeNoncesInSeparateNamespaces() public {
        _settle(AsseteraPrimarySales(address(harness)));

        assertTrue(harness.usedIntentNonce(buyer, INTENT_NONCE), "intent nonce");
        assertTrue(harness.usedNonce(buyer, KYC_NONCE), "KYC nonce");
        assertTrue(harness.usedFeeNonce(buyer, FEE_NONCE), "fee nonce");

        // The three namespaces are genuinely separate: the intent's nonce is not spent in the
        // KYC or fee counters, and vice versa.
        assertFalse(harness.usedNonce(buyer, INTENT_NONCE), "intent nonce leaked into KYC");
        assertFalse(harness.usedIntentNonce(buyer, KYC_NONCE), "KYC nonce leaked into intent");
        assertFalse(harness.usedIntentNonce(buyer, FEE_NONCE), "fee nonce leaked into intent");
    }

    function test_SettlePrimary_RejectsAReplayedIntentNonce() public {
        _settle(AsseteraPrimarySales(address(harness)));

        // A fresh KYC/fee pair would be needed for a genuine replay; the intent nonce is
        // checked first, so this is what a replayed intent actually hits.
        vm.expectRevert(IIntentGate.IntentNonceUsed.selector);
        _settle(AsseteraPrimarySales(address(harness)));
    }

    /// 🔴 The event the indexer decodes, pinned field by field. Every amount comes from the
    /// settler's measured result and every identifier from the signed intent, which is what
    /// lets `AsseteraEvmIndexerService` build an activity-ledger leg with no supplier-specific
    /// decoder.
    function test_SettlePrimary_EmitsPrimarySettledFromTheMeasuredResult() public {
        vm.expectEmit(true, true, true, true, address(harness));
        emit PrimarySettled(
            buyer,
            ASSET,
            VENUE,
            harness.STUB_ASSET_DELIVERED(),
            CURRENCY,
            harness.STUB_VENUE_IN(),
            harness.STUB_REFUND(),
            harness.STUB_FEE(),
            collector,
            SUPPLIER_REF,
            INTENT_NONCE
        );

        _settle(AsseteraPrimarySales(address(harness)));
    }

    /// ERC-2771, with the same trusted forwarder as the exchange: the relayer pays the gas and
    /// the buyer is still resolved from the meta-transaction sender, not from `msg.sender`.
    /// Without this, primary sales would be the one flow in the product that requires the
    /// buyer to hold native gas.
    ///
    /// ⚠️ The buyer signs TWICE on this path and the two are not the same object: a
    /// `ForwardRequest` whose `data` is opaque bytes, and the `SettlementIntent` inside those
    /// bytes. That is exactly why the intent signature exists — the forwarder signature is what
    /// no wallet can render as balance changes, and the intent signature is what it can.
    function test_SettlePrimary_ResolvesTheBuyerThroughTheTrustedForwarder() public {
        PrimaryTypes.SettlementIntent memory intent = _intent();
        bytes32 paramsHash = _paramsHash(intent);
        bytes memory data = abi.encodeCall(
            AsseteraPrimarySales.settlePrimary,
            (
                VENUE_CALLDATA,
                intent,
                _signIntent(address(harness), intent),
                _signBuyerConsent(address(harness), intent),
                _kyc(address(harness), paramsHash),
                _fee(address(harness), paramsHash)
            )
        );

        vm.deal(buyer, 0);
        _relay(buyerPk, buyer, address(harness), data);

        assertTrue(harness.usedIntentNonce(buyer, INTENT_NONCE), "settled for the buyer, not the relayer");
        assertFalse(harness.usedIntentNonce(relayer, INTENT_NONCE));
        assertEq(buyer.balance, 0, "the buyer paid no gas");
    }
}

/// @title PrimarySalesAdminTest
/// @notice The admin surface, and that it is admin-only.
contract PrimarySalesAdminTest is PrimarySalesTestBase {
    event CollectorAllowed(address indexed collector, bool allowed);
    event ComplianceRequiredSet(PrimaryTypes.Action indexed action, bool required);

    function test_SetAllowedCollector_OnlyAdmin() public {
        // Read the role BEFORE the prank: it is a call too, and would otherwise consume it.
        bytes32 adminRole = sales.DEFAULT_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole)
        );
        sales.setAllowedCollector(stranger, true);
    }

    function test_SetAllowedCollector_TogglesAndEmits() public {
        vm.expectEmit(true, false, false, true, address(sales));
        emit CollectorAllowed(stranger, true);
        vm.prank(admin);
        sales.setAllowedCollector(stranger, true);
        assertTrue(sales.allowedCollectors(stranger));

        vm.prank(admin);
        sales.setAllowedCollector(stranger, false);
        assertFalse(sales.allowedCollectors(stranger));
    }

    function test_SetComplianceRequired_OnlyAdmin() public {
        // Read the role BEFORE the prank: it is a call too, and would otherwise consume it.
        bytes32 adminRole = sales.DEFAULT_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole)
        );
        sales.setComplianceRequired(PrimaryTypes.Action.SettleVenue, false);
    }

    function test_SetComplianceRequired_TogglesAndEmits() public {
        vm.expectEmit(true, false, false, true, address(sales));
        emit ComplianceRequiredSet(PrimaryTypes.Action.SettleVenue, false);
        vm.prank(admin);
        sales.setComplianceRequired(PrimaryTypes.Action.SettleVenue, false);
        assertFalse(sales.complianceRequired(uint8(PrimaryTypes.Action.SettleVenue)));
    }

    /// Disabling the KYC gate must not disable the intent gate: a settlement still needs a
    /// valid intent from the settlement operator, so an admin toggle cannot turn this contract
    /// into an open router.
    function test_DisablingTheKycGateDoesNotDisableTheIntentGate() public {
        vm.prank(admin);
        sales.setComplianceRequired(PrimaryTypes.Action.SettleVenue, false);

        PrimaryTypes.SettlementIntent memory intent = _intent();
        bytes32 paramsHash = _paramsHash(intent);

        vm.prank(buyer);
        vm.expectRevert(IIntentGate.IntentBadSigner.selector);
        sales.settlePrimary(
            VENUE_CALLDATA,
            intent,
            _signIntentWith(feeSignerPk, address(sales), intent),
            _signBuyerConsent(address(sales), intent),
            _kyc(address(sales), paramsHash),
            _fee(address(sales), paramsHash)
        );
    }

    function test_Pause_OnlyAdmin() public {
        // Read the role BEFORE the prank: it is a call too, and would otherwise consume it.
        bytes32 adminRole = sales.DEFAULT_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole)
        );
        sales.pause();
    }

    function test_Unpause_RestoresSettlement() public {
        vm.startPrank(admin);
        sales.pause();
        sales.unpause();
        vm.stopPrank();

        // The marker is what makes this an assertion rather than a shrug: after the unpause the
        // settlement runs the whole verification path again and stops exactly where an
        // unpaused one always stops, instead of on `EnforcedPause`.
        _expectReachesTheMoneyPath();
        _settle(sales);
    }

    function test_Upgrade_OnlyAdmin() public {
        AsseteraPrimarySales newImpl = new AsseteraPrimarySales(address(forwarder));

        // Read the role BEFORE the prank: it is a call too, and would otherwise consume it.
        bytes32 adminRole = sales.DEFAULT_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole)
        );
        sales.upgradeToAndCall(address(newImpl), "");

        vm.prank(admin);
        sales.upgradeToAndCall(address(newImpl), "");
        assertEq(sales.version(), "1.0.0");
    }
}
