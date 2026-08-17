// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FaucetToken} from "./FaucetToken.sol";

/// @title DinariLikeVenue
/// @notice A third-party settlement venue shaped like **Dinari**, which is the supplier the
///         constrained executor is meant to be proved against first. Backed's settlement
///         semantics are blocked on unanswered vendor questions, so nothing here is modelled
///         on them.
///
///         The three traits that matter to `VenueSettler`, and the only reasons this mock
///         exists rather than a generic "swap" stub:
///
///           1. **It PULLS, it is not pushed.** Dinari's order processor takes the payment
///              token with `transferFrom(msg.sender, …)` against an allowance the caller set
///              beforehand. So the router must approve, and the router's exposure is exactly
///              what it approved — which is what makes "approve exactly `venueQuoteIn`, then
///              set it back to zero" the load-bearing control rather than a tidy-up.
///           2. **It may pull LESS than it was allowed.** An order that fills at a better
///              price, or that rounds a share quantity down, consumes part of the quote and
///              leaves the rest. That is normal supplier behaviour, not an error, and the
///              difference has to come back to the buyer in the same transaction.
///           3. **It delivers to a `recipient` named in the order**, not to its caller. The
///              asset therefore lands on the buyer directly and the delta the router measures
///              is the buyer's, not its own.
///
/// @dev    Deliberately synchronous. Real Dinari fills asynchronously — an operator settles
///         the order in a later transaction — which the constrained executor does not model; it
///         asserts a delivery it measured inside one transaction. A mock that filled later
///         could not exercise a single line of the assertion this packet is about.
///
///         Delivery is a permissionless `FaucetToken.mint`, mirroring a dShare being minted
///         on fill rather than moved out of an inventory.
///
///         The adversarial variants — a venue that lies about what it took, that re-enters,
///         that over-delivers — belong to AO-551 and are not built here.
contract DinariLikeVenue {
    /// @notice One order, in the shape Dinari's processor takes it: both quantities, both
    ///         tokens and the recipient, all named by the caller.
    /// @param paymentToken  The currency the venue pulls.
    /// @param paymentAmount How much of it to pull. May be less than the allowance granted.
    /// @param assetToken    The asset to deliver.
    /// @param assetAmount   How much of it to deliver.
    /// @param recipient     Who receives `assetAmount`. The buyer, never the router.
    struct Order {
        address paymentToken;
        uint256 paymentAmount;
        address assetToken;
        uint256 assetAmount;
        address recipient;
    }

    /// @notice Makes the next `requestOrder` revert, so the caller's handling of a failed
    ///         venue call can be exercised. A venue that rejects a stale quote is ordinary.
    bool public rejectsOrders;

    /// @notice The last order the venue accepted, for assertions.
    Order public lastOrder;

    /// @dev A venue that rejects the order it is handed.
    error OrderRejected();

    /// @notice Accept and immediately fill one order.
    /// @param order The order to fill.
    /// @return filled The payment actually consumed, which is `order.paymentAmount`.
    function requestOrder(Order calldata order) external returns (uint256 filled) {
        if (rejectsOrders) revert OrderRejected();

        lastOrder = order;
        if (order.paymentAmount != 0) {
            IERC20(order.paymentToken).transferFrom(msg.sender, address(this), order.paymentAmount);
        }
        if (order.assetAmount != 0) {
            FaucetToken(order.assetToken).mint(order.recipient, order.assetAmount);
        }
        return order.paymentAmount;
    }

    /// @notice Toggle order rejection.
    /// @param rejects Whether the next order should be rejected.
    function setRejectsOrders(bool rejects) external {
        rejectsOrders = rejects;
    }
}
