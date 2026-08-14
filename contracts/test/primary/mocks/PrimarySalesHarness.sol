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

    /// @dev The stand-in family's own money path, reached only once the shared preamble has
    ///      passed. It reverts so the test can tell "got here" from "stopped earlier", and it
    ///      reverts with an error declared HERE rather than in `src/`: the router has exactly
    ///      one settlement family and no "not implemented" error of its own, and borrowing a
    ///      production error for a test marker is how a marker outlives the thing it marked.
    error AnotherFamilyMoneyPathReached();

    /// @notice 🔴 A second settler family's entry point, which this router does not have and is
    ///         not going to get: the shared preamble, and then straight into its own money path.
    ///
    ///         It exists to make one claim testable — that the per-transaction value cap is
    ///         charged by `SettlementLimits._authorizeSettlement`, which every caller of the
    ///         preamble runs, rather than by `VenueSettler`, which is the only settler that
    ///         exists. The charge used to live in `VenueSettler`'s step 1, so every test of it
    ///         went through `settlePrimary` and none of them asserted anything about a path that
    ///         did not go through `VenueSettler`.
    ///
    ///         ⚠️ It stands in for a family that was REMOVED, and the test is worth more for
    ///         that, not less. `MintSettler` was deleted on 2026-08-14 (our own issuance now
    ///         goes through the venue path, against a per-token sale contract), so nothing in
    ///         `src/` reaches `_authorizeSettlement` except `settlePrimary`. That is exactly the
    ///         shape in which "the cap is charged centrally" degrades into "the cap happens to
    ///         be charged, because there is only one caller" without anyone noticing. This
    ///         harness is the second caller, and it is the only thing that can tell the two
    ///         apart.
    ///
    ///         What the pair of assertions looks like: with no cap set for the settlement
    ///         currency this reverts `PerTxCapExceeded` and never reaches the money path; with a
    ///         cap set it reverts `AnotherFamilyMoneyPathReached`, which is the family's own
    ///         body. Move the charge out of the preamble and the first becomes the second.
    ///
    /// @dev    Deliberately mirrors what any future entry point must do, and nothing more. No
    ///         `whenNotPaused`, no `nonReentrant` and no calldata binding: those are the real
    ///         entry point's business and are asserted against the real one.
    ///
    ///         It runs under `Action.SettleMint` because that ordinal is RESERVED and has no
    ///         entry point in `src/` — so this cannot accidentally be `settlePrimary`'s path,
    ///         and the attestations the test signs carry an ordinal the gates compare.
    function settleAsAnotherFamily(
        SettlementIntent calldata intent,
        bytes calldata intentSignature,
        bytes calldata buyerSignature,
        KycAttestation calldata kyc,
        FeeAttestation calldata fee
    ) external {
        bytes32 paramsHash = _verifyIntent(intent, intentSignature, buyerSignature);
        _authorizeSettlement(uint8(Action.SettleMint), intent, paramsHash, kyc, fee);
        revert AnotherFamilyMoneyPathReached();
    }
}
