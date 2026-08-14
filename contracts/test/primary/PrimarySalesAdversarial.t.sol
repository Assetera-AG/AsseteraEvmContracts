// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {AsseteraPrimarySales} from "../../src/primary/AsseteraPrimarySales.sol";
import {AsseteraECS} from "../../src/AsseteraECS.sol";
import {PrimaryTypes} from "../../src/primary/types/PrimaryTypes.sol";
import {GateTypes} from "../../src/types/GateTypes.sol";
import {GateStorage} from "../../src/gates/GateStorage.sol";
import {IKycGate} from "../../src/interfaces/IKycGate.sol";
import {IFeeGate} from "../../src/interfaces/IFeeGate.sol";
import {IIntentGate} from "../../src/primary/interfaces/IIntentGate.sol";
import {ContractWalletBuyer} from "./mocks/ContractWalletBuyer.sol";
import {
    GarbageWallet,
    PermissiveWallet,
    RevertingWallet,
    ShortReturnWallet,
    TruthyWallet
} from "./mocks/HostileWallets.sol";
import {VenueSettlerTestBase} from "./VenueSettlerTestBase.sol";

/// @title PrimarySalesReplayTest
/// @notice 🔴 Replay, on every axis a settlement can be moved along: the same intent again, the
///         same intent with a fresh buyer signature, an attestation lifted onto a different
///         intent, a payload moved to another proxy, to the exchange, or to another chain.
///
///         Run against the REAL money path — `VenueSettlerTestBase`'s router, real ERC-20s, a
///         real venue — rather than against the stubbed harness, so that "refused" also means
///         "and no token moved".
///
/// @dev    Four signed payloads and three nonce namespaces mean there is no single line that
///         makes replay impossible; there are several, and which one fires depends on the axis.
///         Each test therefore asserts the specific error, because "it reverted" would pass even
///         if the protection had migrated to something weaker.
contract PrimarySalesReplayTest is VenueSettlerTestBase {
    /// A second, independent settlement over the same fixtures: fresh intent, KYC and fee
    /// nonces, so nothing about it collides with the first except what a test deliberately
    /// makes collide.
    function _secondIntent() internal view returns (bytes memory data, PrimaryTypes.SettlementIntent memory intent) {
        data = _venueCalldata(QUOTE, ASSET_OUT);
        intent = _venueIntent(data, QUOTE, FEE, collector);
        intent.nonce = INTENT_NONCE + 1;
        intent.supplierReference = keccak256("dinari:quote:43");
    }

    /// A KYC attestation with an explicit nonce, so nonce reuse can be tested separately from
    /// `paramsHash` reuse.
    function _kycWithNonce(bytes32 paramsHash, uint256 nonce) internal view returns (GateTypes.KycAttestation memory) {
        uint8 action = uint8(PrimaryTypes.Action.SettleVenue);
        uint256 deadline = block.timestamp + 3 minutes;
        bytes32 structHash = keccak256(abi.encode(KYC_TYPEHASH, buyer, action, uint256(0), nonce, deadline, paramsHash));
        return GateTypes.KycAttestation({
            account: buyer,
            action: action,
            orderId: 0,
            nonce: nonce,
            deadline: deadline,
            paramsHash: paramsHash,
            signature: _sign(kycSignerPk, _digest(PRIMARY_DOMAIN_NAME, address(router), structHash))
        });
    }

    /// The same for the fee attestation.
    function _feeWithNonce(bytes32 paramsHash, uint256 nonce) internal view returns (GateTypes.FeeAttestation memory) {
        uint8 action = uint8(PrimaryTypes.Action.SettleVenue);
        uint256 deadline = block.timestamp + 3 minutes;
        bytes32 structHash = keccak256(
            abi.encode(
                FEE_TYPEHASH,
                buyer,
                action,
                nonce,
                deadline,
                paramsHash,
                uint16(0),
                TAKER_BPS,
                collector,
                address(currency)
            )
        );
        return GateTypes.FeeAttestation({
            account: buyer,
            action: action,
            nonce: nonce,
            deadline: deadline,
            paramsHash: paramsHash,
            makerFeeBps: 0,
            takerFeeBps: TAKER_BPS,
            feeCollector: collector,
            feeToken: address(currency),
            signature: _sign(feeSignerPk, _digest(PRIMARY_DOMAIN_NAME, address(router), structHash))
        });
    }

    /// Submit one settlement with every payload supplied explicitly, so a test can swap exactly
    /// one of them.
    function _submitWith(
        bytes memory data,
        PrimaryTypes.SettlementIntent memory intent,
        bytes memory intentSignature,
        bytes memory buyerSignature,
        GateTypes.KycAttestation memory kyc,
        GateTypes.FeeAttestation memory fee
    ) internal {
        vm.prank(buyer);
        AsseteraPrimarySales(address(router)).settlePrimary(data, intent, intentSignature, buyerSignature, kyc, fee);
    }

    // ── the same settlement, twice ────────────────────────────────────────────────────────

    /// 🔴 The plainest replay: the identical transaction resubmitted. The intent's single-use
    /// nonce is checked in `_verifyIntent`, before any signature is recovered and long before
    /// any token moves, so the second attempt costs the attacker a revert and the buyer nothing.
    function test_Replay_TheSameSettlementTwiceIsRefusedAndDebitsTheBuyerOnce() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();
        uint256 buyerBefore = currency.balanceOf(buyer);

        _settleVenueWith(data, intent, TAKER_BPS);
        assertEq(currency.balanceOf(buyer), buyerBefore - QUOTE - FEE, "fixture: the first settlement must land");

        // Re-approve, so the second attempt fails on the replay rather than on an exhausted
        // allowance. Without this the test would pass for the wrong reason.
        _approveExact(intent);
        vm.expectRevert(IIntentGate.IntentNonceUsed.selector);
        _submit(data, intent, TAKER_BPS);

        assertEq(currency.balanceOf(buyer), buyerBefore - QUOTE - FEE, "the buyer was debited twice");
        assertEq(asset.balanceOf(buyer), ASSET_OUT, "the asset was delivered twice");
    }

    /// The buyer's signature is not a second, independent authorisation that could refresh a
    /// spent intent: a NEW, perfectly valid buyer signature over the same terms still meets the
    /// burned nonce. Three nonce namespaces rather than four is only safe because of this — the
    /// intent's nonce is the buyer's replay protection too.
    function test_Replay_AFreshBuyerSignatureDoesNotReviveASpentIntent() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();
        _settleVenueWith(data, intent, TAKER_BPS);

        bytes32 paramsHash = _paramsHash(intent);
        _approveExact(intent);
        vm.expectRevert(IIntentGate.IntentNonceUsed.selector);
        _submitWith(
            data,
            intent,
            _signIntent(address(router), intent),
            _signBuyerConsent(address(router), intent), // signed again, from scratch
            _kyc(address(router), paramsHash),
            _fee(address(router), paramsHash, 0, TAKER_BPS, collector, address(currency))
        );
    }

    // ── attestations moved between settlements ────────────────────────────────────────────

    /// 🔴 A KYC attestation is pinned to ONE settlement by its `paramsHash`, which is the
    /// intent's EIP-712 struct hash. Lifting a genuine one onto a different intent — a different
    /// amount, asset or venue — fails on the binding, not on the nonce, so it fails even if the
    /// original settlement never ran.
    function test_Replay_AKycAttestationCannotBeLiftedOntoADifferentIntent() public {
        (, PrimaryTypes.SettlementIntent memory first) = _happyPath();
        (bytes memory data, PrimaryTypes.SettlementIntent memory second) = _secondIntent();
        bytes32 secondHash = _paramsHash(second);

        _approveExact(second);
        vm.expectRevert(GateStorage.ParamsHashMismatch.selector);
        _submitWith(
            data,
            second,
            _signIntent(address(router), second),
            _signBuyerConsent(address(router), second),
            _kyc(address(router), _paramsHash(first)), // bound to the OTHER settlement
            _fee(address(router), secondHash, 0, TAKER_BPS, collector, address(currency))
        );
    }

    /// The same for the fee attestation, which carries the basis points the buyer's fee is
    /// cross-checked against. Moving one would let a fee quoted for a small settlement authorise
    /// the fee on a large one.
    function test_Replay_AFeeAttestationCannotBeLiftedOntoADifferentIntent() public {
        (, PrimaryTypes.SettlementIntent memory first) = _happyPath();
        (bytes memory data, PrimaryTypes.SettlementIntent memory second) = _secondIntent();

        _approveExact(second);
        vm.expectRevert(GateStorage.ParamsHashMismatch.selector);
        _submitWith(
            data,
            second,
            _signIntent(address(router), second),
            _signBuyerConsent(address(router), second),
            _kyc(address(router), _paramsHash(second)),
            _fee(address(router), _paramsHash(first), 0, TAKER_BPS, collector, address(currency))
        );
    }

    /// And the nonce namespace behind it: a compliance signer who re-minted an attestation
    /// correctly bound to the SECOND settlement but under a nonce already spent is refused. The
    /// `paramsHash` binding and the nonce are independent protections, and this is the test that
    /// shows the second one is live.
    function test_Replay_AKycNonceCannotBeSpentTwiceEvenForADifferentSettlement() public {
        (bytes memory firstData, PrimaryTypes.SettlementIntent memory first) = _happyPath();
        _settleVenueWith(firstData, first, TAKER_BPS);

        (bytes memory data, PrimaryTypes.SettlementIntent memory second) = _secondIntent();
        bytes32 secondHash = _paramsHash(second);

        _approveExact(second);
        vm.expectRevert(IKycGate.KycNonceUsed.selector);
        _submitWith(
            data,
            second,
            _signIntent(address(router), second),
            _signBuyerConsent(address(router), second),
            _kycWithNonce(secondHash, KYC_NONCE), // correctly bound, already-spent nonce
            _feeWithNonce(secondHash, FEE_NONCE + 1)
        );
    }

    function test_Replay_AFeeNonceCannotBeSpentTwiceEvenForADifferentSettlement() public {
        (bytes memory firstData, PrimaryTypes.SettlementIntent memory first) = _happyPath();
        _settleVenueWith(firstData, first, TAKER_BPS);

        (bytes memory data, PrimaryTypes.SettlementIntent memory second) = _secondIntent();
        bytes32 secondHash = _paramsHash(second);

        _approveExact(second);
        vm.expectRevert(IFeeGate.FeeNonceUsed.selector);
        _submitWith(
            data,
            second,
            _signIntent(address(router), second),
            _signBuyerConsent(address(router), second),
            _kycWithNonce(secondHash, KYC_NONCE + 1),
            _feeWithNonce(secondHash, FEE_NONCE) // correctly bound, already-spent nonce
        );
    }

    /// The mutation for the four tests above: fresh nonces on both attestations and the SECOND
    /// settlement goes through. Without it, an unrelated breakage in `_secondIntent` would read
    /// as "replay is impossible".
    function test_Replay_ASecondSettlementWithFreshNoncesSucceeds() public {
        (bytes memory firstData, PrimaryTypes.SettlementIntent memory first) = _happyPath();
        _settleVenueWith(firstData, first, TAKER_BPS);

        (bytes memory data, PrimaryTypes.SettlementIntent memory second) = _secondIntent();
        bytes32 secondHash = _paramsHash(second);

        _approveExact(second);
        _submitWith(
            data,
            second,
            _signIntent(address(router), second),
            _signBuyerConsent(address(router), second),
            _kycWithNonce(secondHash, KYC_NONCE + 1),
            _feeWithNonce(secondHash, FEE_NONCE + 1)
        );

        assertEq(asset.balanceOf(buyer), ASSET_OUT * 2, "the second settlement did not land");
    }

    // ── moved to another verifying contract ───────────────────────────────────────────────

    /// 🔴 A whole settlement assembled for one proxy, submitted to another instance of the SAME
    /// contract with the SAME domain name and the SAME three signers. Refused, because the
    /// verifying contract is part of every EIP-712 digest — so a staging deployment's payloads
    /// cannot be replayed against production, and a second router deployed alongside the first
    /// is not a way around a burned nonce.
    function test_Replay_ASettlementAssembledForOneProxyIsRefusedByAnother() public {
        AsseteraPrimarySales twin = _deployTwin();
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();
        bytes32 paramsHash = _paramsHash(intent);

        _approveExactTo(address(twin), intent);
        vm.prank(buyer);
        vm.expectRevert(IIntentGate.IntentBadSigner.selector);
        twin.settlePrimary(
            data,
            intent,
            _signIntent(address(router), intent), // signed for the OTHER proxy
            _signBuyerConsent(address(router), intent),
            _kyc(address(router), paramsHash),
            _fee(address(router), paramsHash, 0, TAKER_BPS, collector, address(currency))
        );
    }

    /// 🔴 The direction the existing domain suite does not cover: an attestation minted HERE,
    /// used on the EXCHANGE. The compliance key is the same, the account is the same, ordinal 1
    /// is `SettleVenue` here and `Place` there, and the attestation is bound to the exchange's
    /// own `paramsHash` — so the only thing wrong with it is the domain it was signed under, and
    /// it recovers to an address that holds no role there.
    ///
    /// Together with `test_ExchangeAttestation_CannotBeReplayedHere` this closes the pair: the
    /// two contracts' payloads are mutually unusable by construction rather than by check.
    function test_Replay_APrimaryAttestationIsRefusedByTheExchange() public {
        AsseteraECS exchange = _deployExchange();

        address sellToken = address(currency);
        address buyToken = address(asset);
        uint256 sellAmount = 100e6;
        uint256 buyAmount = 1e18;
        bytes32 orderParamsHash = keccak256(abi.encode(sellToken, sellAmount, buyToken, buyAmount));

        // Minted under THIS router's domain, for the exchange's `Place` action and the
        // exchange's own parameter binding.
        GateTypes.KycAttestation memory stolen =
            _exchangeShapedKyc(PRIMARY_DOMAIN_NAME, address(router), orderParamsHash);
        GateTypes.FeeAttestation memory genuineFee =
            _exchangeFee(EXCHANGE_DOMAIN_NAME, address(exchange), orderParamsHash, sellToken);

        vm.prank(buyer);
        vm.expectRevert(IKycGate.KycBadSigner.selector);
        exchange.placeOrder(sellToken, sellAmount, buyToken, buyAmount, 0, stolen, genuineFee);
    }

    /// The mutation for the test above: the SAME attestation, differing only in the domain it
    /// was signed under, is accepted by the exchange and the order is placed. Without this the
    /// refusal could be caused by any of the half-dozen checks that run before the signer
    /// recovery, and the test would be claiming more than it proves.
    function test_Replay_TheSameAttestationUnderTheExchangeDomainIsAccepted() public {
        AsseteraECS exchange = _deployExchange();

        address sellToken = address(currency);
        address buyToken = address(asset);
        uint256 sellAmount = 100e6;
        uint256 buyAmount = 1e18;
        bytes32 orderParamsHash = keccak256(abi.encode(sellToken, sellAmount, buyToken, buyAmount));

        vm.prank(buyer);
        currency.approve(address(exchange), sellAmount);

        vm.prank(buyer);
        uint256 id = exchange.placeOrder(
            sellToken,
            sellAmount,
            buyToken,
            buyAmount,
            0,
            _exchangeShapedKyc(EXCHANGE_DOMAIN_NAME, address(exchange), orderParamsHash),
            _exchangeFee(EXCHANGE_DOMAIN_NAME, address(exchange), orderParamsHash, sellToken)
        );

        assertEq(id, 1, "the control order was not placed");
    }

    // ── moved to another chain ────────────────────────────────────────────────────────────

    /// 🔴 The chain id is part of the EIP-712 domain, and `EIP712Upgradeable` rebuilds the
    /// separator from `block.chainid` on every call rather than caching it — so a settlement
    /// signed on one chain recovers to a different address on another and is refused.
    ///
    /// This matters because the router is deployed at the SAME address on several chains through
    /// CREATE3: without the chain id, a payload captured on Amoy would be valid on Polygon
    /// mainnet against the same verifying contract.
    function test_Replay_ASettlementSignedOnOneChainIsRefusedOnAnother() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();
        bytes32 paramsHash = _paramsHash(intent);

        // Assemble everything under the current chain id …
        bytes memory intentSignature = _signIntent(address(router), intent);
        bytes memory buyerSignature = _signBuyerConsent(address(router), intent);
        GateTypes.KycAttestation memory kyc = _kyc(address(router), paramsHash);
        GateTypes.FeeAttestation memory fee =
            _fee(address(router), paramsHash, 0, TAKER_BPS, collector, address(currency));

        _approveExact(intent);
        // … then move the chain out from under it.
        vm.chainId(block.chainid + 1);

        vm.expectRevert(IIntentGate.IntentBadSigner.selector);
        _submitWith(data, intent, intentSignature, buyerSignature, kyc, fee);
    }

    /// The mutation: the identical payloads, submitted without moving the chain, settle. What
    /// separates the two tests is one field of the domain separator and nothing else.
    function test_Replay_TheSamePayloadsOnTheSigningChainSettle() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();
        bytes32 paramsHash = _paramsHash(intent);

        _approveExact(intent);
        _submitWith(
            data,
            intent,
            _signIntent(address(router), intent),
            _signBuyerConsent(address(router), intent),
            _kyc(address(router), paramsHash),
            _fee(address(router), paramsHash, 0, TAKER_BPS, collector, address(currency))
        );

        assertEq(asset.balanceOf(buyer), ASSET_OUT, "the control settlement did not land");
    }

    // ── fixtures ──────────────────────────────────────────────────────────────────────────

    function _deployTwin() internal returns (AsseteraPrimarySales) {
        AsseteraPrimarySales impl = new AsseteraPrimarySales(address(forwarder));
        bytes memory initData =
            abi.encodeCall(AsseteraPrimarySales.initialize, (admin, kycSigner, feeSigner, settlementSigner));
        AsseteraPrimarySales twin = AsseteraPrimarySales(address(new ERC1967Proxy(address(impl), initData)));
        vm.prank(admin);
        twin.setAllowedCollector(collector, true);
        return twin;
    }

    function _deployExchange() internal returns (AsseteraECS) {
        AsseteraECS impl = new AsseteraECS(address(forwarder));
        bytes memory initData = abi.encodeCall(AsseteraECS.initialize, (admin, kycSigner, feeSigner));
        AsseteraECS exchange = AsseteraECS(address(new ERC1967Proxy(address(impl), initData)));
        vm.prank(admin);
        exchange.setAllowedCollector(collector, true);
        return exchange;
    }

    /// A KYC attestation shaped for the EXCHANGE's `Place` action — which happens to share
    /// ordinal 1 with this router's `SettleVenue`, so the ordinal cannot be what refuses it —
    /// signed under whichever domain the caller names.
    function _exchangeShapedKyc(string memory domainName, address target, bytes32 paramsHash)
        internal
        view
        returns (GateTypes.KycAttestation memory)
    {
        uint8 action = 1; // Action.Place on the exchange, Action.SettleVenue here
        uint256 deadline = block.timestamp + 3 minutes;
        bytes32 structHash =
            keccak256(abi.encode(KYC_TYPEHASH, buyer, action, uint256(0), KYC_NONCE, deadline, paramsHash));
        return GateTypes.KycAttestation({
            account: buyer,
            action: action,
            orderId: 0,
            nonce: KYC_NONCE,
            deadline: deadline,
            paramsHash: paramsHash,
            signature: _sign(kycSignerPk, _digest(domainName, target, structHash))
        });
    }

    function _exchangeFee(string memory domainName, address target, bytes32 paramsHash, address feeToken)
        internal
        view
        returns (GateTypes.FeeAttestation memory)
    {
        uint8 action = 1;
        uint256 deadline = block.timestamp + 3 minutes;
        bytes32 structHash = keccak256(
            abi.encode(
                FEE_TYPEHASH, buyer, action, FEE_NONCE, deadline, paramsHash, uint16(0), TAKER_BPS, collector, feeToken
            )
        );
        return GateTypes.FeeAttestation({
            account: buyer,
            action: action,
            nonce: FEE_NONCE,
            deadline: deadline,
            paramsHash: paramsHash,
            makerFeeBps: 0,
            takerFeeBps: TAKER_BPS,
            feeCollector: collector,
            feeToken: feeToken,
            signature: _sign(feeSignerPk, _digest(domainName, target, structHash))
        });
    }
}

