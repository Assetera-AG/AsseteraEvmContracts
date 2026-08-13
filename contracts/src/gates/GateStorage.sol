// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {GateTypes} from "../types/GateTypes.sol";

/// @title GateStorage
/// @notice Universal base of the attestation gates: their state, the OZ
///         upgradeable bases they need (inherited exactly once here, so every
///         gate reaches them via a single linear path — no diamond ambiguity),
///         and the errors raised by more than one gate.
///
///         Split out of `ExchangeStorage` by AO-514. `KycGate`/`FeeGate` used to
///         inherit the order book's storage, so any second contract that wanted
///         the compliance gate — the forthcoming primary-settlement venue — had
///         to inherit `_orders`, `_offers` and their counters as well. This base
///         carries the gate half and nothing else.
///
/// @dev    ⚠️ The four gate mappings live in **ERC-7201 namespaced storage**, not
///         in the linear layout, following the same idiom as the OZ v5
///         upgradeable bases. That is deliberate: a namespace is addressed by a
///         constant hash, so the gate state sits at the same place regardless of
///         where `GateStorage` lands in an inheriting contract's linearization.
///         A second venue with a completely different storage layout therefore
///         shares this base without either contract constraining the other, and
///         no `__gap` is needed here — the struct can grow in place.
abstract contract GateStorage is GateTypes, AccessControlUpgradeable, EIP712Upgradeable {
    // --------------------------------------------------------------------- //
    //                       Namespaced gate state                            //
    // --------------------------------------------------------------------- //

    /// @custom:storage-location erc7201:assetera.storage.Gate
    struct GateData {
        /// @dev Consumed KYC attestation nonces, per account. Single-use replay guard.
        mapping(address account => mapping(uint256 nonce => bool used)) usedNonce;
        /// @dev Consumed fee attestation nonces, per account. Separate namespace from
        ///      `usedNonce` since fee attestations are signed by a different party.
        mapping(address account => mapping(uint256 nonce => bool used)) usedFeeNonce;
        /// @dev Whether each action requires a KYC attestation. KYC ONLY (AC-884) — see
        ///      the `complianceRequired` getter below.
        mapping(uint8 action => bool required) complianceRequired;
        /// @dev Admin-managed allowlist of permitted fee collector addresses.
        mapping(address collector => bool allowed) allowedCollectors;
    }

    // keccak256(abi.encode(uint256(keccak256("assetera.storage.Gate")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant GATE_STORAGE_LOCATION = 0xa7ce1588183c3b5b9f93bf4096b3044102abf2a0ba114024279c565ad2f53300;

    /// @dev The namespaced state. `internal` rather than OZ's `private`, because unlike an OZ
    ///      base this one is written from sibling modules (`KycGate`, `FeeGate`, the admin
    ///      surface) rather than only from within itself.
    function _gate() internal pure returns (GateData storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := GATE_STORAGE_LOCATION
        }
    }

    // --------------------------------------------------------------------- //
    //                            Public getters                              //
    // --------------------------------------------------------------------- //
    // These replace the compiler-generated getters of the four `public` mappings that used to
    // sit in `ExchangeStorage`. Same names, same selectors, same argument and return types, so
    // every off-chain consumer is unaffected by the move into namespaced storage.

    /// @notice Whether a KYC attestation nonce has already been consumed for an account.
    /// @param account The attested party.
    /// @param nonce   The attestation's single-use nonce.
    /// @return Whether that nonce is spent.
    function usedNonce(address account, uint256 nonce) public view returns (bool) {
        return _gate().usedNonce[account][nonce];
    }

    /// @notice Whether a FEE attestation nonce has already been consumed for an account.
    ///         A separate namespace from `usedNonce`, since fee attestations are signed by a
    ///         different party and the two are issued independently.
    /// @param account The attested party.
    /// @param nonce   The attestation's single-use nonce.
    /// @return Whether that nonce is spent.
    function usedFeeNonce(address account, uint256 nonce) public view returns (bool) {
        return _gate().usedFeeNonce[account][nonce];
    }

    /// @notice Whether an action requires a KYC attestation.
    /// @dev KYC ONLY — it does NOT govern the fee attestation, which fee-setting actions always
    ///      require (AC-884). `action` is the caller-defined `uint8` the attestation carries; the
    ///      exchange's values are `ExchangeTypes.Action`.
    ///
    ///      ⚠️ **The underlying mapping is fail-OPEN.** Every `uint8` reads `false` until someone
    ///      writes it, and `KycGate._verifyKyc` returns immediately when this is `false` — so an
    ///      action nobody enabled is not gated at all, rather than gated by default. `AsseteraECS`
    ///      is safe because its initializer enables each of its actions explicitly (pinned by
    ///      `test_Initialize_GatesEveryDeclaredAction`), NOT because the gate defaults to on.
    ///      Any new consumer of this base must do the same for every action it defines, and prove
    ///      it in a test. The default is not inverted here because `complianceRequired` is a public
    ///      getter whose meaning is already relied on off-chain; changing its polarity is a breaking
    ///      change to the admin surface, and the forthcoming primary-settlement venue is expected to
    ///      express the policy as a required override instead (see AO-516).
    /// @param action The action ordinal.
    /// @return Whether a KYC attestation is required for it.
    function complianceRequired(uint8 action) public view returns (bool) {
        return _gate().complianceRequired[action];
    }

    /// @notice Whether an address is on the fee-collector allowlist.
    /// @dev A compromised fee signer cannot route fees to an arbitrary wallet, because the
    ///      collector must be allowlisted at the time the fee terms are attested.
    /// @param collector The candidate fee recipient.
    /// @return Whether it is allowed.
    function allowedCollectors(address collector) public view returns (bool) {
        return _gate().allowedCollectors[collector];
    }

    // --------------------------------------------------------------------- //
    //                          Shared errors                                 //
    // --------------------------------------------------------------------- //
    // Raised by more than one gate, so they must live in the common ancestor — declaring them
    // per-gate would collide with "Identifier already declared" once co-inherited.

    error ZeroAddress();
    error ParamsHashMismatch();
}
