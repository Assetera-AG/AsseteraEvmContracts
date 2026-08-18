// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CreateXScript} from "createx-forge/script/CreateXScript.sol";
import {console2} from "forge-std/Script.sol";
import {DeploymentFile} from "./DeploymentFile.sol";

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
///           "contracts":       { "AsseteraECS": "0x..(proxy)..", "AsseteraPrimarySales": "0x..(proxy)..",
///                                "Forwarder": "0x..", "MockUSDC": "0x..", "MockRWA": "0x.." },
///           "implementations": { "AsseteraECS": "0x..(impl)..", "AsseteraPrimarySales": "0x..(impl).." },
///           "metadata":        { "deployer": "0x..", "admin": "0x..", "operator": "0x..", "kycSigner": "0x..",
///                                "feeSigner": "0x..", "settlementSigner": "0x..", "relayer": "0x..",
///                                "deployBlock": 0, "deployTimestamp": 0 }
///         }
///
///         The numeric `chainId` key serves the viem/wagmi client; `caip2` + `namespace` let the CAIP-2-keyed
///         indexer/API (ADR-0006) consume the same file directly.
abstract contract DeployBase is CreateXScript {
    /// @dev Default salt version, used by every component that has no version of its own. Bumping it
    ///      rotates ALL of those addresses at once — the forwarder and the faucet mocks included — so it is
    ///      almost never the knob you want. To rotate one component, give it its own version below and bump
    ///      that (AO-514 review finding: a global bump silently re-deploys the forwarder, which the exchange
    ///      redeploy runbook does not account for).
    string internal constant SALT_VERSION = "v1";

    /// @dev Salt version of the exchange proxy and implementation ONLY. Separate from `SALT_VERSION` so the
    ///      planned fresh deploy rotates the exchange address without disturbing the forwarder or the mocks.
    ///      Bumping this is the intended way to land a storage-layout break: the new address has no code,
    ///      so `Deploy.s.sol` takes the fresh-deploy branch and the old proxy is never touched.
    ///
    ///      ⚠️ **"v2" since AO-514's gate extraction.** The exchange address on every chain therefore
    ///      CHANGES on the next deploy, and nothing at the old address is migrated — the live testnet
    ///      orders, offers and escrow stay where they are, on a proxy this source no longer describes.
    ///      Every consumer (SDK, indexer, signer service, fronts) must re-point.
    string internal constant EXCHANGE_SALT_VERSION = "v2";

    /// @dev Whether the implementation built from THIS commit may be installed onto an exchange proxy that
    ///      already has code, via `upgradeToAndCall`.
    ///
    ///      ⚠️ Keep this `false` whenever the commit changes the linear storage layout. It is `false` today
    ///      because AO-514 moved the gate mappings into ERC-7201 namespaced storage, shifting `_offers`
    ///      5 → 2, `totalOffers` 6 → 3 and `__gap` 8 → 4. Installing that over the live Amoy/Sepolia proxies
    ///      would reinterpret the existing order book as offers and corrupt every escrow balance.
    ///
    ///      This is a compile-time constant rather than an env flag on purpose: the answer is a property of
    ///      the source tree, not of the operator running the script, so it belongs in the commit that makes
    ///      the layout incompatible. `Deploy.s.sol` and `UpgradeCalldata.s.sol` both refuse to produce an
    ///      in-place upgrade while it is `false`.
    ///
    ///      ⚠️ **Bumping `EXCHANGE_SALT_VERSION` to "v2" is NOT the moment to flip this back to `true`, and
    ///      that bump is already made above.** After the bump the new exchange address has no code, so
    ///      `Deploy.s.sol` takes the fresh-deploy branch and never reaches this guard — leaving it `false`
    ///      costs the fresh deploy nothing. Flipping it belongs in a FOLLOW-UP commit made after that fresh
    ///      deploy exists, because only then is the layout of the proxy sitting at the v2 address the one
    ///      this source tree describes. Flip it earlier and the guard is open for a proxy nobody has
    ///      deployed yet, against a layout nobody has checked.
    bool internal constant INPLACE_UPGRADE_ALLOWED = false;

    /// @dev Human-readable refusal reason, shared by both scripts so the two never drift.
    string internal constant INPLACE_UPGRADE_REFUSAL =
        "refusing in-place upgrade: this commit's storage layout is not compatible with the deployed proxy. Land it by bumping EXCHANGE_SALT_VERSION for a fresh deploy, or set INPLACE_UPGRADE_ALLOWED once the layout is compatible again.";

    uint256 internal chainId;
    string internal deploymentPath;

    // Resolved during the run; written on save.
    address internal exchangeProxy;
    address internal exchangeImpl;
    address internal primarySalesProxy;
    address internal primarySalesImpl;
    address internal forwarder;
    address internal usdc;
    address internal rwa;
    address internal kycSigner;
    address internal feeSigner;
    address internal settlementSigner;
    address internal operator;
    address internal relayer;
    address internal admin;

    function _initPaths() internal {
        chainId = block.chainid;
        // Written relative to the Foundry root (contracts/); the SDK owns the file. The path itself lives in
        // `DeploymentFile` so the verification and upgrade scripts cannot drift away from it again.
        deploymentPath = DeploymentFile.pathFor(chainId);
    }

    /// @dev CreateX guarded salt: [ deployer (20 bytes) | 0x00 no-cross-chain flag | entropy (11 bytes) ].
    ///      Permissioned to `deployer` (only it can deploy to the address — grief-proof) and NOT cross-chain
    ///      protected (same address on every chain for the same deployer). This layout matches what
    ///      `CreateXScript.computeCreate3Address(salt, deployer)` expects.
    function _salt(address deployer, string memory name) internal pure returns (bytes32) {
        bytes11 entropy = bytes11(keccak256(abi.encodePacked("assetera.evm.", name, ".", _saltVersion(name))));
        return bytes32(abi.encodePacked(bytes20(deployer), bytes1(0x00), entropy));
    }

    /// @dev The salt version that applies to `name`. Per-component so one address can be rotated alone;
    ///      see `EXCHANGE_SALT_VERSION`. Matching on the exact labels rather than a prefix keeps a typo in a
    ///      label from silently inheriting the default version and computing an unrelated address.
    ///
    ///      `AsseteraPrimarySales.*` deliberately has NO version of its own: it has never been deployed, so
    ///      there is no address to rotate away from and nothing a bump could rescue. Give it one at the
    ///      first storage-layout break AFTER it is live, not before.
    function _saltVersion(string memory name) internal pure returns (string memory) {
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("AsseteraExchange.proxy") || h == keccak256("AsseteraExchange.impl")) {
            return EXCHANGE_SALT_VERSION;
        }
        return SALT_VERSION;
    }

    /// @dev True if `a` is a deployed contract (has code).
    function _hasCode(address a) internal view returns (bool) {
        return a != address(0) && a.code.length > 0;
    }

    /// @dev Chains where the open-mint faucet tokens (MockUSDC/MockRWA) are allowed to deploy:
    ///      local anvil (31337), Polygon Amoy (80002), Ethereum Sepolia (11155111). On any other
    ///      chain — notably mainnets — the faucet is never deployed (real venues reference real
    ///      settlement/asset tokens). Overridable via the `DEPLOY_MOCKS` env in `Deploy.run()`.
    function _isTestnet(uint256 id) internal pure returns (bool) {
        return id == 31337 || id == 80002 || id == 11155111;
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

    /// @dev The exchange PROXY's creation block/timestamp — the indexer's start cursor (ADR-0006). Because the
    ///      proxy is a CREATE3 address that survives implementation upgrades, an upgrade re-run leaves the proxy
    ///      untouched, so its provenance MUST NOT move. Stamp the current block ONLY when the proxy was actually
    ///      created this run; otherwise preserve whatever the deployment file already records.
    ///
    ///      This closes AC-665: the previous `_save` wrote `block.number`/`block.timestamp` unconditionally, so
    ///      every impl upgrade silently pushed `deployBlock` forward to the upgrade block. Consumers that start
    ///      indexing at `deployBlock` (the live indexer + the reconcile job) then skipped all history between the
    ///      real proxy-creation block and the upgrade — surfacing as an incomplete activity ledger.
    function _provenance(bool proxyCreated) internal view returns (uint256 deployBlock, uint256 deployTimestamp) {
        if (!proxyCreated && vm.exists(deploymentPath)) {
            string memory prior = vm.readFile(deploymentPath);
            // Preserve prior values when present; fall back to the current block only if the file predates
            // these fields (older records / a first save that never wrote them).
            deployBlock = vm.keyExistsJson(prior, ".metadata.deployBlock")
                ? vm.parseJsonUint(prior, ".metadata.deployBlock")
                : block.number;
            deployTimestamp = vm.keyExistsJson(prior, ".metadata.deployTimestamp")
                ? vm.parseJsonUint(prior, ".metadata.deployTimestamp")
                : block.timestamp;
            return (deployBlock, deployTimestamp);
        }
        return (block.number, block.timestamp);
    }

    /// @dev Serialize and write the full deployment file (chainId/CAIP-2 at the top level). `proxyCreated` is
    ///      true only when the exchange proxy was newly deployed this run (not an impl upgrade or a no-op re-run);
    ///      it gates whether `deployBlock`/`deployTimestamp` are re-stamped or preserved (see `_provenance`).
    function _save(address deployer, bool proxyCreated) internal {
        // MockUSDC/MockRWA only exist on testnets (see `_isTestnet`); omit their keys entirely on chains
        // where the faucet wasn't deployed rather than recording a misleading 0x0. AsseteraECS is
        // serialized last so its return value carries the full "contracts" object regardless.
        string memory c = "contracts";
        if (usdc != address(0)) vm.serializeAddress(c, "MockUSDC", usdc);
        if (rwa != address(0)) vm.serializeAddress(c, "MockRWA", rwa);
        vm.serializeAddress(c, "Forwarder", forwarder);
        vm.serializeAddress(c, "AsseteraPrimarySales", primarySalesProxy);
        string memory cJson = vm.serializeAddress(c, "AsseteraECS", exchangeProxy);

        string memory im = "implementations";
        vm.serializeAddress(im, "AsseteraPrimarySales", primarySalesImpl);
        string memory imJson = vm.serializeAddress(im, "AsseteraECS", exchangeImpl);

        (uint256 deployBlock, uint256 deployTimestamp) = _provenance(proxyCreated);

        string memory m = "metadata";
        vm.serializeAddress(m, "deployer", deployer);
        vm.serializeAddress(m, "admin", admin);
        vm.serializeAddress(m, "operator", operator);
        vm.serializeAddress(m, "kycSigner", kycSigner);
        vm.serializeAddress(m, "feeSigner", feeSigner);
        // ⚠️ TODO(AO-520) — today this is the same key as `feeSigner`/`kycSigner` unless the operator
        //    overrides it; AO-520 provisions a distinct settlement key. Recorded here so an operator can
        //    see WHICH key holds SETTLEMENT_OPERATOR_ROLE without reading the chain.
        vm.serializeAddress(m, "settlementSigner", settlementSigner);
        vm.serializeAddress(m, "relayer", relayer);
        vm.serializeUint(m, "deployBlock", deployBlock);
        string memory mJson = vm.serializeUint(m, "deployTimestamp", deployTimestamp);

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
