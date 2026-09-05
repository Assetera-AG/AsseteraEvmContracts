// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AsseteraPrimarySales} from "../../src/primary/AsseteraPrimarySales.sol";
import {PrimaryTypes} from "../../src/primary/types/PrimaryTypes.sol";
import {IIntentGate} from "../../src/primary/interfaces/IIntentGate.sol";
import {IKycGate} from "../../src/interfaces/IKycGate.sol";
import {IAsseteraECS} from "../../src/interfaces/IAsseteraECS.sol";
import {IFeeGate} from "../../src/interfaces/IFeeGate.sol";
import {ISettler} from "../../src/primary/interfaces/ISettler.sol";
import {GateTypes} from "../../src/types/GateTypes.sol";
import {PrimarySalesHarness} from "./mocks/PrimarySalesHarness.sol";
import {PrimarySalesTestBase} from "./PrimarySalesTestBase.sol";

/// @title PrimaryRedemptionTest
/// @notice AO-847: everything `redeemPrimary` does BEFORE the money, and everything it does
///         after the seam. The mirror of the gate half of `AsseteraPrimarySales.t.sol`.
///
///         Two fixtures, for the reason the buy suites give. Against `sales` the settlement
///         currency has no cap, so a well-formed redemption stops on the shared preamble's last
///         line with `PerTxCapExceeded` — the marker meaning "every signature and both
///         attestations passed". Against `harness` the seam is stubbed, so the nonce burns and
///         `PrimaryRedeemed` can be observed without a token moving.
contract PrimaryRedemptionTest is PrimarySalesTestBase {
    // -- the happy shape -------------------------------------------------------------------

    /// A well-formed redemption passes every gate and reaches the money path.
    function test_Redeem_ReachesTheMoneyPath() public {
        _expectRedemptionReachesTheMoneyPath();
        _redeem(sales);
    }

    /// 🔴 The cap is charged on `venueQuoteOut`, the GROSS proceeds, and the marker error carries
    /// the amount — so this also proves the fee does not shave a redemption under its cap.
    function test_Redeem_ChargesTheCapOnTheGrossQuoteNotTheNet() public {
        _expectRedemptionReachesTheMoneyPath(); // the amount in the error is QUOTE_OUT alone
        _redeem(sales);
    }

    /// The event maps the settler's four measured numbers onto the frozen field list, and carries
    /// the identifiers the settlement operator signed.
    function test_Redeem_EmitsPrimaryRedeemed() public {
        vm.expectEmit(true, true, true, true, address(harness));
        emit ISettler.PrimaryRedeemed(
            buyer,
            ASSET,
            VENUE,
            harness.STUB_ASSET_IN(),
            CURRENCY,
            harness.STUB_VENUE_OUT(),
            harness.STUB_ASSET_REFUND(),
            harness.STUB_SELLER_FEE(),
            collector,
            SUPPLIER_REF,
            INTENT_NONCE
        );
        _redeem(AsseteraPrimarySales(address(harness)));
    }

    /// `IntentConsumed` carries the action ordinal, which is what lets the indexer tell a sell
    /// back from a purchase when it joins the two events on `(party, nonce)`.
    function test_Redeem_BurnsTheIntentNonceUnderTheRedeemOrdinal() public {
        vm.expectEmit(true, true, true, true, address(harness));
        emit IIntentGate.IntentConsumed(buyer, uint8(PrimaryTypes.Action.RedeemVenue), INTENT_NONCE);
        _redeem(AsseteraPrimarySales(address(harness)));

        assertTrue(harness.usedIntentNonce(buyer, INTENT_NONCE), "the nonce is spent");
    }

    /// All three nonce namespaces are burned, as on the buy leg.
    function test_Redeem_BurnsAllThreeNonces() public {
        _redeem(AsseteraPrimarySales(address(harness)));

        assertTrue(harness.usedIntentNonce(buyer, INTENT_NONCE), "intent");
        assertTrue(harness.usedNonce(buyer, KYC_NONCE), "kyc");
        assertTrue(harness.usedFeeNonce(buyer, FEE_NONCE), "fee");
    }

    // -- the nonce namespace is SHARED with the buy leg -------------------------------------

    /// A redemption nonce is single use.
    function test_Redeem_RevertsOnNonceReuse() public {
        _redeem(AsseteraPrimarySales(address(harness)));

        PrimaryTypes.RedemptionIntent memory intent = _redemption();
        bytes32 paramsHash = _paramsHash(intent);
        vm.prank(buyer);
        vm.expectRevert(IIntentGate.IntentNonceUsed.selector);
        harness.redeemPrimary(
            VENUE_CALLDATA,
            intent,
            _signRedemption(address(harness), intent),
            _signSellerConsent(address(harness), intent),
            _kycRedeem(address(harness), paramsHash),
            _feeRedeem(address(harness), paramsHash)
        );
    }

    /// 🔴 And it is the SAME namespace the buy leg uses. Sharing it is what let this leg land
    /// with no new storage, and the consequence — one number cannot serve both legs for one
    /// account — is a constraint on the signer service, so it is pinned here rather than left to
    /// be discovered.
    function test_Redeem_SharesTheIntentNonceNamespaceWithTheBuyLeg() public {
        _settle(AsseteraPrimarySales(address(harness))); // burns INTENT_NONCE as a purchase

        PrimaryTypes.RedemptionIntent memory intent = _redemption();
        bytes32 paramsHash = _paramsHash(intent);
        vm.prank(buyer);
        vm.expectRevert(IIntentGate.IntentNonceUsed.selector);
        harness.redeemPrimary(
            VENUE_CALLDATA,
            intent,
            _signRedemption(address(harness), intent),
            _signSellerConsent(address(harness), intent),
            _kycRedeem(address(harness), paramsHash),
            _feeRedeem(address(harness), paramsHash)
        );
    }

    // -- who may submit, and who must consent ----------------------------------------------

    /// The seller is the actor. Nobody redeems on somebody else's behalf.
    function test_Redeem_RevertsWhenTheSubmitterIsNotTheSeller() public {
        PrimaryTypes.RedemptionIntent memory intent = _redemption();
        bytes32 paramsHash = _paramsHash(intent);
        vm.prank(stranger);
        vm.expectRevert(IIntentGate.IntentSellerMismatch.selector);
        sales.redeemPrimary(
            VENUE_CALLDATA,
            intent,
            _signRedemption(address(sales), intent),
            _signSellerConsent(address(sales), intent),
            _kycRedeem(address(sales), paramsHash),
            _feeRedeem(address(sales), paramsHash)
        );
    }

    /// 🔴 The seller's own consent to these exact terms. Without it a compromised settlement
    /// operator sets `minSettlementOut` to one wei and sells the holding for nothing.
    function test_Redeem_RevertsWithoutTheSellersConsent() public {
        PrimaryTypes.RedemptionIntent memory intent = _redemption();
        bytes32 paramsHash = _paramsHash(intent);
        vm.prank(buyer);
        vm.expectRevert(IIntentGate.SellerConsentBadSignature.selector);
        sales.redeemPrimary(
            VENUE_CALLDATA,
            intent,
            _signRedemption(address(sales), intent),
            // the OPERATOR's signature offered as the seller's: a valid signature by the wrong
            // party, which is the case a length check would not catch
            _signRedemption(address(sales), intent),
            _kycRedeem(address(sales), paramsHash),
            _feeRedeem(address(sales), paramsHash)
        );
    }

    /// The operator signature must recover to a `SETTLEMENT_OPERATOR_ROLE` holder.
    function test_Redeem_RevertsWhenTheIntentSignerHasNoRole() public {
        PrimaryTypes.RedemptionIntent memory intent = _redemption();
        bytes32 paramsHash = _paramsHash(intent);
        vm.prank(buyer);
        vm.expectRevert(IIntentGate.IntentBadSigner.selector);
        sales.redeemPrimary(
            VENUE_CALLDATA,
            intent,
            _signRedemptionWith(buyerPk, address(sales), intent),
            _signSellerConsent(address(sales), intent),
            _kycRedeem(address(sales), paramsHash),
            _feeRedeem(address(sales), paramsHash)
        );
    }

    // -- the calldata binding ---------------------------------------------------------------

    /// The opaque bytes are bound by hash. Handing the venue anything else is refused.
    function test_Redeem_RevertsOnACalldataHashMismatch() public {
        PrimaryTypes.RedemptionIntent memory intent = _redemption();
        bytes32 paramsHash = _paramsHash(intent);
        bytes memory tampered = hex"a9059cbb0000000000000000000000000000000000000000000000000000000000000002";
        vm.prank(buyer);
        vm.expectRevert(IIntentGate.CalldataHashMismatch.selector);
        sales.redeemPrimary(
            tampered,
            intent,
            _signRedemption(address(sales), intent),
            _signSellerConsent(address(sales), intent),
            _kycRedeem(address(sales), paramsHash),
            _feeRedeem(address(sales), paramsHash)
        );
    }

    /// And by selector, which is the human-readable half of the same binding.
    function test_Redeem_RevertsOnASelectorMismatch() public {
        PrimaryTypes.RedemptionIntent memory intent = _redemption();
        intent.selector = 0x11111111;
        bytes32 paramsHash = _paramsHash(intent);
        vm.prank(buyer);
        vm.expectRevert(IIntentGate.SelectorMismatch.selector);
        sales.redeemPrimary(
            VENUE_CALLDATA,
            intent,
            _signRedemption(address(sales), intent),
            _signSellerConsent(address(sales), intent),
            _kycRedeem(address(sales), paramsHash),
            _feeRedeem(address(sales), paramsHash)
        );
    }

    // -- the attestations -------------------------------------------------------------------

    /// 🔴 An attestation minted for the BUY ordinal cannot be spent on a redemption. The ordinal
    /// is what the compliance signer signs, and this is what makes it mean something: a customer
    /// screened for a purchase has not thereby been screened for a sale.
    function test_Redeem_RejectsAKycAttestationForTheBuyOrdinal() public {
        PrimaryTypes.RedemptionIntent memory intent = _redemption();
        bytes32 paramsHash = _paramsHash(intent);
        vm.prank(buyer);
        vm.expectRevert(IKycGate.KycActionMismatch.selector);
        sales.redeemPrimary(
            VENUE_CALLDATA,
            intent,
            _signRedemption(address(sales), intent),
            _signSellerConsent(address(sales), intent),
            _kycForAction(uint8(PrimaryTypes.Action.SettleVenue), PRIMARY_DOMAIN_NAME, address(sales), 0, paramsHash),
            _feeRedeem(address(sales), paramsHash)
        );
    }

    /// The same for the fee attestation.
    function test_Redeem_RejectsAFeeAttestationForTheBuyOrdinal() public {
        PrimaryTypes.RedemptionIntent memory intent = _redemption();
        bytes32 paramsHash = _paramsHash(intent);
        vm.prank(buyer);
        vm.expectRevert(IFeeGate.FeeActionMismatch.selector);
        sales.redeemPrimary(
            VENUE_CALLDATA,
            intent,
            _signRedemption(address(sales), intent),
            _signSellerConsent(address(sales), intent),
            _kycRedeem(address(sales), paramsHash),
            _feeForAction(
                uint8(PrimaryTypes.Action.SettleVenue), address(sales), paramsHash, 0, 50, collector, CURRENCY
            )
        );
    }

    /// Both attestations are pinned to the redemption's own struct hash. An attestation bound to
    /// the equivalent PURCHASE cannot be spent here, because the two struct hashes differ.
    function test_Redeem_RejectsAParamsHashFromTheBuyPayload() public {
        PrimaryTypes.RedemptionIntent memory intent = _redemption();
        bytes32 buyHash = _paramsHash(_intent());
        vm.prank(buyer);
        vm.expectRevert(IAsseteraECS.ParamsHashMismatch.selector);
        sales.redeemPrimary(
            VENUE_CALLDATA,
            intent,
            _signRedemption(address(sales), intent),
            _signSellerConsent(address(sales), intent),
            _kycRedeem(address(sales), buyHash),
            _feeRedeem(address(sales), buyHash)
        );
    }

    /// 🔴 A non-zero maker fee is refused BEFORE the collector checks, so the revert names the
    /// actual defect — this family cannot charge an issuer-side fee at all — rather than a
    /// consequence of it. Pinned because this is exactly the line a later tidy-up reorders.
    function test_Redeem_RejectsANonZeroMakerFeeBeforeTheCollectorChecks() public {
        PrimaryTypes.RedemptionIntent memory intent = _redemption();
        intent.feeCollector = stranger; // an unlisted collector, which would otherwise revert first
        bytes32 paramsHash = _paramsHash(intent);
        vm.prank(buyer);
        vm.expectRevert(IIntentGate.MakerFeeNotSupported.selector);
        sales.redeemPrimary(
            VENUE_CALLDATA,
            intent,
            _signRedemption(address(sales), intent),
            _signSellerConsent(address(sales), intent),
            _kycRedeem(address(sales), paramsHash),
            _feeForAction(
                uint8(PrimaryTypes.Action.RedeemVenue), address(sales), paramsHash, 10, 50, stranger, CURRENCY
            )
        );
    }

    /// The collector must be on this router's own allowlist.
    function test_Redeem_RejectsAnUnlistedCollector() public {
        PrimaryTypes.RedemptionIntent memory intent = _redemption();
        intent.feeCollector = stranger;
        bytes32 paramsHash = _paramsHash(intent);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IFeeGate.FeeCollectorNotAllowed.selector, stranger));
        sales.redeemPrimary(
            VENUE_CALLDATA,
            intent,
            _signRedemption(address(sales), intent),
            _signSellerConsent(address(sales), intent),
            _kycRedeem(address(sales), paramsHash),
            _feeForAction(uint8(PrimaryTypes.Action.RedeemVenue), address(sales), paramsHash, 0, 50, stranger, CURRENCY)
        );
    }

    // -- TTL, pause, and the amount relations ------------------------------------------------

    function test_Redeem_RevertsAfterTheDeadline() public {
        PrimaryTypes.RedemptionIntent memory intent = _redemption();
        bytes32 paramsHash = _paramsHash(intent);
        bytes memory operatorSig = _signRedemption(address(sales), intent);
        bytes memory sellerSig = _signSellerConsent(address(sales), intent);
        GateTypes.KycAttestation memory kyc = _kycRedeem(address(sales), paramsHash);
        GateTypes.FeeAttestation memory fee = _feeRedeem(address(sales), paramsHash);

        vm.warp(intent.deadline + 1);
        vm.prank(buyer);
        vm.expectRevert(IIntentGate.IntentExpired.selector);
        sales.redeemPrimary(VENUE_CALLDATA, intent, operatorSig, sellerSig, kyc, fee);
    }

    /// The TTL cap binds even a signature a real operator produced. A long-lived intent is a
    /// long-lived authorisation to sell somebody's holding.
    function test_Redeem_RevertsWhenTheTtlIsTooLong() public {
        PrimaryTypes.RedemptionIntent memory intent = _redemption();
        intent.deadline = block.timestamp + sales.MAX_INTENT_TTL() + 1;
        bytes32 paramsHash = _paramsHash(intent);
        vm.prank(buyer);
        vm.expectRevert(IIntentGate.IntentTtlTooLong.selector);
        sales.redeemPrimary(
            VENUE_CALLDATA,
            intent,
            _signRedemption(address(sales), intent),
            _signSellerConsent(address(sales), intent),
            _kycRedeem(address(sales), paramsHash),
            _feeRedeem(address(sales), paramsHash)
        );
    }

    /// The pause lever stops both legs, and it is this router's own.
    function test_Redeem_RevertsWhenPaused() public {
        vm.prank(admin);
        sales.pause();

        PrimaryTypes.RedemptionIntent memory intent = _redemption();
        bytes32 paramsHash = _paramsHash(intent);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        sales.redeemPrimary(
            VENUE_CALLDATA,
            intent,
            _signRedemption(address(sales), intent),
            _signSellerConsent(address(sales), intent),
            _kycRedeem(address(sales), paramsHash),
            _feeRedeem(address(sales), paramsHash)
        );
    }

    /// Every amount relation the gate enforces, one intent at a time. Each is checked before a
    /// signature is recovered, so a malformed request costs nothing to refuse.
    function test_Redeem_AmountRelations() public {
        PrimaryTypes.RedemptionIntent memory m;

        m = _redemption();
        m.maxAssetIn = 0;
        _expectRedemptionRevert(m, IIntentGate.ZeroAmount.selector);

        m = _redemption();
        m.venueQuoteOut = 0;
        _expectRedemptionRevert(m, IIntentGate.ZeroRedemptionQuote.selector);

        // 🔴 A zero floor would make the proceeds assertion vacuous: a venue could take the asset
        //    and pay nothing. The mirror of the buy leg's refusal of a zero `minAssetOut`.
        m = _redemption();
        m.minSettlementOut = 0;
        _expectRedemptionRevert(m, IIntentGate.ZeroAmount.selector);

        m = _redemption();
        m.sellerFee = m.venueQuoteOut + 1;
        _expectRedemptionRevert(m, IIntentGate.SellerFeeExceedsProceeds.selector);

        m = _redemption();
        m.minSettlementOut = m.venueQuoteOut - m.sellerFee + 1;
        _expectRedemptionRevert(m, IIntentGate.MinSettlementTooHigh.selector);

        m = _redemption();
        m.settlementToken = m.assetToken;
        _expectRedemptionRevert(m, IIntentGate.SameToken.selector);

        m = _redemption();
        m.venue = address(0);
        _expectRedemptionRevert(m, IAsseteraECS.ZeroAddress.selector);

        m = _redemption();
        m.assetToken = address(0);
        _expectRedemptionRevert(m, IAsseteraECS.ZeroAddress.selector);
    }

    /// The floor may equal the quote net of the fee exactly. The boundary is inclusive, which is
    /// what makes "sell at the quote" expressible rather than one raw unit short of it.
    function test_Redeem_TheTightestFloorIsAccepted() public {
        PrimaryTypes.RedemptionIntent memory intent = _redemption();
        intent.minSettlementOut = intent.venueQuoteOut - intent.sellerFee;
        bytes32 paramsHash = _paramsHash(intent);
        _expectRedemptionReachesTheMoneyPath();
        vm.prank(buyer);
        sales.redeemPrimary(
            VENUE_CALLDATA,
            intent,
            _signRedemption(address(sales), intent),
            _signSellerConsent(address(sales), intent),
            _kycRedeem(address(sales), paramsHash),
            _feeRedeem(address(sales), paramsHash)
        );
    }

    /// A redemption assembled for one proxy is refused by another: the verifying contract is part
    /// of every digest, so an intent signed for `harness` cannot be replayed against `sales`.
    function test_Redeem_CannotBeReplayedAgainstAnotherProxy() public {
        PrimaryTypes.RedemptionIntent memory intent = _redemption();
        bytes32 paramsHash = _paramsHash(intent);
        vm.prank(buyer);
        vm.expectRevert(IIntentGate.IntentBadSigner.selector);
        sales.redeemPrimary(
            VENUE_CALLDATA,
            intent,
            _signRedemption(address(harness), intent),
            _signSellerConsent(address(harness), intent),
            _kycRedeem(address(harness), paramsHash),
            _feeRedeem(address(harness), paramsHash)
        );
    }

    // -- helper -----------------------------------------------------------------------------

    function _expectRedemptionRevert(PrimaryTypes.RedemptionIntent memory intent, bytes4 selector) private {
        bytes32 paramsHash = _paramsHash(intent);
        bytes memory operatorSig = _signRedemption(address(sales), intent);
        bytes memory sellerSig = _signSellerConsent(address(sales), intent);
        GateTypes.KycAttestation memory kyc = _kycRedeem(address(sales), paramsHash);
        GateTypes.FeeAttestation memory fee = _feeRedeem(address(sales), paramsHash);

        vm.prank(buyer);
        vm.expectRevert(selector);
        sales.redeemPrimary(VENUE_CALLDATA, intent, operatorSig, sellerSig, kyc, fee);
    }
}
