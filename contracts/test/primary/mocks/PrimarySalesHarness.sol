// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AsseteraPrimarySales} from "../../../src/primary/AsseteraPrimarySales.sol";

/// @notice `AsseteraPrimarySales` with the S2 seam filled by a fixed, measured-looking result
///         and two internal hooks exposed for direct assertion.
///
///         It exists for two reasons.
///
///         First, the skeleton on its own reverts at the seam, so nothing that happens AFTER
///         the seam — the three nonce burns, the settlement event — can be observed. Stubbing
///         `_settleVenue` from OUTSIDE `src/` lets those be asserted while proving the same
///         point the revert proves: a settlement family is swappable at a real boundary, and
///         no line of `src/primary/settle/**` is needed to exercise the entry point.
///
///         Second, `_paramsHashAllowed` is the one piece of gate policy this contract
///         overrides, and it is `internal`. Asserting it through behaviour alone would prove
///         it only for the actions that happen to have an entry point.
///
/// @dev    ⚠️ Declares no storage of its own. `AsseteraPrimarySales` has no linear storage at
///         all — every region it uses is ERC-7201 namespaced — and adding some here would make
///         this harness a different storage layout from the contract under test.
contract PrimarySalesHarness is AsseteraPrimarySales {
    uint256 public constant STUB_ASSET_DELIVERED = 42e18;
    uint256 public constant STUB_VENUE_IN = 990e6;
    uint256 public constant STUB_REFUND = 10e6;
    uint256 public constant STUB_FEE = 5e6;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address trustedForwarder) AsseteraPrimarySales(trustedForwarder) {}

    /// @dev The S2 seam, stubbed. Moves no tokens; returns the four numbers the entry point
    ///      puts into `PrimarySettled` so the event's field mapping can be pinned exactly.
    function _settleVenue(bytes calldata, SettlementIntent calldata)
        internal
        pure
        override
        returns (SettlementResult memory)
    {
        return SettlementResult({
            assetDelivered: STUB_ASSET_DELIVERED, venueIn: STUB_VENUE_IN, refund: STUB_REFUND, fee: STUB_FEE
        });
    }

    /// @notice Direct read of the `_paramsHashAllowed` override, action by action.
    function paramsHashAllowed(uint8 action) external view returns (bool) {
        return _paramsHashAllowed(action);
    }

    /// @notice Direct read of the intent struct hash, which is also the `paramsHash` binding.
    function intentStructHash(SettlementIntent calldata intent) external pure returns (bytes32) {
        return _intentStructHash(intent);
    }
}