/// @title PrimarySalesHostileWalletTest
/// @notice 🔴 The buyer's consent is checked with `SignatureChecker`, which hands the verdict to
///         code the BUYER controls whenever `intent.buyer` has any. `intent.buyer` is a field the
///         settlement operator fills in, so "a contract that is not a well-behaved ERC-1271
///         wallet" is a case that reaches this line in production.
///
///         `AsseteraPrimarySales.t.sol` covers the honest wallet and the clean refusal. These are
///         the answers that are neither: a revert, a wrong magic value, a truthy non-answer and a
///         reply shorter than one word. Every one of them must read as "not consented", and none
///         of them may reach the money.
///
/// @dev    Asserted on the REAL money path rather than the stubbed harness, so each test also
///         says that the buyer's tokens did not move.
contract PrimarySalesHostileWalletTest is VenueSettlerTestBase {
    /// The EOA a wallet mock answers for. A separate key from `buyerPk`, so a test cannot pass
    /// on `SignatureChecker`'s EOA branch without ever calling `isValidSignature`.
    uint256 internal walletOwnerPk = 0x5AFE;

    /// Point the whole fixture at `wallet` as the buyer — the intent, both attestations, the
    /// caller — and fund and approve it.
    ///
    /// ⚠️ Split from `_settleAsWallet` because `vm.expectRevert` binds to the NEXT call, and the
    /// mint and the approve here are calls. Folding the two together made every refusal test
    /// fail with "next call did not revert as expected" while claiming to be about consent.
    function _prepareWallet(address wallet) internal {
        buyer = wallet;
        currency.mint(wallet, 10_000e6);
        vm.prank(wallet);
        currency.approve(address(router), QUOTE + FEE);
    }

    /// Settle for the prepared wallet with `buyerSignature` supplied verbatim.
    function _settleAsWallet(bytes memory buyerSignature) internal {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();
        bytes32 paramsHash = _paramsHash(intent);

        AsseteraPrimarySales primary = AsseteraPrimarySales(address(router));
        vm.prank(intent.buyer);
        primary.settlePrimary(
            data,
            intent,
            _signIntent(address(router), intent),
            buyerSignature,
            _kyc(address(router), paramsHash),
            _fee(address(router), paramsHash, 0, TAKER_BPS, collector, address(currency))
        );
    }

    /// The owner's signature over the intent the fixture will build for `wallet`. Built by
    /// temporarily repointing `buyer`, because the intent's `buyer` field is part of the digest.
    function _ownerSignatureFor(address wallet) internal returns (bytes memory) {
        address previous = buyer;
        buyer = wallet;
        (, PrimaryTypes.SettlementIntent memory intent) = _happyPath();
        bytes memory signature = _signIntentWith(walletOwnerPk, address(router), intent);
        buyer = previous;
        return signature;
    }

    /// A wallet that REVERTS instead of answering. `SignatureChecker` treats a failed staticcall
    /// as "not valid", so the buyer sees this router's named error rather than an undecodable
    /// bubble out of somebody else's contract.
    function test_HostileWallet_ARevertingWalletIsRefused() public {
        address wallet = address(new RevertingWallet());
        bytes memory signature = _ownerSignatureFor(wallet);
        _prepareWallet(wallet);

        vm.expectRevert(IIntentGate.BuyerConsentBadSignature.selector);
        _settleAsWallet(signature);

        assertEq(currency.balanceOf(address(venue)), 0, "the venue was paid without consent");
    }

    /// A wallet that answers with a well-formed `bytes4` that is not the magic value.
    function test_HostileWallet_AWrongMagicValueIsRefused() public {
        address wallet = address(new GarbageWallet());
        bytes memory signature = _ownerSignatureFor(wallet);
        _prepareWallet(wallet);

        vm.expectRevert(IIntentGate.BuyerConsentBadSignature.selector);
        _settleAsWallet(signature);
    }

    /// 🔴 A wallet that answers with a NON-ZERO word which is not the magic value. This is the
    /// one a "did it return something truthy?" check would wave through, and it is the reason
    /// ERC-1271 specifies an exact selector rather than a boolean.
    function test_HostileWallet_ATruthyNonMagicAnswerIsRefused() public {
        address wallet = address(new TruthyWallet());
        bytes memory signature = _ownerSignatureFor(wallet);
        _prepareWallet(wallet);

        vm.expectRevert(IIntentGate.BuyerConsentBadSignature.selector);
        _settleAsWallet(signature);
    }

    /// A wallet whose reply is shorter than one word — the right four bytes and nothing else.
    /// `abi.decode` would revert on it if the length were not checked first, so this pins that
    /// the refusal is the named error rather than a decode failure.
    function test_HostileWallet_AShortReplyIsRefused() public {
        address wallet = address(new ShortReturnWallet());
        bytes memory signature = _ownerSignatureFor(wallet);
        _prepareWallet(wallet);

        vm.expectRevert(IIntentGate.BuyerConsentBadSignature.selector);
        _settleAsWallet(signature);
    }

    /// ⚠️ And the other end of the same fact, stated plainly rather than left implicit: a wallet
    /// that returns the magic value for ANY bytes is accepted, including for a signature nobody
    /// produced. That is where the trust boundary sits — ERC-1271 delegates the verdict to the
    /// buyer's own code, and a buyer whose wallet accepts everything has consented to everything.
    ///
    /// It is not an attack on this router: `intent.buyer` is the account being debited, so such a
    /// wallet can only authorise spending its own allowance. Pinned so that nobody later reads
    /// the four refusals above as "the router validates the wallet".
    function test_HostileWallet_APermissiveWalletIsAcceptedAndThatIsTheTrustBoundary() public {
        address wallet = address(new PermissiveWallet());
        _prepareWallet(wallet);

        _settleAsWallet(hex"00");

        assertTrue(router.usedIntentNonce(wallet, INTENT_NONCE), "the permissive wallet's settlement did not complete");
        assertEq(asset.balanceOf(wallet), ASSET_OUT, "the asset did not reach the wallet");
    }

    /// The honest contract wallet, on the real money path: it consents, it is debited, it
    /// receives the asset. The control the five tests above are measured against.
    function test_HostileWallet_TheHonestWalletStillSettles() public {
        address wallet = address(new ContractWalletBuyer(vm.addr(walletOwnerPk)));
        bytes memory signature = _ownerSignatureFor(wallet);
        _prepareWallet(wallet);

        _settleAsWallet(signature);

        assertEq(asset.balanceOf(wallet), ASSET_OUT, "the honest wallet was not delivered to");
        assertEq(currency.balanceOf(collector), FEE, "the fee was not paid");
    }
}

