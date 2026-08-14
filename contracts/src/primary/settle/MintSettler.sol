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
///             `Action.SettleMint`, which is KYC-gated already and would be gated even if it
///             were not declared: `AsseteraPrimarySales.complianceRequired` overrides the shared
///             fail-open getter so that every ordinal is required until an admin exempts it.
///           * The same TWO-CALL preamble the venue path uses, reachable because `IntentGate`
///             and `SettlementLimits` both sit BELOW this module:
///
///             ```solidity
///             bytes32 paramsHash = _verifyIntent(intent, intentSignature, buyerSignature);
///             _authorizeSettlement(uint8(Action.SettleMint), intent, paramsHash, kyc, fee);
///             ```
///
///             The buyer's own signature over the intent is checked inside the first, so this
///             family gets it for free and cannot forget it. The second binds both attestations,
///             charges the per-transaction value cap and burns all three nonces.
///             ⚠️ An earlier version of this list spelled the preamble out step by step and
///             OMITTED the cap, which is precisely how the mint family would have shipped
///             uncapped. There is now nothing to omit: the cap is inside
///             `_authorizeSettlement`, and a family cannot burn the intent nonce without it.
///             `orderId` is zero here too; there is no order book on this path either.
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
