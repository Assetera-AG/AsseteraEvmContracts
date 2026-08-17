// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AsseteraPrimarySales} from "../../src/primary/AsseteraPrimarySales.sol";
import {PrimarySalesTestBase} from "./PrimarySalesTestBase.sol";

/// @title PrimaryStorageNamespaceTest
/// @notice Pins WHERE the primary-sale state lives, and that it cannot reach the gate's.
///
///         `PrimaryStorage` addresses its state through a hardcoded ERC-7201 constant. A wrong
///         constant does not fail to compile and does not fail any behavioural test — the
///         contract would simply read and write a different region and keep agreeing with
///         itself. The two ways that goes wrong are both silent: the region could overlap the
///         GATE namespace, in which case burning an intent nonce would corrupt a KYC nonce or
///         the collector allowlist; or it could move between implementations, losing every
///         consumed nonce on an upgrade.
///
///         So this test re-derives BOTH namespaces from their preimages, proves they are
///         disjoint, and then proves a real write lands at exactly the derived slot.
contract PrimaryStorageNamespaceTest is PrimarySalesTestBase {
    string internal constant PRIMARY_NAMESPACE = "assetera.storage.PrimarySales";
    string internal constant GATE_NAMESPACE = "assetera.storage.Gate";

    /// keccak256(abi.encode(uint256(keccak256("assetera.storage.PrimarySales")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant PRIMARY_STORAGE_LOCATION =
        0xc3c7d533132905df5cacdace21b89e3afb4b7188f583ae32f30e0a7379982700;

    /// The gate's namespace, as declared by `GateStorage`. Repeated here as a literal on
    /// purpose: this test must fail if EITHER constant moves, and reading it from the source
    /// would make half the assertion tautological.
    bytes32 internal constant GATE_STORAGE_LOCATION =
        0xa7ce1588183c3b5b9f93bf4096b3044102abf2a0ba114024279c565ad2f53300;

    // Field order inside `PrimaryStorage.PrimaryData`. A reorder would break these offsets.
    uint256 internal constant SLOT_USED_INTENT_NONCE = 0;

    // Field order inside `GateStorage.GateData`.
    uint256 internal constant GATE_SLOT_USED_NONCE = 0;
    uint256 internal constant GATE_SLOT_USED_FEE_NONCE = 1;
    uint256 internal constant GATE_SLOT_COMPLIANCE_REQUIRED = 2;
    uint256 internal constant GATE_SLOT_ALLOWED_COLLECTORS = 3;

    /// Both constants are the ERC-7201 formula applied to their namespace strings, not numbers
    /// somebody typed. The low byte must be zero so neither region can collide with a mapping
    /// or dynamic-array slot derived from an adjacent namespace.
    function test_NamespaceConstants_AreTheErc7201DerivationsOfTheirStrings() public pure {
        assertEq(_derive(PRIMARY_NAMESPACE), PRIMARY_STORAGE_LOCATION, "primary");
        assertEq(_derive(GATE_NAMESPACE), GATE_STORAGE_LOCATION, "gate");
        assertEq(uint256(PRIMARY_STORAGE_LOCATION) & 0xff, 0);
        assertEq(uint256(GATE_STORAGE_LOCATION) & 0xff, 0);
    }

    /// 🔴 The acceptance criterion. The two namespaces are not merely unequal, they are far
    /// enough apart that no struct-field offset from one can land inside the other. A struct
    /// would have to grow by more than 2^128 members to close the gap.
    function test_PrimaryNamespace_DoesNotCollideWithTheGateNamespace() public pure {
        uint256 primary = uint256(PRIMARY_STORAGE_LOCATION);
        uint256 gate = uint256(GATE_STORAGE_LOCATION);
        assertTrue(primary != gate, "namespaces are identical");

        uint256 gap = primary > gate ? primary - gate : gate - primary;
        assertGt(gap, 2 ** 128, "namespaces are close enough for a field offset to bridge them");
    }

    /// The mapping slots actually derived from the two bases, for the same key, must differ —
    /// which is what stops an intent-nonce burn from marking a KYC nonce spent.
    function test_TheDerivedMappingSlotsDoNotOverlap() public pure {
        address key = address(0xBEEF);
        bytes32 intentSlot = keccak256(abi.encode(key, uint256(PRIMARY_STORAGE_LOCATION) + SLOT_USED_INTENT_NONCE));

        assertTrue(
            intentSlot != keccak256(abi.encode(key, uint256(GATE_STORAGE_LOCATION) + GATE_SLOT_USED_NONCE)), "kyc"
        );
        assertTrue(
            intentSlot != keccak256(abi.encode(key, uint256(GATE_STORAGE_LOCATION) + GATE_SLOT_USED_FEE_NONCE)), "fee"
        );
        assertTrue(
            intentSlot != keccak256(abi.encode(key, uint256(GATE_STORAGE_LOCATION) + GATE_SLOT_ALLOWED_COLLECTORS)),
            "collectors"
        );
        assertTrue(
            intentSlot
                != keccak256(abi.encode(uint8(1), uint256(GATE_STORAGE_LOCATION) + GATE_SLOT_COMPLIANCE_REQUIRED)),
            "compliance"
        );
    }

    /// Consuming an intent must write at `keccak256(buyer . keccak256(nonce . base+0))` and
    /// nowhere else. This is the assertion that fails if the namespace constant or the struct
    /// field order moves.
    function test_UsedIntentNonce_WritesInsideTheNamespace() public {
        bytes32 outer = keccak256(abi.encode(buyer, uint256(PRIMARY_STORAGE_LOCATION) + SLOT_USED_INTENT_NONCE));
        bytes32 slot = keccak256(abi.encode(INTENT_NONCE, outer));

        assertEq(vm.load(address(harness), slot), bytes32(0));

        _settle(AsseteraPrimarySales(address(harness)));

        assertEq(vm.load(address(harness), slot), bytes32(uint256(1)));
        assertTrue(harness.usedIntentNonce(buyer, INTENT_NONCE));
    }

    /// `AsseteraPrimarySales` declares no linear storage at all — every region it uses is
    /// namespaced — so a settlement must leave the low slots untouched.
    function test_SettlementDoesNotTouchTheLowLinearSlots() public {
        _settle(AsseteraPrimarySales(address(harness)));

        for (uint256 i = 0; i < 8; i++) {
            assertEq(vm.load(address(harness), bytes32(i)), bytes32(0), "a namespaced write hit a linear slot");
        }
    }

    function _derive(string memory namespace) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(namespace))) - 1)) & ~bytes32(uint256(0xff));
    }
}
