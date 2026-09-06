// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PrimaryTypes} from "../../src/primary/types/PrimaryTypes.sol";
import {PrimarySalesTestBase} from "./PrimarySalesTestBase.sol";

/// @title PrimaryIntentVectorsTest
/// @notice Pins the EIP-712 identity of `SettlementIntent` as hardcoded literals, in the same
///         spirit as `test/ParamsHashVectors.t.sol` does for the two attestations.
///
///         Three repositories code against this shape without reading Solidity: the signer
///         service builds the digest, the marketplace API assembles the call, and the indexer
///         decodes the resulting event. A field added, removed, reordered or retyped changes
///         the typehash and therefore every digest and every `paramsHash` binding, and it
///         would otherwise change nothing that fails to compile.
contract PrimaryIntentVectorsTest is PrimarySalesTestBase {
    /// The literal an off-chain signer can hardcode instead of hashing the type string.
    bytes32 internal constant EXPECTED_INTENT_TYPEHASH =
        0xa24f008693b1ca921f2aca00e79f4bc40748d499f86d54d0d8377dfdc884bf68;

    function test_IntentTypehash_IsPinned() public view {
        assertEq(INTENT_TYPEHASH, EXPECTED_INTENT_TYPEHASH, "typehash moved: the struct changed");
        assertEq(sales.INTENT_TYPEHASH(), EXPECTED_INTENT_TYPEHASH, "the deployed contract disagrees");
        assertEq(sales.INTENT_TYPEHASH(), keccak256(bytes(INTENT_TYPE_STRING)), "typehash is not its type string");
    }

    /// 🔴 `paramsHash` is computed on-chain as `keccak256(abi.encode(INTENT_TYPEHASH, intent))`,
    /// which is a shortcut. It is only equal to the canonical EIP-712 `hashStruct` because
    /// every member of `SettlementIntent` is a STATIC type — `abi.encode` of an all-static
    /// struct is exactly its fifteen head words, with `bytes4` right-padded and `uint8`
    /// left-padded in both encodings.
    ///
    /// Adding a dynamic member (`bytes`, `string`, an array) would break that silently: the
    /// ABI encoding would gain an offset word while EIP-712 would substitute a hash, and the
    /// contract's `paramsHash` would stop matching the digest the signer signed. This test is
    /// what notices, because it builds the canonical encoding field by field.
    function test_ParamsHash_EqualsTheCanonicalEip712StructHash() public view {
        PrimaryTypes.SettlementIntent memory intent = _intent();

        bytes memory canonical = abi.encodePacked(
            EXPECTED_INTENT_TYPEHASH,
            bytes32(uint256(uint160(intent.buyer))),
            bytes32(uint256(uint160(intent.assetToken))),
            // ⚠️ `uint8` is encoded LEFT-padded to a full word, in both `abi.encode` and EIP-712,
            //    which is what keeps the shortcut equal to the canonical hash. It is also why the
            //    type string must say `uint8` and not the enum's name: no EIP-712 library has a
            //    notion of `AssetAccountingMode`, so a signer that wrote the Solidity type name
            //    into its own copy of this string would produce a different, silently wrong
            //    digest. See `PrimaryTypes.AssetAccountingMode`.
            bytes32(uint256(intent.accountingMode)),
            bytes32(intent.minAssetOut),
            bytes32(uint256(uint160(intent.settlementToken))),
            bytes32(intent.venueQuoteIn),
            bytes32(intent.buyerFee),
            bytes32(intent.maxSettlementIn)
        );
        canonical = abi.encodePacked(
            canonical,
            bytes32(uint256(uint160(intent.feeCollector))),
            bytes32(uint256(uint160(intent.venue))),
            bytes32(intent.selector),
            intent.calldataHash,
            intent.supplierReference,
            bytes32(intent.nonce),
            bytes32(intent.deadline)
        );

        assertEq(canonical.length, 32 * 16, "typehash plus fifteen single-word members");
        assertEq(_paramsHash(intent), keccak256(canonical), "the abi.encode shortcut diverged from EIP-712");
        assertEq(harness.intentStructHash(intent), keccak256(canonical), "the contract disagrees");
    }

    /// The struct hash must change when ANY field changes, which is what makes it usable as
    /// the `paramsHash` binding for the two attestations that ride with it.
    function test_ParamsHash_ChangesWithEveryField() public view {
        bytes32 base = _paramsHash(_intent());
        PrimaryTypes.SettlementIntent memory m;

        m = _intent();
        m.buyer = stranger;
        assertTrue(_paramsHash(m) != base, "buyer");
        m = _intent();
        m.assetToken = address(1);
        assertTrue(_paramsHash(m) != base, "assetToken");
        m = _intent();
        m.minAssetOut += 1;
        assertTrue(_paramsHash(m) != base, "minAssetOut");
        m = _intent();
        m.settlementToken = address(2);
        assertTrue(_paramsHash(m) != base, "settlementToken");
        m = _intent();
        m.venueQuoteIn += 1;
        assertTrue(_paramsHash(m) != base, "venueQuoteIn");
        m = _intent();
        m.buyerFee += 1;
        assertTrue(_paramsHash(m) != base, "buyerFee");
        m = _intent();
        m.maxSettlementIn += 1;
        assertTrue(_paramsHash(m) != base, "maxSettlementIn");
        m = _intent();
        m.feeCollector = address(3);
        assertTrue(_paramsHash(m) != base, "feeCollector");
        m = _intent();
        m.venue = address(4);
        assertTrue(_paramsHash(m) != base, "venue");
        m = _intent();
        m.selector = 0x11111111;
        assertTrue(_paramsHash(m) != base, "selector");
        m = _intent();
        m.calldataHash = keccak256("x");
        assertTrue(_paramsHash(m) != base, "calldataHash");
        m = _intent();
        m.supplierReference = keccak256("y");
        assertTrue(_paramsHash(m) != base, "supplierReference");
        m = _intent();
        m.nonce += 1;
        assertTrue(_paramsHash(m) != base, "nonce");
        m = _intent();
        m.deadline += 1;
        assertTrue(_paramsHash(m) != base, "deadline");
    }

    // -- the sell-back leg -----------------------------------------------------------------

    /// The literal an off-chain signer can hardcode instead of hashing the type string.
    bytes32 internal constant EXPECTED_REDEMPTION_TYPEHASH =
        0x0f518f193bdea7541e9281c432a5e8447455bc3e86b4d1ed635daecfd1daa481;

    function test_RedemptionTypehash_IsPinned() public view {
        assertEq(REDEMPTION_TYPEHASH, EXPECTED_REDEMPTION_TYPEHASH, "typehash moved: the struct changed");
        assertEq(sales.REDEMPTION_TYPEHASH(), EXPECTED_REDEMPTION_TYPEHASH, "the deployed contract disagrees");
        assertEq(
            sales.REDEMPTION_TYPEHASH(), keccak256(bytes(REDEMPTION_TYPE_STRING)), "typehash is not its type string"
        );
    }

    /// 🔴 The two payloads must never collide. They are different structs with different fields,
    /// so a shared typehash would let a redemption signature be replayed as a purchase.
    function test_TheTwoTypehashesAreDistinct() public view {
        assertTrue(sales.INTENT_TYPEHASH() != sales.REDEMPTION_TYPEHASH(), "one payload cannot be both legs");
    }

    /// The same all-static-members argument as `test_ParamsHash_EqualsTheCanonicalEip712StructHash`,
    /// for the redemption payload. See that test for why the shortcut is only valid while every
    /// member is a static type.
    function test_RedemptionParamsHash_EqualsTheCanonicalEip712StructHash() public view {
        PrimaryTypes.RedemptionIntent memory intent = _redemption();

        bytes memory canonical = abi.encodePacked(
            EXPECTED_REDEMPTION_TYPEHASH,
            bytes32(uint256(uint160(intent.seller))),
            bytes32(uint256(uint160(intent.assetToken))),
            bytes32(uint256(intent.accountingMode)),
            bytes32(intent.maxAssetIn),
            bytes32(uint256(uint160(intent.settlementToken))),
            bytes32(intent.venueQuoteOut),
            bytes32(intent.sellerFee),
            bytes32(intent.minSettlementOut)
        );
        canonical = abi.encodePacked(
            canonical,
            bytes32(uint256(uint160(intent.feeCollector))),
            bytes32(uint256(uint160(intent.venue))),
            bytes32(intent.selector),
            intent.calldataHash,
            intent.supplierReference,
            bytes32(intent.nonce),
            bytes32(intent.deadline)
        );

        assertEq(canonical.length, 32 * 16, "typehash plus fifteen single-word members");
        assertEq(_paramsHash(intent), keccak256(canonical), "the abi.encode shortcut diverged from EIP-712");
        assertEq(harness.redemptionStructHash(intent), keccak256(canonical), "the contract disagrees");
    }

    /// 🔴 The SHARED known-answer vector. The signer service and the compliance service pin this
    /// same struct hash against their own EIP-712 tooling, so this test is what proves the
    /// three implementations agree. A typehash pin alone would not: it says nothing about field
    /// order, padding, or the `bytes4` and `uint8` encodings.
    ///
    /// Every input is a fixed literal rather than a fixture value, deliberately. A vector that
    /// moved with `block.timestamp` could not be reproduced in another repository.
    function test_RedemptionStructHash_MatchesTheSharedKnownAnswerVector() public view {
        PrimaryTypes.RedemptionIntent memory intent = PrimaryTypes.RedemptionIntent({
            seller: 0x1111111111111111111111111111111111111111,
            assetToken: 0x2222222222222222222222222222222222222222,
            accountingMode: 1,
            maxAssetIn: 1_234_567_890_123_456_789,
            settlementToken: 0x3333333333333333333333333333333333333333,
            venueQuoteOut: 250_000_000,
            sellerFee: 1_250_000,
            minSettlementOut: 248_750_000,
            feeCollector: 0x4444444444444444444444444444444444444444,
            venue: 0x5555555555555555555555555555555555555555,
            selector: 0xa9059cbb,
            calldataHash: 0x4387c5b7a5a3a3779a243e1994a477b8dc661a2bbbac1d4e0a6a5aa6e9a16037,
            supplierReference: 0x5d3093ed0d2b2bb3fece5cd8635f5cdcbb42e4a87d24e4aaddae770f99fe3de2,
            nonce: 42,
            deadline: 1_893_456_000
        });

        assertEq(
            harness.redemptionStructHash(intent),
            0xe3c728ec39708608d1ad3b9d44152d09226b78bd5d00022590527df2de840668,
            "the router disagrees with the shared vector"
        );
        assertEq(_paramsHash(intent), harness.redemptionStructHash(intent), "and the test's own encoding disagrees");
    }

    /// The struct hash must change when ANY field changes, which is what makes it usable as the
    /// `paramsHash` binding. The sell-back mirror of `test_ParamsHash_ChangesWithEveryField`.
    function test_RedemptionParamsHash_ChangesWithEveryField() public view {
        bytes32 base = _paramsHash(_redemption());
        PrimaryTypes.RedemptionIntent memory m;

        m = _redemption();
        m.seller = stranger;
        assertTrue(_paramsHash(m) != base, "seller");
        m = _redemption();
        m.assetToken = address(1);
        assertTrue(_paramsHash(m) != base, "assetToken");
        m = _redemption();
        m.accountingMode = 1;
        assertTrue(_paramsHash(m) != base, "accountingMode");
        m = _redemption();
        m.maxAssetIn += 1;
        assertTrue(_paramsHash(m) != base, "maxAssetIn");
        m = _redemption();
        m.settlementToken = address(2);
        assertTrue(_paramsHash(m) != base, "settlementToken");
        m = _redemption();
        m.venueQuoteOut += 1;
        assertTrue(_paramsHash(m) != base, "venueQuoteOut");
        m = _redemption();
        m.sellerFee += 1;
        assertTrue(_paramsHash(m) != base, "sellerFee");
        m = _redemption();
        m.minSettlementOut += 1;
        assertTrue(_paramsHash(m) != base, "minSettlementOut");
        m = _redemption();
        m.feeCollector = address(3);
        assertTrue(_paramsHash(m) != base, "feeCollector");
        m = _redemption();
        m.venue = address(4);
        assertTrue(_paramsHash(m) != base, "venue");
        m = _redemption();
        m.selector = 0x11111111;
        assertTrue(_paramsHash(m) != base, "selector");
        m = _redemption();
        m.calldataHash = keccak256("x");
        assertTrue(_paramsHash(m) != base, "calldataHash");
        m = _redemption();
        m.supplierReference = keccak256("y");
        assertTrue(_paramsHash(m) != base, "supplierReference");
        m = _redemption();
        m.nonce += 1;
        assertTrue(_paramsHash(m) != base, "nonce");
        m = _redemption();
        m.deadline += 1;
        assertTrue(_paramsHash(m) != base, "deadline");
    }

    /// The `PrimarySettled` topic0 the indexer filters on. Pinned so that reordering or
    /// retyping a field cannot silently stop matching a deployed stream filter — the failure
    /// mode is a feed that looks alive and carries no primary sales.
    function test_PrimarySettledEventSignature_IsPinned() public pure {
        assertEq(
            keccak256(
                "PrimarySettled(address,address,address,uint256,address,uint256,uint256,uint256,address,bytes32,uint256)"
            ),
            0x30b9072b6411a3b6352a8664921029a444d29156e42a80d3a2076aa4ca87868e
        );
    }

    /// The `PrimaryRedeemed` topic0, pinned for the same reason. ⚠️ It is a SECOND topic beside
    /// the buy's rather than a change to it, so a deployed filter keeps matching what it always
    /// matched and picks the sell-back leg up by adding a filter.
    function test_PrimaryRedeemedEventSignature_IsPinned() public pure {
        assertEq(
            keccak256(
                "PrimaryRedeemed(address,address,address,uint256,address,uint256,uint256,uint256,address,bytes32,uint256)"
            ),
            0x8cda59bfeb2102501e5e556f5265da55930da46e4aeb3add87d19081b4ab503b
        );
    }
}
