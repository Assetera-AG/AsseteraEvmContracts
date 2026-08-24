// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BackedLikeShareToken} from "./BackedLikeShareToken.sol";

/// @title XStocksLikeVenue
/// @notice A settlement venue shaped like the **xStocks `AtomicSwap`** contract, which differs
///         from `DinariLikeVenue` in the two ways that matter to AO-713:
///
///           1. **It delivers out of its own inventory with a NOMINAL transfer**, rather than
///              minting. That single nominal hop is where the first integer division into
///              shares happens, and it is why the router can never receive the provider's
///              quoted amount exactly.
///           2. **The recipient is whoever the signed swap message names**, and in the Assetera
///              route that is the ROUTER, because xStocks only quotes to wallets registered at
///              its API layer. The asset therefore transits, and the router has to forward it.
///
/// @dev    It can also move the asset's multiplier mid-call. That is not hostile behaviour: a
///         Backed multiplier moves on a stock split, a dividend or a fee accrual, and none of
///         those are things Assetera schedules. A settlement that cannot survive one is a
///         settlement that reverts on corporate-action day.
contract XStocksLikeVenue {
    /// @notice One swap, in the shape xStocks signs it.
    /// @param paymentToken  The currency the venue pulls from its caller.
    /// @param paymentAmount How much of it to pull. May be less than the allowance granted.
    /// @param assetToken    The asset to deliver.
    /// @param assetAmount   The NOMINAL amount to deliver, as the provider's quote states it.
    /// @param recipient     Who receives it. The router, in the Assetera route.
    struct Swap {
        address paymentToken;
        uint256 paymentAmount;
        address assetToken;
        uint256 assetAmount;
        address recipient;
    }

    /// @notice When non-zero, the multiplier the asset is moved to DURING the swap, before the
    ///         asset is delivered. Simulates a corporate action landing inside our transaction.
    uint256 public multiplierDuringCall;

    /// @notice The last swap the venue accepted, for assertions.
    Swap public lastSwap;

    /// @notice Fill one swap: pull the payment, optionally rebase, then deliver nominally.
    /// @param swap The swap to fill.
    /// @return filled The payment actually consumed.
    function executeSwap(Swap calldata swap) external returns (uint256 filled) {
        lastSwap = swap;

        if (swap.paymentAmount != 0) {
            IERC20(swap.paymentToken).transferFrom(msg.sender, address(this), swap.paymentAmount);
        }

        // Ordered BEFORE delivery on purpose. A multiplier change that landed after the transfer
        // would leave the router's share count untouched and prove nothing; landing it here
        // means the nominal delivery below is itself converted at the NEW multiplier, which is
        // what a corporate action inside the settlement transaction actually looks like.
        if (multiplierDuringCall != 0) {
            BackedLikeShareToken(swap.assetToken).setMultiplier(multiplierDuringCall);
        }

        if (swap.assetAmount != 0) {
            IERC20(swap.assetToken).transfer(swap.recipient, swap.assetAmount);
        }
        return swap.paymentAmount;
    }

    /// @notice Schedule a mid-call multiplier change. Zero disables it.
    /// @param multiplier_ The multiplier to move the asset to during the next swap.
    function setMultiplierDuringCall(uint256 multiplier_) external {
        multiplierDuringCall = multiplier_;
    }
}
