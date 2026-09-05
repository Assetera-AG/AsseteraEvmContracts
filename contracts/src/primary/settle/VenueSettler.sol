// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SettlementLimits} from "../admin/SettlementLimits.sol";
import {IShareAccountingToken} from "../interfaces/IShareAccountingToken.sol";
import {ISettler} from "../interfaces/ISettler.sol";
import {FeeMath} from "../../libs/FeeMath.sol";

/// @title VenueSettler
/// @notice The router's ONE settlement family: the buyer settles against a venue whose call we
///         do not control and never allowlist — a third party (Dinari, Backed, …) or, for our
///         own issuance, the per-token sale contract that fronts it. This module cannot tell
///         them apart and does not try; the whole point of routing our own issuance through a
///         separate sale contract is that it needs no privileged treatment here (the argument is
///         in `AsseteraPrimarySales`).
///
///         `AsseteraPrimarySales.settlePrimary` has already done everything that is common to
///         every settlement by the time this runs: all three signatures verified, the calldata
///         bound by hash and selector, both attestations pinned to the intent's struct hash,
///         all three nonces burned. What is left is exactly the money, and that is this file.
///
///         **We never trust the venue's calldata to be honest.** The bytes are bound by hash
///         and handed over opaquely; what the settlement is judged on afterwards is the set of
///         balance deltas THIS contract measured. Bind the outcome, not the bytes.
///
/// @dev    The ordered flow of `_settleVenue`, and why each step is where it is:
///           0. structural guards that cost two comparisons — the venue may not be either of
///              the two tokens this settlement moves — plus the buyer-fee cross-check;
///           1. (the value caps, charged for every settlement path by
///              `SettlementLimits._authorizeSettlement` before this function is entered);
///           2. snapshot `assetToken.balanceOf(intent.buyer)` and this contract's OWN
///              `settlementToken` AND `assetToken` balances;
///           3. pull `venueQuoteIn + buyerFee` from the buyer — never an unlimited allowance,
///              always an exact amount for this one settlement — and MEASURE what arrived,
///              refusing the settlement (`SettlementPullMismatch`) if the currency delivered
///              anything other than the amount asked for;
///           4. approve EXACTLY `venueQuoteIn` to `intent.venue` and call it with
///              `venueCalldata`;
///           5. set the approval back to zero and measure what the venue actually consumed;
///           6. refund whatever the venue did not consume to the buyer;
///           7. forward to the buyer any ASSET token that landed on this contract during the
///              call — the increase over the step-2 baseline, never the whole balance — and
///              then assert the measured asset delta is at least `minAssetOut`
///              (`InsufficientAssetDelivered`) — a revert, never a silent bad fill;
///           8. transfer `buyerFee` to `intent.feeCollector`;
///           9. assert this contract's settlement-token AND asset-token balances returned to
///              their PRE-CALL values (`RouterBalanceChanged`) — against the pre-call balances,
///              not against the venue having consumed the whole quote;
///          10. return the four MEASURED numbers.
///
///         ⚠️ **Two deliberate departures from the ordered flow the skeleton packet sketched
///         for this file, both forced:**
///           * The sketch put the cap charge inside step 2 (with the pull), called by this
///             module. It is charged before this function is entered at all, by
///             `SettlementLimits._authorizeSettlement`, which every settlement path runs — a cap
///             each path remembers to charge is not a cap, and the mint stub that then stood
///             beside this file had already omitted it from its documented preamble. Nothing
///             observable changes for a venue settlement: the whole call is
///             atomic, and the charge still lands before the first external call, so a
///             settlement in a currency nobody sized is refused with
///             `PerTxCapExceeded(token, debit, 0)` before a single token call is made.
///             ⚠️ **The number charged is `venueQuoteIn + buyerFee`, the FULL authorised debit,
///             not the net one.** `ISettlementLimits` and `SettlementLimits` were written around
///             "the amount actually debited, after the refund is known", and that cannot hold
///             for a charge made before the venue has been called: the refund is not known yet.
///             The full debit is the conservative reading — it is never below the net one, so
///             the cap can only ever bite earlier, never later — and it is the number a human
///             sizing the cap is looking at, because it is the most the buyer can be asked for.
///             Do not "fix" this by moving the charge below the money.
///           * The sketch asserted the router balance in step 4, before the fee transfer of step
///             6. That is not satisfiable: between the refund and the fee transfer the router
///             still holds exactly `buyerFee`. The assertion is made once, LAST, where it is
///             strongest — it then also catches a fee transfer that silently moved nothing.
///
///         ⚠️ **BOTH legs are measured, and the settlement leg only became so on review of
///         PR #58.** The asset leg was always judged on a balance delta; the settlement leg was
///         not — `safeTransferFrom` was called for `venueQuoteIn + buyerFee` and the flow then
///         assumed the router held that. On a fee-on-transfer or deflationary currency it does
///         not, and the failure was NOT clean: it failed closed only when the venue happened to
///         ask for the whole quote, and otherwise settled while misreporting — the token's own
///         burn counted as venue consumption, the collector credited below the attested fee,
///         both silently. Step 3 now measures the pull and refuses anything other than the
///         exact amount, which makes such a currency unsettleable rather than lossy. That is a
///         listing decision, taken at the first line that moves money.
///
///         ⚠️ **The zero-standing-balance invariant is asserted on BOTH tokens, and the asset
///         half only landed on review of PR #58.** The settlement leg always asserted that this
///         contract's balance returned to its pre-call value; the asset leg asserted nothing, so
///         asset token a venue misdirected here accumulated silently with no sweep and no event.
///         The router is not allowed to hold asset token, real or dust. What lands here during
///         the call is FORWARDED to the buyer rather than reverted on, because `minAssetOut` is
///         a floor and not a ceiling: more than expected reaching the buyer is fine, and
///         refusing an otherwise honest settlement over the venue's choice of recipient is not.
///         The two legs are deliberately symmetrical — both snapshot in step 2, both move only
///         the INCREASE over that snapshot, both assert the return to it in step 9 — so a
///         pre-existing donation from a third party is never handed to whichever buyer happens
///         to settle next, on either token.
///
///         ⚠️ **What the balance-delta assertion does and does not survive.** An earlier
///         version of this comment claimed a rebase "cannot occur mid-call". That is false —
///         the venue is arbitrary code and can call the asset token during its own execution —
///         and the three tests in `VenueSettlerRebasingAssetTest`
///         (`test/primary/VenueSettlerHostile.t.sol`) pin what is actually true:
///           * A rebase BEFORE the call contributes nothing, because the snapshot is taken
///             inside the call rather than carried across blocks
///             (`test_Rebasing_ARebaseBeforeTheCallIsOutsideTheMeasurement`). Any path that
///             holds a rebasing asset (which is what tokenised equities are) ACROSS blocks and
///             reasons about a raw balance is still wrong.
///           * A rebase DURING the call IS counted as delivery
///             (`test_Rebasing_ARebaseDuringTheCallIsCountedAsDelivery`: the venue takes the
///             whole quote, delivers nothing, rebases the buyer's existing position up by 10 %
///             and clears the floor). Nothing here can tell it from an honest transfer, because
///             both are only a balance delta.
///           * The practical bound, stated honestly rather than reassuringly: it grants a venue
///             that fully CONTROLS the asset token nothing new, since such a venue could simply
///             mint to the buyer — and minting to the buyer is what honest delivery is. Where
///             it bites is a genuinely rebasing asset whose rebase the venue can trigger but
///             does not control, and it additionally requires the buyer to ALREADY hold a
///             position in that asset, which a primary sale usually does not
///             (`test_Rebasing_TheSameVenueIsRefusedWhenTheBuyerHoldsNoPosition`: same venue,
///             empty buyer, measured delta zero, settlement refused).
///         Reported rather than patched: the venue and the asset are both named in an intent the
///         buyer signed, and there is no on-chain check that separates the two cases.
///
///         ⚠️ **An unset cap is CLOSED, and this file is where that becomes a settlement-level
///         property rather than a module-level one.** `SettlementLimits` reads zero as "this
///         currency cannot be settled in at all", and because the charge is step 1 here, a
///         currency nobody deliberately sized cannot reach a single line of the money path —
///         no pull, no approval, no venue call. Every settlement currency therefore needs an
///         explicit `setSettlementCap` before the first primary sale in it can succeed, which
///         is the intended deployment step and not a bug to route around.
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

    // ⚠️ `UnsupportedAccountingMode` and `ShareTransferFailed` are declared on `ISettler`,
    //    beside `RouterBalanceChanged` and `InsufficientAssetDelivered`, rather than here.
    //    That is where the settlement error vocabulary lives and therefore what a consumer
    //    decoding this router's reverts by selector actually compiles against; an error
    //    declared only on this module would revert identically on chain and fail to decode in
    //    the frontend.

    /// @dev The settlement seam. Not an address, not a `delegatecall` target, not
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
        // 🔴 The accounting mode decides how the asset is MEASURED and MOVED, so an ordinal this
        //    router cannot implement must be refused before the first token call rather than
        //    discovered at the forward. Checked once here; the default arms of the three helpers
        //    below are the belt to this braces and are deliberately kept.
        if (intent.accountingMode > uint8(AssetAccountingMode.RebasingShares)) {
            revert UnsupportedAccountingMode(intent.accountingMode);
        }
        // 🔴 The cross-check that makes the attested basis points mean something. Without it
        //    `buyerFee` is whatever the settlement signer typed and the two signatures silently
        //    disagree about the fee. It runs before anything moves.
        _assertBuyerFee(intent, takerFeeBps);
        // ⚠️ **A local `allowedCollectors(intent.feeCollector)` check USED TO STAND HERE and was
        //    removed on review of PR #58. Do not "restore" it.** Its own comment already called
        //    it provably unreachable, and a guard that cannot fire is not evidencing the
        //    invariant it claims to guard — it only costs a storage read on every fee-bearing
        //    settlement. Unreachable because the cross-check on the line above forces
        //    `buyerFee == 0` whenever the attested bps are zero, and non-zero bps mean
        //    `IntentGate._bindAttestations` has ALREADY required both
        //    `allowedCollectors(feeAtt.feeCollector)` (via `FeeGate._validateFees`) and
        //    `feeAtt.feeCollector == intent.feeCollector`.
        //
        //    The invariant is therefore evidenced where it is actually enforced, by two tests in
        //    `test/primary/AsseteraPrimarySales.t.sol`:
        //    `test_SettlePrimary_RejectsAnUnlistedCollector` (a fee to a collector this router
        //    never listed) and `test_SettlePrimary_RejectsACollectorThatDisagreesWithTheIntent`
        //    (a listed collector that is not the one the buyer signed for). If either upstream
        //    check is ever relaxed, fix it there — a second copy of the rule down here is how
        //    the two silently drift apart.

        IERC20 currency = IERC20(intent.settlementToken);
        // ⚠️ There is deliberately no `IERC20 asset` local any more. Every asset read and write
        //    now goes through `_assetUnitsOf` / `_forwardAssetUnits` / `_assetUnderlyingOf`, which
        //    dispatch on the signed accounting mode. A bare `IERC20` handle sitting here is an
        //    invitation to reach past them and reintroduce a `balanceOf` comparison.

        // `IntentGate._verifyIntent` already evaluated `venueQuoteIn + buyerFee` under checked
        // arithmetic to compare it against `maxSettlementIn`, so this addition cannot overflow.
        uint256 debit = intent.venueQuoteIn + intent.buyerFee;

        // ── 1 · value caps ────────────────────────────────────────────────────────────────
        // Charged by `SettlementLimits._authorizeSettlement`, which every settlement path runs,
        // rather than here — see that function for why a cap each path opts into is not a cap.
        // It still runs before the first external call of this settlement; what changed is that
        // no path can reach this line without it having run.

        // ── 2 · snapshots ─────────────────────────────────────────────────────────────────
        // The router's own pre-call balances, NOT zero: the invariant asserted at the end is
        // "no standing balance was created", and a stray donation sitting here must neither
        // be counted as venue consumption nor be swept into the refund.
        //
        // The ASSET baseline is the same statement about the other token, and it exists for
        // exactly the same reason the settlement one does: step 7 forwards only what this call
        // added, so a third party's donation is never handed to whichever buyer happens to
        // settle next. Keep the two symmetrical.
        //
        // ⚠️ BOTH asset snapshots are taken in the asset's OWN unit of account — `balanceOf`
        //    under `Erc20Balance`, `sharesOf` under `RebasingShares` — and every later comparison
        //    against them uses the same unit. Mixing the two is the bug this whole change exists
        //    to remove, so the unit is chosen once, here, and never re-decided further down.
        uint256 buyerAssetBefore = _assetUnitsOf(intent.accountingMode, intent.assetToken, intent.buyer);
        uint256 routerBefore = currency.balanceOf(address(this));
        uint256 routerAssetBefore = _assetUnitsOf(intent.accountingMode, intent.assetToken, address(this));

        // ── 3 · pull exactly this settlement's debit, and MEASURE what arrived ────────────
        // The buyer's allowance to this router is the true ceiling on a compromised settlement
        // signer, and it is an exact amount for one transaction rather than a standing grant.
        // That is what makes the loss ceiling one transaction structurally rather than by
        // policy, and it is why nothing on this path ever asks for `type(uint256).max`.
        currency.safeTransferFrom(intent.buyer, address(this), debit);

        // 🔴 What `safeTransferFrom` was ASKED to move is not what this contract RECEIVED. A
        //    fee-on-transfer or deflationary currency debits the buyer in full and credits us
        //    less, and every number computed after this point is a difference of the ROUTER's
        //    own balances — so a flow driven by the quoted `debit` on such a token settles
        //    while misreporting: the token's burn is counted as venue consumption and the
        //    collector is credited below the attested fee. Measured, not quoted, which is the
        //    discipline the asset leg in step 7 already follows.
        //
        //    Clamped rather than left to a checked subtraction so a balance that went DOWN
        //    reports through the named error instead of an arithmetic panic.
        uint256 afterPull = currency.balanceOf(address(this));
        uint256 received = afterPull > routerBefore ? afterPull - routerBefore : 0;
        // A short pull REVERTS rather than quietly becoming a smaller purchase: the buyer
        // signed `venueQuoteIn + buyerFee`, so approving the venue less than the signed quote
        // is not the trade they consented to, and paying the collector less than the attested
        // fee is the defect being fixed. A surplus is refused for the mirror reason — the
        // router would report a venue consumption that never happened. See
        // `ISettler.SettlementPullMismatch`; the consequence is that a deflationary settlement
        // currency cannot settle at all, which is a listing decision taken here rather than
        // discovered in the ledger.
        if (received != debit) revert SettlementPullMismatch(debit, received);

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
        // `held` must lie in `[routerBefore + buyerFee, routerBefore + received]`. The lower
        // bound says the venue took no more than the `venueQuoteIn` it was approved and never
        // touched our fee or a pre-existing balance; the upper bound says it did not push
        // settlement token back at us. Both subtractions below are provably safe under it.
        //
        // Against `received` — what we hold — rather than against `debit` — what we asked for.
        // Step 3 has already made the two equal, so nothing changes today; the point is that
        // the venue is judged against the money that is actually here, so this arithmetic
        // cannot start lying if that equality is ever relaxed.
        if (held < routerBefore + intent.buyerFee || held > routerBefore + received) {
            revert RouterBalanceChanged();
        }
        uint256 venueIn = routerBefore + received - held;
        uint256 refund = intent.venueQuoteIn - venueIn;

        // ── 6 · refund what the venue rounded away ────────────────────────────────────────
        // A venue that consumes less than approved is normal, not an error: reverting instead
        // would break every venue that rounds a fill down. Leaving the difference in the
        // router would contradict the zero-standing-balance invariant.
        if (refund != 0) currency.safeTransfer(intent.buyer, refund);

        // ── 7 · forward misdirected asset, then the delivery assertion ────────────────────
        // 🔴 The router is not allowed to hold asset token, real or dust. This contract holds
        //    no asset by design, so anything a venue put here is somebody's delivery, and
        //    without this it would sit here with no sweep and no event.
        //
        //    FORWARDED rather than reverted on: `minAssetOut` is a floor and not a ceiling, so
        //    more than expected reaching the buyer is fine, and refusing an otherwise honest
        //    settlement over the venue's choice of recipient is not.
        //
        //    ⚠️ The INCREASE over the step-2 baseline, NEVER the whole balance. This is the
        //    same reasoning already written down for the settlement-token snapshot, and the two
        //    are deliberately symmetrical: a pre-existing donation from a third party is not
        //    this settlement's money and must not be handed to whichever buyer happens to
        //    settle next.
        //
        //    ⚠️ BEFORE the delivery delta is measured, which is why this sits here rather than
        //    beside the step-9 assertion. A venue that splits delivery between the buyer and
        //    the router would otherwise fail `minAssetOut` even though the buyer ends up
        //    holding everything.
        //    ⚠️ Under `RebasingShares` this forwards an exact SHARE delta with `transferShares`.
        //    That is the whole point: forwarding the measured `balanceOf` increase converts
        //    nominal-to-shares a SECOND time, and the remainder it strands is what made the
        //    2026-08-24 AAPLx fork proof revert at step 9.
        uint256 routerAssetAfter = _assetUnitsOf(intent.accountingMode, intent.assetToken, address(this));
        if (routerAssetAfter > routerAssetBefore) {
            _forwardAssetUnits(
                intent.accountingMode, intent.assetToken, intent.buyer, routerAssetAfter - routerAssetBefore
            );
        }

        // ⚠️ TODO(AO-550) — `intent.assetToken` may be a CLAIM token rather than the instrument
        //    the buyer bought, and nothing here can tell the difference. Every supplier we
        //    settle against (Dinari, Ondo, our own sale contract) is atomic, and where a mint is
        //    genuinely asynchronous it is fronted by a claim minted synchronously in this same
        //    transaction — which is exactly what makes this balance delta measurable and this
        //    contract correct either way.
        //
        //    What is NOT settled is what the layers above do with a claim: the activity ledger
        //    could report it as a final position, and the claim-to-instrument leg is a second
        //    event that nothing currently emits. Deliberately deferred (2026-08-14) rather than
        //    designed for now, because the indexer already watches every token in the catalogue,
        //    so the transfers are observed even before anyone models the distinction. Settle it
        //    when the first primary sale is built out.
        uint256 buyerAssetAfter = _assetUnitsOf(intent.accountingMode, intent.assetToken, intent.buyer);
        // Clamped rather than left to a checked subtraction so a balance that went DOWN — a
        // downward rebase inside the call, or a venue that took the buyer's asset — reports
        // the shortfall through the settlement error instead of an arithmetic panic.
        uint256 deliveredUnits = buyerAssetAfter > buyerAssetBefore ? buyerAssetAfter - buyerAssetBefore : 0;
        // 🔴 MEASURED in the asset's own unit, REPORTED in the buyer's. Under `RebasingShares`
        //    the delta above is a share count and this converts it once, at the post-call
        //    multiplier, so `minAssetOut` stays denominated in the instrument. Both halves matter:
        //
        //      * measuring in shares is what stops a multiplier change during the venue call from
        //        counting the revaluation of the buyer's EXISTING position as delivery. That is
        //        the weakness `test_Rebasing_ARebaseDuringTheCallIsCountedAsDelivery` pins, and a
        //        split or dividend makes it a real corporate action rather than a hostile edge;
        //      * reporting in underlying is what keeps the buyer's consent meaningful. A client
        //        cannot agree to a share count, and `SettlementResult.assetDelivered` feeds the
        //        settlement event and the activity ledger.
        //
        //    ⚠️ A one-hop rounding floor still remains and is the SIGNER's job, not this
        //    contract's: the provider's own nominal transfer into the router converts to shares
        //    once, so the signable floor is
        //    `getUnderlyingAmountByShares(getSharesByUnderlyingAmount(providerOutgoingAmount))`.
        //    Signing the provider's raw nominal amount reverts here, correctly.
        uint256 delivered = _assetUnderlyingOf(intent.accountingMode, intent.assetToken, deliveredUnits);
        if (delivered < intent.minAssetOut) revert InsufficientAssetDelivered(delivered, intent.minAssetOut);

        // ── 8 · our fee ───────────────────────────────────────────────────────────────────
        if (intent.buyerFee != 0) currency.safeTransfer(intent.feeCollector, intent.buyerFee);

        // ── 9 · no standing balance, on EITHER token ──────────────────────────────────────
        // Against the PRE-CALL balances, which is the actual invariant, and not against zero
        // (a donation would break that) nor against the venue having consumed the whole quote.
        //
        // The asset leg closes step 7: it holds only if the forward actually moved what it was
        // asked to move, so a fee-on-transfer asset — or a venue that pushed more asset at us
        // after the forward, from a callback the token itself made — is refused rather than
        // leaving a standing balance nobody can sweep.
        // 🔴 The ASSET assertion is in the asset's own unit of account, and under
        //    `RebasingShares` it REPLACES the `balanceOf` one rather than standing beside it.
        //    Do not "also" assert the balance here. The two agree whenever the multiplier is
        //    still, so a redundant balance check passes every ordinary test and every fork run,
        //    and reverts only when the multiplier moves DURING the venue call — which is exactly
        //    the case share accounting was introduced to survive. It would be a rare,
        //    hard-to-reproduce reintroduction of the bug, hidden behind a line that reads like
        //    belt and braces. `test_Shares_AMultiplierChangeDuringTheCallStillReturnsToBaseline`
        //    is what stops someone restoring it.
        //
        //    The SETTLEMENT leg keeps its `balanceOf` assertion: the settlement currency must be
        //    a plain ERC-20. Nothing here makes a rebasing settlement currency work, and a
        //    settlement in one is refused rather than mismeasured.
        if (currency.balanceOf(address(this)) != routerBefore) revert RouterBalanceChanged();
        if (_assetUnitsOf(intent.accountingMode, intent.assetToken, address(this)) != routerAssetBefore) {
            revert RouterBalanceChanged();
        }

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

    // --------------------------------------------------------------------- //
    //                          Asset accounting seam                         //
    // --------------------------------------------------------------------- //
    //
    // Three functions, one rule: `_assetUnitsOf` and `_forwardAssetUnits` speak the asset's OWN
    // unit of account and must always be used together, and `_assetUnderlyingOf` is the single
    // place where that unit is converted back to the one the buyer signed for.
    //
    // 🔴 Every arm dispatches on the SAME `intent.accountingMode`, which `_settleVenue` validated
    //    in step 0 and which is signed by the settlement operator and by the buyer. Nothing here
    //    probes the token for `sharesOf`, and nothing here reads a per-asset mapping: this router
    //    has no on-chain asset registry, deliberately, and this change does not give it one. The
    //    operator already signs `venue` — arbitrary executable code — so a one-bit accounting
    //    ordinal is strictly weaker than the trust already placed in that signature.
    //
    // ⚠️ A WRONG mode fails closed in both directions, which is what makes moving this decision
    //    off chain acceptable. `Erc20Balance` against a share token reproduces exactly the
    //    pre-AO-713 behaviour and reverts at step 9's `RouterBalanceChanged`. `RebasingShares`
    //    against a plain ERC-20 reverts on the missing selector. Neither over-delivers, and
    //    neither can move value to anyone but the signed buyer. The residual cost of a mistake is
    //    a failed settlement, not a loss.

    /// @dev The asset balance of `account` in the unit this settlement is judged in.
    ///
    ///      ⚠️ Under `RebasingShares` this is a SHARE count and is NOT comparable with anything
    ///      denominated in the token's visible units — `minAssetOut` above all. Pass it through
    ///      `_assetUnderlyingOf` before any such comparison.
    ///      ⚠️ Takes the SIGNED MODE and the SIGNED TOKEN rather than an intent, and is
    ///      `internal` rather than `private`, so the sell-back leg in `VenueRedeemer` measures the
    ///      asset through this same function (AO-847). A second copy of the dispatch would be a
    ///      second place for a new accounting family to be forgotten.
    function _assetUnitsOf(uint8 mode, address assetToken, address account) internal view returns (uint256) {
        if (mode == uint8(AssetAccountingMode.Erc20Balance)) {
            return IERC20(assetToken).balanceOf(account);
        }
        if (mode == uint8(AssetAccountingMode.RebasingShares)) {
            return IShareAccountingToken(assetToken).sharesOf(account);
        }
        revert UnsupportedAccountingMode(mode);
    }

    /// @dev Move `units` of the asset to `to`, in the same unit `_assetUnitsOf` measured.
    ///
    ///      ⚠️ `transferShares` returns `bool` and has no SafeERC20 equivalent, so the return is
    ///      checked here explicitly. A token that returns nothing would fail to decode and revert,
    ///      which is also correct.
    ///      ⚠️ Primitives and `internal`, for the reason on `_assetUnitsOf`.
    function _forwardAssetUnits(uint8 mode, address assetToken, address to, uint256 units) internal {
        if (mode == uint8(AssetAccountingMode.Erc20Balance)) {
            SafeERC20.safeTransfer(IERC20(assetToken), to, units);
            return;
        }
        if (mode == uint8(AssetAccountingMode.RebasingShares)) {
            if (!IShareAccountingToken(assetToken).transferShares(to, units)) revert ShareTransferFailed();
            return;
        }
        revert UnsupportedAccountingMode(mode);
    }

    /// @dev Convert a measured amount from the settlement's unit of account into the token's
    ///      VISIBLE units, which is what `minAssetOut` and `SettlementResult.assetDelivered` are
    ///      denominated in.
    ///
    ///      Identity under `Erc20Balance`. Under `RebasingShares` it is one conversion at the
    ///      post-call multiplier, and it rounds DOWN, so the number compared against the buyer's
    ///      signed floor can never overstate what the buyer can actually withdraw.
    ///      ⚠️ Primitives and `internal`, for the reason on `_assetUnitsOf`.
    function _assetUnderlyingOf(uint8 mode, address assetToken, uint256 units) internal view returns (uint256) {
        if (mode == uint8(AssetAccountingMode.Erc20Balance)) {
            return units;
        }
        if (mode == uint8(AssetAccountingMode.RebasingShares)) {
            return IShareAccountingToken(assetToken).getUnderlyingAmountByShares(units);
        }
        revert UnsupportedAccountingMode(mode);
    }
}
