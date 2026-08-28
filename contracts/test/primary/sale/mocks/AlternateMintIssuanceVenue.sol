// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AsseteraIssuanceVenue} from "../../../../src/primary/sale/AsseteraIssuanceVenue.sol";
import {LegacyMintAssetToken} from "./IssuanceVenueMocks.sol";

/// @title AlternateMintIssuanceVenue
/// @notice The whole of what it takes to support an asset token whose mint is not
///         `mint(address,uint256)`: one overridden internal function, and nothing else.
///
///         `IMintableERC20` claims that the OpenZeppelin mint shape is isolated behind
///         `AsseteraIssuanceVenue._mintAsset` so a differently-shaped token is a subclass rather
///         than a rewrite. This contract is that claim written as code — a partitioned
///         `issue(address,uint256,bytes32)` instead of a plain mint — and the tests that drive it
///         run the same assertions as the ones that drive the base venue, which is what turns the
///         claim into evidence.
///
/// @dev    ⚠️ **Note what is NOT overridden.** The cap, the quote, the rounding, the measured
///         pull, the measured delivery, the event and every role are inherited untouched. If a
///         future change to `purchase` ever made a second override necessary here, the isolation
///         this file demonstrates has been lost and the change is the thing to reconsider.
contract AlternateMintIssuanceVenue is AsseteraIssuanceVenue {
    /// @notice The partition every issuance from this venue is created in. One offering, one
    ///         partition, fixed at deployment like everything else about an offering.
    bytes32 public immutable PARTITION;

    constructor(SaleConfig memory config, bytes32 partition) AsseteraIssuanceVenue(config) {
        PARTITION = partition;
    }

    /// @inheritdoc AsseteraIssuanceVenue
    /// @dev The one line. The base class still measures `balanceOf(to)` across this call, so a
    ///      partitioned token that under-delivers is caught here exactly as it is on the standard
    ///      path — the assertion belongs to the caller and is not something an override can
    ///      weaken by forgetting it.
    function _mintAsset(address to, uint256 amount) internal override {
        LegacyMintAssetToken(address(ASSET_TOKEN)).issue(to, amount, PARTITION);
    }
}
