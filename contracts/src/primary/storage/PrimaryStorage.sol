// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {FeeGate} from "../../gates/FeeGate.sol";
import {PrimaryTypes} from "../types/PrimaryTypes.sol";

/// @title PrimaryStorage
/// @notice Universal base of the primary-sale router: its own state, the settlement-operator
///         role, and the OZ upgradeable bases only this venue needs (inherited exactly once
///         here, so every derived module reaches them through a single linear path — no
///         diamond ambiguity).
///
///         The gates arrive through `FeeGate`, which AO-514 lifted off `ExchangeStorage`
///         precisely so a second contract could inherit the compliance and fee machinery
///         without inheriting an order book it has no use for. This is that second contract.
///
/// @dev    ⚠️ **This contract declares NO linear storage at all.** Its own state lives in the
///         ERC-7201 namespace `assetera.storage.PrimarySales`; the gate state lives in
///         `assetera.storage.Gate`; the OZ v5 bases each use their own. That is deliberate:
///         a namespace is addressed by a constant hash, so nothing here can be moved by a
///         change to the inheritance list or by a dependency bump, and no `__gap` is needed
///         because the struct grows in place.
///
///         The two namespaces are provably distinct and
///         `test/primary/PrimaryStorageNamespace.t.sol` re-derives BOTH from their preimages
///         and asserts it. A wrong namespace constant does not fail to compile and does not
///         fail any behavioural test — the state would simply live somewhere else and keep
///         agreeing with itself — so the derivation has to be the thing under test.
abstract contract PrimaryStorage is PrimaryTypes, FeeGate, ReentrancyGuardUpgradeable, PausableUpgradeable {
    // --------------------------------------------------------------------- //
    //                                Roles                                   //
    // --------------------------------------------------------------------- //

    /// @notice Whitelisted settlement-intent signers. Any intent whose recovered signer holds
    ///         this role is accepted. Managed by the admin multisig.
    ///
    /// @dev    ⚠️ A THIRD role, deliberately distinct from `KYC_OPERATOR_ROLE` and
    ///         `FEE_OPERATOR_ROLE` and with its own key. It is the only one of the three that
    ///         can cause a transfer: the compliance signer decides who may trade and the fee
    ///         signer decides the terms, but this signer decides that money moves and where.
    ///         Overloading it onto the fee role would silently promote the fee service to a
    ///         spending authority. `test_SettlementOperatorRole_IsDistinct` pins it.
    bytes32 public constant SETTLEMENT_OPERATOR_ROLE = keccak256("SETTLEMENT_OPERATOR_ROLE");

    // --------------------------------------------------------------------- //
    //                     Namespaced primary-sale state                      //
    // --------------------------------------------------------------------- //

    /// @custom:storage-location erc7201:assetera.storage.PrimarySales
    struct PrimaryData {
        /// @dev Consumed settlement-intent nonces, per buyer. Single-use replay guard, in a
        ///      namespace of its own: an intent is signed by a third party (the settlement
        ///      operator) and issued independently of the KYC and fee attestations, so it
        ///      must not share their counters.
        mapping(address buyer => mapping(uint256 nonce => bool used)) usedIntentNonce;
        // ── per-transaction settlement cap (AO-517), APPENDED ─────────────────────────────
        // Keyed by SETTLEMENT TOKEN and by nothing else. No buyer dimension: the settlement
        // operator names the buyer in the intent it signs, so anything keyed by buyer bounds
        // nothing that matters.
        /// @dev Per-transaction cap on the amount debited, per settlement token, in the token's
        ///      RAW units. ZERO means "no settlement in this token at all" rather than
        ///      "unlimited" — the fail-closed default for a token nobody configured. Converted
        ///      once from whole tokens when it is set; see `SettlementLimits`.
        mapping(address token => uint256 rawCap) settlementPerTxCap;
        /// @dev The same cap in WHOLE tokens, exactly as a human typed it into the Safe. Held
        ///      alongside the raw one so an operator can confirm the number without knowing the
        ///      token's decimals, and so the conversion is auditable after the fact.
        mapping(address token => uint256 wholeUnits) settlementPerTxCapWholeUnits;
        // ── the compliance gate, INVERTED, APPENDED (PR #58 review) ──────────────────────
        /// @dev Whether an action is EXEMPT from the KYC gate. The polarity is the whole point:
        ///      `GateStorage.complianceRequired` is a `mapping(uint8 => bool)`, so on the shared
        ///      base an action nobody wrote reads "not required" and is UNGATED — one forgotten
        ///      initializer line away from an ungated primary sale. Stored as an exemption in
        ///      THIS router's own namespace, an ordinal nobody has heard of reads `false` here
        ///      and is therefore GATED, which is the fail-closed answer and needs no enumeration
        ///      to stay true.
        ///
        ///      ⚠️ Never read this directly. `AsseteraPrimarySales.complianceRequired` is the
        ///      only reader, and it is the override every gate goes through — the shared
        ///      `_gate().complianceRequired` mapping is DEAD for this contract and writing it
        ///      would change nothing.
        mapping(uint8 action => bool exempt) complianceExempt;
    }

    // keccak256(abi.encode(uint256(keccak256("assetera.storage.PrimarySales")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PRIMARY_STORAGE_LOCATION =
        0xc3c7d533132905df5cacdace21b89e3afb4b7188f583ae32f30e0a7379982700;

    /// @dev The namespaced state. `internal` rather than OZ's `private`, because unlike an OZ
    ///      base this one is written from sibling modules (the intent gate, the value caps,
    ///      the settler families) rather than only from within itself.
    ///
    ///      The settlement value caps (AO-517) APPENDED their four mappings to `PrimaryData`.
    ///      Appending to an ERC-7201 struct is upgrade-safe — the region is addressed by a
    ///      constant hash and existing members keep their offsets — and no other packet in the
    ///      wave touches this file, so the append was not a parallel-edit conflict.
    ///      ⚠️ `usedIntentNonce` must stay at offset 0: `PrimaryStorageNamespace.t.sol` derives
    ///      its slot from that offset and asserts a real write lands there.
    function _primary() internal pure returns (PrimaryData storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := PRIMARY_STORAGE_LOCATION
        }
    }

    // --------------------------------------------------------------------- //
    //                            Public getters                              //
    // --------------------------------------------------------------------- //

    /// @notice Whether a settlement-intent nonce has already been consumed for a buyer.
    /// @dev A separate namespace from `usedNonce` (KYC) and `usedFeeNonce` (fee), for the same
    ///      reason those two are separate from each other: three independent signers issue
    ///      three independent single-use payloads, and a shared counter would let one of them
    ///      invalidate another's.
    /// @param buyer The party the intent authorises.
    /// @param nonce The intent's single-use nonce.
    /// @return Whether that nonce is spent.
    function usedIntentNonce(address buyer, uint256 nonce) public view returns (bool) {
        return _primary().usedIntentNonce[buyer][nonce];
    }
}