/// @title PrimarySalesBuyerConsentReplayTest
/// @notice 🔴 The buyer's signature as a captured artefact. It is over the SAME digest the
///         settlement operator signs, which is what makes "could one be used as the other, or
///         one settlement's consent be used for another" the question worth asking.
contract PrimarySalesBuyerConsentReplayTest is VenueSettlerTestBase {
    /// A buyer signature captured from one settlement does not authorise a different one, even
    /// when everything else about the second is valid and the buyer really did sign the first.
    /// The two intents here differ only in nonce, which is the smallest difference there is.
    function test_BuyerConsent_ASignatureCapturedFromOneSettlementDoesNotAuthoriseAnother() public {
        (, PrimaryTypes.SettlementIntent memory first) = _happyPath();
        (bytes memory data, PrimaryTypes.SettlementIntent memory second) = _happyPath();
        second.nonce = INTENT_NONCE + 1;
        bytes32 secondHash = _paramsHash(second);

        AsseteraPrimarySales primary = AsseteraPrimarySales(address(router));
        _approveExact(second);
        vm.prank(buyer);
        vm.expectRevert(IIntentGate.BuyerConsentBadSignature.selector);
        primary.settlePrimary(
            data,
            second,
            _signIntent(address(router), second),
            _signBuyerConsent(address(router), first), // the captured one
            _kyc(address(router), secondHash),
            _fee(address(router), secondHash, 0, TAKER_BPS, collector, address(currency))
        );
    }

    /// 🔴 A buyer signature captured for one PROXY does not authorise the same terms on another,
    /// because the verifying contract is inside the digest the buyer signed. A signature
    /// harvested from a staging router is not a consent on production.
    function test_BuyerConsent_ASignatureForOneProxyDoesNotAuthoriseTheSameTermsOnAnother() public {
        AsseteraPrimarySales impl = new AsseteraPrimarySales(address(forwarder));
        bytes memory initData =
            abi.encodeCall(AsseteraPrimarySales.initialize, (admin, kycSigner, feeSigner, settlementSigner));
        AsseteraPrimarySales twin = AsseteraPrimarySales(address(new ERC1967Proxy(address(impl), initData)));
        vm.prank(admin);
        twin.setAllowedCollector(collector, true);

        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();
        bytes32 paramsHash = _paramsHash(intent);

        _approveExactTo(address(twin), intent);
        vm.prank(buyer);
        vm.expectRevert(IIntentGate.BuyerConsentBadSignature.selector);
        twin.settlePrimary(
            data,
            intent,
            _signIntent(address(twin), intent), // the operator signed for THIS proxy
            _signBuyerConsent(address(router), intent), // the buyer did not
            _kyc(address(twin), paramsHash),
            _fee(address(twin), paramsHash, 0, TAKER_BPS, collector, address(currency))
        );
    }

    /// 🔴 A malleated buyer signature — the same `r`, the complementary `s`, the flipped `v` —
    /// is refused. `ECDSA.tryRecover` rejects the upper half of the curve order, so a captured
    /// consent cannot be reshaped into a second distinct signature over the same digest.
    ///
    /// The intent's nonce already makes a second submission useless, so this is defence in depth
    /// rather than the only line. It is worth pinning because "one digest, two signers" is
    /// exactly the shape where a malleable signature would be tempting to treat as a new one.
    function test_BuyerConsent_AMalleatedSignatureIsRefused() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();
        bytes32 paramsHash = _paramsHash(intent);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(buyerPk, _digest(PRIMARY_DOMAIN_NAME, address(router), paramsHash));
        // secp256k1 group order; `n - s` is the other valid `s` for the same signature.
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 flippedS = bytes32(n - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        bytes memory malleated = abi.encodePacked(r, flippedS, flippedV);

        AsseteraPrimarySales primary = AsseteraPrimarySales(address(router));
        _approveExact(intent);
        vm.prank(buyer);
        vm.expectRevert(IIntentGate.BuyerConsentBadSignature.selector);
        primary.settlePrimary(
            data,
            intent,
            _signIntent(address(router), intent),
            malleated,
            _kyc(address(router), paramsHash),
            _fee(address(router), paramsHash, 0, TAKER_BPS, collector, address(currency))
        );
    }
}

