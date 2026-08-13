// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IntentGate} from "../IntentGate.sol";
import {ISettlementLimits} from "../interfaces/ISettlementLimits.sol";

/// @title SettlementLimits
/// @notice **STUB — the value-caps packet (AO-517) owns this body.** Per-transaction and
///         rolling per-day caps on settled value, per settlement token, enforced on the
///         amount ACTUALLY DEBITED rather than on the quoted one.
///
///         The skeleton packet created this file, wired it into the inheritance list and
///         froze `ISettlementLimits`, so the caps packet only ever edits its own file and
///         never the one four other packets code against.
///
/// @dev    What the caps packet adds here, and nowhere else:
///           1. `is ISettlementLimits` on the line below, plus the four external functions it
///              declares (`perTxCap`, `perDayCap`, `settledToday`, `setSettlementCaps`), the
///              admin setter gated by `DEFAULT_ADMIN_ROLE` and emitting `SettlementCapsSet`,
///              following the `ExchangeAdmin` pattern rather than a new ownership model.
///           2. The cap state, APPENDED to `PrimaryStorage.PrimaryData` (appending to an
///              ERC-7201 struct is upgrade-safe and no other packet touches that file).
///           3. A real body for `_consumeSettlementLimit`.
///
///         ⚠️ This packet was a venue and selector allowlist until 2026-08-13 and is
///         deliberately no longer one. Do not quietly reintroduce a list: it did not bound a
///         compromised signer's damage to the buyer, and it did not protect the minting
///         right. Caps bound IMPACT rather than likelihood, and with nothing on-chain
///         constraining the call target they are the only remaining contract-level limit on
///         how much a single compromised key can move.
abstract contract SettlementLimits is IntentGate {
    /// @dev Charge one settlement against the caps for its settlement token, and revert if it
    ///      does not fit. Called by each settler family with the amount actually debited from
    ///      the buyer — after the refund is known, not the quote.
    ///
    ///      ⚠️ **Fails CLOSED while unimplemented.** An unimplemented cap must block a
    ///      settlement, never wave it through: the fail-open alternative is a router with no
    ///      value limit at all, which is precisely the state the allowlist removal was
    ///      predicated on not being acceptable.
    ///      Takes the settlement token and the amount debited. Parameters are left unnamed so
    ///      the stub compiles warning-free.
    function _consumeSettlementLimit(address, uint256) internal virtual {
        revert ISettlementLimits.SettlementLimitsNotImplemented();
    }
}
