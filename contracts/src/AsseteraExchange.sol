// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {ERC2771ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title AsseteraExchange
/// @notice Escrow-based limit-order venue with NO on-chain matching engine — the
///         simplified essence of the Assetera Agora order book, hardened for a
///         MiFID-style regulated venue.
///
///         Compliance is a two-sided gate:
///           * POSITIVE — every state-changing trade action requires a fresh,
///             single-use EIP-712 **KYC attestation** signed by a holder of
///             `KYC_OPERATOR_ROLE` (the centralized KYC backend). "Freezing" a
///             user is simply the backend declining to sign.
///           * NEGATIVE / escape hatch — `cancelOrderForUser` lets the admin
///             multisig force-cancel a (e.g. frozen) user's order and route the
///             escrow to a compliance-chosen recipient.
///
///         Identity is resolved via `_msgSender()` (ERC-2771), so the caller may
///         be a relayer (gasless meta-tx) or — later — an ERC-4337 smart account;
///         the contract never assumes `msg.sender == maker/taker`.
contract AsseteraExchange is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    EIP712Upgradeable,
    ERC2771ContextUpgradeable
{
    using SafeERC20 for IERC20;

    // --------------------------------------------------------------------- //
    //                                Roles                                   //
    // --------------------------------------------------------------------- //

    /// @notice Settlement agent: settle matched orders, refund, pause. (Safe in prod.)
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice Whitelisted KYC signers. Any attestation whose recovered signer
    ///         holds this role is accepted. Managed by the admin multisig.
    bytes32 public constant KYC_OPERATOR_ROLE = keccak256("KYC_OPERATOR_ROLE");

    // --------------------------------------------------------------------- //
    //                              Data model                                //
    // --------------------------------------------------------------------- //

    enum OrderStatus {
        None, // 0
        Open, // 1
        Filled, // 2 — fully filled by taker
        Settled, // 3 — operator-settled (fully or final partial)
        Cancelled, // 4 — by maker (KYC-gated or self-cancel)
        Refunded, // 5 — by operator
        ForceCancelled, // 6 — by admin (cancelOrderForUser)
        Expired // 7 — swept after expireTs
    }

    enum OfferStatus {
        None, // 0
        Open, // 1 — initial proposal by maker
        Countered, // 2 — either party has replaced with new terms
        Accepted, // 3 — non-proposer has accepted; both sides escrowed
        Settled, // 4 — operator transferred both sides
        Cancelled, // 5 — cancelled by maker or taker
        ForceCancelled, // 6 — admin escape hatch (cancelOfferForUser)
        Expired // 7 — swept after expireTs via sweepExpiredOffers
    }

    /// @notice Trade actions that can be KYC-gated.
    enum Action {
        None, // 0
        Place, // 1
        Fill, // 2
        Settle, // 3 — order-level settle only
        Cancel, // 4 — order-level cancel only
        MakeOffer, // 5
        ReplaceOffer, // 6
        AcceptOffer, // 7
        CancelOffer, // 8 — offer-level cancel (distinct from Cancel to prevent cross-function replay)
        SettleOffer // 9 — offer-level settle (distinct from Settle for the same reason)
    }

    struct Order {
        uint256 id;
        address maker;
        address sellToken;
        uint256 sellAmount; // original escrowed amount
        address buyToken;
        uint256 buyAmount; // original desired amount
        OrderStatus status;
        uint64 createdAt;
        uint256 remainingQuantity; // remaining sellAmount not yet filled/settled
        uint64 expireTs; // unix expiry; 0 = never expires
        // Fee snapshot — set at placement, immutable for the lifetime of the order.
        uint16 makerFeeBps; // fee deducted from what maker receives (in buyToken)
        uint16 takerFeeBps; // fee deducted from what taker receives (in sellToken)
        address feeCollector; // allowlisted recipient of collected fees
    }

    struct Offer {
        uint256 id;
        address maker; // initiating party
        address taker; // targeted counterparty
        address makerToken; // maker's sell token
        uint256 makerAmount;
        address takerToken; // taker's sell token
        uint256 takerAmount;
        OfferStatus status;
        uint64 createdAt;
        uint64 expireTs;
        address proposedBy; // who made the current round's proposal (their tokens are escrowed)
        uint16 makerFeeBps; // fee deducted from what maker receives at settlement
        uint16 takerFeeBps; // fee deducted from what taker receives at settlement
        address feeCollector; // allowlisted recipient; address(0) when no fee
    }

    /// @notice A single-use KYC authorization. The first five fields are EIP-712
    ///         signed by a `KYC_OPERATOR_ROLE` holder; `signature` is that sig.
    struct KycAttestation {
        address account; // the party being authorized; must equal the actor
        Action action; // which action this authorizes
        uint256 orderId; // bound order (0 for Place)
        uint256 nonce; // single-use, per-account
        uint256 deadline; // unix expiry (backend sets ~3 min)
        bytes32 paramsHash; // keccak256(abi.encode(sellToken,sellAmount,buyToken,buyAmount)) for Place; bytes32(0) otherwise
        // Per-pair fee parameters — backend signs these for Place; zero for all other actions.
        uint16 makerFeeBps; // fee the maker pays from what they receive
        uint16 takerFeeBps; // fee the taker pays from what they receive
        address feeCollector; // must be in the on-chain allowlist when non-zero fees
        bytes signature; // KYC operator's EIP-712 signature over the above
    }

    bytes32 public constant KYC_TYPEHASH = keccak256(
        "KycAttestation(address account,uint8 action,uint256 orderId,uint256 nonce,uint256 deadline,bytes32 paramsHash,uint16 makerFeeBps,uint16 takerFeeBps,address feeCollector)"
    );

    /// @notice Hard cap on attestation freshness; rejects over-long deadlines
    ///         even if a signer produced one. Backend uses ~3 min.
    uint256 public constant MAX_KYC_TTL = 15 minutes;

    /// @notice Absolute upper bound on fee basis points (100 % = 10 000 bps).
    ///         Practical configs will be well below this.
    uint16 public constant MAX_FEE_BPS = 10_000;

    mapping(uint256 => Order) private _orders;
    uint256 public totalOrders;

    /// @notice Consumed attestation nonces, per account. Single-use replay guard.
    mapping(address => mapping(uint256 => bool)) public usedNonce;

    /// @notice Whether each action requires a KYC attestation. Composable: turn
    ///         gating on/off per action (admin). Defaults to all-on.
    mapping(Action => bool) public complianceRequired;

    /// @notice On-chain compliance fallback. Keyed by keccak256(abi.encodePacked(account))
    ///         so the list is pseudonymised and not enumerable from chain data.
    mapping(bytes32 => bool) private _blacklist;

    mapping(uint256 => Offer) private _offers;
    uint256 public totalOffers;

    /// @notice Admin-managed allowlist of permitted fee collector addresses.
    ///         A compromised KYC signer cannot route fees to an arbitrary wallet
    ///         because the collector must be in this allowlist at placement time.
    mapping(address => bool) public allowedCollectors;

    uint256[42] private __gap; // reduced from [43]: allowedCollectors uses one slot

    // --------------------------------------------------------------------- //
    //                                Events                                  //
    // --------------------------------------------------------------------- //

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
    event OrderForceCancelled(uint256 indexed id, address indexed maker, address recipient, address indexed admin);
    event OrderExpired(uint256 indexed id, address indexed maker, uint256 remainingQuantity);
    /// @notice Emitted when the admin updates the fee collector allowlist.
    event CollectorAllowed(address indexed collector, bool allowed);
    event KycConsumed(address indexed account, Action indexed action, uint256 indexed orderId, uint256 nonce);
    event ComplianceRequiredSet(Action indexed action, bool required);
    event BlacklistUpdated(bytes32 indexed hashedAccount, bool blocked);
    event OfferMade(
        uint256 indexed id,
        address indexed maker,
        address indexed taker,
        address makerToken,
        uint256 makerAmount,
        address takerToken,
        uint256 takerAmount,
        uint64 expireTs,
        uint16 makerFeeBps,
        uint16 takerFeeBps,
        address feeCollector
    );
    event OfferReplaced(
        uint256 indexed id, address indexed by, uint256 newMakerAmount, uint256 newTakerAmount, uint64 expireTs
    );
    event OfferCancelled(uint256 indexed id, address indexed by, uint256 makerAmount, uint256 takerAmount);
    event OfferForceCancelled(
        uint256 indexed id, address indexed maker, address makerRecipient, address takerRecipient, address indexed admin
    );
    event OfferExpired(uint256 indexed id, address indexed proposedBy, uint256 amountReturned);
    event OfferAccepted(uint256 indexed id, address indexed by, uint256 makerAmount, uint256 takerAmount);
    event OfferSettled(
        uint256 indexed id,
        address indexed operator,
        uint256 makerReceived,
        uint256 takerReceived,
        uint256 makerFeeAmount,
        uint256 takerFeeAmount,
        address feeCollector
    );

    // --------------------------------------------------------------------- //
    //                                Errors                                  //
    // --------------------------------------------------------------------- //

    error ZeroAddress();
    error ZeroAmount();
    error SameToken();
    error OrderNotOpen(uint256 id);
    error NotMaker(uint256 id);
    error NotComplementary(uint256 buyId, uint256 sellId);
    error PriceNotCrossed(uint256 buyId, uint256 sellId);
    error SelfTrade(uint256 id);
    error OrderIsExpired(uint256 id);
    error InvalidExpiry();
    error FillAmountZero();
    error FillExceedsRemaining(uint256 id, uint256 remaining);
    error AccountBlacklisted();
    error ParamsHashMismatch();
    error FeeCollectorNotAllowed(address collector);
    error InvalidFee();
    // Offer
    error OfferNotFound(uint256 id);
    error OfferNotOpen(uint256 id);
    error OfferNotAccepted(uint256 id);
    error NotOfferParty(uint256 id);
    error OfferSelfTarget();
    error AcceptorIsProposer(uint256 id);
    error OfferIsExpired(uint256 id);
    // KYC
    error KycAccountMismatch();
    error KycActionMismatch();
    error KycOrderMismatch();
    error KycExpired();
    error KycTtlTooLong();
    error KycNonceUsed();
    error KycBadSigner();

    // --------------------------------------------------------------------- //
    //                              Initializer                               //
    // --------------------------------------------------------------------- //

    /// @param trustedForwarder ERC-2771 forwarder (relayer). Immutable in impl
    ///        bytecode — proxy-safe. Set to address(0) to disable meta-tx.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address trustedForwarder) ERC2771ContextUpgradeable(trustedForwarder) {
        _disableInitializers();
    }

    /// @param admin    DEFAULT_ADMIN_ROLE (upgrade, role mgmt, force-cancel). Multisig in prod.
    /// @param operator OPERATOR_ROLE (settle/refund/pause).
    /// @param kycSigner Initial KYC_OPERATOR_ROLE holder (the backend signer).
    function initialize(address admin, address operator, address kycSigner) external initializer {
        if (admin == address(0) || operator == address(0) || kycSigner == address(0)) revert ZeroAddress();

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __EIP712_init("AsseteraExchange", "1");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, operator);
        _grantRole(KYC_OPERATOR_ROLE, kycSigner);

        // Default: every trade action is KYC-gated.
        complianceRequired[Action.Place] = true;
        complianceRequired[Action.Fill] = true;
        complianceRequired[Action.Settle] = true;
        complianceRequired[Action.Cancel] = true;
        complianceRequired[Action.MakeOffer] = true;
        complianceRequired[Action.ReplaceOffer] = true;
        complianceRequired[Action.AcceptOffer] = true;
        complianceRequired[Action.CancelOffer] = true;
        complianceRequired[Action.SettleOffer] = true;
    }

    // --------------------------------------------------------------------- //
    //                           KYC attestation core                         //
    // --------------------------------------------------------------------- //

    /// @dev Verify a KYC attestation without consuming the nonce. Pure validation;
    ///      no state writes. Used by _consumeKyc and directly by settle() so both
    ///      attestations can be verified before either nonce is burned.
    function _verifyKyc(address account, Action action, uint256 orderId, KycAttestation calldata att) private view {
        // Blacklist is unconditional — applies even when attestation gating is disabled.
        if (_blacklist[keccak256(abi.encodePacked(account))]) revert AccountBlacklisted();
        if (!complianceRequired[action]) return;
        if (att.account != account) revert KycAccountMismatch();
        if (att.action != action) revert KycActionMismatch();
        if (att.orderId != orderId) revert KycOrderMismatch();
        // paramsHash is only allowed for actions that bind extra parameters; content is checked by callers.
        // CancelOffer and SettleOffer are intentionally separate from Cancel and Settle to prevent
        // cross-function attestation replay between order-level and offer-level operations.
        bool paramsAllowed = action == Action.Place || action == Action.MakeOffer || action == Action.ReplaceOffer
            || action == Action.AcceptOffer || action == Action.CancelOffer || action == Action.SettleOffer;
        if (!paramsAllowed && att.paramsHash != bytes32(0)) revert ParamsHashMismatch();
        if (block.timestamp > att.deadline) revert KycExpired();
        if (att.deadline > block.timestamp + MAX_KYC_TTL) revert KycTtlTooLong();
        if (usedNonce[account][att.nonce]) revert KycNonceUsed();

        bytes32 structHash = keccak256(
            abi.encode(
                KYC_TYPEHASH,
                att.account,
                uint8(att.action),
                att.orderId,
                att.nonce,
                att.deadline,
                att.paramsHash,
                att.makerFeeBps,
                att.takerFeeBps,
                att.feeCollector
            )
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), att.signature);
        if (!hasRole(KYC_OPERATOR_ROLE, signer)) revert KycBadSigner();
    }

    /// @dev Verify + consume a single-use KYC attestation for `account`/`action`.
    ///      No-op (after blacklist check) if gating for `action` is disabled.
    function _consumeKyc(address account, Action action, uint256 orderId, KycAttestation calldata att) private {
        _verifyKyc(account, action, orderId, att);
        if (complianceRequired[action]) {
            usedNonce[account][att.nonce] = true;
            emit KycConsumed(account, action, orderId, att.nonce);
        }
    }

    // --------------------------------------------------------------------- //
    //                              Maker actions                             //
    // --------------------------------------------------------------------- //

    /// @param expireTs Unix timestamp after which the order can be swept; 0 = no expiry.
    function placeOrder(
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 buyAmount,
        uint64 expireTs,
        KycAttestation calldata att
    ) external whenNotPaused nonReentrant returns (uint256 id) {
        // Validate all params and paramsHash BEFORE consuming the KYC nonce so
        // that a bad call does not burn the attestation.
        if (sellToken == address(0) || buyToken == address(0)) revert ZeroAddress();
        if (sellAmount == 0 || buyAmount == 0) revert ZeroAmount();
        if (sellToken == buyToken) revert SameToken();
        if (expireTs != 0 && expireTs <= block.timestamp) revert InvalidExpiry();
        if (
            complianceRequired[Action.Place]
                && att.paramsHash != keccak256(abi.encode(sellToken, sellAmount, buyToken, buyAmount))
        ) {
            revert ParamsHashMismatch();
        }
        // Fee validation — always enforced so a compromised signer cannot
        // set extreme fees or route to an unlisted collector.
        if (att.makerFeeBps > MAX_FEE_BPS || att.takerFeeBps > MAX_FEE_BPS) revert InvalidFee();
        if (att.makerFeeBps > 0 || att.takerFeeBps > 0) {
            if (att.feeCollector == address(0)) revert ZeroAddress();
            if (!allowedCollectors[att.feeCollector]) revert FeeCollectorNotAllowed(att.feeCollector);
        }
        _consumeKyc(_msgSender(), Action.Place, 0, att);
        return _placeOrder(
            sellToken, sellAmount, buyToken, buyAmount, expireTs, att.makerFeeBps, att.takerFeeBps, att.feeCollector
        );
    }

    /// @param expireTs Unix timestamp after which the order can be swept; 0 = no expiry.
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
        KycAttestation calldata att
    ) external whenNotPaused nonReentrant returns (uint256 id) {
        // Validate all params and paramsHash BEFORE consuming the KYC nonce so
        // that a bad call does not burn the attestation.
        if (sellToken == address(0) || buyToken == address(0)) revert ZeroAddress();
        if (sellAmount == 0 || buyAmount == 0) revert ZeroAmount();
        if (sellToken == buyToken) revert SameToken();
        if (expireTs != 0 && expireTs <= block.timestamp) revert InvalidExpiry();
        if (
            complianceRequired[Action.Place]
                && att.paramsHash != keccak256(abi.encode(sellToken, sellAmount, buyToken, buyAmount))
        ) {
            revert ParamsHashMismatch();
        }
        if (att.makerFeeBps > MAX_FEE_BPS || att.takerFeeBps > MAX_FEE_BPS) revert InvalidFee();
        if (att.makerFeeBps > 0 || att.takerFeeBps > 0) {
            if (att.feeCollector == address(0)) revert ZeroAddress();
            if (!allowedCollectors[att.feeCollector]) revert FeeCollectorNotAllowed(att.feeCollector);
        }
        _consumeKyc(_msgSender(), Action.Place, 0, att);
        _tryPermit(sellToken, sellAmount, permitDeadline, v, r, s);
        return _placeOrder(
            sellToken, sellAmount, buyToken, buyAmount, expireTs, att.makerFeeBps, att.takerFeeBps, att.feeCollector
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

    /// @notice KYC-gated maker cancel. Backend-frozen users cannot cancel here —
    ///         the backend will not sign for them. Use cancelOrderSelf for an
    ///         unattested self-cancel, or cancelOrderForUser (admin) to release
    ///         a frozen user's funds to a compliance-chosen address.
    function cancelOrder(uint256 id, KycAttestation calldata att) external nonReentrant {
        Order storage o = _orders[id];
        if (o.status != OrderStatus.Open) revert OrderNotOpen(id);

        address maker = _msgSender();
        if (o.maker != maker) revert NotMaker(id);

        _consumeKyc(maker, Action.Cancel, id, att);

        o.status = OrderStatus.Cancelled;
        IERC20(o.sellToken).safeTransfer(o.maker, o.remainingQuantity);
        emit OrderCancelled(id, o.maker);
    }

    /// @notice Maker self-cancel without KYC attestation. Blocked for accounts
    ///         on the on-chain compliance blacklist; use cancelOrderForUser (admin)
    ///         to release a blacklisted maker's escrowed funds to a compliance-chosen address.
    function cancelOrderSelf(uint256 id) external nonReentrant {
        if (_blacklist[keccak256(abi.encodePacked(_msgSender()))]) revert AccountBlacklisted();
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
        uint256 buyAmountDue = (fillSellAmount * o.buyAmount + o.sellAmount - 1) / o.sellAmount;

        // Compute fees. Floor division benefits maker/taker over the collector.
        uint256 makerFeeAmount = (buyAmountDue * o.makerFeeBps) / 10_000;
        uint256 takerFeeAmount = (fillSellAmount * o.takerFeeBps) / 10_000;
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
    //                            Operator actions                            //
    // --------------------------------------------------------------------- //

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
        uint256 buyMakerFeeAmount = (settleB * a.makerFeeBps) / 10_000;
        uint256 sellMakerFeeAmount = (settleA * b.makerFeeBps) / 10_000;

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

    /// @notice Admin (multisig) escape hatch: force-cancel any open order and
    ///         route the escrow to `recipient` (the maker, or a
    ///         compliance-directed address). Resolves funds for frozen users who
    ///         can no longer obtain a KYC signature to self-cancel.
    function cancelOrderForUser(uint256 id, address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();
        Order storage o = _orders[id];
        if (o.status != OrderStatus.Open) revert OrderNotOpen(id);
        o.status = OrderStatus.ForceCancelled;
        IERC20(o.sellToken).safeTransfer(recipient, o.remainingQuantity);
        emit OrderForceCancelled(id, o.maker, recipient, _msgSender());
    }

    /// @notice Anyone can sweep a batch of expired orders, returning each order's
    ///         remaining escrow to the maker. Orders that are not Open, lack an
    ///         expireTs, have not yet expired, or belong to a blacklisted maker
    ///         are silently skipped. Blacklisted makers' expired orders must be
    ///         released via cancelOrderForUser (admin) to route funds to a
    ///         compliance-chosen recipient.
    ///         Callers should batch `ids` in chunks of at most 100 to avoid out-of-gas reverts.
    function sweepExpired(uint256[] calldata ids) external nonReentrant {
        for (uint256 i = 0; i < ids.length; i++) {
            Order storage o = _orders[ids[i]];
            if (o.status != OrderStatus.Open) continue;
            if (o.expireTs == 0 || block.timestamp <= o.expireTs) continue;
            if (_blacklist[keccak256(abi.encodePacked(o.maker))]) continue;

            uint256 remaining = o.remainingQuantity;
            address maker = o.maker;
            address token = o.sellToken;
            o.status = OrderStatus.Expired;
            o.remainingQuantity = 0;

            IERC20(token).safeTransfer(maker, remaining);
            emit OrderExpired(ids[i], maker, remaining);
        }
    }

    /// @notice Anyone can sweep a batch of expired offers, returning the current
    ///         proposer's escrowed tokens to them. Only Open/Countered offers with
    ///         a non-zero expireTs that has passed are swept; all other states are
    ///         silently skipped. Blacklisted proposers are skipped — their funds
    ///         must be released via cancelOfferForUser (admin).
    ///         Callers should batch `ids` in chunks of at most 100 to avoid out-of-gas reverts.
    /// @param ids Offer IDs to sweep. Non-expired, non-Open/Countered, and blacklisted entries
    ///            are silently skipped without reverting.
    function sweepExpiredOffers(uint256[] calldata ids) external nonReentrant {
        for (uint256 i = 0; i < ids.length; i++) {
            Offer storage o = _offers[ids[i]];
            if (o.status != OfferStatus.Open && o.status != OfferStatus.Countered) continue;
            if (o.expireTs == 0 || block.timestamp <= o.expireTs) continue;
            if (_blacklist[keccak256(abi.encodePacked(o.proposedBy))]) continue;

            address proposedBy = o.proposedBy;
            address token;
            uint256 amount;
            if (proposedBy == o.maker) {
                token = o.makerToken;
                amount = o.makerAmount;
            } else {
                token = o.takerToken;
                amount = o.takerAmount;
            }

            o.status = OfferStatus.Expired;

            IERC20(token).safeTransfer(proposedBy, amount);
            emit OfferExpired(ids[i], proposedBy, amount);
        }
    }

    // --------------------------------------------------------------------- //
    //                        Offer / counter-offer                           //
    // --------------------------------------------------------------------- //

    /// @notice Create a targeted offer. Maker escrows makerToken; only the
    ///         nominated taker can respond. KYC-gated on the maker.
    function makeOffer(
        address taker,
        address makerToken,
        uint256 makerAmount,
        address takerToken,
        uint256 takerAmount,
        uint64 expireTs,
        KycAttestation calldata att
    ) external whenNotPaused nonReentrant returns (uint256 id) {
        address maker = _msgSender();
        if (taker == address(0) || makerToken == address(0) || takerToken == address(0)) revert ZeroAddress();
        if (makerAmount == 0 || takerAmount == 0) revert ZeroAmount();
        if (makerToken == takerToken) revert SameToken();
        if (taker == maker) revert OfferSelfTarget();
        if (expireTs != 0 && expireTs <= block.timestamp) revert InvalidExpiry();

        if (
            complianceRequired[Action.MakeOffer]
                && att.paramsHash
                    != keccak256(abi.encodePacked(taker, makerToken, makerAmount, takerToken, takerAmount))
        ) {
            revert ParamsHashMismatch();
        }
        _validateFees(att.makerFeeBps, att.takerFeeBps, att.feeCollector);
        _consumeKyc(maker, Action.MakeOffer, 0, att);

        id = _storeOffer(maker, taker, makerToken, makerAmount, takerToken, takerAmount, expireTs, att);
        IERC20(makerToken).safeTransferFrom(maker, address(this), makerAmount);
        emit OfferMade(
            id,
            maker,
            taker,
            makerToken,
            makerAmount,
            takerToken,
            takerAmount,
            expireTs,
            att.makerFeeBps,
            att.takerFeeBps,
            att.feeCollector
        );
    }

    function _validateFees(uint16 makerFeeBps, uint16 takerFeeBps, address feeCollector) internal view {
        if (makerFeeBps > MAX_FEE_BPS || takerFeeBps > MAX_FEE_BPS) revert InvalidFee();
        if (makerFeeBps > 0 || takerFeeBps > 0) {
            if (feeCollector == address(0)) revert ZeroAddress();
            if (!allowedCollectors[feeCollector]) revert FeeCollectorNotAllowed(feeCollector);
        }
    }

    function _storeOffer(
        address maker,
        address taker,
        address makerToken,
        uint256 makerAmount,
        address takerToken,
        uint256 takerAmount,
        uint64 expireTs,
        KycAttestation calldata att
    ) internal returns (uint256 id) {
        id = ++totalOffers;
        _offers[id] = Offer({
            id: id,
            maker: maker,
            taker: taker,
            makerToken: makerToken,
            makerAmount: makerAmount,
            takerToken: takerToken,
            takerAmount: takerAmount,
            status: OfferStatus.Open,
            createdAt: uint64(block.timestamp),
            expireTs: expireTs,
            proposedBy: maker,
            makerFeeBps: att.makerFeeBps,
            takerFeeBps: att.takerFeeBps,
            feeCollector: att.feeCollector
        });
    }

    /// @notice Either party revises the offer terms. The previous proposer's
    ///         escrow is returned; the caller escrows their side at the new amounts.
    ///         KYC-gated on the caller.
    function replaceOffer(
        uint256 offerId,
        uint256 newMakerAmount,
        uint256 newTakerAmount,
        uint64 expireTs,
        KycAttestation calldata att
    ) external whenNotPaused nonReentrant {
        Offer storage o = _offers[offerId];
        if (o.id == 0) revert OfferNotFound(offerId);
        if (o.status != OfferStatus.Open && o.status != OfferStatus.Countered) revert OfferNotOpen(offerId);
        if (o.expireTs != 0 && block.timestamp > o.expireTs) revert OfferIsExpired(offerId);
        if (newMakerAmount == 0 || newTakerAmount == 0) revert ZeroAmount();
        if (expireTs != 0 && expireTs <= block.timestamp) revert InvalidExpiry();

        address caller = _msgSender();
        if (caller != o.maker && caller != o.taker) revert NotOfferParty(offerId);

        if (
            complianceRequired[Action.ReplaceOffer]
                && att.paramsHash != keccak256(abi.encodePacked(offerId, newMakerAmount, newTakerAmount))
        ) {
            revert ParamsHashMismatch();
        }
        _consumeKyc(caller, Action.ReplaceOffer, offerId, att);

        // Cache before state changes (CEI).
        address prevProposedBy = o.proposedBy;
        address prevMakerToken = o.makerToken;
        uint256 prevMakerAmount = o.makerAmount;
        address prevTakerToken = o.takerToken;
        uint256 prevTakerAmount = o.takerAmount;

        // Effects.
        o.makerAmount = newMakerAmount;
        o.takerAmount = newTakerAmount;
        o.expireTs = expireTs;
        o.proposedBy = caller;
        o.status = OfferStatus.Countered;

        // Return previous proposer's escrow.
        if (prevProposedBy == o.maker) {
            IERC20(prevMakerToken).safeTransfer(o.maker, prevMakerAmount);
        } else {
            IERC20(prevTakerToken).safeTransfer(o.taker, prevTakerAmount);
        }

        // Escrow caller's side at the new amounts.
        if (caller == o.maker) {
            IERC20(o.makerToken).safeTransferFrom(o.maker, address(this), newMakerAmount);
        } else {
            IERC20(o.takerToken).safeTransferFrom(o.taker, address(this), newTakerAmount);
        }

        emit OfferReplaced(offerId, caller, newMakerAmount, newTakerAmount, expireTs);
    }

    /// @notice Either party cancels the offer while it is Open or Countered.
    ///         The current proposer's escrowed tokens are returned. KYC-gated.
    /// @param offerId The offer to cancel.
    /// @param att     KYC attestation authorising the caller for CancelOffer on this offerId.
    function cancelOffer(uint256 offerId, KycAttestation calldata att) external nonReentrant {
        Offer storage o = _offers[offerId];
        if (o.id == 0) revert OfferNotFound(offerId);
        if (o.status != OfferStatus.Open && o.status != OfferStatus.Countered) revert OfferNotOpen(offerId);

        address caller = _msgSender();
        if (caller != o.maker && caller != o.taker) revert NotOfferParty(offerId);

        if (
            complianceRequired[Action.CancelOffer]
                && att.paramsHash != keccak256(abi.encodePacked(offerId, o.makerAmount, o.takerAmount))
        ) {
            revert ParamsHashMismatch();
        }
        _consumeKyc(caller, Action.CancelOffer, offerId, att);

        // Cache before state changes (CEI).
        address proposedBy = o.proposedBy;
        address makerToken = o.makerToken;
        uint256 makerAmount = o.makerAmount;
        address takerToken = o.takerToken;
        uint256 takerAmount = o.takerAmount;

        o.status = OfferStatus.Cancelled;

        if (proposedBy == o.maker) {
            IERC20(makerToken).safeTransfer(o.maker, makerAmount);
        } else {
            IERC20(takerToken).safeTransfer(o.taker, takerAmount);
        }

        emit OfferCancelled(offerId, caller, makerAmount, takerAmount);
    }

    /// @notice The non-proposing party accepts current terms and escrows their
    ///         side. Status transitions to Accepted, enabling settleOffer.
    ///         KYC-gated on the caller.
    /// @param offerId The offer to accept.
    /// @param att     KYC attestation authorising the caller for AcceptOffer on this offerId,
    ///                with paramsHash bound to keccak256(offerId, makerAmount, takerAmount).
    function acceptOffer(uint256 offerId, KycAttestation calldata att) external whenNotPaused nonReentrant {
        Offer storage o = _offers[offerId];
        if (o.id == 0) revert OfferNotFound(offerId);
        if (o.status != OfferStatus.Open && o.status != OfferStatus.Countered) revert OfferNotOpen(offerId);
        if (o.expireTs != 0 && block.timestamp > o.expireTs) revert OfferIsExpired(offerId);

        address caller = _msgSender();
        if (caller != o.maker && caller != o.taker) revert NotOfferParty(offerId);
        if (caller == o.proposedBy) revert AcceptorIsProposer(offerId);

        if (
            complianceRequired[Action.AcceptOffer]
                && att.paramsHash != keccak256(abi.encodePacked(offerId, o.makerAmount, o.takerAmount))
        ) {
            revert ParamsHashMismatch();
        }
        _consumeKyc(caller, Action.AcceptOffer, offerId, att);

        // Cache terms before state change so the event carries the agreed amounts.
        uint256 makerAmount = o.makerAmount;
        uint256 takerAmount = o.takerAmount;

        // Effects before interaction (CEI).
        o.status = OfferStatus.Accepted;

        // Escrow the accepting party's tokens. By Accepted, both sides are held.
        if (caller == o.taker) {
            IERC20(o.takerToken).safeTransferFrom(o.taker, address(this), takerAmount);
        } else {
            IERC20(o.makerToken).safeTransferFrom(o.maker, address(this), makerAmount);
        }

        emit OfferAccepted(offerId, caller, makerAmount, takerAmount);
    }

    /// @notice Operator settles an Accepted offer. Both parties must provide a
    ///         fresh Settle attestation. Blacklist is enforced on both sides.
    function settleOffer(uint256 offerId, KycAttestation calldata makerAtt, KycAttestation calldata takerAtt)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
    {
        Offer storage o = _offers[offerId];
        if (o.id == 0) revert OfferNotFound(offerId);
        if (o.status != OfferStatus.Accepted) revert OfferNotAccepted(offerId);

        // Verify both signatures before consuming either nonce.
        _verifyKyc(o.maker, Action.SettleOffer, offerId, makerAtt);
        _verifyKyc(o.taker, Action.SettleOffer, offerId, takerAtt);
        if (complianceRequired[Action.SettleOffer]) {
            bytes32 ph = keccak256(abi.encodePacked(offerId, o.makerAmount, o.takerAmount));
            if (makerAtt.paramsHash != ph) revert ParamsHashMismatch();
            if (takerAtt.paramsHash != ph) revert ParamsHashMismatch();
            usedNonce[o.maker][makerAtt.nonce] = true;
            emit KycConsumed(o.maker, Action.SettleOffer, offerId, makerAtt.nonce);
            usedNonce[o.taker][takerAtt.nonce] = true;
            emit KycConsumed(o.taker, Action.SettleOffer, offerId, takerAtt.nonce);
        }

        // Fees deducted from what each party receives at settlement.
        uint256 makerFeeAmount = (o.takerAmount * o.makerFeeBps) / 10_000;
        uint256 takerFeeAmount = (o.makerAmount * o.takerFeeBps) / 10_000;
        uint256 makerReceived = o.takerAmount - makerFeeAmount;
        uint256 takerReceived = o.makerAmount - takerFeeAmount;
        address collector = o.feeCollector;

        // Effects before transfers (CEI).
        o.status = OfferStatus.Settled;

        IERC20(o.takerToken).safeTransfer(o.maker, makerReceived);
        if (makerFeeAmount > 0) IERC20(o.takerToken).safeTransfer(collector, makerFeeAmount);
        IERC20(o.makerToken).safeTransfer(o.taker, takerReceived);
        if (takerFeeAmount > 0) IERC20(o.makerToken).safeTransfer(collector, takerFeeAmount);

        emit OfferSettled(
            offerId, _msgSender(), makerReceived, takerReceived, makerFeeAmount, takerFeeAmount, collector
        );
    }

    /// @notice Admin (multisig) escape hatch: force-cancel any non-settled offer
    ///         and route each party's escrowed tokens to compliance-chosen recipients.
    ///         Works in all non-terminal states including Accepted (both sides escrowed).
    ///         Mirrors cancelOrderForUser for regular orders — needed when a party is
    ///         blacklisted after acceptOffer, which otherwise permanently locks both escrows.
    /// @param offerId         The offer to force-cancel.
    /// @param makerRecipient  Address to receive the maker's escrowed tokens.
    /// @param takerRecipient  Address to receive the taker's escrowed tokens (only used when Accepted).
    function cancelOfferForUser(uint256 offerId, address makerRecipient, address takerRecipient)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (makerRecipient == address(0) || takerRecipient == address(0)) revert ZeroAddress();
        Offer storage o = _offers[offerId];
        if (o.id == 0) revert OfferNotFound(offerId);
        if (
            o.status == OfferStatus.Settled || o.status == OfferStatus.Cancelled
                || o.status == OfferStatus.ForceCancelled || o.status == OfferStatus.Expired
        ) {
            revert OfferNotOpen(offerId);
        }

        address makerToken = o.makerToken;
        uint256 makerAmount = o.makerAmount;
        address takerToken = o.takerToken;
        uint256 takerAmount = o.takerAmount;
        OfferStatus prevStatus = o.status;

        o.status = OfferStatus.ForceCancelled;

        if (prevStatus == OfferStatus.Accepted) {
            // Both sides escrowed — return each to their designated recipient.
            IERC20(makerToken).safeTransfer(makerRecipient, makerAmount);
            IERC20(takerToken).safeTransfer(takerRecipient, takerAmount);
        } else {
            // Only the current proposer's side is held in escrow.
            if (o.proposedBy == o.maker) {
                IERC20(makerToken).safeTransfer(makerRecipient, makerAmount);
            } else {
                IERC20(takerToken).safeTransfer(takerRecipient, takerAmount);
            }
        }

        emit OfferForceCancelled(offerId, o.maker, makerRecipient, takerRecipient, _msgSender());
    }

    /// @notice Add or remove an address from the fee collector allowlist.
    ///         Only DEFAULT_ADMIN_ROLE (the Safe multisig in prod) can manage this,
    ///         preventing a compromised KYC signer from redirecting fees arbitrarily.
    function setAllowedCollector(address collector, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        allowedCollectors[collector] = allowed;
        emit CollectorAllowed(collector, allowed);
    }

    function pause() external onlyRole(OPERATOR_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(OPERATOR_ROLE) {
        _unpause();
    }

    /// @notice Toggle KYC gating per action (composability). Admin only.
    function setComplianceRequired(Action action, bool required) external onlyRole(DEFAULT_ADMIN_ROLE) {
        complianceRequired[action] = required;
        emit ComplianceRequiredSet(action, required);
    }

    /// @notice Add or remove an address from the on-chain compliance blacklist.
    ///         Pass keccak256(abi.encodePacked(account)) — the address is never
    ///         stored in plaintext (pseudonymisation for GDPR). Blacklisted accounts
    ///         are blocked from all user-initiated actions, including cancelOrderSelf.
    ///         Use cancelOrderForUser to release escrowed funds to a compliance-chosen recipient.
    function setBlacklisted(bytes32 hashedAccount, bool blocked) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _blacklist[hashedAccount] = blocked;
        emit BlacklistUpdated(hashedAccount, blocked);
    }

    // --------------------------------------------------------------------- //
    //                                 Views                                  //
    // --------------------------------------------------------------------- //

    function getOffer(uint256 id) external view returns (Offer memory) {
        return _offers[id];
    }

    function getOrder(uint256 id) external view returns (Order memory) {
        return _orders[id];
    }

    // --------------------------------------------------------------------- //
    //                       UUPS + ERC-2771 plumbing                         //
    // --------------------------------------------------------------------- //

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function version() external pure virtual returns (string memory) {
        return "3.1.0";
    }

    function _msgSender() internal view override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (address) {
        return ERC2771ContextUpgradeable._msgSender();
    }

    function _msgData() internal view override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (bytes calldata) {
        return ERC2771ContextUpgradeable._msgData();
    }

    function _contextSuffixLength()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (uint256)
    {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }
}
