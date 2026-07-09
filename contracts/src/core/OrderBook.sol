// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {KycGate} from "../gates/KycGate.sol";
import {FeeGate} from "../gates/FeeGate.sol";
import {ExchangeAdmin} from "../admin/ExchangeAdmin.sol";
import {FeeMath} from "../libs/FeeMath.sol";

/// @title OrderBook
/// @notice Order lifecycle: place, self-cancel, fill, and permissionless sweep
///         of expired orders. Operator-only settle/refund are parked — see
///         admin/OperatorFunctions.sol (AC-246).
abstract contract OrderBook is KycGate, FeeGate, ExchangeAdmin {
    using SafeERC20 for IERC20;

    event OrderPlaced(
        uint256 indexed id,
        address indexed maker,
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 buyAmount,
        uint64 expireTs
    );
    event OrderCancelled(uint256 indexed id, address indexed maker);
    /// @dev Emitted when an order is completely filled (remainingQuantity == 0).
    ///      Includes fee amounts and collector for indexer/client cost disclosure.
    event OrderFilled(
        uint256 indexed id,
        address indexed maker,
        address indexed taker,
        uint256 filledSellAmount,
        uint256 filledBuyAmount,
        uint256 makerFeeAmount,
        uint256 takerFeeAmount,
        address feeCollector
    );
    /// @dev Emitted on a partial fill (remainingQuantity > 0 after the fill).
    ///      Includes fee amounts and collector for indexer/client cost disclosure.
    event OrderPartiallyFilled(
        uint256 indexed id,
        address indexed maker,
        address indexed taker,
        uint256 filledSellAmount,
        uint256 remainingQuantity,
        uint256 makerFeeAmount,
        uint256 takerFeeAmount,
        address feeCollector
    );
    event OrderExpired(uint256 indexed id, address indexed maker, uint256 remainingQuantity);

    error NotMaker(uint256 id);
    error SelfTrade(uint256 id);
    error OrderIsExpired(uint256 id);
    error FillAmountZero();
    error FillExceedsRemaining(uint256 id, uint256 remaining);

    // --------------------------------------------------------------------- //
    //                              Maker actions                             //
    // --------------------------------------------------------------------- //

    /// @param expireTs Unix timestamp after which the order can be swept; 0 = no expiry.
    /// @param att      KYC attestation authorising Place (no fee terms).
    /// @param feeAtt   Fee attestation from the fee service, authorising the fee terms
    ///                 snapshotted onto the order. Bound to the same account/action/
    ///                 paramsHash as `att` (see `_consumeKycAndFee`).
    function placeOrder(
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 buyAmount,
        uint64 expireTs,
        KycAttestation calldata att,
        FeeAttestation calldata feeAtt
    ) external whenNotPaused nonReentrant returns (uint256 id) {
        // Validate all params and paramsHash BEFORE consuming either nonce so
        // that a bad call does not burn either attestation.
        if (sellToken == address(0) || buyToken == address(0)) revert ZeroAddress();
        if (sellAmount == 0 || buyAmount == 0) revert ZeroAmount();
        if (sellToken == buyToken) revert SameToken();
        if (expireTs != 0 && expireTs <= block.timestamp) revert InvalidExpiry();
        if (complianceRequired[Action.Place]) {
            bytes32 paramsHash = keccak256(abi.encode(sellToken, sellAmount, buyToken, buyAmount));
            if (att.paramsHash != paramsHash) revert ParamsHashMismatch();
            if (feeAtt.paramsHash != paramsHash) revert ParamsHashMismatch();
        }
        // Fee bounds — always enforced (defence in depth) so a compromised fee
        // signer cannot set extreme fees or route to an unlisted collector.
        _validateFees(feeAtt.makerFeeBps, feeAtt.takerFeeBps, feeAtt.feeCollector);
        _consumeKycAndFee(_msgSender(), Action.Place, 0, att, feeAtt);
        return _placeOrder(
            sellToken,
            sellAmount,
            buyToken,
            buyAmount,
            expireTs,
            feeAtt.makerFeeBps,
            feeAtt.takerFeeBps,
            feeAtt.feeCollector
        );
    }

    /// @param expireTs Unix timestamp after which the order can be swept; 0 = no expiry.
    /// @param att      KYC attestation authorising Place (no fee terms).
    /// @param feeAtt   Fee attestation from the fee service, authorising the fee terms
    ///                 snapshotted onto the order. Bound to the same account/action/
    ///                 paramsHash as `att` (see `_consumeKycAndFee`).
    function placeOrderWithPermit(
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 buyAmount,
        uint64 expireTs,
        uint256 permitDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s,
        KycAttestation calldata att,
        FeeAttestation calldata feeAtt
    ) external whenNotPaused nonReentrant returns (uint256 id) {
        // Validate all params and paramsHash BEFORE consuming either nonce so
        // that a bad call does not burn either attestation.
        if (sellToken == address(0) || buyToken == address(0)) revert ZeroAddress();
        if (sellAmount == 0 || buyAmount == 0) revert ZeroAmount();
        if (sellToken == buyToken) revert SameToken();
        if (expireTs != 0 && expireTs <= block.timestamp) revert InvalidExpiry();
        if (complianceRequired[Action.Place]) {
            bytes32 paramsHash = keccak256(abi.encode(sellToken, sellAmount, buyToken, buyAmount));
            if (att.paramsHash != paramsHash) revert ParamsHashMismatch();
            if (feeAtt.paramsHash != paramsHash) revert ParamsHashMismatch();
        }
        _validateFees(feeAtt.makerFeeBps, feeAtt.takerFeeBps, feeAtt.feeCollector);
        _consumeKycAndFee(_msgSender(), Action.Place, 0, att, feeAtt);
        _tryPermit(sellToken, sellAmount, permitDeadline, v, r, s);
        return _placeOrder(
            sellToken,
            sellAmount,
            buyToken,
            buyAmount,
            expireTs,
            feeAtt.makerFeeBps,
            feeAtt.takerFeeBps,
            feeAtt.feeCollector
        );
    }

    function _tryPermit(address token, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) private {
        // Permit failure is intentionally swallowed: the token may not support ERC-2612,
        // or the allowance may already be sufficient. safeTransferFrom below enforces the result.
        try IERC20Permit(token).permit(_msgSender(), address(this), amount, deadline, v, r, s) {} catch {}
    }

    function _placeOrder(
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 buyAmount,
        uint64 expireTs,
        uint16 makerFeeBps,
        uint16 takerFeeBps,
        address feeCollector
    ) private returns (uint256 id) {
        address maker = _msgSender();
        id = ++totalOrders;
        _orders[id] = Order({
            id: id,
            maker: maker,
            sellToken: sellToken,
            sellAmount: sellAmount,
            buyToken: buyToken,
            buyAmount: buyAmount,
            status: OrderStatus.Open,
            createdAt: uint64(block.timestamp),
            remainingQuantity: sellAmount,
            expireTs: expireTs,
            makerFeeBps: makerFeeBps,
            takerFeeBps: takerFeeBps,
            feeCollector: feeCollector
        });

        IERC20(sellToken).safeTransferFrom(maker, address(this), sellAmount);
        emit OrderPlaced(id, maker, sellToken, sellAmount, buyToken, buyAmount, expireTs);
    }

    /// @notice Maker self-cancel. Never requires a KYC attestation — a user must
    ///         always be able to cancel their own open order and reclaim escrow.
    ///         Use cancelOrderForUser (admin) to release a frozen maker's funds
    ///         to a compliance-chosen address.
    function cancelOrder(uint256 id) external nonReentrant {
        Order storage o = _orders[id];
        if (o.status != OrderStatus.Open) revert OrderNotOpen(id);
        if (o.maker != _msgSender()) revert NotMaker(id);

        o.status = OrderStatus.Cancelled;
        IERC20(o.sellToken).safeTransfer(o.maker, o.remainingQuantity);
        emit OrderCancelled(id, o.maker);
    }

    // --------------------------------------------------------------------- //
    //                          Permissioned taker                            //
    // --------------------------------------------------------------------- //

    /// @notice Fill (part of) an open order. The taker specifies `fillSellAmount`
    ///         (how much of the order's sellToken to take). A proportional
    ///         buyToken amount is charged; the order stays Open if partially filled.
    ///         KYC-gated on the taker.
    ///
    /// @param fillSellAmount Amount of sellToken to take from this order.
    ///        Pass `order.remainingQuantity` to fully fill.
    function fillOrder(uint256 id, uint256 fillSellAmount, KycAttestation calldata att)
        external
        whenNotPaused
        nonReentrant
    {
        Order storage o = _orders[id];
        if (o.status != OrderStatus.Open) revert OrderNotOpen(id);
        if (o.expireTs != 0 && block.timestamp > o.expireTs) revert OrderIsExpired(id);
        if (fillSellAmount == 0) revert FillAmountZero();
        if (fillSellAmount > o.remainingQuantity) revert FillExceedsRemaining(id, o.remainingQuantity);

        address taker = _msgSender();
        if (o.maker == taker) revert SelfTrade(id);

        _consumeKyc(taker, Action.Fill, id, att);

        // Ceiling division: taker always pays at least the proportional buyAmount.
        // This protects the maker from rounding loss on partial fills.
        uint256 buyAmountDue = FeeMath.ceilDiv(fillSellAmount * o.buyAmount, o.sellAmount);

        // Compute fees. Floor division benefits maker/taker over the collector.
        uint256 makerFeeAmount = FeeMath.feeAmount(buyAmountDue, o.makerFeeBps);
        uint256 takerFeeAmount = FeeMath.feeAmount(fillSellAmount, o.takerFeeBps);
        address collector = o.feeCollector;

        o.remainingQuantity -= fillSellAmount;
        bool fullFill = (o.remainingQuantity == 0);
        if (fullFill) o.status = OrderStatus.Filled;

        // Taker pays buyAmountDue: (buyAmountDue - makerFeeAmount) to maker, remainder to collector.
        IERC20(o.buyToken).safeTransferFrom(taker, o.maker, buyAmountDue - makerFeeAmount);
        if (makerFeeAmount > 0) IERC20(o.buyToken).safeTransferFrom(taker, collector, makerFeeAmount);
        // Taker receives fillSellAmount minus takerFeeAmount; takerFeeAmount goes to collector.
        IERC20(o.sellToken).safeTransfer(taker, fillSellAmount - takerFeeAmount);
        if (takerFeeAmount > 0) IERC20(o.sellToken).safeTransfer(collector, takerFeeAmount);

        if (fullFill) {
            emit OrderFilled(
                id, o.maker, taker, fillSellAmount, buyAmountDue, makerFeeAmount, takerFeeAmount, collector
            );
        } else {
            emit OrderPartiallyFilled(
                id, o.maker, taker, fillSellAmount, o.remainingQuantity, makerFeeAmount, takerFeeAmount, collector
            );
        }
    }

    // --------------------------------------------------------------------- //
    //                          Permissionless sweep                          //
    // --------------------------------------------------------------------- //

    /// @notice Anyone can sweep a batch of expired orders, returning each order's
    ///         remaining escrow to the maker. Orders that are not Open, lack an
    ///         expireTs, or have not yet expired are silently skipped.
    ///         Callers should batch `ids` in chunks of at most 100 to avoid out-of-gas reverts.
    function sweepExpired(uint256[] calldata ids) external nonReentrant {
        for (uint256 i = 0; i < ids.length; i++) {
            Order storage o = _orders[ids[i]];
            if (o.status != OrderStatus.Open) continue;
            if (o.expireTs == 0 || block.timestamp <= o.expireTs) continue;

            uint256 remaining = o.remainingQuantity;
            address maker = o.maker;
            address token = o.sellToken;
            o.status = OrderStatus.Expired;
            o.remainingQuantity = 0;

            IERC20(token).safeTransfer(maker, remaining);
            emit OrderExpired(ids[i], maker, remaining);
        }
    }

    // --------------------------------------------------------------------- //
    //                                 Views                                  //
    // --------------------------------------------------------------------- //

    function getOrder(uint256 id) external view returns (Order memory) {
        return _orders[id];
    }
}
