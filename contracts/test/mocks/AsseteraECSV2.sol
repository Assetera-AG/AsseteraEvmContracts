// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AsseteraECS} from "../../src/AsseteraECS.sol";

/// @notice Upgrade target used only in tests to prove the UUPS path: it bumps
///         the version, adds a new function, and — crucially — adds a new
///         storage variable so the upgrade tests can assert that appending
///         state neither corrupts existing slots nor is corrupted by them.
///
///         `upgradeNote` lands after all inherited storage (past the base
///         `__gap`), in genuinely unused space. A production upgrade that adds
///         state would instead shrink `ExchangeStorage.__gap` and place the new
///         var in the reserved region; the storage-layout snapshot guard
///         (`script/storage-layout.sh`) exists to catch exactly that edit and
///         turn it into a reviewed diff. For a test mock, appending is enough to
///         exercise the "old state preserved + new state writable" property.
contract AsseteraECSV2 is AsseteraECS {
    /// @dev New state introduced by the upgrade (see contract-level note).
    uint256 public upgradeNote;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address trustedForwarder) AsseteraECS(trustedForwarder) {}

    function version() external pure override returns (string memory) {
        return "4.0.0";
    }

    function isUpgraded() external pure returns (bool) {
        return true;
    }

    function setUpgradeNote(uint256 v) external {
        upgradeNote = v;
    }
}
