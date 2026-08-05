// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {KycGate} from "../gates/KycGate.sol";
import {FeeGate} from "../gates/FeeGate.sol";
import {ExchangeAdmin} from "../admin/ExchangeAdmin.sol";
import {PermitRelay} from "./PermitRelay.sol";
import {FeeMath} from "../libs/FeeMath.sol";

/// @title OrderBook
/// @notice Order lifecycle: place, self-cancel, fill, and permissionless sweep
///         of expired orders. Operator-only settle/refund are parked — see
///         docs/parked/OperatorFunctions.sol (AC-246).
abstract contract OrderBook is KycGate, FeeGate, ExchangeAdmin, PermitRelay {
    using SafeERC20 for IERC20;

    /// @dev Emitted when a new order is placed. Includes the fee terms snapshotted onto the
    ///      order from the fee attestation (mirrors OfferMade, which carries its fee fields
    ///      at creation too), rather than only surfacing them once the order fills.
    event OrderPlaced(
        uint256 indexed id,
        address indexed maker,
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 buyAmount,
        uint64 expireTs,
        uint16 makerFeeBps,
        uint16 takerFeeBps,
        address feeCollector,
        address feeToken
    );
    /// @dev Emitted on maker self-cancel. `refunded` is the total sellToken amount returned to
    ///      the maker — remaining escrow PLUS any unconsumed escrowed fee (AC-833).
    event OrderCancelled(uint256 indexed id, address indexed maker, uint256 refunded);
    /// @dev Emitted when an order is completely filled (remainingQuantity == 0).
    ///      All amounts are GROSS (pre-fee); both fees are denominated in `feeToken`
    ///      (AC-833), so the collector's take is exactly makerFeeAmount + takerFeeAmount
    ///      in that one token.
    event OrderFilled(
        uint256 indexed id,
        address indexed maker,
        address indexed taker,
        uint256 filledSellAmount,
        uint256 filledBuyAmount,
        uint256 makerFeeAmount,
        uint256 takerFeeAmount,
        address feeCollector,
        address feeToken
    );
    /// @dev Emitted on a partial fill (remainingQuantity > 0 after the fill). Carries
    ///      `filledBuyAmount` (the gross notional for THIS fill) so consumers no longer
    ///      have to re-derive it by mirroring the contract's ceil-division (AC-833).
    event OrderPartiallyFilled(
        uint256 indexed id,
        address indexed maker,
        address indexed taker,
        uint256 filledSellAmount,
        uint256 filledBuyAmount,
        uint256 remainingQuantity,
        uint256 makerFeeAmount,
        uint256 takerFeeAmount,
        address feeCollector,
        address feeToken
    );
    /// @dev `refunded` is remaining escrow plus any unconsumed escrowed fee (AC-833).
    event OrderExpired(uint256 indexed id, address indexed maker, uint256 refunded);

    /// @dev An order placed before the AC-833 upgrade carries no settlement currency
    ///      (`feeToken == address(0)`), so its fees cannot be denominated correctly.
    ///      Such orders can still be cancelled/swept — they just cannot be traded.
    error LegacyOrderMustBeUnwound(uint256 id);

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
        _bindParamsHash(Action.Place, att, feeAtt, keccak256(abi.encode(sellToken, sellAmount, buyToken, buyAmount)));
        // Fee bounds + denomination — always enforced (defence in depth) so a compromised
        // fee signer cannot set extreme fees, route to an unlisted collector, or
        // denominate the fees in a token that isn't part of this trade.
        _validateFees(feeAtt, sellToken, buyToken);
        _consumeKycAndFee(_msgSender(), Action.Place, 0, att, feeAtt);
        return _placeOrder(sellToken, sellAmount, buyToken, buyAmount, expireTs, feeAtt);
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
        _bindParamsHash(Action.Place, att, feeAtt, keccak256(abi.encode(sellToken, sellAmount, buyToken, buyAmount)));
        _validateFees(feeAtt, sellToken, buyToken);
        _consumeKycAndFee(_msgSender(), Action.Place, 0, att, feeAtt);
        // Permit must cover the FULL escrow, which on a buy-side order is
        // sellAmount + the maker's escrowed fee — see `_placeOrder`.
        _tryPermit(sellToken, _escrowTotal(sellToken, sellAmount, feeAtt), permitDeadline, v, r, s);
        return _placeOrder(sellToken, sellAmount, buyToken, buyAmount, expireTs, feeAtt);
    }

    /// @dev The maker's escrowed fee (AC-833). Non-zero only when the maker is selling
    ///      the SETTLEMENT CURRENCY (a buy-side order): they are the currency payer, so
    ///      their fee must be escrowed up front alongside the notional. When the maker
    ///      sells the asset, their fee is instead withheld from the currency the taker
    ///      pays in, and nothing extra is escrowed.
    function _makerEscrowedFee(address sellToken, uint256 sellAmount, FeeAttestation calldata feeAtt)
        private
        pure
        returns (uint256)
    {
        if (feeAtt.feeToken != sellToken) return 0;
        return FeeMath.feeAmount(sellAmount, feeAtt.makerFeeBps);
    }

    /// @dev Total the maker must transfer in at placement: notional + escrowed fee.
    function _escrowTotal(address sellToken, uint256 sellAmount, FeeAttestation calldata feeAtt)
        private
        pure
        returns (uint256)
    {
        return sellAmount + _makerEscrowedFee(sellToken, sellAmount, feeAtt);
    }

    function _placeOrder(
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 buyAmount,
        uint64 expireTs,
        FeeAttestation calldata feeAtt
    ) private returns (uint256 id) {
        address maker = _msgSender();
        uint256 escrowedFee = _makerEscrowedFee(sellToken, sellAmount, feeAtt);
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
            makerFeeBps: feeAtt.makerFeeBps,
            takerFeeBps: feeAtt.takerFeeBps,
            feeCollector: feeAtt.feeCollector,
            feeToken: feeAtt.feeToken,
            escrowedFee: escrowedFee
        });

        IERC20(sellToken).safeTransferFrom(maker, address(this), sellAmount + escrowedFee);
        emit OrderPlaced(
            id,
            maker,
            sellToken,
            sellAmount,
            buyToken,
            buyAmount,
            expireTs,
            feeAtt.makerFeeBps,
            feeAtt.takerFeeBps,
            feeAtt.feeCollector,
            feeAtt.feeToken
        );
    }

    /// @notice Maker self-cancel. Never requires a KYC attestation — a user must
    ///         always be able to cancel their own open order and reclaim escrow.
    ///         Use cancelOrderForUser (admin) to release a frozen maker's funds
    ///         to a compliance-chosen address.
    function cancelOrder(uint256 id) external nonReentrant {
        Order storage o = _orders[id];
        if (o.status != OrderStatus.Open) revert OrderNotOpen(id);
        if (o.maker != _msgSender()) revert NotMaker(id);

        // The escrowed fee is the maker's money until a fill earns it (AC-833), so an
        // untouched order returns the maker to their exact starting balance.
        uint256 refunded = o.remainingQuantity + o.escrowedFee;
        o.status = OrderStatus.Cancelled;
        o.remainingQuantity = 0;
        o.escrowedFee = 0;
        IERC20(o.sellToken).safeTransfer(o.maker, refunded);
        emit OrderCancelled(id, o.maker, refunded);
    }

    // --------------------------------------------------------------------- //
    //                          Permissioned taker                            //
    // --------------------------------------------------------------------- //

    /// @notice Fill (part of) an open order. The taker specifies `fillSellAmount`
    ///         (how much of the order's sellToken to take). A proportional
    ///         buyToken amount is charged; the order stays Open if partially filled.
    ///         KYC-gated on the taker.
    ///
    ///         Fees (AC-833): both are denominated in the order's `feeToken` — the
    ///         settlement currency — and are EXCLUSIVE on the payer. The party paying
    ///         currency pays `notional + their own fee`; the party receiving currency
    ///         receives `notional − their own fee`; the ASSET LEG MOVES GROSS.
    ///
    ///         So a taker filling "10 A for 100 C" at 1 %/1 % pays **101 C** and
    ///         receives the full **10 A**; the maker receives **99 C**; the collector
    ///         takes **2 C** and zero A.
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
        // Pre-AC-833 orders have no settlement currency, so their fees cannot be
        // denominated. They remain cancellable/sweepable, but never fillable.
        if (o.feeToken == address(0)) revert LegacyOrderMustBeUnwound(id);
        if (o.expireTs != 0 && block.timestamp > o.expireTs) revert OrderIsExpired(id);
        if (fillSellAmount == 0) revert FillAmountZero();
        if (fillSellAmount > o.remainingQuantity) revert FillExceedsRemaining(id, o.remainingQuantity);

        address taker = _msgSender();
        if (o.maker == taker) revert SelfTrade(id);

        _consumeKyc(taker, Action.Fill, id, att);

        // Ceiling division: taker always pays at least the proportional buyAmount.
        // This protects the maker from rounding loss on partial fills.
        uint256 buyAmountDue = FeeMath.ceilDiv(fillSellAmount * o.buyAmount, o.sellAmount);
        _settleFill(o, id, taker, fillSellAmount, buyAmountDue);
    }

    /// @dev Split out of `fillOrder` to keep the two settlement directions legible
    ///      (and the stack shallow). `o` is a storage pointer — effects are written
    ///      here, before any token interaction (CEI).
    function _settleFill(Order storage o, uint256 id, address taker, uint256 fillSellAmount, uint256 buyAmountDue)
        private
    {
        // The notional `N` is always the CURRENCY leg of this fill, whichever side it is.
        bool makerSellsCurrency = (o.sellToken == o.feeToken);
        uint256 notional = makerSellsCurrency ? fillSellAmount : buyAmountDue;

        // Floor division: rounding favours maker/taker over the collector.
        uint256 makerFeeAmount = FeeMath.feeAmount(notional, o.makerFeeBps);
        uint256 takerFeeAmount = FeeMath.feeAmount(notional, o.takerFeeBps);
        uint256 collectorTake = makerFeeAmount + takerFeeAmount;
        address collector = o.feeCollector;
        address maker = o.maker;

        // ---- Effects (CEI) --------------------------------------------------- //
        o.remainingQuantity -= fillSellAmount;
        bool fullFill = (o.remainingQuantity == 0);
        if (fullFill) o.status = OrderStatus.Filled;

        uint256 feeDust;
        if (makerSellsCurrency) {
            // The maker's fee was escrowed at placement; this fill earns part of it.
            // Safe by construction: the per-fill fee is floor(fᵢ·bps) over fills whose
            // fᵢ sum to sellAmount, and Σfloor(x) ≤ floor(Σx) = escrowedFee.
            o.escrowedFee -= makerFeeAmount;
            // On the last fill, rounding dust left in escrow goes back to the maker —
            // it is their money and the contract must not retain a residue.
            if (fullFill) {
                feeDust = o.escrowedFee;
                o.escrowedFee = 0;
            }
        }

        // ---- Interactions ---------------------------------------------------- //
        if (makerSellsCurrency) {
            // Buy-side order: maker is the currency payer (already escrowed notional +
            // fee); taker is the currency receiver. Asset moves gross to the maker.
            IERC20(o.buyToken).safeTransferFrom(taker, maker, buyAmountDue);
            IERC20(o.sellToken).safeTransfer(taker, fillSellAmount - takerFeeAmount);
            if (collectorTake > 0) IERC20(o.sellToken).safeTransfer(collector, collectorTake);
            if (feeDust > 0) IERC20(o.sellToken).safeTransfer(maker, feeDust);
        } else {
            // Sell-side order: taker is the currency payer — they pay notional + their
            // OWN fee, and receive the full asset amount. Maker receives notional less
            // the maker fee. Nothing is ever withheld from the asset leg.
            IERC20(o.buyToken).safeTransferFrom(taker, maker, notional - makerFeeAmount);
            if (collectorTake > 0) IERC20(o.buyToken).safeTransferFrom(taker, collector, collectorTake);
            IERC20(o.sellToken).safeTransfer(taker, fillSellAmount);
        }

        if (fullFill) {
            emit OrderFilled(
                id, maker, taker, fillSellAmount, buyAmountDue, makerFeeAmount, takerFeeAmount, collector, o.feeToken
            );
        } else {
            emit OrderPartiallyFilled(
                id,
                maker,
                taker,
                fillSellAmount,
                buyAmountDue,
                o.remainingQuantity,
                makerFeeAmount,
                takerFeeAmount,
                collector,
                o.feeToken
            );
        }
    }

    // --------------------------------------------------------------------- //
    //                          Permissionless sweep                          //
    // --------------------------------------------------------------------- //

    /// @notice Anyone can sweep a batch of expired orders, returning each order's
    ///         remaining escrow — plus any unconsumed escrowed fee (AC-833) — to the
    ///         maker. Orders that are not Open, lack an expireTs, or have not yet
    ///         expired are silently skipped.
    ///         Callers should batch `ids` in chunks of at most 100 to avoid out-of-gas reverts.
    function sweepExpired(uint256[] calldata ids) external nonReentrant {
        for (uint256 i = 0; i < ids.length; i++) {
            Order storage o = _orders[ids[i]];
            if (o.status != OrderStatus.Open) continue;
            if (o.expireTs == 0 || block.timestamp <= o.expireTs) continue;

            uint256 refunded = o.remainingQuantity + o.escrowedFee;
            address maker = o.maker;
            address token = o.sellToken;
            o.status = OrderStatus.Expired;
            o.remainingQuantity = 0;
            o.escrowedFee = 0;

            IERC20(token).safeTransfer(maker, refunded);
            emit OrderExpired(ids[i], maker, refunded);
        }
    }

    // --------------------------------------------------------------------- //
    //                                 Views                                  //
    // --------------------------------------------------------------------- //

    function getOrder(uint256 id) external view returns (Order memory) {
        return _orders[id];
    }
}
