// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GateTypes} from "../../types/GateTypes.sol";

/// @title PrimaryTypes
/// @notice The vocabulary of the primary-sale router: its action set, the frozen
///         `SettlementIntent` the settlement operator signs, its EIP-712 typehash,
///         and the measured-effects struct a settler family hands back.
///
///         Declared as an `abstract contract` rather than an `interface` for the same
///         reason `ExchangeTypes` is, and it inherits `GateTypes` for the same reason:
///         so `AsseteraPrimarySales.KycAttestation memory att` resolves in TYPE
///         position for consumers that only import the assembled contract.
///
/// @dev    ⚠️ **Inheritance carries a nested type into TYPE position only.**
///         `PrimaryTypes.KycAttestation memory a` compiles; the struct LITERAL
///         `PrimaryTypes.KycAttestation({…})` does NOT — an expression-position
///         `Contract.Type` must name the contract that DECLARES the type. Write
///         `GateTypes.KycAttestation({…})` at every construction site. The same
///         asymmetry applies to enum members.
abstract contract PrimaryTypes is GateTypes {
    // --------------------------------------------------------------------- //
    //                              Action set                                //
    // --------------------------------------------------------------------- //

    /// @notice The primary-sale actions that can be KYC-gated, in this router's OWN
    ///         numbering. Sharing `KycGate`/`FeeGate` with `AsseteraECS` does NOT mean
    ///         sharing an action set: the gate stores the flag under an opaque `uint8`
    ///         and an attestation is bound to a verifying contract by the EIP-712 domain,
    ///         so ordinal 1 here and ordinal 1 on the exchange are unrelated.
    ///
    /// @dev    ✅ **Appending a member here is safe on its own, and it did not use to be.**
    ///         `GateStorage.complianceRequired` is a `mapping(uint8 => bool)` and is therefore
    ///         fail-OPEN — an action nobody wrote reads `false`, `KycGate._verifyKyc` returns on
    ///         its first line, and the settlement runs unscreened. The router used to answer that
    ///         with an initializer that enumerated this enum, which gated exactly the members
    ///         somebody remembered. `AsseteraPrimarySales.complianceRequired` now overrides the
    ///         getter to read an EXEMPTION out of the router's own namespace, so a member added
    ///         here is gated the moment it exists, with no line to add anywhere.
    ///
    ///         ⚠️ What a new member DOES still need: an entry in
    ///         `AsseteraPrimarySales._paramsHashAllowed` if it binds an intent (it will), and its
    ///         own entry point. Neither can be forgotten silently — the first rejects every
    ///         attestation the action produces, the second does not exist.
    ///
    ///         Ordinals are append-only: `AsseteraSignerService` signs the ordinal, so
    ///         renumbering silently re-points every attestation in flight.
    ///
    ///         ⚠️ **`SettleMint` (2) is RESERVED, not dead, and it is currently UNREACHABLE.**
    ///         `AsseteraPrimarySales.settlePrimary` hardcodes `Action.SettleVenue` and is the
    ///         only settlement entry point there is, so no transaction can run under ordinal 2.
    ///         It is held anyway because the settlement mechanics and the COMPLIANCE question
    ///         are not the same question: subscribing to our own issuance and buying a
    ///         third-party asset go down one code path — the sale contract is just another venue
    ///         — but they may carry different appropriateness treatment, and the ordinal is what
    ///         the compliance signer signs. Keeping it means that distinction can be made
    ///         without renumbering anything, which is the one thing this enum must never do.
    ///
    ///         ⚠️ **Holding an unreachable ordinal is only safe because the compliance gate on
    ///         this router is fail-CLOSED, and that is a recent property rather than a
    ///         long-standing one.** `AsseteraPrimarySales.complianceRequired` overrides the
    ///         shared getter to read an EXEMPTION out of the router's own namespace, so an
    ///         ordinal nobody enabled is GATED rather than ungated;
    ///         `test_ComplianceGate_IsClosedForEveryOrdinal` walks all 256 of them. Under the
    ///         previous fail-open arrangement — a `mapping(uint8 => bool)` written by an
    ///         initializer that enumerated this enum — a reserved ordinal would have been a hole:
    ///         the day somebody gave it an entry point without also remembering the initializer
    ///         line, it would have settled unscreened. Do not reserve ordinals here again if
    ///         that override is ever removed.
    enum Action {
        None, // 0 — never gated, never accepted; a zero action is an unset field
        SettleVenue, // 1 — a venue settlement through the constrained executor: a third party's
        // contract, or the per-token sale contract fronting our own issuance
        SettleMint // 2 — RESERVED and unreachable; see the ⚠️ above before giving it a caller
        // S3 ("observed", recorded rather than executed) has no ordinal yet: it may end up
        // off-chain only. Appending it later is safe, and it is gated the moment it exists.
    }

    // --------------------------------------------------------------------- //
    //                          The settlement intent                         //
    // --------------------------------------------------------------------- //

    /// @notice What the settlement operator signs to authorise ONE primary settlement — and
    ///         what the BUYER signs to agree to it.
    ///
    ///         It carries two of the four signatures on the path, alongside the KYC attestation
    ///         (compliance backend) and the fee attestation (fee service). The operator's is the
    ///         only one of ours whose signer can cause a transfer, which is why it has its own
    ///         role and its own key.
    ///
    ///         ⚠️ **ONE digest, TWO signers, and the struct did not change to make that so.**
    ///         `IntentGate._verifyIntent` takes both signatures and validates each against a
    ///         different party — the operator against `SETTLEMENT_OPERATOR_ROLE`, the buyer
    ///         against `intent.buyer` with ERC-1271 support. `INTENT_TYPEHASH` is what it always
    ///         was; the only thing that moved is the `settlePrimary` selector, which gained a
    ///         parameter. A reader reaching the frozen-payload warning below should not conclude
    ///         from it that the typehash moved. The reason there is no separate "BuyerConsent"
    ///         struct is in `_verifyIntent`: a mirror struct drifts, one payload cannot.
    ///
    ///         The amount model, stated once so the four numbers cannot drift apart:
    ///
    ///         - `venueQuoteIn`    — the venue's firm quote. Approved to the venue, and the
    ///                               most it can pull.
    ///         - `buyerFee`        — our fee, derived by `FeeMath` from the attested
    ///                               `takerFeeBps`, in the settlement currency, charged ON TOP
    ///                               of the quote rather than carved out of it.
    ///         - `maxSettlementIn` — the buyer's slippage cap and the only number the buyer
    ///                               needs to read. Asserted `>= venueQuoteIn + buyerFee`.
    ///         - the measured consumption, after the call: whatever the venue did not take is
    ///           refunded to the buyer in the same transaction.
    ///
    /// @dev    ⚠️ **This is an EIP-712 SIGNED PAYLOAD and it is FROZEN.** Adding, removing,
    ///         reordering or retyping a field changes `INTENT_TYPEHASH` and therefore the
    ///         digest, which invalidates every intent `AsseteraSignerService` has in flight
    ///         AND every `paramsHash` binding on the two attestations that ride with it —
    ///         `paramsHash` IS this struct's EIP-712 struct hash. Three repositories code
    ///         against this shape: the signer service, the marketplace API and the indexer.
    ///
    ///         ⚠️ All fourteen members are STATIC types, which is what makes
    ///         `keccak256(abi.encode(INTENT_TYPEHASH, intent))` identical to the EIP-712
    ///         struct hash: `abi.encode` of an all-static struct is exactly its fourteen head
    ///         words, and `bytes4` is right-padded in both encodings. Introducing a dynamic
    ///         member (`bytes`, `string`, an array) would silently break that identity — the
    ///         ABI encoding would gain an offset word while EIP-712 would substitute a hash —
    ///         and `paramsHash` would stop matching the signed digest.
    struct SettlementIntent {
        address buyer; // must equal `_msgSender()` (ERC-2771 aware)
        address assetToken; // what the buyer must end up holding
        uint256 minAssetOut; // asserted against the MEASURED delivery after the call
        address settlementToken; // must equal `fee.feeToken`; NOT registered on-chain
        uint256 venueQuoteIn; // approved to the venue; the venue may consume less
        uint256 buyerFee; // our fee, same token, charged ON TOP of `venueQuoteIn`
        uint256 maxSettlementIn; // hard cap on the TOTAL buyer debit
        address feeCollector; // must be on this router's collector allowlist
        address venue; // signed, but checked against NO on-chain list (see below)
        bytes4 selector; // signed, and asserted against `bytes4(venueCalldata)`
        bytes32 calldataHash; // keccak256 of the calldata passed as its own argument
        bytes32 supplierReference; // the venue's own quote/order id, so the event can carry it
        uint256 nonce; // single-use, in this router's own namespace
        uint256 deadline; // hard TTL cap, as the two attestations have
    }

    /// @notice The EIP-712 typehash of `SettlementIntent` —
    ///         `0x86c9b91e614acc7421e39417dc43dd7b9bd2e0b2c8ce196c12f8b7391d281a03`, pinned as a
    ///         hardcoded literal in `test/primary/PrimaryIntentVectors.t.sol` so that editing the
    ///         struct cannot land quietly.
    bytes32 public constant INTENT_TYPEHASH = keccak256(
        "SettlementIntent(address buyer,address assetToken,uint256 minAssetOut,address settlementToken,uint256 venueQuoteIn,uint256 buyerFee,uint256 maxSettlementIn,address feeCollector,address venue,bytes4 selector,bytes32 calldataHash,bytes32 supplierReference,uint256 nonce,uint256 deadline)"
    );

    // --------------------------------------------------------------------- //
    //                          Measured effects                              //
    // --------------------------------------------------------------------- //

    /// @notice What a settler family hands back to the entry point: the four numbers the
    ///         settlement event reports, every one of them MEASURED rather than quoted.
    ///
    /// @dev    This is the whole reason the indexer needs no supplier-specific decoder. The
    ///         event is generated by us from balance deltas we observed, not relayed from
    ///         whatever the venue chose to emit, so `assetDelivered` is what the buyer
    ///         actually received and `venueIn` is what the venue actually took.
    struct SettlementResult {
        uint256 assetDelivered; // measured `assetToken` delta on the buyer; `>= minAssetOut`
        uint256 venueIn; // measured settlement-token consumption by the venue
        uint256 refund; // unconsumed settlement token returned to the buyer
        uint256 fee; // settlement token paid to `intent.feeCollector`
    }
}
