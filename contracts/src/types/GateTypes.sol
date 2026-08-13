// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title GateTypes
/// @notice The attestation vocabulary of the compliance/fee gates, split out of
///         `ExchangeTypes` (AO-514) so a contract can use the gates without
///         inheriting the order book's `Order`/`Offer`/`OrderStatus` types.
///
///         Declared as an `abstract contract` rather than an `interface` for the
///         same reason `ExchangeTypes` is — see that file's doc comment.
///
/// @dev    ⚠️ Both structs are EIP-712 SIGNED PAYLOADS. Adding, removing,
///         reordering or retyping a field changes the typehash and therefore the
///         digest, which invalidates every attestation AsseteraSignerService has
///         in flight. `test/ParamsHashVectors.t.sol` pins the digests as
///         hardcoded literals precisely so such a change cannot land quietly.
abstract contract GateTypes {
    /// @notice A single-use KYC authorization. The first six fields are EIP-712
    ///         signed by a `KYC_OPERATOR_ROLE` holder; `signature` is that sig.
    ///         Carries no fee terms — fees are authorised separately via
    ///         `FeeAttestation`, signed by the (distinct) fee service.
    struct KycAttestation {
        address account; // the party being authorized; must equal the actor
        /// @dev The action this authorizes, as the gate-agnostic `uint8` the EIP-712 typehash
        ///      has always declared (`uint8 action`). Consumers give it meaning: the exchange
        ///      reads it as `ExchangeTypes.Action`. Retyped from that enum to `uint8` by AO-514
        ///      so a second venue can define its own action set over the same gate; the ABI and
        ///      the digest are unchanged, since an enum is already `uint8` in both.
        uint8 action;
        uint256 orderId; // bound order (0 for Place)
        uint256 nonce; // single-use, per-account
        uint256 deadline; // unix expiry (backend sets ~3 min)
        bytes32 paramsHash; // keccak256(abi.encode(sellToken,sellAmount,buyToken,buyAmount)) for Place; bytes32(0) otherwise
        bytes signature; // KYC operator's EIP-712 signature over the above
    }

    /// @notice A single-use fee authorization from the fee service, required
    ///         alongside a `KycAttestation` on fee-setting actions (`placeOrder`,
    ///         `placeOrderWithPermit`, `makeOffer`). Bound to the same actor and
    ///         action as the paired KYC attestation, and to the same `paramsHash`
    ///         (both are checked against the identical on-chain-computed hash),
    ///         so a fee attestation cannot be replayed against a different order/
    ///         offer or paired with a mismatched KYC attestation. Uses a separate
    ///         nonce namespace (`usedFeeNonce`) from KYC.
    struct FeeAttestation {
        address account; // the party being authorized; must equal the actor
        uint8 action; // which action this authorizes (Place or MakeOffer); see KycAttestation.action
        uint256 nonce; // single-use, per-account, separate from KYC nonces
        uint256 deadline; // unix expiry (fee service sets ~3 min)
        bytes32 paramsHash; // must equal the paired KycAttestation's paramsHash
        uint16 makerFeeBps; // maker's fee on the notional, denominated in feeToken
        uint16 takerFeeBps; // taker's fee on the notional, denominated in feeToken
        address feeCollector; // must be in the on-chain allowlist when non-zero fees
        /// @dev The settlement currency both fees are denominated in (AC-833). The fee
        ///      service resolves it from the catalog (`token_pairs.settlement_currency_id`)
        ///      — the contract knows tokens, not markets, so it cannot infer which leg is
        ///      money. Asserted on-chain to be one of the two legs; required even when
        ///      both bps are zero, so that a legacy (pre-AC-833) order stays
        ///      distinguishable by `feeToken == address(0)`.
        address feeToken;
        bytes signature; // fee operator's EIP-712 signature over the above
    }
}
