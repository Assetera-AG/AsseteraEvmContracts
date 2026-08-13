// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {FeeGate} from "../../src/gates/FeeGate.sol";

/// @notice A contract that uses the compliance and fee gates and NOTHING else — no orders, no
///         offers, no counters, no `ExchangeTypes`. It exists to make AO-514's whole point a
///         compile-time assertion instead of a claim in a PR body: before the extraction this
///         file could not have existed, because `KycGate` was `is ExchangeStorage` and would
///         have dragged the entire order book in with it.
///
///         It is deliberately NOT a sketch of the forthcoming primary-settlement venue (that is
///         a separate subtask). It is the smallest thing that can consume the gates: one action
///         of its own numbering, one call that verifies and burns both attestations.
///
///         Its second job is to pin the `_paramsHashAllowed` default. This venue does not
///         override the hook, so `KycGate` must reject any non-zero `paramsHash` — the
///         restrictive answer. A future edit that flipped the default to "allowed" would let a
///         venue accept an unbound `paramsHash` it never checked, and this mock is what notices.
contract GateOnlyVenue is Initializable, FeeGate {
    /// @dev This venue's own action numbering, unrelated to `ExchangeTypes.Action`. Sharing the
    ///      gate does not mean sharing an action set — that is what the `uint8` retype bought.
    uint8 public constant ACTION_SETTLE = 1;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Mirrors `AsseteraECS.initialize` closely enough to exercise the gate's bases.
    /// @param admin     DEFAULT_ADMIN_ROLE holder.
    /// @param kycSigner Initial KYC_OPERATOR_ROLE holder.
    /// @param feeSigner Initial FEE_OPERATOR_ROLE holder.
    function initialize(address admin, address kycSigner, address feeSigner) external initializer {
        __AccessControl_init();
        __EIP712_init("GateOnlyVenue", "1");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(KYC_OPERATOR_ROLE, kycSigner);
        _grantRole(FEE_OPERATOR_ROLE, feeSigner);
        _gate().complianceRequired[ACTION_SETTLE] = true;
    }

    /// @notice Verify and consume both attestations for this venue's one action.
    /// @param kycAtt KYC attestation authorising `ACTION_SETTLE`.
    /// @param feeAtt Fee attestation for the same account and action.
    function settle(KycAttestation calldata kycAtt, FeeAttestation calldata feeAtt) external {
        _consumeKycAndFee(msg.sender, ACTION_SETTLE, 0, kycAtt, feeAtt);
    }
}