/// @title PrimarySalesMetaTxTest
/// @notice 🔴 ERC-2771. `intent.buyer` must equal `_msgSender()`, and `_msgSender()` reads the
///         last twenty bytes of calldata — but ONLY when the caller is the trusted forwarder.
///         Everything below is about that "only".
///
///         It matters here more than on the exchange, because the buyer's consent signature is
///         what makes `minAssetOut` meaningful and a spoofable sender would let somebody else's
///         consent be spent under a relayed call.
contract PrimarySalesMetaTxTest is VenueSettlerTestBase {
    /// The full settlement payload, as the marketplace API would build it.
    function _settlementCalldata(bytes memory data, PrimaryTypes.SettlementIntent memory intent)
        internal
        view
        returns (bytes memory)
    {
        bytes32 paramsHash = _paramsHash(intent);
        return abi.encodeCall(
            AsseteraPrimarySales.settlePrimary,
            (
                data,
                intent,
                _signIntent(address(router), intent),
                _signBuyerConsent(address(router), intent),
                _kyc(address(router), paramsHash),
                _fee(address(router), paramsHash, 0, TAKER_BPS, collector, address(currency))
            )
        );
    }

    /// A signed forwarder request, built without touching the forwarder beyond reading a nonce.
    ///
    /// `PrimarySalesTestBase._relay` builds and executes in one go, which is right for the happy
    /// path and wrong for the two tests below: `vm.expectRevert` binds to the NEXT call, and the
    /// nonce read inside that helper is a call.
    ///
    /// @param fromPk The key that signs the request.
    /// @param from   The address the request claims to be from. Not necessarily `fromPk`'s.
    /// @param to     The target.
    /// @param data   The calldata to relay.
    function _forwardRequest(uint256 fromPk, address from, address to, bytes memory data)
        internal
        view
        returns (ERC2771Forwarder.ForwardRequestData memory request)
    {
        request = ERC2771Forwarder.ForwardRequestData({
            from: from,
            to: to,
            value: 0,
            gas: 2_000_000,
            deadline: uint48(block.timestamp + 1 hours),
            data: data,
            signature: ""
        });
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)"
                ),
                request.from,
                request.to,
                request.value,
                request.gas,
                forwarder.nonces(from),
                request.deadline,
                keccak256(request.data)
            )
        );
        request.signature = _sign(fromPk, _digest("AsseteraForwarder", address(forwarder), structHash));
    }

    /// 🔴 A DIRECT call whose last twenty bytes spell the buyer's address. `_msgSender()` ignores
    /// the suffix because `msg.sender` is not the trusted forwarder, so the actor is the
    /// stranger who sent it and the intent is refused.
    ///
    /// This is the calldata-shaped attack the ERC-2771 suffix invites, and the answer is that the
    /// suffix is only ever read from an address the constructor pinned.
    function test_MetaTx_AppendedSenderBytesOnADirectCallAreIgnored() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();
        bytes memory spoofed = abi.encodePacked(_settlementCalldata(data, intent), buyer);

        _approveExact(intent);
        vm.prank(stranger);
        (bool ok, bytes memory ret) = address(router).call(spoofed);

        assertFalse(ok, "a direct call spoofed the buyer through appended calldata");
        assertEq(bytes4(ret), IIntentGate.IntentBuyerMismatch.selector, "refused for the wrong reason");
        assertFalse(router.usedIntentNonce(buyer, INTENT_NONCE), "the buyer's intent was consumed by a stranger");
        assertEq(currency.balanceOf(address(venue)), 0, "the venue was paid on a spoofed call");
    }

    /// The mutation: the same payload, sent directly by the buyer with NO suffix, settles. What
    /// separates the two is who sent it, which is the whole claim.
    function test_MetaTx_TheSamePayloadFromTheBuyerDirectlySettles() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();
        bytes memory payload = _settlementCalldata(data, intent);

        _approveExact(intent);
        vm.prank(buyer);
        (bool ok,) = address(router).call(payload);

        assertTrue(ok, "the control settlement did not land");
        assertEq(asset.balanceOf(buyer), ASSET_OUT, "the asset was not delivered");
    }

    /// 🔴 Through the trusted forwarder, with the appended bytes manipulated the only way an
    /// attacker actually can: by putting the victim's address at the end of the RELAYED data and
    /// signing the request as themselves. The forwarder appends `request.from` after that data,
    /// so the attacker's own address is what `_msgSender()` reads and the settlement is refused.
    ///
    /// `Errors.FailedCall` rather than the router's own error because `ERC2771Forwarder.execute`
    /// does not bubble the target's revert data; the state assertions are what say WHICH failure
    /// it was.
    function test_MetaTx_ARelayedCallCannotSpoofTheBuyerThroughTheRelayedData() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();
        // The attacker's relayed data ends with the buyer's address. The forwarder appends its
        // own verified `from` after it, so the last twenty bytes are the ATTACKER's.
        bytes memory spoofed = abi.encodePacked(_settlementCalldata(data, intent), buyer);

        _approveExact(intent);
        // The request is built here rather than through `_relay`, because that helper reads the
        // forwarder's nonce — a call, which `vm.expectRevert` would bind to instead.
        ERC2771Forwarder.ForwardRequestData memory request =
            _forwardRequest(uint256(0xDECAF), vm.addr(0xDECAF), address(router), spoofed);

        vm.prank(relayer);
        vm.expectRevert(Errors.FailedCall.selector);
        forwarder.execute(request);

        assertFalse(router.usedIntentNonce(buyer, INTENT_NONCE), "the buyer's intent was consumed by a relayed spoof");
        assertEq(currency.balanceOf(address(venue)), 0, "the venue was paid on a spoofed relay");
    }

    /// 🔴 The relayed happy path on the real money path: the relayer pays the gas, the BUYER is
    /// debited and delivered to, and the buyer holds no native currency at any point. Without
    /// this, primary sales would be the one flow in the product that needs the buyer to hold gas.
    function test_MetaTx_ARelayedSettlementDebitsTheBuyerAndNotTheRelayer() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();
        uint256 buyerBefore = currency.balanceOf(buyer);

        _approveExact(intent);
        vm.deal(buyer, 0);
        _relay(buyerPk, buyer, address(router), _settlementCalldata(data, intent));

        assertEq(currency.balanceOf(buyer), buyerBefore - QUOTE - FEE, "the buyer was not debited");
        assertEq(asset.balanceOf(buyer), ASSET_OUT, "the asset did not reach the buyer");
        assertEq(asset.balanceOf(relayer), 0, "the relayer received the asset");
        assertEq(buyer.balance, 0, "the buyer paid gas");
    }

    /// The forwarder itself is the trust anchor, and it only ever appends the address whose
    /// signature it verified. A request claiming to be from the buyer but signed by somebody
    /// else never reaches the router at all.
    function test_MetaTx_TheForwarderRefusesARequestSignedByAnyoneButTheClaimedSender() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();
        bytes memory payload = _settlementCalldata(data, intent);

        _approveExact(intent);
        // Signed by a stranger while claiming to be the buyer.
        ERC2771Forwarder.ForwardRequestData memory request = _forwardRequest(0xDECAF, buyer, address(router), payload);

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(ERC2771Forwarder.ERC2771ForwarderInvalidSigner.selector, vm.addr(0xDECAF), buyer)
        );
        forwarder.execute(request);

        assertFalse(router.usedIntentNonce(buyer, INTENT_NONCE), "the settlement ran on a forged request");
    }
}
