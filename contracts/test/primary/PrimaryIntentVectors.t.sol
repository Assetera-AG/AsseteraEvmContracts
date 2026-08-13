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
        0x86c9b91e614acc7421e39417dc43dd7b9bd2e0b2c8ce196c12f8b7391d281a03;

    function test_IntentTypehash_IsPinned() public view {
        assertEq(INTENT_TYPEHASH, EXPECTED_INTENT_TYPEHASH, "typehash moved: the struct changed");
        assertEq(sales.INTENT_TYPEHASH(), EXPECTED_INTENT_TYPEHASH, "the deployed contract disagrees");
        assertEq(sales.INTENT_TYPEHASH(), keccak256(bytes(INTENT_TYPE_STRING)), "typehash is not its type string");
    }

    /// 🔴 `paramsHash` is computed on-chain as `keccak256(abi.encode(INTENT_TYPEHASH, intent))`,
    /// which is a shortcut. It is only equal to the canonical EIP-712 `hashStruct` because
    /// every member of `SettlementIntent` is a STATIC type — `abi.encode` of an all-static
    /// struct is exactly its fourteen head words, with `bytes4` right-padded in both encodings.
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

        assertEq(canonical.length, 32 * 15, "typehash plus fourteen single-word members");
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
}
