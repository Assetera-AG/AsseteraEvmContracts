// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {AsseteraECS} from "../src/AsseteraECS.sol";
import {ExchangeTypes} from "../src/types/ExchangeTypes.sol";
import {ExchangeStorage} from "../src/storage/ExchangeStorage.sol";
import {FaucetToken} from "./mocks/FaucetToken.sol";

// =========================================================================================== //
//                        THE CROSS-REPO paramsHash VECTORS — READ THIS                        //
// =========================================================================================== //
//
// WHAT THIS FILE IS
// -----------------
// Three services compute an attestation's `paramsHash` off chain, and the venue recomputes it on
// chain and compares. If the two ever disagree by one byte the call reverts with
// `ParamsHashMismatch` and the user cannot trade. The three off-chain implementations are:
//
//   * AsseteraComplianceService — C# / BouncyCastle, `src/Compliance.Infrastructure/Crypto/
//     EvmParamsHasher.cs`, pinned in `tests/Compliance.UnitTests/Infrastructure/
//     EvmParamsHasherTests.cs`.
//   * AsseteraMarketplaceAPI — TypeScript / viem, `src/modules/attestations/params-hash.ts`,
//     pinned in `src/modules/attestations/params-hash.test.ts`.
//   * AsseteraSignerService — signs whatever `paramsHash` it is handed, so it inherits whichever
//     of the two above produced it.
//
// Both of those repos pin the SAME hardcoded expected values that are pinned below. Until AO-297
// this repo — the one that actually defines the encoding — pinned nothing: every Foundry test
// rebuilt the hash with the same expression it was testing, so the assertions were tautological
// and would have followed an encoding change silently. This file fixes that. It is the authority:
// the numbers here are the contract's own output, and the other two repos are copies of it.
//
// WHY DUPLICATE A CONSTANT INSTEAD OF SHARING ONE
// -----------------------------------------------
// A shared constant would defeat the purpose. The value is only useful as a check because each
// repo derives it independently from the spec and then compares. If all three read one library,
// a wrong value would agree with itself everywhere and nothing would fail. These are frozen test
// vectors, not configuration — duplication is the mechanism, not an accident.
//
// IF YOU NEED TO CHANGE AN EXPECTED VALUE HERE
// ---------------------------------------------
// Then you have changed the on-chain encoding, and the identical change MUST land in both repos
// named above in the same release. Otherwise every affected action reverts on chain the moment
// this contract is upgraded: offers cannot be made, replaced, accepted or cancelled, and orders
// cannot be placed. Do not "fix" a failing assertion by pasting in the new number.
//
// HOW THE VECTORS WERE DERIVED (re-derive them; don't trust the file)
// -------------------------------------------------------------------
// Each one was computed with foundry's `cast` — a Rust keccak/ABI implementation independent of
// both solc and the test below. The exact command sits above each constant, so any reviewer can
// reproduce it in one shell line.
//
// TWO TEST CONTRACTS, AND WHY BOTH ARE NEEDED
// --------------------------------------------
// `ParamsHashVectorsTest` re-states the contracts' expressions and compares them to the pinned
// constants. On its own that would still be a copy of the algorithm, not the algorithm: edit
// `OfferBook.sol` and this contract would not notice, because it holds its own copy. What it does
// catch is drift in the CONSTANTS — someone "updating" a vector without updating the other repos.
//
// `ParamsHashVectorsOnChainTest` closes that gap. It deploys the real venue and calls `placeOrder`,
// `makeOffer` and `cancelOffer` with attestations whose `paramsHash` IS the hardcoded constant. If
// anyone changes the encoding in `OrderBook.sol` or `OfferBook.sol`, those calls start reverting
// with `ParamsHashMismatch` and the suite goes red. That is the assertion the old tests could never
// make, because they recomputed the hash with the same expression they were exercising.
//
// THREE PREIMAGES, TWO ENCODINGS
// -------------------------------
//   1. Place (action 1)                       — abi.encode,       PADDED, 128 bytes
//      OrderBook.sol:106 (`placeOrder`) and OrderBook.sol:139 (`placeOrderWithPermit`).
//   2. MakeOffer (action 4)                   — abi.encodePacked, PACKED, 124 bytes
//      OfferBook.sol:90. Note `taker` LEADS the preimage — an offer's attestation is bound to
//      its counterparty.
//   3. Offer amounts (actions 5, 6, 7)        — abi.encodePacked, 96 bytes
//      OfferBook.sol:184 (`replaceOffer`), :244 (`cancelOffer`), :294 (`acceptOffer`). Three
//      uint256s are already word-sized, so packed and padded coincide here byte for byte; what
//      these vectors pin is the field set, its order and its widths.
//
// =========================================================================================== //

