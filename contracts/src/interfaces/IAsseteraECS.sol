// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ExchangeTypes} from "../types/ExchangeTypes.sol";
import {IKycGate} from "./IKycGate.sol";
import {IFeeGate} from "./IFeeGate.sol";

/// @title IAsseteraECS
/// @notice Standalone, SDK/caller-facing reference interface for the full
///         assembled `AsseteraECS` ABI. Not `is`-inherited by the concrete
///         contract (that would reintroduce duplicate-declaration conflicts
///         with `ExchangeStorage`/`OrderBook`/`OfferBook`/`ExchangeAdmin`, which
///         are plain abstract contracts an interface cannot inherit) — this is
///         a documentation/consumer-side ABI surface, satisfied structurally by
///         the concrete contract's matching functions, in the same spirit as
///         `IKycGate`/`IFeeGate` which ARE formally inherited by their gates.
///         References `ExchangeTypes.*` via qualified import rather than
///         inheriting `ExchangeTypes` — see ExchangeTypes.sol's doc comment.
interface IAsseteraECS is IKycGate, IFeeGate {
    // --------------------------------------------------------------------- //
    //               ExchangeStorage-level errors (see storage/)              //
    // --------------------------------------------------------------------- //

    error ZeroAddress();
    error ZeroAmount();
    error SameToken();
    error InvalidExpiry();
    error ParamsHashMismatch();
    error OrderNotOpen(uint256 id);
    error OfferNotOpen(uint256 id);
    error OfferNotFound(uint256 id);

    // --------------------------------------------------------------------- //
    //                   OrderBook-level errors/events                        //
    // --------------------------------------------------------------------- //

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
        address feeCollector
    );
    event OrderCancelled(uint256 indexed id, address indexed maker, uint256 remainingQuantity);
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
    //                   OfferBook-level errors/events                        //
    // --------------------------------------------------------------------- //

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
    event OfferExpired(uint256 indexed id, address indexed proposedBy, uint256 amountReturned);
    event OfferAccepted(uint256 indexed id, address indexed by, uint256 makerAmount, uint256 takerAmount);
    event OfferSettled(
        uint256 indexed id,
        address indexed by,
        uint256 makerReceived,
        uint256 takerReceived,
        uint256 makerFeeAmount,
        uint256 takerFeeAmount,
        address feeCollector
    );

    error NotOfferParty(uint256 id);
    error OfferSelfTarget();
    error AcceptorIsProposer(uint256 id);
    error OfferIsExpired(uint256 id);

    // --------------------------------------------------------------------- //
    //                  ExchangeAdmin-level errors/events                     //
    // --------------------------------------------------------------------- //

    event CollectorAllowed(address indexed collector, bool allowed);
    event ComplianceRequiredSet(ExchangeTypes.Action indexed action, bool required);
    event OrderForceCancelled(uint256 indexed id, address indexed maker, address recipient, address indexed admin);
    event OfferForceCancelled(
        uint256 indexed id, address indexed maker, address makerRecipient, address takerRecipient, address indexed admin
    );

    // --------------------------------------------------------------------- //
    //                                Initializer                             //
    // --------------------------------------------------------------------- //

    function initialize(address admin, address kycSigner, address feeSigner) external;

    // --------------------------------------------------------------------- //
    //                              Maker actions                             //
    // --------------------------------------------------------------------- //

    function placeOrder(
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 buyAmount,
        uint64 expireTs,
        ExchangeTypes.KycAttestation calldata att,
        ExchangeTypes.FeeAttestation calldata feeAtt
    ) external returns (uint256 id);

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
        ExchangeTypes.KycAttestation calldata att,
        ExchangeTypes.FeeAttestation calldata feeAtt
    ) external returns (uint256 id);

    function cancelOrder(uint256 id) external;

    // --------------------------------------------------------------------- //
    //                       Permit + call (any actor)                        //
    // --------------------------------------------------------------------- //

    /// @notice Run an ERC-2612 permit for the caller, then make one call on this contract with
    ///         the allowance it granted. Lets a taker or an offer party approve and trade in a
    ///         single transaction (AO-298), the way `placeOrderWithPermit` already let a maker.
    /// @param data ABI-encoded call to make afterwards, e.g. `fillOrder(id, amount, att)`.
    /// @return permitAccepted Whether the token accepted the permit. False means the inner call
    ///                        ran against a pre-existing allowance, or is about to revert.
    /// @return result         The inner call's return data.
    function permitAndCall(
        address token,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s,
        bytes calldata data
    ) external returns (bool permitAccepted, bytes memory result);

    // --------------------------------------------------------------------- //
    //                          Permissioned taker                            //
    // --------------------------------------------------------------------- //

    function fillOrder(uint256 id, uint256 fillSellAmount, ExchangeTypes.KycAttestation calldata att) external;

    // --------------------------------------------------------------------- //
    //                           Admin escape hatch                           //
    // --------------------------------------------------------------------- //
    // settle/refund are parked (AC-246) — see docs/parked/OperatorFunctions.sol.

    function cancelOrderForUser(uint256 id, address recipient) external;

    function sweepExpired(uint256[] calldata ids) external;

    function sweepExpiredOffers(uint256[] calldata ids) external;

    // --------------------------------------------------------------------- //
    //                        Offer / counter-offer                           //
    // --------------------------------------------------------------------- //

    function makeOffer(
        address taker,
        address makerToken,
        uint256 makerAmount,
        address takerToken,
        uint256 takerAmount,
        uint64 expireTs,
        ExchangeTypes.KycAttestation calldata att,
        ExchangeTypes.FeeAttestation calldata feeAtt
    ) external returns (uint256 id);

    function replaceOffer(
        uint256 offerId,
        uint256 newMakerAmount,
        uint256 newTakerAmount,
        uint64 expireTs,
        ExchangeTypes.KycAttestation calldata att
    ) external;

    function cancelOffer(uint256 offerId, ExchangeTypes.KycAttestation calldata att) external;

    function acceptOffer(uint256 offerId, ExchangeTypes.KycAttestation calldata att) external;

    function cancelOfferForUser(uint256 offerId, address makerRecipient, address takerRecipient) external;

    // --------------------------------------------------------------------- //
    //                                 Admin                                  //
    // --------------------------------------------------------------------- //

    function setAllowedCollector(address collector, bool allowed) external;

    function pause() external;

    function unpause() external;

    function setComplianceRequired(ExchangeTypes.Action action, bool required) external;

    // --------------------------------------------------------------------- //
    //                                 Views                                  //
    // --------------------------------------------------------------------- //

    function getOffer(uint256 id) external view returns (ExchangeTypes.Offer memory);

    function getOrder(uint256 id) external view returns (ExchangeTypes.Order memory);

    function version() external pure returns (string memory);

    function totalOrders() external view returns (uint256);

    function totalOffers() external view returns (uint256);

    function usedNonce(address account, uint256 nonce) external view returns (bool);

    function usedFeeNonce(address account, uint256 nonce) external view returns (bool);

    function complianceRequired(ExchangeTypes.Action action) external view returns (bool);

    function allowedCollectors(address collector) external view returns (bool);
}
