// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CreateXScript} from "createx-forge/script/CreateXScript.sol";
import {console2} from "forge-std/Script.sol";

/// @title DeployBase
/// @notice Deterministic-deploy bookkeeping (ADR-0026). Contracts are deployed through the **CreateX**
///         factory (`0xba5Ed0…`, present on every live chain; etched locally on anvil by `withCreateX`).
///         The exchange proxy and forwarder use **CREATE3**, so their address depends only on
///         `(deployer, salt)` — never on the initcode — giving **one stable address on every chain**
///         (for a given deployer) that survives implementation upgrades and constructor-arg changes.
///
///         The deployment record is the SDK's source of truth and is written to
///         `packages/sdk/src/deployments/<chainId>.json`:
///
///         {
///           "chainId": 31337, "caip2": "eip155:31337", "namespace": "eip155",
///           "contracts":       { "AsseteraExchange": "0x..(proxy)..", "Forwarder": "0x..", "MockUSDC": "0x..", "MockRWA": "0x.." },
///           "implementations": { "AsseteraExchange": "0x..(impl).." },
///           "metadata":        { "deployer": "0x..", "admin": "0x..", "operator": "0x..", "kycSigner": "0x..",
///                                "feeSigner": "0x..", "relayer": "0x..", "deployBlock": 0, "deployTimestamp": 0 }
///         }
///
///         The numeric `chainId` key serves the viem/wagmi client; `caip2` + `namespace` let the CAIP-2-keyed
///         indexer/API (ADR-0006) consume the same file directly.
abstract contract DeployBase is CreateXScript {
    /// @dev Bump to intentionally rotate every deterministic address to a fresh deployment.
    string internal constant SALT_VERSION = "v1";

    uint256 internal chainId;
    string internal deploymentPath;

    // Resolved during the run; written on save.
    address internal exchangeProxy;
    address internal exchangeImpl;
    address internal forwarder;
    address internal usdc;
    address internal rwa;
    address internal kycSigner;
    address internal feeSigner;
    address internal operator;
    address internal relayer;
    address internal admin;

    function _initPaths() internal {
        chainId = block.chainid;
        // Written relative to the Foundry root (contracts/); the SDK owns the file.
        deploymentPath = string.concat("../packages/sdk/src/deployments/", vm.toString(chainId), ".json");
    }

    /// @dev CreateX guarded salt: [ deployer (20 bytes) | 0x00 no-cross-chain flag | entropy (11 bytes) ].
    ///      Permissioned to `deployer` (only it can deploy to the address — grief-proof) and NOT cross-chain
    ///      protected (same address on every chain for the same deployer). This layout matches what
    ///      `CreateXScript.computeCreate3Address(salt, deployer)` expects.
    function _salt(address deployer, string memory name) internal pure returns (bytes32) {
        bytes11 entropy = bytes11(keccak256(abi.encodePacked("assetera.evm.", name, ".", SALT_VERSION)));
        return bytes32(abi.encodePacked(bytes20(deployer), bytes1(0x00), entropy));
    }

    /// @dev True if `a` is a deployed contract (has code).
    function _hasCode(address a) internal view returns (bool) {
        return a != address(0) && a.code.length > 0;
    }

    /// @dev CREATE3-deploy `initCode` at its stable, deployer-permissioned address; reuse if already there.
    ///      Address depends only on (deployer, salt) — use for contracts whose address must be constant
    ///      across chains AND across initcode/bytecode changes (the proxy, the forwarder).
    function _deploy3(address deployer, string memory name, bytes memory initCode)
        internal
        returns (address addr, bool created)
    {
        bytes32 salt = _salt(deployer, name);
        addr = computeCreate3Address(salt, deployer);
        if (_hasCode(addr)) return (addr, false);
        address deployed = create3(salt, initCode);
        require(deployed == addr, "create3 address mismatch");
        return (deployed, true);
    }

    /// @dev CREATE2-deploy `initCode` at a deployer-permissioned address that depends on the initcode —
    ///      i.e. the **same bytecode maps to the same address**, so a re-run with unchanged bytecode is a
    ///      true no-op, while changed bytecode yields a new address (→ the proxy upgrade path). Use for the
    ///      implementation, whose address is not consumer-facing but should be stable per bytecode version.
    function _deploy2(address deployer, string memory name, bytes memory initCode)
        internal
        returns (address addr, bool created)
    {
        bytes32 salt = _salt(deployer, name);
        // CreateX guards a permissioned salt as keccak256(deployer, salt) — mirror it to predict the address.
        bytes32 guardedSalt = keccak256(abi.encodePacked(uint256(uint160(deployer)), salt));
        addr = CreateX.computeCreate2Address(guardedSalt, keccak256(initCode), address(CreateX));
        if (_hasCode(addr)) return (addr, false);
        address deployed = CreateX.deployCreate2(salt, initCode);
        require(deployed == addr, "create2 address mismatch");
        return (deployed, true);
    }

    /// @dev Serialize and write the full deployment file (chainId/CAIP-2 at the top level).
    function _save(address deployer) internal {
        string memory c = "contracts";
        vm.serializeAddress(c, "MockUSDC", usdc);
        vm.serializeAddress(c, "MockRWA", rwa);
        vm.serializeAddress(c, "Forwarder", forwarder);
        string memory cJson = vm.serializeAddress(c, "AsseteraExchange", exchangeProxy);

        string memory im = "implementations";
        string memory imJson = vm.serializeAddress(im, "AsseteraExchange", exchangeImpl);

        string memory m = "metadata";
        vm.serializeAddress(m, "deployer", deployer);
        vm.serializeAddress(m, "admin", admin);
        vm.serializeAddress(m, "operator", operator);
        vm.serializeAddress(m, "kycSigner", kycSigner);
        vm.serializeAddress(m, "feeSigner", feeSigner);
        vm.serializeAddress(m, "relayer", relayer);
        vm.serializeUint(m, "deployBlock", block.number);
        string memory mJson = vm.serializeUint(m, "deployTimestamp", block.timestamp);

        string memory root = "root";
        vm.serializeUint(root, "chainId", chainId);
        vm.serializeString(root, "caip2", string.concat("eip155:", vm.toString(chainId)));
        vm.serializeString(root, "namespace", "eip155");
        vm.serializeString(root, "contracts", cJson);
        vm.serializeString(root, "implementations", imJson);
        string memory rootJson = vm.serializeString(root, "metadata", mJson);

        vm.writeJson(rootJson, deploymentPath);
        console2.log("Deployment written to:", deploymentPath);
    }
}