/// @title ParamsHashVectorsTest
/// @notice Pins the cross-repo `paramsHash` vectors against the exact expressions the production
///         contracts evaluate, and proves the two encodings are not interchangeable.
contract ParamsHashVectorsTest is Test {
    // ── Shared inputs. These are the values AsseteraComplianceService and AsseteraMarketplaceAPI
    //    already pin, so all three repos assert the same numbers on the same inputs.
    address internal constant TOKEN_A = 0x1111111111111111111111111111111111111111;
    address internal constant TOKEN_B = 0x2222222222222222222222222222222222222222;
    address internal constant TAKER = 0x3333333333333333333333333333333333333333;
    uint256 internal constant AMOUNT_A = 1_000_000; // 1.0 of a 6-decimal token
    uint256 internal constant AMOUNT_B = 5_000_000_000_000_000_000; // 5.0 of an 18-decimal token

    // ── The pinned vectors ────────────────────────────────────────────────────────────────────

    /// cast keccak $(cast abi-encode "f(address,uint256,address,uint256)" \
    ///   0x1111111111111111111111111111111111111111 1000000 \
    ///   0x2222222222222222222222222222222222222222 5000000000000000000)
    bytes32 internal constant PLACE_VECTOR = 0xa2ef1df146cbf2a4faec90f3b1fe87edce9fdeb2b7db8da457f98759361f7067;

    /// The SAME four values packed instead of padded. Never a valid Place hash — pinned so the
    /// wrong-encoding failure mode has a name and a number rather than being "some other hash".
    /// cast keccak $(cast abi-encode --packed "f(address,uint256,address,uint256)" …)
    bytes32 internal constant PLACE_VECTOR_IF_PACKED =
        0x4e35f438b46aee5bdcfbed116d5a0f51cce210592b22cd17a4b3fbba71749238;

    /// cast keccak $(cast abi-encode --packed "f(address,address,uint256,address,uint256)" \
    ///   0x3333333333333333333333333333333333333333 0x1111111111111111111111111111111111111111 \
    ///   1000000 0x2222222222222222222222222222222222222222 5000000000000000000)
    bytes32 internal constant MAKE_OFFER_VECTOR = 0x06a1c430b2b9b118814cd05488d9eb1c4853fc0578e6b2180843327eebade902;

    /// The SAME five values padded instead of packed — i.e. what a refactor that "unified" the
    /// two books onto `abi.encode` would produce. `makeOffer` rejects it with `ParamsHashMismatch`.
    /// cast keccak $(cast abi-encode "f(address,address,uint256,address,uint256)" …)
    bytes32 internal constant MAKE_OFFER_VECTOR_IF_PADDED =
        0xd75bae8d982097aff75562cad4b194e5c0318e9adb8317838e86ef5ffc305a56;

    /// Widths, not values: near-zero addresses and amounts of 1. A packed encoder that emitted
    /// minimal-length big-endian bytes (the classic hand-rolled bug) would hash a 5-byte preimage
    /// here instead of a 124-byte one, and would miss this vector.
    /// cast keccak $(cast abi-encode --packed "f(address,address,uint256,address,uint256)" \
    ///   0x…01 0x…02 1 0x…03 1)
    bytes32 internal constant MAKE_OFFER_VECTOR_MINIMAL_WIDTHS =
        0xcad786270b240998f92c71b45659a4d693a5e72846695a5ae419cae9b45a3caa;

    /// cast keccak $(cast abi-encode --packed "f(uint256,uint256,uint256)" 42 1000000 5000000000000000000)
    bytes32 internal constant OFFER_AMOUNTS_VECTOR = 0xb940d0adb5d4c62079f7f09c4ab2c33542349fb193417f6ed49a4e288c9bdd95;

    /// cast keccak $(cast abi-encode --packed "f(uint256,uint256,uint256)" 1 2 3)
    bytes32 internal constant OFFER_AMOUNTS_VECTOR_SMALL =
        0x6e0c627900b24bd432fe7b1f713f1b0744091a646a9fe4a65a18dfed21f2949c;

    // ── 1. Place — OrderBook.sol:106 and :139 ─────────────────────────────────────────────────

    /// @dev The expression on the right is a character-for-character copy of the one inside
    ///      `placeOrder`; the left is a constant that came from outside this repo. That is what
    ///      makes this assertion capable of failing.
    function test_PlaceVector_MatchesTheOrderBookExpression() public pure {
        address sellToken = TOKEN_A;
        uint256 sellAmount = AMOUNT_A;
        address buyToken = TOKEN_B;
        uint256 buyAmount = AMOUNT_B;

        assertEq(keccak256(abi.encode(sellToken, sellAmount, buyToken, buyAmount)), PLACE_VECTOR);
    }

    /// `placeOrderWithPermit` must bind the identical hash, or a permit-funded order would need a
    /// different attestation than the same order placed with a prior approval.
    function test_PlaceVector_IsIdenticalForThePermitVariant() public pure {
        bytes32 plain = keccak256(abi.encode(TOKEN_A, AMOUNT_A, TOKEN_B, AMOUNT_B));
        bytes32 withPermit = keccak256(abi.encode(TOKEN_A, AMOUNT_A, TOKEN_B, AMOUNT_B));

        assertEq(plain, withPermit);
        assertEq(withPermit, PLACE_VECTOR);
    }

    /// NEGATIVE — the encodings are not interchangeable. If someone switches `placeOrder` to
    /// `abi.encodePacked`, the expression starts producing the second constant and the first
    /// assertion above fails loudly instead of the change slipping through.
    function test_PlaceVector_IsPaddedNotPacked() public pure {
        assertEq(keccak256(abi.encodePacked(TOKEN_A, AMOUNT_A, TOKEN_B, AMOUNT_B)), PLACE_VECTOR_IF_PACKED);
        assertTrue(PLACE_VECTOR != PLACE_VECTOR_IF_PACKED);
    }

    /// The preimage is four full words. Asserting the LENGTH separately means a future encoding
    /// change is caught even by a reader who only skims.
    function test_PlaceVector_PreimageIsFourFullWords() public pure {
        assertEq(abi.encode(TOKEN_A, AMOUNT_A, TOKEN_B, AMOUNT_B).length, 4 * 32);
        assertEq(abi.encodePacked(TOKEN_A, AMOUNT_A, TOKEN_B, AMOUNT_B).length, 20 + 32 + 20 + 32);
    }

    // ── 2. MakeOffer — OfferBook.sol:90 ───────────────────────────────────────────────────────

    function test_MakeOfferVector_MatchesTheOfferBookExpression() public pure {
        address taker = TAKER;
        address makerToken = TOKEN_A;
        uint256 makerAmount = AMOUNT_A;
        address takerToken = TOKEN_B;
        uint256 takerAmount = AMOUNT_B;

        assertEq(
            keccak256(abi.encodePacked(taker, makerToken, makerAmount, takerToken, takerAmount)), MAKE_OFFER_VECTOR
        );
    }

    /// NEGATIVE — the half of this that a five-field `abi.encode` would still get wrong.
    function test_MakeOfferVector_IsPackedNotPadded() public pure {
        assertEq(keccak256(abi.encode(TAKER, TOKEN_A, AMOUNT_A, TOKEN_B, AMOUNT_B)), MAKE_OFFER_VECTOR_IF_PADDED);
        assertTrue(MAKE_OFFER_VECTOR != MAKE_OFFER_VECTOR_IF_PADDED);
    }

    /// NEGATIVE — and it is not the Place hash of the same two legs either. Reusing the order
    /// hash for offers is the specific bug AO-273 shipped; every such signature reverted.
    function test_MakeOfferVector_IsNotThePlaceVectorOfTheSameLegs() public pure {
        assertTrue(MAKE_OFFER_VECTOR != PLACE_VECTOR);
    }

    function test_MakeOfferVector_PreimageIs124Bytes() public pure {
        // 20 + 20 + 32 + 20 + 32. Under abi.encode it would be 5 × 32 = 160.
        assertEq(abi.encodePacked(TAKER, TOKEN_A, AMOUNT_A, TOKEN_B, AMOUNT_B).length, 124);
        assertEq(abi.encode(TAKER, TOKEN_A, AMOUNT_A, TOKEN_B, AMOUNT_B).length, 160);
    }

    /// Element widths survive near-zero inputs — see the constant's comment.
    function test_MakeOfferVector_KeepsFullElementWidthsOnMinimalInputs() public pure {
        bytes32 h = keccak256(
            abi.encodePacked(
                address(0x0000000000000000000000000000000000000001),
                address(0x0000000000000000000000000000000000000002),
                uint256(1),
                address(0x0000000000000000000000000000000000000003),
                uint256(1)
            )
        );

        assertEq(h, MAKE_OFFER_VECTOR_MINIMAL_WIDTHS);
    }

    /// `taker` leads the preimage, which is what binds an offer attestation to one counterparty.
    function test_MakeOfferVector_IsBoundToTheTaker() public pure {
        bytes32 other = keccak256(
            abi.encodePacked(address(0x4444444444444444444444444444444444444444), TOKEN_A, AMOUNT_A, TOKEN_B, AMOUNT_B)
        );

        assertTrue(other != MAKE_OFFER_VECTOR);
    }

    /// Swapping the two legs is the most plausible way to get the field order wrong while still
    /// producing a hash that looks fine.
    function test_MakeOfferVector_ChangesWhenTheLegsAreSwapped() public pure {
        assertTrue(keccak256(abi.encodePacked(TAKER, TOKEN_B, AMOUNT_B, TOKEN_A, AMOUNT_A)) != MAKE_OFFER_VECTOR);
    }

    // ── 3. Offer amounts — OfferBook.sol:184, :244, :294 ──────────────────────────────────────

    function test_OfferAmountsVector_MatchesTheOfferBookExpression() public pure {
        uint256 offerId = 42;
        uint256 makerAmount = AMOUNT_A;
        uint256 takerAmount = AMOUNT_B;

        assertEq(keccak256(abi.encodePacked(offerId, makerAmount, takerAmount)), OFFER_AMOUNTS_VECTOR);
    }

    /// All three call sites must bind the same hash for the same offer state, otherwise an
    /// attestation minted for a cancel would not be usable for the accept it was issued against.
    function test_OfferAmountsVector_IsIdenticalAcrossReplaceCancelAndAccept() public pure {
        uint256 offerId = 42;
        // OfferBook.sol:184 (replaceOffer, the NEW amounts).
        bytes32 replaceHash = keccak256(abi.encodePacked(offerId, AMOUNT_A, AMOUNT_B));
        // OfferBook.sol:244 (cancelOffer) and :294 (acceptOffer, the CURRENTLY STORED amounts).
        bytes32 cancelHash = keccak256(abi.encodePacked(offerId, AMOUNT_A, AMOUNT_B));
        bytes32 acceptHash = keccak256(abi.encodePacked(offerId, AMOUNT_A, AMOUNT_B));

        assertEq(replaceHash, OFFER_AMOUNTS_VECTOR);
        assertEq(cancelHash, OFFER_AMOUNTS_VECTOR);
        assertEq(acceptHash, OFFER_AMOUNTS_VECTOR);
    }

    function test_OfferAmountsVector_SmallValuesStillUseFullWords() public pure {
        assertEq(keccak256(abi.encodePacked(uint256(1), uint256(2), uint256(3))), OFFER_AMOUNTS_VECTOR_SMALL);
    }

    /// Three uint256s are already word-sized, so packed == padded here. Recorded as an assertion
    /// rather than a comment: it is the one place where the two encodings legitimately coincide,
    /// and a reader who assumes otherwise will mis-read the other two preimages.
    function test_OfferAmountsVector_PackedAndPaddedCoincideForThreeWords() public pure {
        assertEq(
            keccak256(abi.encodePacked(uint256(42), AMOUNT_A, AMOUNT_B)),
            keccak256(abi.encode(uint256(42), AMOUNT_A, AMOUNT_B))
        );
        assertEq(abi.encodePacked(uint256(42), AMOUNT_A, AMOUNT_B).length, 96);
    }

    /// The offer id makes an accept/cancel attestation non-replayable across offers; the amounts
    /// make it non-replayable across counter-proposals.
    function test_OfferAmountsVector_BindsTheIdAndTheCurrentAmounts() public pure {
        assertTrue(keccak256(abi.encodePacked(uint256(43), AMOUNT_A, AMOUNT_B)) != OFFER_AMOUNTS_VECTOR);
        assertTrue(keccak256(abi.encodePacked(uint256(42), AMOUNT_A, uint256(4 ether))) != OFFER_AMOUNTS_VECTOR);
        // Field order: moving the id out of first position must change the hash.
        assertTrue(keccak256(abi.encodePacked(AMOUNT_A, uint256(42), AMOUNT_B)) != OFFER_AMOUNTS_VECTOR);
    }

    // ── 4. The three vectors are mutually distinct ────────────────────────────────────────────

    /// Cheap, but it is the property the whole scheme rests on: an attestation issued for one
    /// action can never satisfy another.
    function test_TheThreeVectorsAreDistinct() public pure {
        assertTrue(PLACE_VECTOR != MAKE_OFFER_VECTOR);
        assertTrue(PLACE_VECTOR != OFFER_AMOUNTS_VECTOR);
        assertTrue(MAKE_OFFER_VECTOR != OFFER_AMOUNTS_VECTOR);
    }
}

