// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AsseteraECS} from "../src/AsseteraECS.sol";
import {ExchangeTypes} from "../src/types/ExchangeTypes.sol";

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
