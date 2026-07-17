// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title FeeMath
/// @notice Pure fee-split / ceiling-division helpers shared by OrderBook and
///         OfferBook. Dependency-free (own BPS_DENOMINATOR constant) so the
///         libs/ layer never imports from gates/.
library FeeMath {
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @dev Floor division: fee amounts are rounded down, benefiting the payer
    ///      over the fee collector — matches every existing call site exactly.
    function feeAmount(uint256 amount, uint16 bps) internal pure returns (uint256) {
        return (amount * bps) / BPS_DENOMINATOR;
    }

    /// @dev Ceiling division. Multiplication is left at the call site so the
    ///      overflow-checked arithmetic ordering matches the original inline
    ///      expression exactly.
    function ceilDiv(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        return (numerator + denominator - 1) / denominator;
    }
}