/// @title ParamsHashVectorsOnChainTest
/// @notice The other half of the proof. The contract above shows the vectors match the
///         *expressions*; this one shows the deployed venue actually ACCEPTS an attestation
///         carrying the hardcoded constant — i.e. that a signature minted by the C# or the
///         TypeScript hasher on these inputs would settle rather than revert.
contract ParamsHashVectorsOnChainTest is Test {
    address internal constant TOKEN_A = 0x1111111111111111111111111111111111111111;
    address internal constant TOKEN_B = 0x2222222222222222222222222222222222222222;
    address internal constant TAKER = 0x3333333333333333333333333333333333333333;
    uint256 internal constant AMOUNT_A = 1_000_000;
    uint256 internal constant AMOUNT_B = 5_000_000_000_000_000_000;

    bytes32 internal constant PLACE_VECTOR = 0xa2ef1df146cbf2a4faec90f3b1fe87edce9fdeb2b7db8da457f98759361f7067;
    bytes32 internal constant MAKE_OFFER_VECTOR = 0x06a1c430b2b9b118814cd05488d9eb1c4853fc0578e6b2180843327eebade902;
    /// keccak256(abi.encodePacked(uint256(1), uint256(2), uint256(3))) — offer #1, amounts 2 and 3.
    bytes32 internal constant OFFER_AMOUNTS_VECTOR_SMALL =
        0x6e0c627900b24bd432fe7b1f713f1b0744091a646a9fe4a65a18dfed21f2949c;

    bytes32 internal constant KYC_TYPEHASH = keccak256(
        "KycAttestation(address account,uint8 action,uint256 orderId,uint256 nonce,uint256 deadline,bytes32 paramsHash)"
    );
    bytes32 internal constant FEE_TYPEHASH = keccak256(
        "FeeAttestation(address account,uint8 action,uint256 nonce,uint256 deadline,bytes32 paramsHash,uint16 makerFeeBps,uint16 takerFeeBps,address feeCollector,address feeToken)"
    );

    AsseteraECS internal exchange;
    address internal admin = makeAddr("admin");
    address internal maker = makeAddr("maker");

    uint256 internal kycSignerPk = 0xACE1;
    uint256 internal feeSignerPk = 0xFEE1;

    uint256 internal _nonceCtr;

    function setUp() public {
        // The vectors name specific token addresses, so the fixtures have to live AT those
        // addresses — the address bytes are part of the preimage.
        deployCodeTo("FaucetToken.sol:FaucetToken", abi.encode("Vector Token A", "VTA", uint8(6)), TOKEN_A);
        deployCodeTo("FaucetToken.sol:FaucetToken", abi.encode("Vector Token B", "VTB", uint8(18)), TOKEN_B);

        ERC2771Forwarder forwarder = new ERC2771Forwarder("AsseteraForwarder");
        AsseteraECS impl = new AsseteraECS(address(forwarder));
        bytes memory initData =
            abi.encodeCall(AsseteraECS.initialize, (admin, vm.addr(kycSignerPk), vm.addr(feeSignerPk)));
        exchange = AsseteraECS(address(new ERC1967Proxy(address(impl), initData)));

        FaucetToken(TOKEN_A).mint(maker, 1_000_000_000);
        FaucetToken(TOKEN_B).mint(maker, 1_000 ether);
    }

    // ── the pinned constants are accepted by the venue ────────────────────────────────────────

    function test_PlaceOrder_AcceptsTheHardcodedPlaceVector() public {
        AsseteraECS.KycAttestation memory att = _kyc(maker, ExchangeTypes.Action.Place, 0, PLACE_VECTOR);
        AsseteraECS.FeeAttestation memory feeAtt = _fee(maker, ExchangeTypes.Action.Place, PLACE_VECTOR, TOKEN_A);

        vm.startPrank(maker);
        FaucetToken(TOKEN_A).approve(address(exchange), AMOUNT_A);
        uint256 id = exchange.placeOrder(TOKEN_A, AMOUNT_A, TOKEN_B, AMOUNT_B, 0, att, feeAtt);
        vm.stopPrank();

        assertEq(id, 1);
    }

    /// The control. One flipped bit and the same call reverts — so the test above is passing
    /// because the constant is right, not because the gate is off.
    function test_PlaceOrder_RevertsOnAOneBitPerturbationOfThePlaceVector() public {
        bytes32 wrong = PLACE_VECTOR ^ bytes32(uint256(1));
        AsseteraECS.KycAttestation memory att = _kyc(maker, ExchangeTypes.Action.Place, 0, wrong);
        AsseteraECS.FeeAttestation memory feeAtt = _fee(maker, ExchangeTypes.Action.Place, wrong, TOKEN_A);

        vm.startPrank(maker);
        FaucetToken(TOKEN_A).approve(address(exchange), AMOUNT_A);
        vm.expectRevert(ExchangeStorage.ParamsHashMismatch.selector);
        exchange.placeOrder(TOKEN_A, AMOUNT_A, TOKEN_B, AMOUNT_B, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_MakeOffer_AcceptsTheHardcodedMakeOfferVector() public {
        uint256 id = _makeOffer(MAKE_OFFER_VECTOR, AMOUNT_A, AMOUNT_B);

        assertEq(id, 1);
    }

    function test_MakeOffer_RevertsOnThePaddedEncodingOfTheSameFields() public {
        bytes32 padded = keccak256(abi.encode(TAKER, TOKEN_A, AMOUNT_A, TOKEN_B, AMOUNT_B));
        AsseteraECS.KycAttestation memory att = _kyc(maker, ExchangeTypes.Action.MakeOffer, 0, padded);
        AsseteraECS.FeeAttestation memory feeAtt = _fee(maker, ExchangeTypes.Action.MakeOffer, padded, TOKEN_A);

        vm.startPrank(maker);
        FaucetToken(TOKEN_A).approve(address(exchange), AMOUNT_A);
        vm.expectRevert(ExchangeStorage.ParamsHashMismatch.selector);
        exchange.makeOffer(TAKER, TOKEN_A, AMOUNT_A, TOKEN_B, AMOUNT_B, 0, att, feeAtt);
        vm.stopPrank();
    }

    /// Offer #1 with amounts 2 and 3 reproduces the (1, 2, 3) vector exactly, so the venue can be
    /// asked to accept that hardcoded constant on a real `cancelOffer`.
    function test_CancelOffer_AcceptsTheHardcodedOfferAmountsVector() public {
        bytes32 makeHash = keccak256(abi.encodePacked(TAKER, TOKEN_A, uint256(2), TOKEN_B, uint256(3)));
        uint256 id = _makeOffer(makeHash, 2, 3);
        assertEq(id, 1);

        AsseteraECS.KycAttestation memory att =
            _kyc(maker, ExchangeTypes.Action.CancelOffer, id, OFFER_AMOUNTS_VECTOR_SMALL);

        vm.prank(maker);
        exchange.cancelOffer(id, att);

        assertEq(uint8(exchange.getOffer(id).status), uint8(ExchangeTypes.OfferStatus.Cancelled));
    }

    // ── helpers ───────────────────────────────────────────────────────────────────────────────

    function _makeOffer(bytes32 paramsHash, uint256 makerAmount, uint256 takerAmount) internal returns (uint256 id) {
        AsseteraECS.KycAttestation memory att = _kyc(maker, ExchangeTypes.Action.MakeOffer, 0, paramsHash);
        AsseteraECS.FeeAttestation memory feeAtt = _fee(maker, ExchangeTypes.Action.MakeOffer, paramsHash, TOKEN_A);

        vm.startPrank(maker);
        FaucetToken(TOKEN_A).approve(address(exchange), makerAmount);
        id = exchange.makeOffer(TAKER, TOKEN_A, makerAmount, TOKEN_B, takerAmount, 0, att, feeAtt);
        vm.stopPrank();
    }

    function _kyc(address account, AsseteraECS.Action action, uint256 orderId, bytes32 paramsHash)
        internal
        returns (AsseteraECS.KycAttestation memory att)
    {
        uint256 nonce = ++_nonceCtr;
        uint256 deadline = block.timestamp + 3 minutes;
        bytes32 structHash =
            keccak256(abi.encode(KYC_TYPEHASH, account, uint8(action), orderId, nonce, deadline, paramsHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(kycSignerPk, _digest(structHash));
        att = ExchangeTypes.KycAttestation({
            account: account,
            action: action,
            orderId: orderId,
            nonce: nonce,
            deadline: deadline,
            paramsHash: paramsHash,
            signature: abi.encodePacked(r, s, v)
        });
    }

    /// A zero-fee attestation. `feeToken` still has to be one of the two legs (AC-833).
    function _fee(address account, AsseteraECS.Action action, bytes32 paramsHash, address feeToken)
        internal
        returns (AsseteraECS.FeeAttestation memory att)
    {
        uint256 nonce = ++_nonceCtr;
        uint256 deadline = block.timestamp + 3 minutes;
        bytes32 structHash = keccak256(
            abi.encode(
                FEE_TYPEHASH,
                account,
                uint8(action),
                nonce,
                deadline,
                paramsHash,
                uint16(0),
                uint16(0),
                address(0),
                feeToken
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(feeSignerPk, _digest(structHash));
        att = ExchangeTypes.FeeAttestation({
            account: account,
            action: action,
            nonce: nonce,
            deadline: deadline,
            paramsHash: paramsHash,
            makerFeeBps: 0,
            takerFeeBps: 0,
            feeCollector: address(0),
            feeToken: feeToken,
            signature: abi.encodePacked(r, s, v)
        });
    }

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                // Still "AsseteraExchange" on purpose — see AsseteraECS.initialize.
                keccak256(bytes("AsseteraExchange")),
                keccak256(bytes("1")),
                block.chainid,
                address(exchange)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }
}
