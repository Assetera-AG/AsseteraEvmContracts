// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SettlementLimits} from "../admin/SettlementLimits.sol";
import {ISettler} from "../interfaces/ISettler.sol";

/// @title VenueSettler
/// @notice **STUB — the constrained-executor packet owns this body.** Family S2: the buyer
///         settles against a third-party venue (Dinari, Backed, …) whose call we do not
///         control and never allowlist.
///
///         `AsseteraPrimarySales.settlePrimary` has already done everything that is common to
///         every family by the time this runs: all three signatures verified, the calldata
///         bound by hash and selector, both attestations pinned to the intent's struct hash,
///         all three nonces burned. What is left is exactly the money, and that is this file.
///
/// @dev    What the executor packet implements in `_settleVenue`, in order:
///           1. snapshot `assetToken.balanceOf(intent.buyer)` and this contract's own
///              `settlementToken` balance;
///           2. pull `venueQuoteIn + buyerFee` from the buyer (never an unlimited allowance —
///              permit or an exact amount per call) and charge it against
///              `_consumeSettlementLimit`;
///           3. approve EXACTLY `venueQuoteIn` to `intent.venue` and call it with
///              `venueCalldata`;
///           4. set the approval back to zero, refund whatever the venue did not consume to
///              the buyer, and assert this contract's settlement-token balance returned to its
///              pre-call value (`RouterBalanceChanged`);
///           5. assert the measured asset delta is at least `minAssetOut`
///              (`InsufficientAssetDelivered`) — a revert, never a silent bad fill;
///           6. transfer `buyerFee` to `intent.feeCollector`;
///           7. return the four MEASURED numbers.
///
///         Two obligations that belong here rather than in the entry point, because they are
///         arithmetic rather than well-formedness:
///           * `intent.buyerFee` must equal what `FeeMath` derives from the attested
///             `takerFeeBps` on `venueQuoteIn`, rounded in our favour, pinned by a test with
///             the exact vector as the exchange already does. Without that cross-check the
///             fee is whatever the settlement signer typed.
///           * The venue MAY consume less than approved and the difference MUST be refunded
///             in the same transaction. Leaving dust contradicts the zero-standing-balance
///             invariant, and reverting instead would break every venue that rounds down.
///
///         ⚠️ The balance-delta assertion is safe here and only here: measured inside one
///         transaction, a rebase cannot occur mid-call. Any path that holds a rebasing asset
///         (which is what xStocks are) ACROSS blocks and reasons about a raw balance is wrong.
abstract contract VenueSettler is SettlementLimits, ISettler {
    /// @dev The internal seam for family S2. Not an address, not a `delegatecall` target, not
    ///      an external call — one proxy, inherited modules (§4.5).
    ///
    ///      Takes the opaque venue calldata (already bound by hash and selector) and the
    ///      verified settlement intent; returns the four MEASURED numbers the settlement event
    ///      reports. Parameters are left unnamed so the stub compiles warning-free.
    function _settleVenue(bytes calldata, SettlementIntent calldata)
        internal
        virtual
        returns (SettlementResult memory)
    {
        revert SettlerNotImplemented();
    }
}
