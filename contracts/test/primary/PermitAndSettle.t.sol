// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {AsseteraPrimarySales} from "../../src/primary/AsseteraPrimarySales.sol";
import {PermitRelay} from "../../src/core/PermitRelay.sol";
import {PrimaryTypes} from "../../src/primary/types/PrimaryTypes.sol";
import {IIntentGate} from "../../src/primary/interfaces/IIntentGate.sol";
import {ISettler} from "../../src/primary/interfaces/ISettler.sol";
import {DinariLikeVenue} from "../mocks/DinariLikeVenue.sol";
import {DivergentDomainToken} from "../mocks/DivergentDomainToken.sol";
import {ReentrantToken} from "../mocks/ReentrantToken.sol";
import {VenueSettlerTestBase} from "./VenueSettlerTestBase.sol";

/// @title PermitAndSettleTest
/// @notice A primary purchase in ONE transaction (AO-713): the buyer's ERC-2612 `permit` and the
///         settlement it pays for, submitted together through the inherited
///         `PermitRelay.permitAndCall`.
///
///         These mirror `AsseteraECS.t.sol`'s `permitAndCall` block onto the primary path,
///         because the two proxies now share one implementation of it and a claim proved on the
///         exchange alone would say nothing about the router. What differs is the inner call
///         (`settlePrimary` rather than a fill) and one fact the exchange has no equivalent of:
///         `IntentGate` requires `intent.buyer == _msgSender()`, so the permit `owner`, the
///         caller and the party debited are structurally the same address.
///
///         The saving is not mainly gas. An `approve` takes 15-30 seconds to mine and a firm
///         venue quote is not good for that long, so the storefront had to keep the approval off
///         the quote's clock and confirm in two phases. A permit is a signature.
///
/// @dev    Built on `VenueSettlerTestBase`, so the settlement these drive is the REAL money path
///         against a Dinari-shaped venue — the same fixture `VenueSettler.t.sol` shows working —
///         rather than a settlement stopped at a seam.
contract PermitAndSettleTest is VenueSettlerTestBase {
    /// The venue's asset delivery, for the alternate-currency settlements below. The 18-decimal
    /// quote keeps 50 bps dividing exactly, as `QUOTE`/`FEE` do at six decimals.
    uint256 internal constant ALT_QUOTE = 1_000e18;
    uint256 internal constant ALT_FEE = 5e18;

    // ── permit signing ────────────────────────────────────────────────────────────────────

    /// Sign an ERC-2612 permit against the domain separator the token itself reports, for
    /// `address(router)` as spender. This is the correct client behaviour;
    /// `_signPermitAgainstName` below is the naive one.
    function _permitSig(address token, uint256 ownerPk, address owner, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        return _permitSigWithDomain(token, ownerPk, owner, value, deadline, IERC20Permit(token).DOMAIN_SEPARATOR());
    }

    /// Sign a permit against a domain separator built from an arbitrary name — how a client that
    /// assumes `domain.name == token.name()` behaves. Correct for the faucet tokens, wrong for
    /// EUROP.
    function _signPermitAgainstName(
        address token,
        uint256 ownerPk,
        address owner,
        uint256 value,
        uint256 deadline,
        string memory domainName
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        return _permitSigWithDomain(token, ownerPk, owner, value, deadline, _domainSeparator(domainName, token));
    }

    function _permitSigWithDomain(
        address token,
        uint256 ownerPk,
        address owner,
        uint256 value,
        uint256 deadline,
        bytes32 domainSeparator
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                address(router),
                value,
                IERC20Permit(token).nonces(owner),
                deadline
            )
        );
        (v, r, s) = vm.sign(ownerPk, keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash)));
    }

    // ── fixtures for a settlement in a currency other than the base's `currency` ───────────

    /// The opaque venue bytes, with the payment token as a parameter so a settlement can be
    /// driven in a token that is not the base fixture's `currency`.
    function _venueCalldataIn(address paymentToken, uint256 paymentAmount, uint256 assetAmount)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(
            DinariLikeVenue.requestOrder,
            (DinariLikeVenue.Order({
                    paymentToken: paymentToken,
                    paymentAmount: paymentAmount,
                    assetToken: address(asset),
                    assetAmount: assetAmount,
                    recipient: buyer
                }))
        );
    }

    /// The matching intent. `settlementToken` is the same token the venue is told to pull, which
    /// is what `VenueSettler` measures the deltas on.
    function _intentIn(address settlementToken, bytes memory venueCalldata, uint256 quote, uint256 buyerFee)
        internal
        view
        returns (PrimaryTypes.SettlementIntent memory)
    {
        return PrimaryTypes.SettlementIntent({
            buyer: buyer,
            assetToken: address(asset),
            accountingMode: uint8(PrimaryTypes.AssetAccountingMode.Erc20Balance),
            minAssetOut: MIN_OUT,
            settlementToken: settlementToken,
            venueQuoteIn: quote,
            buyerFee: buyerFee,
            maxSettlementIn: quote + buyerFee,
            feeCollector: collector,
            venue: address(venue),
            selector: DinariLikeVenue.requestOrder.selector,
            calldataHash: keccak256(venueCalldata),
            supplierReference: SUPPLIER_REF,
            nonce: INTENT_NONCE,
            deadline: block.timestamp + 3 minutes
        });
    }

    /// The `settlePrimary` call the relay delegates into, assembled for `router` with the fee
    /// attested in the settlement currency (the only denomination this path accepts).
    function _inner(bytes memory data, PrimaryTypes.SettlementIntent memory intent)
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
                _fee(address(router), paramsHash, 0, TAKER_BPS, collector, intent.settlementToken)
            )
        );
    }

    // ── the one-transaction purchase ──────────────────────────────────────────────────────

    /// 🔴 The whole point: no `approve` was ever sent, and the purchase settles. The permit and
    /// the settlement are one transaction, so the buyer's confirm is one signature and one send.
    function test_PermitAndSettle_SettlesWithNoPriorAllowance() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(address(currency), buyerPk, buyer, QUOTE + FEE, deadline);
        uint256 buyerCurrencyBefore = currency.balanceOf(buyer);

        assertEq(currency.allowance(buyer, address(router)), 0, "starts with no allowance");

        vm.prank(buyer);
        (bool permitAccepted,) = AsseteraPrimarySales(address(router))
            .permitAndCall(address(currency), QUOTE + FEE, deadline, v, r, s, _inner(data, intent));

        assertTrue(permitAccepted, "the token did not accept the permit");
        assertEq(currency.balanceOf(buyer), buyerCurrencyBefore - QUOTE - FEE, "buyer debited the quote plus the fee");
        assertEq(currency.balanceOf(address(venue)), QUOTE, "venue took the quote");
        assertEq(currency.balanceOf(collector), FEE, "collector took the fee");
        assertEq(asset.balanceOf(buyer), ASSET_OUT, "asset delivered to the buyer");
        assertTrue(router.usedIntentNonce(buyer, INTENT_NONCE), "the intent was not consumed");
    }

    /// The permit grants exactly one settlement's worth and the settlement spends it to zero, so
    /// the one-transaction path leaves the router with no standing allowance either. That the
    /// buyer's grant is exact and short-lived is the ceiling on a compromised settlement signer,
    /// and a permit must not quietly turn it into a standing one.
    function test_PermitAndSettle_LeavesNoStandingAllowance() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(address(currency), buyerPk, buyer, QUOTE + FEE, deadline);

        vm.prank(buyer);
        AsseteraPrimarySales(address(router))
            .permitAndCall(address(currency), QUOTE + FEE, deadline, v, r, s, _inner(data, intent));

        assertEq(currency.allowance(buyer, address(router)), 0, "the permit allowance outlived the settlement");
    }

    /// The event the indexer decodes is emitted by the router, from inside the `delegatecall`,
    /// exactly as it is on the two-transaction path. A settlement reached through the relay must
    /// be indistinguishable downstream.
    function test_PermitAndSettle_EmitsPrimarySettledFromTheRouter() public {
        bytes memory data = _venueCalldata(900e6, ASSET_OUT);
        PrimaryTypes.SettlementIntent memory intent = _venueIntent(data, QUOTE, FEE, collector);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(address(currency), buyerPk, buyer, QUOTE + FEE, deadline);

        vm.expectEmit(true, true, true, true, address(router));
        emit ISettler.PrimarySettled(
            buyer,
            address(asset),
            address(venue),
            ASSET_OUT,
            address(currency),
            900e6,
            QUOTE - 900e6,
            FEE,
            collector,
            SUPPLIER_REF,
            INTENT_NONCE
        );
        vm.prank(buyer);
        AsseteraPrimarySales(address(router))
            .permitAndCall(address(currency), QUOTE + FEE, deadline, v, r, s, _inner(data, intent));
    }

    // ── identity, through the relayer and against redirection ─────────────────────────────

    /// 🔴 The ERC-2771 sender suffix survives the self-`delegatecall`, so `IntentGate`'s
    /// `intent.buyer == _msgSender()` still resolves the BUYER and not the forwarder. Without
    /// this the gasless primary sale and the one-transaction primary sale would be mutually
    /// exclusive.
    function test_PermitAndSettle_Relayed_IdentityIsTheBuyerNotTheRelayer() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(address(currency), buyerPk, buyer, QUOTE + FEE, deadline);
        uint256 buyerCurrencyBefore = currency.balanceOf(buyer);

        bytes memory outer = abi.encodeCall(
            PermitRelay.permitAndCall, (address(currency), QUOTE + FEE, deadline, v, r, s, _inner(data, intent))
        );

        vm.deal(buyer, 0); // no ETH: the relayer pays
        _relay(buyerPk, buyer, address(router), outer);

        // The permit owner AND the settlement's buyer were both resolved as the buyer, not as
        // the forwarder and not as the relayer.
        assertEq(currency.balanceOf(buyer), buyerCurrencyBefore - QUOTE - FEE, "the buyer was not debited");
        assertEq(asset.balanceOf(buyer), ASSET_OUT, "the asset did not reach the buyer");
        assertEq(asset.balanceOf(relayer), 0, "the relayer received the asset");
        assertEq(buyer.balance, 0, "the buyer paid gas");
    }

    /// A permit signed by the buyer cannot be redirected by a third party into a settlement they
    /// submit. `_tryPermit` names `_msgSender()` as the owner, so a stranger's call presents the
    /// stranger's own permit, which does not recover — and `IntentGate` then refuses the
    /// settlement outright because the caller is not the buyer.
    function test_PermitAndSettle_AStrangerCannotCarryTheBuyersPermit() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(address(currency), buyerPk, buyer, QUOTE + FEE, deadline);

        vm.prank(stranger);
        vm.expectRevert(IIntentGate.IntentBuyerMismatch.selector);
        AsseteraPrimarySales(address(router))
            .permitAndCall(address(currency), QUOTE + FEE, deadline, v, r, s, _inner(data, intent));

        assertEq(currency.allowance(buyer, address(router)), 0, "the buyer's permit was redirected");
        assertFalse(router.usedIntentNonce(buyer, INTENT_NONCE), "the buyer's intent was consumed by a stranger");
    }

    /// The self-`delegatecall` must not lend the caller the router's own authority. The admin
    /// surface checks roles against the same `_msgSender()` the relay preserves.
    function test_PermitAndSettle_CannotReachAdminFunctionsWithoutTheRole() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(address(currency), buyerPk, buyer, 1, deadline);
        // Read before the prank: an argument evaluated inside `vm.expectRevert(...)` is a call,
        // and it would be the one the prank landed on.
        bytes32 adminRole = router.DEFAULT_ADMIN_ROLE();

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", buyer, adminRole));
        AsseteraPrimarySales(address(router))
            .permitAndCall(
                address(currency),
                1,
                deadline,
                v,
                r,
                s,
                abi.encodeCall(AsseteraPrimarySales.setAllowedCollector, (stranger, true))
            );
    }

    // ── the fallback path: the permit does not land ───────────────────────────────────────

    /// 🔴 A settlement currency with no ERC-2612 at all. `_tryPermit` swallows the failure and
    /// the settlement runs on the allowance the buyer set the old way, so adding the relay
    /// cannot take a currency away from the router.
    function test_PermitAndSettle_TokenWithoutErc2612_FallsBackToAllowance() public {
        ReentrantToken plain = new ReentrantToken(); // never armed: a plain ERC-20, no permit
        plain.mint(buyer, 10_000e18);

        bytes memory data = _venueCalldataIn(address(plain), ALT_QUOTE, ASSET_OUT);
        PrimaryTypes.SettlementIntent memory intent = _intentIn(address(plain), data, ALT_QUOTE, ALT_FEE);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(buyerPk, keccak256("not a permit this token understands"));

        vm.startPrank(buyer);
        plain.approve(address(router), ALT_QUOTE + ALT_FEE); // the old two-transaction way
        (bool permitAccepted,) = AsseteraPrimarySales(address(router))
            .permitAndCall(address(plain), ALT_QUOTE + ALT_FEE, deadline, v, r, s, _inner(data, intent));
        vm.stopPrank();

        assertFalse(permitAccepted, "no ERC-2612: the permit is reported as not accepted");
        assertEq(plain.balanceOf(address(venue)), ALT_QUOTE, "the settlement did not run");
        assertEq(plain.balanceOf(collector), ALT_FEE, "the collector was not paid");
        assertEq(asset.balanceOf(buyer), ASSET_OUT, "the asset did not reach the buyer");
    }

    /// A signature that does not recover, on a token that DOES implement ERC-2612. The token
    /// reverts, `_tryPermit` swallows it, and the settlement still runs on the standing
    /// allowance. `permitAccepted == false` is the diagnostic a client simulates for.
    function test_PermitAndSettle_SignatureThatDoesNotRecover_DoesNotRevertTheSettlement() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(buyerPk, keccak256("junk"));

        _approveExact(intent);
        vm.prank(buyer);
        (bool permitAccepted,) = AsseteraPrimarySales(address(router))
            .permitAndCall(address(currency), QUOTE + FEE, deadline, v, r, s, _inner(data, intent));

        assertFalse(permitAccepted, "a signature that does not recover was reported as accepted");
        assertEq(currency.balanceOf(address(venue)), QUOTE, "the settlement did not run");
        assertEq(asset.balanceOf(buyer), ASSET_OUT, "the asset did not reach the buyer");
    }

    /// EUROP's shape: `name()` is not the EIP-712 domain name, so a client that signs against
    /// `name()` produces a signature the token rejects. Real settlement currencies do this and
    /// the playground faucet tokens cannot reproduce it. The settlement must survive on the
    /// standing allowance.
    function test_PermitAndSettle_DivergentDomain_FallsBackToAllowance() public {
        DivergentDomainToken eurp = new DivergentDomainToken("EUROP", "EURP", "EUR CoinVertible", false);
        eurp.mint(buyer, 10_000e18);

        bytes memory data = _venueCalldataIn(address(eurp), ALT_QUOTE, ASSET_OUT);
        PrimaryTypes.SettlementIntent memory intent = _intentIn(address(eurp), data, ALT_QUOTE, ALT_FEE);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermitAgainstName(address(eurp), buyerPk, buyer, ALT_QUOTE + ALT_FEE, deadline, eurp.name());

        vm.startPrank(buyer);
        eurp.approve(address(router), ALT_QUOTE + ALT_FEE);
        (bool permitAccepted,) = AsseteraPrimarySales(address(router))
            .permitAndCall(address(eurp), ALT_QUOTE + ALT_FEE, deadline, v, r, s, _inner(data, intent));
        vm.stopPrank();

        assertFalse(permitAccepted, "permit rejected: signed against name(), not the real domain");
        assertEq(eurp.balanceOf(address(venue)), ALT_QUOTE, "the settlement did not run");
        assertEq(asset.balanceOf(buyer), ASSET_OUT, "the asset did not reach the buyer");
    }

    /// The same token, signed against the domain separator the token itself reports. This is
    /// what a client has to do, and it is the only reliable way: read `DOMAIN_SEPARATOR()` and
    /// match candidate names against it.
    function test_PermitAndSettle_DivergentDomain_SigningAgainstTheRealDomainWorks() public {
        DivergentDomainToken eurp = new DivergentDomainToken("EUROP", "EURP", "EUR CoinVertible", false);
        eurp.mint(buyer, 10_000e18);

        bytes memory data = _venueCalldataIn(address(eurp), ALT_QUOTE, ASSET_OUT);
        PrimaryTypes.SettlementIntent memory intent = _intentIn(address(eurp), data, ALT_QUOTE, ALT_FEE);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(address(eurp), buyerPk, buyer, ALT_QUOTE + ALT_FEE, deadline);

        vm.prank(buyer);
        (bool permitAccepted,) = AsseteraPrimarySales(address(router))
            .permitAndCall(address(eurp), ALT_QUOTE + ALT_FEE, deadline, v, r, s, _inner(data, intent));

        assertTrue(permitAccepted);
        assertEq(eurp.balanceOf(address(venue)), ALT_QUOTE, "the settlement did not run");
        assertEq(eurp.allowance(buyer, address(router)), 0, "permit allowance was consumed exactly");
    }

    // ── guards ────────────────────────────────────────────────────────────────────────────

    /// The inner call's revert is bubbled unchanged, so a client keeps the error it would have
    /// got had it called `settlePrimary` directly.
    function test_PermitAndSettle_BubblesTheInnerRevert() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();
        intent.deadline = block.timestamp - 1; // stale quote
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(address(currency), buyerPk, buyer, QUOTE + FEE, deadline);

        vm.prank(buyer);
        vm.expectRevert(IIntentGate.IntentExpired.selector);
        AsseteraPrimarySales(address(router))
            .permitAndCall(address(currency), QUOTE + FEE, deadline, v, r, s, _inner(data, intent));
    }

    /// 🔴 `permitAndCall` is deliberately not `nonReentrant` — taking the guard here would make
    /// `settlePrimary`'s own guard revert the inner call. What must hold is the INNER guard,
    /// including when the token used for the permit is the one re-entering.
    function test_PermitAndSettle_ReentrantTokenCannotReenterSettlePrimary() public {
        ReentrantToken evil = new ReentrantToken();
        evil.mint(buyer, 10_000e18);

        bytes memory data = _venueCalldataIn(address(evil), ALT_QUOTE, ASSET_OUT);
        PrimaryTypes.SettlementIntent memory intent = _intentIn(address(evil), data, ALT_QUOTE, ALT_FEE);
        bytes memory inner = _inner(data, intent);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(buyerPk, keccak256("junk"));

        vm.startPrank(buyer);
        evil.approve(address(router), ALT_QUOTE + ALT_FEE);
        // The token re-enters the settlement while the router is pulling the buyer's funds.
        evil.arm(address(router), inner);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        AsseteraPrimarySales(address(router))
            .permitAndCall(address(evil), ALT_QUOTE + ALT_FEE, deadline, v, r, s, inner);
        vm.stopPrank();
    }

    /// The one permit failure that is NOT swallowed: a `token` address with no code. Solidity
    /// performs the `extcodesize` check outside the `try`, so it reverts the whole call. A
    /// caller bug rather than a token quirk, and unchanged from the exchange — pinned so nobody
    /// assumes `_tryPermit` can never revert.
    function test_PermitAndSettle_CodelessTokenAddressReverts() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(buyerPk, keccak256("junk"));

        vm.prank(buyer);
        vm.expectRevert();
        AsseteraPrimarySales(address(router))
            .permitAndCall(makeAddr("not-a-contract"), QUOTE + FEE, deadline, v, r, s, _inner(data, intent));
    }

    /// The pause lever reaches the relayed settlement too: `whenNotPaused` sits on
    /// `settlePrimary`, which the relay delegates into, so "stop primary sales" is not something
    /// a permit can be used to route around.
    function test_PermitAndSettle_IsStoppedByThePauseLever() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _happyPath();
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(address(currency), buyerPk, buyer, QUOTE + FEE, deadline);

        vm.prank(admin);
        router.pause();

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        AsseteraPrimarySales(address(router))
            .permitAndCall(address(currency), QUOTE + FEE, deadline, v, r, s, _inner(data, intent));
    }
}
