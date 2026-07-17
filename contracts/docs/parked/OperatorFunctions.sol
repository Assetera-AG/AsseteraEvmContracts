// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {KycGate} from "../gates/KycGate.sol";
import {FeeMath} from "../libs/FeeMath.sol";

// ============================================================================
// PARKED (AC-246) — operator-role functions. NOT COMPILED, NOT DEPLOYED.
//
// This file lives under `docs/parked/` on purpose: it is outside the Foundry
// source tree (`src/`), so it is not compiled, not part of any deployed
// bytecode, and explicitly out of audit scope (see `contracts/AUDIT-SCOPE.md`).
// It is retained as a reference implementation, not live code — the import
// paths above are written relative to its re-enable home (`src/admin/`).
//
// Standard operation needs no operator actions: settlement/matching isn't done
// on-chain by an operator. `settle` and `refund` are parked here — kept as a
// reference, not deleted — so they can be re-enabled later via a single UUPS
// upgrade if ever needed, without carrying live, reachable, rarely exercised
// privileged code paths on the active surface today.
//
// `settleOffer` is NOT parked here — it's retired. Its logic was merged
// directly into `OfferBook.acceptOffer` (still AC-246): acceptance settles
// atomically in the same call, so there's no separate settle step for offers
// to ever re-enable. See `OfferBook.sol`.
//
// `pause`/`unpause` moved from OPERATOR_ROLE to DEFAULT_ADMIN_ROLE (now in
// admin/ExchangeAdmin.sol) — a "stop the venue" lever is worth keeping active,
// admin-gated. `cancelOrderForUser`/`cancelOfferForUser` (already
// DEFAULT_ADMIN_ROLE, in admin/ExchangeAdmin.sol) remain the emergency-exit
// path: if the platform ceases operation, reassign admin (Safe) and
// cancel/return everyone's orders and offers — no operator role needed.
//
// To re-enable:
//   1. Move this file back to `src/admin/OperatorFunctions.sol` (the import
//      paths above are already written relative to that location).
//   2. Delete the `/*` / `*/` markers below to uncomment this whole block.
//   3. Add `OperatorFunctions` to `OrderBook`'s `is` list (already inherits
//      `KycGate`, so no further wiring is needed there).
//   4. Grant `OPERATOR_ROLE` to the operator. The `operator` param was dropped
//      from `AsseteraExchange.sol::initialize` (commit 78aee84), so there is no
//      commented-out grant line to uncomment — either add an `operator` param
//      back to `initialize` (breaking initializer change, needs a fresh deploy
//      like the `feeSigner` addition did) or add a `reinitializer` function that
//      grants `OPERATOR_ROLE` on an already-initialized proxy.
//   5. Deploy a new implementation and call `upgradeToAndCall`.
// ============================================================================

