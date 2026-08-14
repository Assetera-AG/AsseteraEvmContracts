// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AsseteraPrimarySales} from "../../../src/primary/AsseteraPrimarySales.sol";
import {ISettlementLimits} from "../../../src/primary/interfaces/ISettlementLimits.sol";

/// @notice `AsseteraPrimarySales` with the REAL S2 settler and a MOCK `ISettlementLimits`.
///
///         The venue settler charges `_consumeSettlementLimit` before it moves anything, and
///         the caps module (AO-517) is a stub that reverts unconditionally, so a settlement
///         against the plain contract cannot reach a single line of the money path. This
///         harness supplies the smallest thing that satisfies the frozen `ISettlementLimits`
///         semantics — a per-transaction cap enforced on the amount handed to it — so the
///         venue packet can be tested without waiting for, or depending on, that packet
///         landing.
///
///         It also records what it was charged. "Which number the settler passes to the caps"
///         is a claim about this packet rather than about AO-517, so it is asserted here.
///
/// @dev    ⚠️ Unlike `PrimarySalesHarness`, this one DOES declare linear storage. That is safe
///         here and must stay confined to test code: `AsseteraPrimarySales` has no linear
///         storage at all (every region it uses is ERC-7201 namespaced), so slot 0 upward is
///         free and nothing can be shadowed. This harness is never used for a storage-layout
///         or upgrade assertion — `PrimarySalesHarness` is the one for those.
contract CappedPrimarySalesHarness is AsseteraPrimarySales {
    /// @notice The settlement token of the most recent `_consumeSettlementLimit` call.
    address public lastLimitToken;
    /// @notice The amount of the most recent `_consumeSettlementLimit` call.
    uint256 public lastLimitAmount;
    /// @notice How many times the settler charged the caps during the last settlement.
    uint256 public limitCalls;

    /// @notice Mock per-transaction cap, per settlement token. Zero means "uncapped", which is
    ///         the OPPOSITE of the real module's fail-closed reading of zero; a mock that
    ///         blocked everything by default would need a setter call in every test.
    mapping(address token => uint256 cap) public mockPerTxCap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address trustedForwarder) AsseteraPrimarySales(trustedForwarder) {}

    /// @notice Set the mock per-transaction cap for one settlement token.
    /// @param token The settlement currency.
    /// @param cap   The cap, or zero for "uncapped" in this mock's reading.
    function setMockPerTxCap(address token, uint256 cap) external {
        mockPerTxCap[token] = cap;
    }

    /// @dev The mock caps module. Records, then enforces.
    function _consumeSettlementLimit(address token, uint256 amount) internal override {
        lastLimitToken = token;
        lastLimitAmount = amount;
        limitCalls += 1;

        uint256 cap = mockPerTxCap[token];
        if (cap != 0 && amount > cap) revert ISettlementLimits.PerTxCapExceeded(token, amount, cap);
    }

    /// @notice Direct read of the unwired buyer-fee derivation, so its rounding policy can be
    ///         pinned by hardcoded vectors even though `_settleVenue` cannot yet call it.
    /// @param venueQuoteIn The venue's firm quote.
    /// @param takerFeeBps  The attested basis points.
    /// @return The fee those two imply.
    function expectedBuyerFee(uint256 venueQuoteIn, uint16 takerFeeBps) external pure returns (uint256) {
        return _expectedBuyerFee(venueQuoteIn, takerFeeBps);
    }

    /// @notice Direct call of the unwired buyer-fee cross-check.
    /// @param intent      The settlement intent whose `buyerFee` is under test.
    /// @param takerFeeBps The basis points the fee service attested for it.
    function assertBuyerFee(SettlementIntent calldata intent, uint16 takerFeeBps) external pure {
        _assertBuyerFee(intent, takerFeeBps);
    }
}
