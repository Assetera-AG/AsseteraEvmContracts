// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ISettlementLimits
/// @notice The admin surface and vocabulary of the settlement value caps: a per-transaction
///         cap and a rolling per-day cap, per settlement token, enforced on the amount
///         ACTUALLY DEBITED rather than on the quoted one.
///
///         Frozen by the skeleton packet so the constrained-executor packet can code against
///         it with a mock and not wait for the implementation.
///
/// @dev    ⚠️ This is **not** a venue or selector allowlist, and it deliberately replaced one.
///         Nothing on-chain constrains what the router calls (decided 2026-08-13): an
///         allowlist did not bound a compromised signer's loss to the buyer — the attacker
///         names the genuine venue and selector with `minAssetOut = 0` — and it could not
///         have protected the minting right either, since a generic mint path would have had
///         to allowlist `(ourToken, mint)` for the feature to work at all. Caps bound
///         IMPACT rather than likelihood, they work whether the signer is compromised or
///         merely buggy, and they need no per-supplier ceremony. With the allowlist gone this
///         is the only remaining contract-level limit on how much one compromised key can
///         move, so it is not an optional hardening pass. Do not quietly reintroduce a list.
interface ISettlementLimits {
    /// @notice The caps for one settlement token changed.
    /// @param token     The settlement currency the caps apply to.
    /// @param perTxCap  New per-transaction cap. Zero means "no settlement in this token".
    /// @param perDayCap New rolling per-day cap, across every buyer.
    event SettlementCapsSet(address indexed token, uint256 perTxCap, uint256 perDayCap);

    /// @dev One settlement's debit exceeds the per-transaction cap for its settlement token.
    error PerTxCapExceeded(address token, uint256 amount, uint256 cap);
    /// @dev This settlement would push the rolling daily total past the per-day cap.
    error PerDayCapExceeded(address token, uint256 amount, uint256 cap);
    /// @dev The caps module has not been implemented yet. Fails closed: an unimplemented cap
    ///      must block a settlement, never wave it through.
    error SettlementLimitsNotImplemented();

    /// @notice Per-transaction cap on the amount debited, for one settlement token.
    function perTxCap(address token) external view returns (uint256);

    /// @notice Rolling per-day cap on the amount debited, for one settlement token.
    function perDayCap(address token) external view returns (uint256);

    /// @notice How much of the current day's allowance has already been consumed for a token.
    function settledToday(address token) external view returns (uint256);

    /// @notice Set both caps for one settlement token. Admin only, with an event, following
    ///         the `ExchangeAdmin` pattern (calldata pasted into the Safe UI) rather than a
    ///         new ownership model.
    function setSettlementCaps(address token, uint256 newPerTxCap, uint256 newPerDayCap) external;
}