/*
abstract contract OperatorFunctions is KycGate {
    using SafeERC20 for IERC20;

    /// @notice Settlement agent: settle matched orders, refund. (Safe in prod.)
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @dev settledSellAmount/settledBuyAmount are gross (pre-fee) quantities.
    event OrderSettled(
        uint256 indexed buyId,
        uint256 indexed sellId,
        address indexed operator,
        uint256 settledSellAmount,
        uint256 settledBuyAmount,
        uint256 buyMakerFeeAmount,
        uint256 sellMakerFeeAmount,
        address buyFeeCollector,
        address sellFeeCollector
    );
    event OrderRefunded(uint256 indexed id, address indexed maker, address indexed operator, string reason);

    error NotComplementary(uint256 buyId, uint256 sellId);
    error PriceNotCrossed(uint256 buyId, uint256 sellId);

    /// @notice Settle two complementary orders. Both makers must present a fresh
    ///         KYC attestation. The operator decides when to call settle — the
    ///         contract transfers each order's full remaining quantity to the
    ///         counterparty, supporting partial-fill scenarios.
    function settle(uint256 buyId, uint256 sellId, KycAttestation calldata attBuy, KycAttestation calldata attSell)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
    {
        Order storage a = _orders[buyId];
        Order storage b = _orders[sellId];
        if (a.status != OrderStatus.Open) revert OrderNotOpen(buyId);
        if (b.status != OrderStatus.Open) revert OrderNotOpen(sellId);
        if (a.expireTs != 0 && block.timestamp > a.expireTs) revert OrderIsExpired(buyId);
        if (b.expireTs != 0 && block.timestamp > b.expireTs) revert OrderIsExpired(sellId);
        if (a.sellToken != b.buyToken || a.buyToken != b.sellToken) revert NotComplementary(buyId, sellId);
        if (a.maker == b.maker) revert SelfTrade(buyId);

        // Settle full remaining quantities of both orders.
        uint256 settleA = a.remainingQuantity; // a.sellToken → b.maker
        uint256 settleB = b.remainingQuantity; // b.sellToken → a.maker

        // Price check at remaining quantities via cross-multiplication (no division).
        // Each maker receives at least the rate their original limit price implies.
        // Equivalent to the original-amount comparison when neither order has been partially filled.
        if (settleB * a.sellAmount < settleA * a.buyAmount) revert PriceNotCrossed(buyId, sellId);
        if (settleA * b.sellAmount < settleB * b.buyAmount) revert PriceNotCrossed(buyId, sellId);

        // Verify both attestations before consuming either nonce so that an invalid
        // second attestation cannot burn the first maker's nonce on a failed call.
        _verifyKyc(a.maker, Action.Settle, buyId, attBuy);
        _verifyKyc(b.maker, Action.Settle, sellId, attSell);
        if (complianceRequired[Action.Settle]) {
            usedNonce[a.maker][attBuy.nonce] = true;
            emit KycConsumed(a.maker, Action.Settle, buyId, attBuy.nonce);
            usedNonce[b.maker][attSell.nonce] = true;
            emit KycConsumed(b.maker, Action.Settle, sellId, attSell.nonce);
        }

        // Per-order maker fees applied to what each maker receives.
        // settleB = what a.maker receives (b's sellToken); settleA = what b.maker receives (a's sellToken).
        uint256 buyMakerFeeAmount = FeeMath.feeAmount(settleB, a.makerFeeBps);
        uint256 sellMakerFeeAmount = FeeMath.feeAmount(settleA, b.makerFeeBps);

        a.remainingQuantity = 0;
        b.remainingQuantity = 0;
        a.status = OrderStatus.Settled;
        b.status = OrderStatus.Settled;

        IERC20(a.sellToken).safeTransfer(b.maker, settleA - sellMakerFeeAmount);
        if (sellMakerFeeAmount > 0) IERC20(a.sellToken).safeTransfer(b.feeCollector, sellMakerFeeAmount);
        IERC20(b.sellToken).safeTransfer(a.maker, settleB - buyMakerFeeAmount);
        if (buyMakerFeeAmount > 0) IERC20(b.sellToken).safeTransfer(a.feeCollector, buyMakerFeeAmount);

        emit OrderSettled(
            buyId,
            sellId,
            _msgSender(),
            settleA,
            settleB,
            buyMakerFeeAmount,
            sellMakerFeeAmount,
            a.feeCollector,
            b.feeCollector
        );
    }

    /// @notice Operator returns an open order's remaining escrow to its maker.
    function refund(uint256 id, string calldata reason) external onlyRole(OPERATOR_ROLE) nonReentrant {
        Order storage o = _orders[id];
        if (o.status != OrderStatus.Open) revert OrderNotOpen(id);
        o.status = OrderStatus.Refunded;
        IERC20(o.sellToken).safeTransfer(o.maker, o.remainingQuantity);
        emit OrderRefunded(id, o.maker, _msgSender(), reason);
    }

}
*/
