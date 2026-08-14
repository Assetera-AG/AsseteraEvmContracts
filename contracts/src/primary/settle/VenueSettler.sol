// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SettlementLimits} from "../admin/SettlementLimits.sol";
import {ISettler} from "../interfaces/ISettler.sol";
import {FeeMath} from "../../libs/FeeMath.sol";

/// @title VenueSettler
/// @notice Family S2: the buyer settles against a third-party venue (Dinari, Backed, …) whose
///         call we do not control and never allowlist.
///
///         `AsseteraPrimarySales.settlePrimary` has already done everything that is common to
///         every family by the time this runs: all three signatures verified, the calldata
///         bound by hash and selector, both attestations pinned to the intent's struct hash,
///         all three nonces burned. What is left is exactly the money, and that is this file.
///
///         **We never trust the venue's calldata to be honest.** The bytes are bound by hash
///         and handed over opaquely; what the settlement is judged on afterwards is the set of
///         balance deltas THIS contract measured. Bind the outcome, not the bytes.
///
/// @dev    The ordered flow of `_settleVenue`, and why each step is where it is:
///           0. structural guards that cost two comparisons and a storage read — the venue may
///              not be either of the two tokens this settlement moves, and a non-zero fee may
///              only go to an allowlisted collector;
///           1. charge the value caps with the full debit, BEFORE any external call;
///           2. snapshot `assetToken.balanceOf(intent.buyer)` and this contract's own
///              `settlementToken` balance;
///           3. pull `venueQuoteIn + buyerFee` from the buyer — never an unlimited allowance,
///              always an exact amount for this one settlement;
///           4. approve EXACTLY `venueQuoteIn` to `intent.venue` and call it with
///              `venueCalldata`;
///           5. set the approval back to zero and measure what the venue actually consumed;
///           6. refund whatever the venue did not consume to the buyer;
///           7. assert the measured asset delta is at least `minAssetOut`
///              (`InsufficientAssetDelivered`) — a revert, never a silent bad fill;
///           8. transfer `buyerFee` to `intent.feeCollector`;
///           9. assert this contract's settlement-token balance returned to its PRE-CALL
///              value (`RouterBalanceChanged`) — against the pre-call balance, not against the
///              venue having consumed the whole quote;
///          10. return the four MEASURED numbers.
///
///         ⚠️ **Two deliberate departures from the stub's ordered flow, both forced:**
///           * The stub put the cap charge inside step 2 (with the pull). It is charged FIRST
///             here instead. Nothing observable changes — the whole call is atomic, so a cap
///             breach reverts the same transaction either way — but the cheapest check runs
///             before the first external call, and with the caps module unimplemented the seam
///             fails closed on `SettlementLimitsNotImplemented` rather than on a token call.
///             ⚠️ `SettlementLimits`' own doc comment asks for the amount debited "after the
///             refund is known"; the stub for THIS file asks for `venueQuoteIn + buyerFee`.
///             They cannot both hold. This file charges the stub's number, which is the
///             conservative one: it is never below the net debit, so the cap can only ever be
///             tighter than the alternative, never looser.
///           * The stub asserted the router balance in step 4, before the fee transfer of step
///             6. That is not satisfiable: between the refund and the fee transfer the router
///             still holds exactly `buyerFee`. The assertion is made once, LAST, where it is
///             strongest — it then also catches a fee transfer that silently moved nothing.
///
///         ⚠️ **The balance-delta assertion is safe here and only here:** measured inside one
///         transaction, a rebase cannot occur mid-call. Any path that holds a rebasing asset
///         (which is what tokenised equities are) ACROSS blocks and reasons about a raw
///         balance is wrong.
///
///         ⚠️ `forge build` reports "Unreachable code" for every statement below the
///         `_consumeSettlementLimit` call, and that is the CORRECT reading while the value-caps
///         module (AO-517) is a stub that reverts unconditionally: the compiler can prove no
///         line of the money path runs. It is the same warning `AsseteraPrimarySales` documents
///         on its own `emit`, for the same reason, and every one of them disappears when that
///         packet fills its seam. Do not silence them by moving the charge below the money —
///         charging the caps before the first external call is what makes "the caps are not
///         implemented" mean "nothing can move" rather than "the venue was called anyway".
///
///         The adversarial suite — a lying venue, reentrancy, rebasing and fee-on-transfer
///         tokens, replay, over-delivery — is AO-551 and lives outside this packet.
abstract contract VenueSettler is SettlementLimits, ISettler {
    using SafeERC20 for IERC20;

    /// @dev `intent.buyerFee` is not what the attested `takerFeeBps` implies on
    ///      `venueQuoteIn`. Without this the fee is whatever the settlement signer typed and
    ///      the fee service's basis points are decorative — two signatures silently
    ///      disagreeing about the same number.
    ///
    ///      ⚠️ Declared here rather than in `ISettler` alongside the other settlement errors,
    ///      which is where the house style would put it, only because `src/primary/interfaces/**`
    ///      is frozen by the skeleton packet. Move it there when that file next opens.
    error BuyerFeeMismatch(uint256 attested, uint256 expected);

    /// @dev `intent.venue` is `intent.settlementToken` or `intent.assetToken`. The venue is
    ///      called with bytes we did not author; if it were one of the two tokens, those bytes
    ///      would be a token call made by this contract with this contract's own allowances —
    ///      including any allowance a buyer left behind when an earlier settlement reverted
    ///      after their `approve` landed. Two comparisons against fields of the SAME intent,
    ///      which is a structural guard rather than the on-chain allowlist that was
    ///      deliberately rejected on 2026-08-13: nothing here consults a list, and any address
    ///      that is not one of this settlement's own two tokens is still callable.
    error VenueIsASettledToken();

    /// @dev The internal seam for family S2. Not an address, not a `delegatecall` target, not
    ///      an external call — one proxy, inherited modules (§4.5).
    ///
    ///      Takes the opaque venue calldata (already bound by hash and selector) and the
    ///      verified settlement intent; returns the four MEASURED numbers the settlement event
    ///      reports.
    ///
    ///      Reentrancy: `settlePrimary` holds the `nonReentrant` guard for the whole of this
    ///      call, and the intent nonce is already burned before the first line runs, so the
    ///      venue cannot re-enter the entry point and cannot replay this intent.
    ///
    /// @param venueCalldata The opaque bytes to hand the venue.
    /// @param intent        The verified settlement intent.
    /// @param takerFeeBps   The basis points from the FEE attestation, carried in so that the
    ///                      two signatures can be made to agree about the fee. The seam takes
    ///                      this rather than reading it from storage because nothing on the
    ///                      path stores it, and rather than decoding `msg.data` because that
    ///                      would be fragile. It is an INTERNAL signature: the external ABI,
    ///                      the storage layout and every signed payload are untouched.
    /// @return result       The four measured numbers: delivery, consumption, refund, fee.
    function _settleVenue(bytes calldata venueCalldata, SettlementIntent calldata intent, uint16 takerFeeBps)
        internal
        virtual
        returns (SettlementResult memory result)
    {
        // ── 0 · structural guards ──────────────────────────────────────────────────────────
        if (intent.venue == intent.settlementToken || intent.venue == intent.assetToken) {
            revert VenueIsASettledToken();
        }
        // 🔴 The cross-check that makes the attested basis points mean something. Without it
        //    `buyerFee` is whatever the settlement signer typed and the two signatures silently
        //    disagree about the fee. It runs before anything moves.
        _assertBuyerFee(intent, takerFeeBps);
        // Defence in depth, and currently UNREACHABLE — said plainly rather than left to look
        // load-bearing. With the cross-check above wired, zero attested bps force `buyerFee` to
        // zero, and non-zero bps mean `IntentGate._bindAttestations` has already required both
        // `allowedCollectors(feeAtt.feeCollector)` and `feeAtt.feeCollector ==
        // intent.feeCollector`. Kept because it is two comparisons on a path whose whole job is
        // to bound a compromised signer, and because it stops being unreachable the moment
        // either of those upstream checks is relaxed. Delete it only together with a test that
        // proves the upstream pair still holds.
        if (intent.buyerFee != 0 && !allowedCollectors(intent.feeCollector)) {
            revert FeeCollectorNotAllowed(intent.feeCollector);
        }

        IERC20 currency = IERC20(intent.settlementToken);
        IERC20 asset = IERC20(intent.assetToken);

        // `IntentGate._verifyIntent` already evaluated `venueQuoteIn + buyerFee` under checked
        // arithmetic to compare it against `maxSettlementIn`, so this addition cannot overflow.
        uint256 debit = intent.venueQuoteIn + intent.buyerFee;

        // ── 1 · value caps, before the first external call ─────────────────────────────────
        _consumeSettlementLimit(intent.settlementToken, debit);

        // ── 2 · snapshots ─────────────────────────────────────────────────────────────────
        // The router's own pre-call balance, NOT zero: the invariant asserted at the end is
        // "no standing balance was created", and a stray donation sitting here must neither
        // be counted as venue consumption nor be swept into the refund.
        uint256 buyerAssetBefore = asset.balanceOf(intent.buyer);
        uint256 routerBefore = currency.balanceOf(address(this));

        // ── 3 · pull exactly this settlement's debit ──────────────────────────────────────
        // The buyer's allowance to this router is the true ceiling on a compromised settlement
        // signer, and it is an exact amount for one transaction rather than a standing grant.
        // That is what makes the loss ceiling one transaction structurally rather than by
        // policy, and it is why nothing on this path ever asks for `type(uint256).max`.
        currency.safeTransferFrom(intent.buyer, address(this), debit);

        // ── 4 · approve exactly the quote, then hand over the bytes ───────────────────────
        // `buyerFee` is deliberately NOT in the approval: our fee is never reachable by the
        // venue, whatever its calldata says.
        currency.forceApprove(intent.venue, intent.venueQuoteIn);
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok,) = intent.venue.call(venueCalldata);
        // The venue's own revert data is deliberately not bubbled: it is attacker-controlled
        // bytes from an address nothing on-chain constrains, and it is visible in a trace
        // anyway. One deterministic error is what the indexer and ops read.
        if (!ok) revert VenueCallFailed();

        // ── 5 · revoke, then MEASURE what was actually consumed ───────────────────────────
        // Unconditional, before anything else: no standing approval survives this call even
        // when the venue consumed the whole quote.
        currency.forceApprove(intent.venue, 0);

        uint256 held = currency.balanceOf(address(this));
        // `held` must lie in `[routerBefore + buyerFee, routerBefore + debit]`. The lower bound
        // says the venue took no more than the `venueQuoteIn` it was approved and never
        // touched our fee or a pre-existing balance; the upper bound says it did not push
        // settlement token back at us. Both subtractions below are provably safe under it.
        if (held < routerBefore + intent.buyerFee || held > routerBefore + debit) {
            revert RouterBalanceChanged();
        }
        uint256 venueIn = routerBefore + debit - held;
        uint256 refund = intent.venueQuoteIn - venueIn;

        // ── 6 · refund what the venue rounded away ────────────────────────────────────────
        // A venue that consumes less than approved is normal, not an error: reverting instead
        // would break every venue that rounds a fill down. Leaving the difference in the
        // router would contradict the zero-standing-balance invariant.
        if (refund != 0) currency.safeTransfer(intent.buyer, refund);

        // ── 7 · the delivery assertion ────────────────────────────────────────────────────
        uint256 buyerAssetAfter = asset.balanceOf(intent.buyer);
        // Clamped rather than left to a checked subtraction so a balance that went DOWN — a
        // downward rebase inside the call, or a venue that took the buyer's asset — reports
        // the shortfall through the settlement error instead of an arithmetic panic.
        uint256 delivered = buyerAssetAfter > buyerAssetBefore ? buyerAssetAfter - buyerAssetBefore : 0;
        if (delivered < intent.minAssetOut) revert InsufficientAssetDelivered(delivered, intent.minAssetOut);

        // ── 8 · our fee ───────────────────────────────────────────────────────────────────
        if (intent.buyerFee != 0) currency.safeTransfer(intent.feeCollector, intent.buyerFee);

        // ── 9 · no standing balance ───────────────────────────────────────────────────────
        // Against the PRE-CALL balance, which is the actual invariant, and not against zero
        // (a donation would break that) nor against the venue having consumed the whole quote.
        if (currency.balanceOf(address(this)) != routerBefore) revert RouterBalanceChanged();

        // ── 10 · the four measured numbers ────────────────────────────────────────────────
        result = SettlementResult({assetDelivered: delivered, venueIn: venueIn, refund: refund, fee: intent.buyerFee});
    }

    // --------------------------------------------------------------------- //
    //                        The buyer-fee cross-check                       //
    // --------------------------------------------------------------------- //

    /// @dev The buyer fee the attested `takerFeeBps` implies on `venueQuoteIn`.
    ///
    ///      **`FeeMath.feeAmount`, which FLOORS**, and that choice is load-bearing rather than
    ///      incidental. The rounding direction here is an interop contract with
    ///      `AsseteraSignerService` and `AsseteraMarketplaceAPI`, which compute the same number
    ///      off-chain: if the two sides disagree by one wei, every settlement whose fee does
    ///      not divide exactly reverts. `feeAmount` is documented in its own library as
    ///      matching every existing exchange call site exactly, and every fee in this system
    ///      floors, so it is the number the rest of the estate already produces.
    ///
    ///      An earlier revision rounded UP on the reasoning that it favours us over the payer.
    ///      That is true and it is the wrong trade: it buys at most one wei per settlement and
    ///      pays for it by making the contract disagree with every other fee calculation we
    ///      run. `FeeMath.ceilDiv` exists for price arithmetic — an amount DUE from a buyer in
    ///      `OrderBook` — and is not used for a fee anywhere in this codebase.
    ///
    ///      Pinned by hardcoded vectors in `test/primary/VenueSettler.t.sol`, the way the
    ///      exchange pins its own fee maths.
    ///
    /// @param venueQuoteIn The venue's firm quote, in the settlement currency.
    /// @param takerFeeBps  The basis points the fee service attested.
    /// @return The fee that pair implies, floored.
    function _expectedBuyerFee(uint256 venueQuoteIn, uint16 takerFeeBps) internal pure returns (uint256) {
        return FeeMath.feeAmount(venueQuoteIn, takerFeeBps);
    }

    /// @dev Assert that the settlement operator's `buyerFee` is the fee service's
    ///      `takerFeeBps` applied to the same intent's `venueQuoteIn`. Two independent signers
    ///      must agree on one number, or the basis points are decorative.
    ///
    ///      Called from `_settleVenue` before anything moves. `takerFeeBps` lives on the
    ///      `FeeAttestation`, which nothing on the path stores and no `virtual` hook below this
    ///      module exposes, so the seam carries it as a third parameter. That is an INTERNAL
    ///      signature: the frozen external ABI, the storage layout and every signed payload are
    ///      untouched by it.
    ///
    ///      ⚠️ Without this the settlement signer alone decides the fee, bounded only by
    ///      `maxSettlementIn` (its own number) and the buyer's per-call allowance, and the
    ///      attested basis points become decorative while both signatures still verify.
    ///
    /// @param intent       The verified settlement intent.
    /// @param takerFeeBps  The basis points from the fee attestation bound to that intent.
    function _assertBuyerFee(SettlementIntent calldata intent, uint16 takerFeeBps) internal pure {
        uint256 expected = _expectedBuyerFee(intent.venueQuoteIn, takerFeeBps);
        if (intent.buyerFee != expected) revert BuyerFeeMismatch(intent.buyerFee, expected);
    }
}
