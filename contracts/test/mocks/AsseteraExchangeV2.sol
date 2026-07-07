// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AsseteraExchange} from "../../src/AsseteraExchange.sol";

/// @notice Upgrade target used only in tests to prove the UUPS path: it bumps
///         the version and adds a new function while preserving storage layout.
contract AsseteraExchangeV2 is AsseteraExchange {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address trustedForwarder) AsseteraExchange(trustedForwarder) {}

    function version() external pure override returns (string memory) {
        return "4.0.0";
    }

    function isUpgraded() external pure returns (bool) {
        return true;
    }
}
