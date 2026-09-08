// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title EscrowPull
/// @notice The one way tokens enter the exchange's escrow: pull, and MEASURE what arrived.
///
///         The exchange holds one pooled balance per token. Every order's `remainingQuantity` and
///         every offer's escrowed leg is a claim on that pool, and the pool pays each claim at its
///         recorded size. So the recorded size has to be what the token actually delivered, not what
///         the caller asked it to move. A token that charges a fee on transfer delivers less than
///         requested; recording the request would overstate the pool, and the shortfall would be
///         paid out of somebody else's escrow, with the last claimant unable to withdraw at all.
///
///         This helper reads the exchange's balance before and after the pull and returns the delta.
///         Callers decide what to do with a shortfall: an order credits what arrived, an offer refuses
///         it, because an offer's two legs are negotiated as a pair and cannot be scaled one-sidedly.
///         Neither caller ever credits MORE than it asked for, so a token that over-delivers cannot
///         mint a claim out of thin air; and a token whose transfer LOWERS this contract's balance
///         reverts on the checked subtraction rather than opening a negative-sized claim.
///
///         The measurement costs two `balanceOf` reads per pull. Every pull site is `nonReentrant`,
///         so a token that re-enters the exchange between the two reads cannot move the pool.
abstract contract EscrowPull {
    using SafeERC20 for IERC20;

    /// @dev The token delivered less than the caller asked it to move, and the caller cannot absorb
    ///      the difference. `requested` is what was asked for, `received` the measured delta. The
    ///      token is the one named in the call that reverted.
    error EscrowPullShort(uint256 requested, uint256 received);

    /// @dev Pull `amount` of `token` from `from` into this contract and return what actually arrived.
    function _pullEscrow(address token, address from, uint256 amount) internal returns (uint256 received) {
        IERC20 erc20 = IERC20(token);
        uint256 before = erc20.balanceOf(address(this));
        erc20.safeTransferFrom(from, address(this), amount);
        received = erc20.balanceOf(address(this)) - before;
    }
}
