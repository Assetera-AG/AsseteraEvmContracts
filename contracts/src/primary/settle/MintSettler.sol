// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SettlementLimits} from "../admin/SettlementLimits.sol";
import {ISettler} from "../interfaces/ISettler.sol";

/// @title MintSettler
/// @notice **STUB — the mint packet (AO-137, relocated) owns this body.** Family S1: we hold
///         the minting right, so there is no third-party venue and no arbitrary calldata at
///         all. The recipient is `intent.buyer` structurally.
///
/// @dev    ⚠️ **The mint path must never route through the generic calldata executor, and
///         that is a security property rather than a style preference.** The structural
///         recipient is the ONLY thing standing between a compromised settlement signer and
///         `mint(attacker, …)`. There is no on-chain allowlist to fall back on, and even the
///         one that was considered could not have helped: a generic mint path would have
///         required `(ourToken, mint)` to be allowlisted, which would authorise exactly that
///         call. If a future change proposes unifying the two families behind one calldata
///         primitive, this is the reason to refuse.
///
///         What the mint packet adds here, and nowhere else:
///           * An external entry point of its own — the frozen `settlePrimary` is family S2's
///             and takes `venueCalldata`, which this family does not have. It runs under
///             `Action.SettleMint`, which `AsseteraPrimarySales.initialize` ALREADY enables in
///             the KYC gate, so the fail-open `complianceRequired` trap is closed in advance.
///           * The same four-step preamble the venue path uses, reachable because
///             `IntentGate` sits BELOW this module: `_verifyIntent(intent, intentSignature,
///             buyerSignature)` — the buyer's own signature over the intent is checked inside
///             the gate, so this family gets it for free and cannot forget it —
///             `_bindAttestations`,
///             `_consumeKycAndFee(buyer, uint8(Action.SettleMint), 0, kyc, fee)`,
///             `_consumeIntent`. `orderId` is zero here too; there is no order book on this
///             path either.
///           * `_settleMint`, and an emit of `PrimarySettled` with `venue` set to the minted
///             token, so the indexer builds the same activity-ledger leg for both families.
///
///         ⚠️ Structural separation from family S2 is this packet's job and it is cheap:
///         require `venueCalldata.length == 0` (or accept none at all), `intent.selector ==
///         bytes4(0)`, `intent.calldataHash == keccak256("")` and `intent.venue ==
///         intent.assetToken`. Without it, an intent the settlement operator signed for a
///         third-party venue could be presented to the mint entry point instead — the intent
///         nonce namespace is shared, so it can happen at most once, but once is enough.
///
///         Unlike family S2, a non-zero `makerFeeBps` IS meaningful here: we control the
///         proceeds side when we are the issuer. `settlePrimary` rejects it; this family
///         should not.
abstract contract MintSettler is SettlementLimits, ISettler {
    /// @dev The internal seam for family S1. Not an address, not a `delegatecall` target, not
    ///      an external call — one proxy, inherited modules (§4.5).
    ///
    ///      Takes the verified settlement intent and returns the four MEASURED numbers the
    ///      settlement event reports. The parameter is left unnamed so the stub compiles
    ///      warning-free.
    function _settleMint(SettlementIntent calldata) internal virtual returns (SettlementResult memory) {
        revert SettlerNotImplemented();
    }
}
