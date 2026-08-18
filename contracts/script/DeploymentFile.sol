// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title DeploymentFile
/// @notice The one place that knows where a chain's deployment record lives.
///
///         The record is owned by the SDK (`packages/sdk/src/deployments/<chainId>.json`) and is written by
///         the deploy script, so every other script has to agree on that path exactly. They previously did
///         not: the deploy script built the path from the SDK directory while the verification and upgrade
///         scripts each hardcoded a bare `deployments/<chainId>.json` relative to the Foundry root. That
///         directory has not existed since the sources moved under `packages/`, so both of those scripts
///         failed on their first `require` on every chain — which is a bad failure to have in a script whose
///         entire job is to be the gate you run after a deploy.
///
///         Hence a shared constant rather than a shared convention. The path is a fact about the repository
///         layout, so it belongs in one place that all three read.
///
/// @dev Paths are relative to the Foundry root (`contracts/`), and the directory must be granted in
///      `fs_permissions` in `foundry.toml` for a script to read or write through it.
library DeploymentFile {
    /// @dev Trailing slash included so callers cannot disagree about whether to add one.
    string internal constant DIR = "../packages/sdk/src/deployments/";

    /// @notice The deployment record for `chainId`.
    /// @dev `Strings.toString` rather than `vm.toString` so this stays a pure library with no cheatcode
    ///      dependency, and can therefore be used from a plain `Script` as easily as from `DeployBase`.
    function pathFor(uint256 chainId) internal pure returns (string memory) {
        return string.concat(DIR, Strings.toString(chainId), ".json");
    }
}
