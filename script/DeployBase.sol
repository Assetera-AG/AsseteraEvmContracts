// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @title DeployBase
/// @notice Per-network deployment bookkeeping. Each network's addresses are
///         persisted to `deployments/<chainId>.json` with the shape:
///
///         {
///           "contracts":        { "AsseteraExchange": "0x..(proxy)..", "MockUSDC": "0x..", "MockRWA": "0x.." },
///           "implementations":  { "AsseteraExchange": "0x..(impl).." },
///           "metadata":         { "chainId": 31337, "deployTimestamp": 0, "deployer": "0x.." }
///         }
///
///         `contracts` holds the addresses integrators/frontends use (proxy for
///         the exchange). `implementations` holds UUPS impls for upgrade diffing.
abstract contract DeployBase is Script {
    using stdJson for string;

    uint256 internal chainId;
    string internal deploymentPath;

    // Resolved on read; written back on save.
    address internal exchangeProxy;
    address internal exchangeImpl;
    address internal forwarder;
    address internal usdc;
    address internal rwa;
    address internal kycSigner;
    address internal operator;
    address internal relayer;
    address internal admin;

    function _initPaths() internal {
        chainId = block.chainid;
        deploymentPath = string.concat("deployments/", vm.toString(chainId), ".json");
    }

    /// @dev Load any previously-recorded addresses so re-runs can reuse tokens
    ///      and upgrade the proxy in place. Missing file/keys resolve to 0x0.
    function _loadExisting() internal {
        if (!vm.isFile(deploymentPath)) return;
        string memory json = vm.readFile(deploymentPath);
        exchangeProxy = _readAddr(json, ".contracts.AsseteraExchange");
        exchangeImpl = _readAddr(json, ".implementations.AsseteraExchange");
        forwarder = _readAddr(json, ".contracts.Forwarder");
        usdc = _readAddr(json, ".contracts.MockUSDC");
        rwa = _readAddr(json, ".contracts.MockRWA");
        admin = _readAddr(json, ".metadata.admin");
        operator = _readAddr(json, ".metadata.operator");
    }

    function _readAddr(string memory json, string memory key) private view returns (address) {
        if (!vm.keyExistsJson(json, key)) return address(0);
        return json.readAddress(key);
    }

    /// @dev True if `a` is a deployed contract (has code) — used to decide
    ///      whether a recorded address can be reused.
    function _hasCode(address a) internal view returns (bool) {
        return a != address(0) && a.code.length > 0;
    }

    /// @dev Serialize and write the full deployment file.
    function _save(address deployer, address adminAddr) internal {
        string memory c = "contracts";
        vm.serializeAddress(c, "MockUSDC", usdc);
        vm.serializeAddress(c, "MockRWA", rwa);
        vm.serializeAddress(c, "Forwarder", forwarder);
        string memory cJson = vm.serializeAddress(c, "AsseteraExchange", exchangeProxy);

        string memory im = "implementations";
        string memory imJson = vm.serializeAddress(im, "AsseteraExchange", exchangeImpl);

        string memory m = "metadata";
        vm.serializeUint(m, "chainId", chainId);
        vm.serializeUint(m, "deployTimestamp", block.timestamp);
        vm.serializeAddress(m, "admin", adminAddr);
        vm.serializeAddress(m, "operator", operator);
        vm.serializeAddress(m, "kycSigner", kycSigner);
        vm.serializeAddress(m, "relayer", relayer);
        string memory mJson = vm.serializeAddress(m, "deployer", deployer);

        string memory root = "root";
        vm.serializeString(root, "contracts", cJson);
        vm.serializeString(root, "implementations", imJson);
        string memory rootJson = vm.serializeString(root, "metadata", mJson);

        vm.writeJson(rootJson, deploymentPath);
        console2.log("Deployment written to:", deploymentPath);
    }
}
