// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ISettlementLimits
/// @notice The admin surface and vocabulary of the per-transaction settlement cap: the largest
///         amount one settlement may put at risk of being debited from a buyer, per settlement
///         token.
///
///         ⚠️ The charge is made ONCE, by `SettlementLimits._authorizeSettlement`, for every
///         settlement path — not by each path, which is what it used to be and which left the
///         then-planned mint family free to ship uncapped. The number is `venueQuoteIn +
///         buyerFee`, the full authorised debit, BEFORE any external call, because the refund is
///         unknown until after a venue has been called and a cap checked afterwards is a check
///         made after the money moved. Earlier wording here promised "the amount ACTUALLY
///         DEBITED rather than the quoted one"; nothing implements that and it is gone.
///
/// @dev    ⚠️ **This is a bound on BUGS, not on theft, and the distinction decides how to size
///         it.** An earlier revision of this module carried a per-day cap as well and was
///         justified as "the only remaining contract-level limit on how much one compromised
///         key can move". That justification was wrong and was withdrawn on 2026-08-14, for the
///         same reason the venue allowlist before it was wrong:
///
///           * What actually bounds a compromised signer is **the sum of live buyer
///             allowances**, because the router can only move tokens a buyer has already
///             approved to it. With exact-amount approvals per call, that is roughly the orders
///             in flight — and no cap sized not to hinder a regulated brokerage sits below it,
///             since legitimate daily volume is by definition at least the value of orders in
///             flight.
///           * A daily cap without somebody watching does not prevent a loss, it schedules one:
///             the drain takes a few days instead of an afternoon.
///           * The structural controls are elsewhere and are real: four signatures from four
///             distinct parties (the buyer among them) with both attestations bound to the
///             intent's struct hash, exact-amount approvals, and a pause.
///           * 🔴 And for OUR OWN issuance specifically, the control that actually bites is not
///             in this repo at all: the per-token sale contract the router calls (AO-137). It
///             holds the minting right the router deliberately does not, and it mints only
///             against payment it has received, so an intent with a zero quote makes its own
///             pull fail and nothing is minted. The signer cannot mint without paying, whatever
///             they sign. `AsseteraPrimarySales`'s header carries the full argument, including
///             why the alternatives — an allowlist, a value cap, a structural recipient — each
///             failed to bound the same attacker.
///
///         What a per-transaction cap **does** catch, reliably and for two storage reads, is an
///         arithmetic or decimals bug: treating 6-decimal USDC as 18-decimal is a factor of a
///         trillion, and that class of mistake is common in exactly this kind of integration.
///         Sized at ten or a hundred times the largest plausible order it never fires in normal
///         business, needs no volume forecast, and turns that bug into a revert instead of a
///         drained allowance. Size it that way, not as a loss limit.
///
///         ⚠️ Do not reintroduce a venue or selector allowlist here either. Nothing on-chain
///         constrains what the router calls, deliberately (decided 2026-08-13): an allowlist did
///         not bound a compromised signer's loss, because the attacker names the genuine venue
///         and selector with `minAssetOut = 0`. It could not have protected the minting right
///         either, back when a mint path inside this router was still planned — such a path
///         would have had to allowlist `(ourToken, mint)` for the feature to work at all, which
///         authorises exactly the call it was meant to refuse. That is now moot in the strongest
///         way available: the router holds no minting right on any path.
interface ISettlementLimits {
    /// @notice The per-transaction cap for one settlement token changed.
    /// @param token      The settlement currency the cap applies to.
    /// @param wholeUnits The cap as it was SET: whole tokens, the number a human typed.
    /// @param rawCap     The cap as it is STORED and enforced: `wholeUnits * 10 ** decimals`.
    /// @param decimals   The token's decimals at the moment the cap was set, on the record so a
    ///                   token that later changes them can be spotted.
    event SettlementCapSet(address indexed token, uint256 wholeUnits, uint256 rawCap, uint8 decimals);

    /// @dev One settlement's debit exceeds the per-transaction cap for its settlement token.
    ///      Also raised when the token has no cap at all, which is the fail-closed default: the
    ///      reported `cap` is then zero, which is the whole diagnosis.
    error PerTxCapExceeded(address token, uint256 amount, uint256 cap);
    /// @dev The token does not report `decimals()`, so a whole-unit cap cannot be converted into
    ///      the raw units the settlement path compares against. Fails closed: the cap is not set
    ///      and the token stays unsettleable.
    error TokenDecimalsUnavailable(address token);
    /// @dev The token reports more decimals than any real settlement currency, and converting a
    ///      whole-unit cap at that scale would be arithmetic nobody intended.
    error TokenDecimalsImplausible(address token, uint256 decimals);

    /// @notice Per-transaction cap on the amount debited, for one settlement token, in the
    ///         token's own RAW units. Zero means the token cannot be settled in at all.
    function perTxCap(address token) external view returns (uint256);

    /// @notice The same cap in WHOLE tokens, exactly as it was set. Kept as a separate read so
    ///         an operator can confirm the number they typed without knowing the decimals.
    function perTxCapWholeUnits(address token) external view returns (uint256);

    /// @notice Set the per-transaction cap for one settlement token, in WHOLE TOKENS.
    ///
    ///         ⚠️ The unit is deliberately whole tokens rather than raw units, and that is the
    ///         answer to "how does a cap work across currencies with different decimals". The
    ///         contract reads the token's `decimals()` once, here, and stores
    ///         `wholeUnits * 10 ** decimals`; the settlement path then compares raw against raw
    ///         with no external call and no conversion. One million is `1_000_000` whether the
    ///         currency has six decimals or eighteen.
    ///
    ///         The operational reason matters as much as the arithmetic one: this calldata is
    ///         pasted into a Safe UI and read by a human before it is signed, following the
    ///         `ExchangeAdmin` pattern. `1000000` is checkable at a glance;
    ///         `1000000000000000000000000` is how a cap ends up a trillion times too large,
    ///         which is precisely the failure this module exists to catch.
    ///
    /// @param token      The settlement currency. Never `address(0)`.
    /// @param wholeUnits The cap in whole tokens. Zero closes the token again.
    function setSettlementCap(address token, uint256 wholeUnits) external;
}
