// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VenueSettler} from "./VenueSettler.sol";
import {IShareAccountingToken} from "../interfaces/IShareAccountingToken.sol";
import {FeeMath} from "../../libs/FeeMath.sol";

/// @title VenueRedeemer
/// @notice The router's SELL BACK leg (AO-847): the seller hands an asset over and the venue pays
///         settlement currency for it. The mirror of `VenueSettler`, against the same kind of
///         venue, under the same constrained-executor discipline — we hand over opaque calldata
///         we did not author and judge the result purely on the balance deltas WE measured.
///
///         It is a sibling module rather than a direction flag inside `_settleVenue`, and the
///         reversal that represents is recorded on `ISettler`. The short version: the two legs
///         differ in every step that moves value. The buy pulls the CURRENCY and approves the
///         venue in the currency; the sell pulls the ASSET and approves the venue in the asset.
///         The buy measures a delivery and charges the fee ON TOP of the quote; the sell measures
///         proceeds and carves the fee OUT of them. Folding the second into the first would have
///         branched every line of an audited function.
///
///         `AsseteraPrimarySales.redeemPrimary` has already done everything common to both legs
///         by the time this runs: all four signatures verified, the calldata bound by hash and by
///         selector, both attestations pinned to the redemption intent's struct hash, all three
///         nonces burned and the per-transaction cap charged. What is left is the money.
///
/// @dev    It INHERITS `VenueSettler` rather than sitting beside it, so the accounting-mode
///         dispatch (`_assetUnitsOf` / `_forwardAssetUnits` / `_assetUnderlyingOf`) is the same
///         code on both legs rather than two copies that drift. `AsseteraPrimarySales` inherits
///         this module in `VenueSettler`'s former position, so the linearisation — and therefore
///         the storage layout — is unchanged.
///
///         The ordered flow of `_redeemVenue`:
///           0. the same structural guards the buy makes, plus the fee cross-check;
///           1. snapshot the router's own balances on BOTH tokens, the asset in its own unit;
///           2. pull the asset from the seller and MEASURE what arrived, refusing anything but an
///              exact move;
///           3. approve the venue in the asset for exactly the NOMINAL value of what was pulled,
///              then hand over the bytes;
///           4. revoke the approval unconditionally and assert it is gone;
///           5. measure the settlement currency the venue paid, and the asset it left behind;
///           6. assert the net proceeds clear the seller's signed floor;
///           7. return the unconsumed asset, pay the fee, forward the net to the seller;
///           8. assert the router holds no standing balance on either token.
///
///         🔴 **Why the approval is in NOMINAL units even under `RebasingShares`.** The venue is
///         third-party code that knows nothing about shares; it pulls with an ordinary
///         `transferFrom`, and a share-accounted token spends the ERC-20 allowance in visible
///         units. So the router pulls an exact SHARE count — rebase-invariant, which is the whole
///         point of that mode — and then approves the visible value of those shares. Whatever the
///         venue's own nominal-to-shares rounding leaves behind is measured in SHARES at step 5
///         and returned to the seller with `transferShares` at step 7. That is the same
///         second-hop rounding trap AO-713 fixed on the buy leg, arrived at from the other side.
abstract contract VenueRedeemer is VenueSettler {
    using SafeERC20 for IERC20;

    /// @dev `intent.sellerFee` is not `FeeMath.feeAmount(venueQuoteOut, takerFeeBps)`. The two
    ///      signatures disagree about the fee, so neither is authoritative. The sell-back mirror
    ///      of `BuyerFeeMismatch`, and its own selector so the leg is tellable from the revert.
    error SellerFeeMismatch(uint256 attested, uint256 expected);

    // --------------------------------------------------------------------- //
    //                             The money path                             //
    // --------------------------------------------------------------------- //

    /// @dev The second settlement seam. `internal virtual` so a test harness can stub it from
    ///      outside `src/`, exactly as `_settleVenue` is.
    ///
    /// @param venueCalldata The opaque bytes, already bound by hash and by selector.
    /// @param intent        The verified redemption intent.
    /// @param takerFeeBps   The basis points the FEE signer attested, carried in so the fee two
    ///                      independent signers produced can be cross-checked against each other.
    ///                      Without it `sellerFee` is whatever the settlement signer typed.
    /// @return result       The four MEASURED numbers `PrimaryRedeemed` reports.
    function _redeemVenue(bytes calldata venueCalldata, RedemptionIntent calldata intent, uint16 takerFeeBps)
        internal
        virtual
        returns (RedemptionResult memory result)
    {
        // ── 0 · structural guards ──────────────────────────────────────────────────────────
        if (intent.venue == intent.settlementToken || intent.venue == intent.assetToken) {
            revert VenueIsASettledToken();
        }
        if (intent.accountingMode > uint8(AssetAccountingMode.RebasingShares)) {
            revert UnsupportedAccountingMode(intent.accountingMode);
        }
        _assertSellerFee(intent, takerFeeBps);

        IERC20 currency = IERC20(intent.settlementToken);
        // Read once into locals: `intent` is calldata and these two fields are used at eight call
        // sites between them. Choosing the unit of account once, here, is also the rule
        // `VenueSettler` states — every comparison below is in the same unit as its snapshot.
        uint8 mode = intent.accountingMode;
        address assetToken = intent.assetToken;

        // ── 1 · snapshots ─────────────────────────────────────────────────────────────────
        // The router's own PRE-CALL balances, not zero, for the reason the buy leg gives: a
        // stray donation must neither be paid out as proceeds nor returned as somebody's refund.
        uint256 routerBefore = currency.balanceOf(address(this));
        uint256 routerAssetBefore = _assetUnitsOf(mode, assetToken, address(this));

        // ── 2 · pull the asset, and MEASURE what arrived ──────────────────────────────────
        // The seller's allowance to this router is the true ceiling on a compromised settlement
        // signer, and it is an exact amount for one transaction rather than a standing grant —
        // the same argument the buy leg makes about the currency allowance. Nothing here ever
        // asks for `type(uint256).max`.
        uint256 requestedUnits = _pullAssetUnits(mode, assetToken, intent.seller, intent.maxAssetIn);
        uint256 pulledUnits = _assetUnitsOf(mode, assetToken, address(this)) - routerAssetBefore;
        // 🔴 What the pull was ASKED to move is not what this contract RECEIVED. Measured, not
        //    quoted, and an inexact move REVERTS rather than quietly becoming a smaller sale:
        //    approving the venue more asset than the router holds fails later and less legibly,
        //    and approving it less is not the trade the seller signed. `requestedUnits` is zero
        //    when `maxAssetIn` converts to less than one share, which this also catches.
        if (requestedUnits == 0 || pulledUnits != requestedUnits) {
            revert AssetPullMismatch(requestedUnits, pulledUnits);
        }

        // ── 3 · approve exactly what was pulled, then hand over the bytes ─────────────────
        // In NOMINAL units, because the venue pulls with an ordinary `transferFrom` and a
        // share-accounted token spends its ERC-20 allowance in visible units. See the header.
        IERC20(assetToken).forceApprove(intent.venue, _assetUnderlyingOf(mode, assetToken, pulledUnits));
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok,) = intent.venue.call(venueCalldata);
        // The venue's revert data is deliberately not bubbled, as on the buy leg: attacker
        // controlled bytes from an address nothing on-chain constrains, visible in a trace anyway.
        if (!ok) revert VenueCallFailed();

        // ── 4 · revoke, unconditionally, and prove it took ────────────────────────────────
        IERC20(assetToken).forceApprove(intent.venue, 0);
        // 🔴 Not belt and braces. `forceApprove` cannot fail silently on a conforming token, so
        //    this asserts something about a NON-conforming one: an asset whose `approve` is a
        //    no-op, or which re-granted inside a callback the venue triggered, would otherwise
        //    leave the venue a standing claim on a router that is supposed to hold nothing.
        if (IERC20(assetToken).allowance(address(this), intent.venue) != 0) revert AssetApprovalNotCleared();

        // ── 5 · MEASURE the proceeds, and what the venue left behind ──────────────────────
        uint256 heldCurrency = currency.balanceOf(address(this));
        // A currency balance BELOW the pre-call one means the venue took settlement token off
        // this router, which nothing on this leg ever approves. Clamped through the named error
        // rather than left to an arithmetic panic.
        if (heldCurrency < routerBefore) revert RouterBalanceChanged();
        uint256 venueOut = heldCurrency - routerBefore;

        uint256 routerAssetAfter = _assetUnitsOf(mode, assetToken, address(this));
        // Bounded on BOTH sides, in the asset's own unit. Below the baseline means the venue took
        // asset that was not this settlement's; above `baseline + pulled` means it pushed asset
        // back at us, and the router would then report a consumption that never happened while
        // holding a residue it has no sweep for. The mirror of the buy leg's `held` bounds.
        if (routerAssetAfter < routerAssetBefore || routerAssetAfter > routerAssetBefore + pulledUnits) {
            revert RouterBalanceChanged();
        }
        uint256 leftoverUnits = routerAssetAfter - routerAssetBefore;

        // ── 6 · the proceeds assertion ────────────────────────────────────────────────────
        // Clamped rather than left to a checked subtraction, so a venue that paid nothing — or
        // less than our own fee — reports the shortfall through the settlement error instead of
        // an arithmetic panic. `minSettlementOut` is signed non-zero by the gate, so a venue that
        // takes the asset and pays nothing always lands here.
        uint256 net = venueOut > intent.sellerFee ? venueOut - intent.sellerFee : 0;
        if (net < intent.minSettlementOut) revert InsufficientSettlementOut(net, intent.minSettlementOut);

        // ── 7 · return the unconsumed asset, then the money ───────────────────────────────
        // A venue that takes less than it was approved is normal, not an error: nominal-to-share
        // rounding produces one every time under `RebasingShares`. Leaving the difference here
        // would contradict the zero-standing-balance invariant, and the router has no sweep.
        // ⚠️ Returned in the asset's OWN unit — an exact SHARE count under `RebasingShares` —
        //    which is the one-hop rounding trap AO-713 fixed on the buy leg.
        uint256 assetRefund;
        if (leftoverUnits != 0) {
            _forwardAssetUnits(mode, assetToken, intent.seller, leftoverUnits);
            assetRefund = _assetUnderlyingOf(mode, assetToken, leftoverUnits);
        }

        // 🔴 CARVED OUT, never on top. The seller sends no currency on this leg, so there is
        //    nothing to charge a fee in addition to; `minSettlementOut` is the floor on what is
        //    left AFTER this transfer, which is what makes the seller's signed number the number
        //    they actually receive.
        if (intent.sellerFee != 0) currency.safeTransfer(intent.feeCollector, intent.sellerFee);
        currency.safeTransfer(intent.seller, net);

        // ── 8 · no standing balance, on EITHER token ──────────────────────────────────────
        // Against the PRE-CALL balances, which is the actual invariant, and not against zero.
        // The asset leg closes step 7: it holds only if the return actually moved what it was
        // asked to move. 🔴 In the asset's own unit of account, and under `RebasingShares` it
        // REPLACES the `balanceOf` assertion rather than standing beside it — read the long note
        // at `VenueSettler` step 9 before adding a second one here.
        if (currency.balanceOf(address(this)) != routerBefore) revert RouterBalanceChanged();
        if (_assetUnitsOf(mode, assetToken, address(this)) != routerAssetBefore) revert RouterBalanceChanged();

        // ── 9 · the four measured numbers ─────────────────────────────────────────────────
        // Both asset numbers are converted back to VISIBLE units exactly once, here, so the event
        // and the activity ledger speak the instrument rather than the share.
        result = RedemptionResult({
            assetIn: _assetUnderlyingOf(mode, assetToken, requestedUnits - leftoverUnits),
            venueOut: venueOut,
            assetRefund: assetRefund,
            fee: intent.sellerFee
        });
    }

    // --------------------------------------------------------------------- //
    //                       The seller-fee cross-check                       //
    // --------------------------------------------------------------------- //

    /// @dev Derived from `venueQuoteOut`, which is the GROSS quote, so the fee is a share of what
    ///      the venue pays and not of what the seller keeps. Same `FeeMath.feeAmount` and the same
    ///      floor rounding as the buy leg, so the two legs cannot round differently.
    function _expectedSellerFee(uint256 venueQuoteOut, uint16 takerFeeBps) internal pure returns (uint256) {
        return FeeMath.feeAmount(venueQuoteOut, takerFeeBps);
    }

    /// @dev The cross-check that makes the attested basis points mean something. It runs before
    ///      anything moves, exactly as `_assertBuyerFee` does.
    function _assertSellerFee(RedemptionIntent calldata intent, uint16 takerFeeBps) internal pure {
        uint256 expected = _expectedSellerFee(intent.venueQuoteOut, takerFeeBps);
        if (intent.sellerFee != expected) revert SellerFeeMismatch(intent.sellerFee, expected);
    }

    // --------------------------------------------------------------------- //
    //                            The asset pull                              //
    // --------------------------------------------------------------------- //

    /// @dev The one function the buy leg has no counterpart for: `VenueSettler` never pulls the
    ///      asset, it only measures and pushes it. Dispatches on the SAME signed accounting mode
    ///      the three shared helpers do.
    ///
    ///      🔴 **Under `RebasingShares` the router derives the share count itself and pulls
    ///      EXACTLY that many.** `maxAssetIn` is signed in visible units because a client cannot
    ///      consent to a share count; `getSharesByUnderlyingAmount` rounds down, so the allowance
    ///      the pull spends — which the token computes as the visible value of those shares — can
    ///      never exceed `maxAssetIn`. That is what makes "approve the number in the UI" correct
    ///      advice for a seller.
    ///
    ///      ⚠️ A wrong mode fails closed in both directions, as on the buy leg. `Erc20Balance`
    ///      against a share token pulls a nominal amount, converts once more than it should and
    ///      strands a share, which step 8 refuses. `RebasingShares` against a plain ERC-20 reverts
    ///      on the missing selector. Neither over-delivers.
    ///
    /// @param mode       The signed `AssetAccountingMode` ordinal.
    /// @param assetToken The signed asset.
    /// @param from       The seller.
    /// @param maxAssetIn The signed ceiling, in the token's VISIBLE units.
    /// @return requestedUnits What the pull asked for, in the asset's own unit of account, so the
    ///                        caller can compare it against the delta it measured.
    function _pullAssetUnits(uint8 mode, address assetToken, address from, uint256 maxAssetIn)
        internal
        returns (uint256 requestedUnits)
    {
        if (mode == uint8(AssetAccountingMode.Erc20Balance)) {
            IERC20(assetToken).safeTransferFrom(from, address(this), maxAssetIn);
            return maxAssetIn;
        }
        if (mode == uint8(AssetAccountingMode.RebasingShares)) {
            requestedUnits = IShareAccountingToken(assetToken).getSharesByUnderlyingAmount(maxAssetIn);
            // ⚠️ The return is checked for the reason `_forwardAssetUnits` checks its own: there
            //    is no SafeERC20 equivalent for the share surface, so nothing normalises a token
            //    that reports failure by returning false instead of reverting.
            if (!IShareAccountingToken(assetToken).transferSharesFrom(from, address(this), requestedUnits)) {
                revert ShareTransferFailed();
            }
            return requestedUnits;
        }
        revert UnsupportedAccountingMode(mode);
    }
}
