// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AsseteraECS} from "../src/AsseteraECS.sol";
import {ExchangeTypes} from "../src/types/ExchangeTypes.sol";
import {GateTypes} from "../src/types/GateTypes.sol";
import {GateStorage} from "../src/gates/GateStorage.sol";
import {IKycGate} from "../src/interfaces/IKycGate.sol";
import {GateOnlyVenue} from "./mocks/GateOnlyVenue.sol";

/// @title GateStorageNamespaceTest
/// @notice Pins WHERE the gate state lives (AO-514).
///
///         `GateStorage` addresses its four mappings through a hardcoded ERC-7201 constant. A
///         wrong constant does not fail to compile and does not fail any behavioural test — the
///         gate would simply read and write a different region, and would keep agreeing with
///         itself. The two ways that goes wrong are both silent: the region could overlap the
///         venue's linear slots (corrupting orders), or it could move between implementations
///         (losing every consumed nonce and the collector allowlist on an upgrade).
///
///         So this test re-derives the namespace from its preimage and then proves that real
///         writes land at exactly the derived slots.
contract GateStorageNamespaceTest is Test {
    /// The ERC-7201 namespace id. Changing this string moves ALL gate state.
    string internal constant NAMESPACE = "assetera.storage.Gate";

    /// keccak256(abi.encode(uint256(keccak256("assetera.storage.Gate")) - 1)) & ~bytes32(uint256(0xff))
    /// cast keccak $(cast abi-encode "f(uint256)" \
    ///   $(python3 -c 'print(0x3e5e60be991328a19aa5d741bed7e124719c11322f3a5978be85f3da1fc46a7e - 1)'))
    /// then clear the low byte.
    bytes32 internal constant GATE_STORAGE_LOCATION =
        0xa7ce1588183c3b5b9f93bf4096b3044102abf2a0ba114024279c565ad2f53300;

    // Field order inside `GateStorage.GateData`. These offsets are what a reorder would break.
    uint256 internal constant SLOT_USED_NONCE = 0;
    uint256 internal constant SLOT_USED_FEE_NONCE = 1;
    uint256 internal constant SLOT_COMPLIANCE_REQUIRED = 2;
    uint256 internal constant SLOT_ALLOWED_COLLECTORS = 3;

    AsseteraECS internal exchange;
    address internal admin = makeAddr("admin");
    address internal kycSigner = makeAddr("kycSigner");
    address internal feeSigner = makeAddr("feeSigner");

    function setUp() public {
        AsseteraECS impl = new AsseteraECS(address(0));
        bytes memory initData = abi.encodeCall(AsseteraECS.initialize, (admin, kycSigner, feeSigner));
        exchange = AsseteraECS(address(new ERC1967Proxy(address(impl), initData)));
    }

    /// The constant is the ERC-7201 formula applied to the namespace string, not a number
    /// somebody typed. The low byte must be zero so the region cannot collide with a mapping
    /// or dynamic-array slot derived from an adjacent namespace.
    function test_NamespaceConstant_IsTheErc7201DerivationOfTheNamespaceString() public pure {
        bytes32 derived = keccak256(abi.encode(uint256(keccak256(bytes(NAMESPACE))) - 1)) & ~bytes32(uint256(0xff));

        assertEq(derived, GATE_STORAGE_LOCATION);
        assertEq(uint256(GATE_STORAGE_LOCATION) & 0xff, 0);
    }

    /// The namespace must not sit on top of the venue's own linear slots. Those start at 0 and
    /// run through `__gap`; a namespace this far out cannot reach them.
    function test_Namespace_IsFarFromTheVenuesLinearSlots() public pure {
        assertGt(uint256(GATE_STORAGE_LOCATION), 1_000_000);
    }

    /// `setAllowedCollector` must write at `keccak256(collector . base+3)` and nowhere else.
    /// This is the assertion that fails if the namespace constant or the struct field order moves.
    function test_AllowedCollectors_WritesInsideTheNamespace() public {
        address collector = makeAddr("collector");
        bytes32 slot = keccak256(abi.encode(collector, uint256(GATE_STORAGE_LOCATION) + SLOT_ALLOWED_COLLECTORS));

        assertEq(vm.load(address(exchange), slot), bytes32(0));

        vm.prank(admin);
        exchange.setAllowedCollector(collector, true);

        assertEq(vm.load(address(exchange), slot), bytes32(uint256(1)));
        assertTrue(exchange.allowedCollectors(collector));
    }

    /// `initialize` sets the per-action KYC defaults, so the namespace is already populated
    /// before any user call. Reading the derived slot directly proves the getter is not just
    /// consistent with the setter but pointed at the intended region.
    function test_ComplianceRequired_DefaultsLiveInsideTheNamespace() public view {
        bytes32 slot = keccak256(
            abi.encode(uint8(ExchangeTypes.Action.Place), uint256(GATE_STORAGE_LOCATION) + SLOT_COMPLIANCE_REQUIRED)
        );

        assertEq(vm.load(address(exchange), slot), bytes32(uint256(1)));
        assertTrue(exchange.complianceRequired(uint8(ExchangeTypes.Action.Place)));
    }

    /// The two nonce namespaces must be distinct regions, or a spent KYC nonce would block the
    /// fee nonce of the same number (and vice versa). Adjacent struct fields, asserted adjacent.
    function test_TheTwoNonceNamespacesAreDistinct() public pure {
        uint256 base = uint256(GATE_STORAGE_LOCATION);
        bytes32 kycSlot = keccak256(abi.encode(uint256(1), base + SLOT_USED_NONCE));
        bytes32 feeSlot = keccak256(abi.encode(uint256(1), base + SLOT_USED_FEE_NONCE));

        assertTrue(kycSlot != feeSlot);
    }

    /// The venue's first linear slots are the order book's, untouched by any gate write. Slot 0
    /// is `_orders`, so it stays zero; the point is that nothing in the gate reaches down here.
    function test_GateWritesDoNotTouchTheVenuesLowSlots() public {
        vm.prank(admin);
        exchange.setAllowedCollector(makeAddr("collector"), true);

        for (uint256 i = 0; i < 8; i++) {
            assertEq(vm.load(address(exchange), bytes32(i)), bytes32(0), "gate write hit a venue slot");
        }
    }
}

