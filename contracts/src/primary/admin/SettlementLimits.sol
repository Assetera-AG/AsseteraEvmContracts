// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IntentGate} from "../IntentGate.sol";
import {ISettlementLimits} from "../interfaces/ISettlementLimits.sol";

/// @title SettlementLimits
/// @notice Per-transaction and per-day caps on settled value, per settlement token, enforced on
///         the amount ACTUALLY DEBITED from the buyer — the quote minus whatever the venue did
///         not take — rather than on the quoted one. The settler families call
///         `_consumeSettlementLimit` once the refund is known.
///
///         Two dimensions, and only two:
///           * **Per settlement token.** A cap in USDC units is meaningless applied to a token
///             with different decimals or a different price, so there is one pair of caps per
///             currency and no global one.
///           * **Per day, across every buyer.** There is deliberately no buyer dimension. A
///             per-buyer daily cap bounds nothing: the settlement operator names the buyer in
///             the intent it signs, so a compromised signer would mint a fresh buyer per
///             settlement and spend a fresh allowance each time. What has to be bounded is what
///             the ROUTER can move in a day.
///
/// @dev    ⚠️ This packet was a venue and selector allowlist until 2026-08-13 and is
///         deliberately no longer one. Do not quietly reintroduce a list: it did not bound a
///         compromised signer's damage to the buyer — the attacker names the *genuine* venue
///         and selector with `minAssetOut = 0` — and it did not protect the minting right,
///         because a generic mint path would have had to allowlist `(ourToken, mint)` for the
///         feature to work at all. Caps bound IMPACT rather than likelihood, and with nothing
///         on-chain constraining the call target they are the only remaining contract-level
///         limit on how much a single compromised key can move. If a change here starts to look
///         like `mapping(address => bool) allowed`, it is the wrong change.
///
///         **A ZERO `perTxCap` means "no settlement in this token at all", not "unlimited".**
///         That is the whole default: every token starts unconfigured, so a currency nobody
///         deliberately sized cannot be settled in, and the same setter that opens a token
///         closes it again. `_consumeSettlementLimit` tests the zero explicitly rather than
///         relying on `amountDebited > 0`, because a zero debit against a zero cap would
///         otherwise pass the comparison and wave an unconfigured token through.
///
///         **The daily window is a FIXED UTC-DAY BUCKET** (`block.timestamp / 1 days`), not a
///         sliding 24-hour window, and that is a deliberate trade rather than an approximation
///         nobody noticed:
///           * A true sliding window has to remember every settlement's timestamp and amount
///             and prune them as they age out. That is unbounded storage growth and unbounded
///             gas on a path that already does three `ecrecover`s and several token transfers,
///             and it makes one unlucky buyer pay for everybody else's pruning. On a router
///             whose entire purpose is to bound loss, a limit that can itself be griefed into
///             costing more gas than the block allows is not a limit.
///           * A decaying "leaky bucket" (subtract `elapsed * cap / 1 days` on each touch)
///             is O(1) too and has no boundary step, but it turns the cap into a drip rate:
///             `settledToday` would no longer answer "how much has moved today", which is the
///             question the interface asks and the one an operator, a compliance officer and a
///             daily reconciliation actually ask.
///           * The price of the bucket is a KNOWN, BOUNDED boundary effect: up to `2 *
///             perDayCap` can move across a single UTC midnight, by filling the cap just before
///             and again just after. That is pinned by
///             `test_Window_AllowsTwiceThePerDayCapAcrossABoundary` so it is a documented
///             property rather than a surprise, and it is priced in by halving the cap if the
///             true 24-hour exposure is what needs sizing.
///
///         Caps default to zero and this packet deploys nothing. Sizing real ones needs
///         evidence the contract cannot supply: the observed distribution of primary-sale
///         order sizes (so the per-tx cap sits above the legitimate tail rather than through
///         it), the daily settled volume per currency, and the loss the business is willing to
///         absorb between a signer compromise and the multisig reacting. A cap high enough
///         never to fire is theatre; one low enough to break a legitimate large order creates a
///         support path that gets used to argue for raising it.
abstract contract SettlementLimits is IntentGate, ISettlementLimits {
    /// @notice The length of one cap window: a fixed UTC day, indexed by
    ///         `block.timestamp / SETTLEMENT_CAP_WINDOW`. Public so ops and the admin UI read
    ///         the window from the contract rather than assuming it.
    uint256 public constant SETTLEMENT_CAP_WINDOW = 1 days;

    // --------------------------------------------------------------------- //
    //                            Public getters                              //
    // --------------------------------------------------------------------- //

    /// @inheritdoc ISettlementLimits
    /// @dev Zero is the fail-closed default and means the token cannot be settled in.
    function perTxCap(address token) public view returns (uint256) {
        return _primary().settlementPerTxCap[token];
    }

    /// @inheritdoc ISettlementLimits
    function perDayCap(address token) public view returns (uint256) {
        return _primary().settlementPerDayCap[token];
    }

    /// @inheritdoc ISettlementLimits
    /// @dev Reads ZERO once the window has rolled, without anybody having to touch the
    ///      contract to clear it. The accumulator is only cleared lazily, on the next
    ///      settlement, so returning the raw stored number would report yesterday's total as
    ///      today's — and every off-chain consumer of this getter would size headroom against
    ///      a figure that is about to be discarded.
    function settledToday(address token) public view returns (uint256) {
        PrimaryData storage $ = _primary();
        if ($.settlementCapWindow[token] != _capWindow()) return 0;
        return $.settledInCapWindow[token];
    }

    // --------------------------------------------------------------------- //
    //                             Admin surface                              //
    // --------------------------------------------------------------------- //

    /// @inheritdoc ISettlementLimits
    /// @dev `DEFAULT_ADMIN_ROLE` — the Safe multisig in production — following `ExchangeAdmin`
    ///      rather than a new ownership model: one setter, one event, calldata a human can read
    ///      in the Safe UI. Deliberately NOT the settlement operator's role. These caps are the
    ///      only contract-level bound on what that key can move, so letting it raise its own
    ///      ceiling would leave no bound at all.
    ///
    ///      Both caps are written together, on purpose. They are one policy for one currency,
    ///      and a two-setter surface has a window in which half of a policy is live.
    ///
    ///      No relationship between the two is enforced. `newPerDayCap < newPerTxCap` simply
    ///      makes the per-transaction cap unreachable and lets the daily one bind, which is
    ///      coherent and occasionally what you want; `(0, 0)` is how a token is closed again.
    ///      Every combination fails CLOSED, so there is nothing here worth a revert.
    ///
    /// @param token        The settlement currency the caps apply to. Never `address(0)` — that
    ///                     is a fat-fingered Safe transaction, not a policy.
    /// @param newPerTxCap  New per-transaction cap on the amount debited. Zero closes the token.
    /// @param newPerDayCap New per-day cap on the amount debited, across every buyer.
    function setSettlementCaps(address token, uint256 newPerTxCap, uint256 newPerDayCap)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (token == address(0)) revert ZeroAddress();

        PrimaryData storage $ = _primary();
        $.settlementPerTxCap[token] = newPerTxCap;
        $.settlementPerDayCap[token] = newPerDayCap;

        // The day's accumulator is deliberately NOT reset. Lowering a cap mid-day must not hand
        // back the allowance already spent under the old one, which is exactly the move an
        // attacker who has reached the admin role would otherwise make; and raising it must not
        // require the operator to first forget what has already moved.
        emit SettlementCapsSet(token, newPerTxCap, newPerDayCap);
    }

    // --------------------------------------------------------------------- //
    //                             Enforcement                                //
    // --------------------------------------------------------------------- //

    /// @dev Charge one settlement against the caps for its settlement token, and revert if it
    ///      does not fit. Called by each settler family with the amount actually debited from
    ///      the buyer — after the refund is known, not the quote.
    ///
    ///      Order matters: the per-transaction cap is checked FIRST, so a single oversized
    ///      settlement reports `PerTxCapExceeded` rather than being reported as having
    ///      exhausted the day. Both errors carry the debited amount, which is what makes it
    ///      possible to tell from a revert alone whether the caller charged the debit or the
    ///      quote.
    ///
    ///      This writes, so it must be called AFTER the debit is measured and BEFORE the
    ///      transaction can end; a family that reverts later unwinds the accumulator with the
    ///      rest of the state, which is the correct behaviour — an unsettled settlement
    ///      consumes no allowance.
    ///
    /// @param token         The settlement currency being debited.
    /// @param amountDebited The amount ACTUALLY taken from the buyer: quote plus fee, minus the
    ///                      refund the venue did not consume.
    function _consumeSettlementLimit(address token, uint256 amountDebited) internal virtual {
        PrimaryData storage $ = _primary();

        uint256 txCap = $.settlementPerTxCap[token];
        // ⚠️ The `txCap == 0` test is load-bearing and not redundant with the comparison after
        //    it. A zero cap means "this token cannot settle", and a zero debit against a zero
        //    cap would pass `0 > 0`. That is not a hypothetical: a venue that consumed exactly
        //    nothing with a zero fee produces one, and it must not be the one debit an
        //    unconfigured currency accepts.
        if (txCap == 0 || amountDebited > txCap) revert PerTxCapExceeded(token, amountDebited, txCap);

        uint256 window = _capWindow();
        // A stale window is an EMPTY window. Clearing lazily, on the settlement that discovers
        // the roll, is what keeps the whole mechanism O(1): nobody has to be paid to run a
        // daily reset, and a token that goes untouched for a month costs nothing.
        uint256 spent = $.settlementCapWindow[token] == window ? $.settledInCapWindow[token] : 0;
        uint256 dayCap = $.settlementPerDayCap[token];
        // `spent` is bounded by `dayCap` and `amountDebited` by `txCap`, so this can only
        // overflow if an admin set caps near `type(uint256).max` — in which case checked
        // arithmetic panics, which still fails closed.
        uint256 total = spent + amountDebited;
        if (total > dayCap) revert PerDayCapExceeded(token, amountDebited, dayCap);

        $.settlementCapWindow[token] = window;
        $.settledInCapWindow[token] = total;
    }

    /// @dev The current cap window: the UTC day index. `block.timestamp` is used for bucketing
    ///      only, never as a security boundary — a validator nudging the clock by seconds moves
    ///      a settlement between two adjacent buckets and cannot create allowance that the
    ///      2× boundary effect documented above does not already grant.
    function _capWindow() internal view returns (uint256) {
        return block.timestamp / SETTLEMENT_CAP_WINDOW;
    }
}
