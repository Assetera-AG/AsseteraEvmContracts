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
    function _settleVenue(bytes calldata, SettlementIntent calldata, uint16)
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

    /// @notice 🔴 A settler family that is NOT S2, standing in for the mint family and for
    ///         whatever family lands after it: the shared preamble, and then straight into its
    ///         own money path.
    ///
    ///         It exists to make one claim testable — that the per-transaction value cap is
    ///         charged by `SettlementLimits._authorizeSettlement`, which every family runs,
    ///         rather than by `VenueSettler`, which is the only family that exists. The charge
    ///         used to live in S2's step 1, so every test of it went through S2 and none of them
    ///         would have noticed the mint family shipping uncapped.
    ///
    ///         What the pair of assertions looks like: with no cap set for the settlement
    ///         currency this reverts `PerTxCapExceeded` and never reaches `_settleMint`; with a
    ///         cap set it reverts `SettlerNotImplemented`, which is the family's own body. Move
    ///         the charge out of the preamble and the first becomes the second.
    ///
    /// @dev    Deliberately mirrors what the mint packet's real entry point must do, and nothing
    ///         more. No `whenNotPaused`, no `nonReentrant` and no calldata binding: those are
    ///         the real entry point's business and are asserted against the real one.
    function settleAsAnotherFamily(
        SettlementIntent calldata intent,
        bytes calldata intentSignature,
        bytes calldata buyerSignature,
        KycAttestation calldata kyc,
        FeeAttestation calldata fee
    ) external {
        bytes32 paramsHash = _verifyIntent(intent, intentSignature, buyerSignature);
        _authorizeSettlement(uint8(Action.SettleMint), intent, paramsHash, kyc, fee);
        _settleMint(intent);
    }
}