/// @title GateReuseTest
/// @notice The point of AO-514, asserted rather than argued: `GateOnlyVenue` inherits `FeeGate`
///         and no order book. That it COMPILES is most of the proof; these tests add that it also
///         works — a second venue with its own action numbering verifies and burns both
///         attestations through the shared gate, and gets the restrictive `_paramsHashAllowed`
///         default because it does not override the hook.
contract GateReuseTest is Test {
    GateOnlyVenue internal venue;

    address internal admin = makeAddr("admin");
    address internal actor = makeAddr("actor");

    uint256 internal kycSignerPk = 0xACE1;
    uint256 internal feeSignerPk = 0xFEE1;

    address internal constant TOKEN_A = 0x1111111111111111111111111111111111111111;

    function setUp() public {
        venue = _deployVenue();
    }

    function _deployVenue() internal returns (GateOnlyVenue) {
        GateOnlyVenue impl = new GateOnlyVenue();
        bytes memory initData =
            abi.encodeCall(GateOnlyVenue.initialize, (admin, vm.addr(kycSignerPk), vm.addr(feeSignerPk)));
        return GateOnlyVenue(address(new ERC1967Proxy(address(impl), initData)));
    }

    /// The gate is genuinely shared: this venue's action 1 is its own, and the same
    /// `KYC_OPERATOR_ROLE`/`FEE_OPERATOR_ROLE` machinery gates it.
    function test_GateOnlyVenue_ConsumesBothAttestations() public {
        GateTypes.KycAttestation memory kycAtt = _kyc(bytes32(0));
        GateTypes.FeeAttestation memory feeAtt = _fee();

        vm.prank(actor);
        venue.settle(kycAtt, feeAtt);

        assertTrue(venue.usedNonce(actor, 1));
        assertTrue(venue.usedFeeNonce(actor, 2));
    }

    /// The `_paramsHashAllowed` default. `GateOnlyVenue` does not override the hook, so a
    /// non-zero `paramsHash` must be refused rather than quietly accepted unchecked.
    function test_GateOnlyVenue_RejectsAParamsHashItNeverBound() public {
        GateTypes.KycAttestation memory kycAtt = _kyc(keccak256("anything"));
        GateTypes.FeeAttestation memory feeAtt = _fee();

        vm.prank(actor);
        vm.expectRevert(GateStorage.ParamsHashMismatch.selector);
        venue.settle(kycAtt, feeAtt);
    }

    /// Cross-venue replay: an attestation signed for THIS venue must not carry over to another,
    /// because the EIP-712 domain includes the verifying contract. The gate does not need to
    /// know anything about venues for that to hold, which is why it can be shared at all.
    function test_AnAttestationIsBoundToTheVenueThatVerifiesIt() public {
        GateTypes.KycAttestation memory kycAtt = _kyc(bytes32(0));
        GateTypes.FeeAttestation memory feeAtt = _fee();
        GateOnlyVenue other = _deployVenue();

        vm.prank(actor);
        vm.expectRevert(IKycGate.KycBadSigner.selector);
        other.settle(kycAtt, feeAtt);
    }

    // ── helpers ───────────────────────────────────────────────────────────────────────────────

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("GateOnlyVenue")),
                keccak256(bytes("1")),
                block.chainid,
                address(venue)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _kyc(bytes32 paramsHash) internal view returns (GateTypes.KycAttestation memory att) {
        uint8 action = venue.ACTION_SETTLE();
        uint256 deadline = block.timestamp + 3 minutes;
        bytes32 structHash =
            keccak256(abi.encode(venue.KYC_TYPEHASH(), actor, action, uint256(0), uint256(1), deadline, paramsHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(kycSignerPk, _digest(structHash));
        att = GateTypes.KycAttestation({
            account: actor,
            action: action,
            orderId: 0,
            nonce: 1,
            deadline: deadline,
            paramsHash: paramsHash,
            signature: abi.encodePacked(r, s, v)
        });
    }

    function _fee() internal view returns (GateTypes.FeeAttestation memory att) {
        uint8 action = venue.ACTION_SETTLE();
        uint256 deadline = block.timestamp + 3 minutes;
        bytes32 structHash = keccak256(
            abi.encode(
                venue.FEE_TYPEHASH(),
                actor,
                action,
                uint256(2),
                deadline,
                bytes32(0),
                uint16(0),
                uint16(0),
                address(0),
                TOKEN_A
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(feeSignerPk, _digest(structHash));
        att = GateTypes.FeeAttestation({
            account: actor,
            action: action,
            nonce: 2,
            deadline: deadline,
            paramsHash: bytes32(0),
            makerFeeBps: 0,
            takerFeeBps: 0,
            feeCollector: address(0),
            feeToken: TOKEN_A,
            signature: abi.encodePacked(r, s, v)
        });
    }
}
