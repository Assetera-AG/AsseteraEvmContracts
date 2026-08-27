// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CreateXScript} from "createx-forge/script/CreateXScript.sol";
import {console2, VmSafe} from "forge-std/Script.sol";
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
    ///      exchange address can be rotated without disturbing the forwarder or the mocks. Bumping this is
    ///      the intended way to land a storage-layout break: the new address has no code, so `Deploy.s.sol`
    ///      takes the fresh-deploy branch and the old proxy is never touched.
    ///
    ///      ⚠️ **This counts rotations of the CURRENT label, and the label was renamed to `AsseteraECS.*`.**
    ///      It reads "v1" because the `AsseteraECS.*` salt lineage starts here and has been rotated zero
    ///      times — not because nothing came before. The predecessor lineage was labelled
    ///      `AsseteraExchange.*` and reached "v2"; that number described a label this source no longer
    ///      uses, and carrying it over would have made the constant claim a history this address does not
    ///      have. Nothing at any earlier address is migrated: earlier orders, offers and escrow stay where
    ///      they are, on proxies this source no longer describes.
    string internal constant EXCHANGE_SALT_VERSION = "v1";

    /// @dev Salt version of the primary-sales proxy and implementation ONLY, mirroring
    ///      `EXCHANGE_SALT_VERSION`. Its purpose is to make the router's address rotatable ALONE.
    ///
    ///      ⚠️ **Introducing this constant did not move the address, and that is the whole point.** Before
    ///      it existed `_saltVersion` fell through to the default `SALT_VERSION`, which is also "v1", so the
    ///      string fed to `keccak256` in `_salt` is byte-identical either way and the CREATE3 address is
    ///      unchanged on every chain. `test_Salt_PrimaryVersionIntroductionIsAddressNeutral` pins that.
    ///
    ///      Why it was needed: without it the only way to rotate the router was to bump the global
    ///      `SALT_VERSION`, which would also move the forwarder and the faucet mocks — the exact failure the
    ///      AO-514 review called out for the exchange. The router is live on Amoy and Sepolia, so it now has
    ///      an address to rotate away from and the earlier "give it one once it is live" note is satisfied.
    string internal constant PRIMARY_SALT_VERSION = "v1";

    /// @dev Whether the implementation built from THIS commit may be installed onto an exchange proxy that
    ///      already has code, via `upgradeToAndCall`.
    ///
    ///      ⚠️ Keep this `false` whenever the commit changes the linear storage layout. Set it back to
    ///      `true` only in its own commit, and only once the layout of the proxy that is actually deployed
    ///      is the one this source tree describes.
    ///
    ///      This is a compile-time constant rather than an env flag on purpose: the answer is a property of
    ///      the source tree, not of the operator running the script, so it belongs in the commit that makes
    ///      the layout incompatible. `Deploy.s.sol` and `UpgradeCalldata.s.sol` both refuse to produce an
    ///      in-place upgrade while it is `false`.
    ///
    ///      It was `false` from AO-514, which moved the gate mappings into ERC-7201 namespaced storage and
    ///      shifted `_offers` 5 → 2, `totalOffers` 6 → 3 and `__gap` 8 → 4. Installing that over the proxies
    ///      live AT THE TIME would have reinterpreted the order book as offers and corrupted every escrow.
    ///
    ///      That break is now deployed rather than pending, which is what makes it safe to reopen (AO-746):
    ///
    ///        · AO-514 introduced the version string `"4.0.0"` in the same commit as the break, and Amoy,
    ///          Sepolia and Polygon all report `4.0.0` at implementation `0xcb2D5e22…03c2`, which is what
    ///          `packages/sdk/src/deployments/*.json` records. So every live proxy already runs the
    ///          post-AO-514 layout.
    ///        · `contracts/storage/AsseteraECS.txt` has been touched by exactly two commits since: AO-514
    ///          itself, and AO-746. AO-746 is append-only — one added word, `Order.boughtQuantity` at slot
    ///          11 — with every pre-existing slot AND offset byte-identical, and each `Order` lives in a
    ///          mapping so the appended word lands on previously-unused ground.
    ///
    ///      So the deployed layout and this source tree differ by one appended struct member and nothing
    ///      else. Re-verify all of that, not just the flag, before the next layout-touching change.
    ///
    ///      ⚠️ Note `EXCHANGE_SALT_VERSION` is still `"v1"`: the fresh-deploy-at-a-new-address route the
    ///      earlier version of this comment described was never taken. The break was resolved by deploying
    ///      it to the v1 address, not by rotating away from it.
    bool internal constant INPLACE_UPGRADE_ALLOWED = true;

    /// @dev Human-readable refusal reason, shared by both scripts so the two never drift.
    string internal constant INPLACE_UPGRADE_REFUSAL =
        "refusing in-place upgrade: this commit's storage layout is not compatible with the deployed proxy. Land it by bumping EXCHANGE_SALT_VERSION for a fresh deploy, or set INPLACE_UPGRADE_ALLOWED once the layout is compatible again.";

    /// @dev The primary-sales twin of `INPLACE_UPGRADE_ALLOWED`. Whether the implementation built from THIS
    ///      commit may be installed onto a primary-sales proxy that already has code.
    ///
    ///      🔴 It is `false` by DEFAULT, and that is a deliberate difference from the exchange constant,
    ///      whose value tracks a known layout break. No layout break is known here. This is `false` because
    ///      an in-place upgrade of the router must be a decision somebody made, not a side effect.
    ///
    ///      Before this existed, `Deploy.s.sol` upgraded the router in place whenever the freshly built
    ///      implementation bytecode differed from the deployed one, for ANY reason — a dependency bump or a
    ///      compiler-setting change is enough. So a routine re-run of the deploy script against a chain that
    ///      already had the router silently replaced its logic, with no layout check and nothing to approve.
    ///      The exchange's equivalent path was guarded; this one was not.
    ///
    ///      Costs a fresh deploy nothing: on a chain where the address has no code, `Deploy.s.sol` takes the
    ///      fresh-deploy branch and never reaches the guard. So Polygon mainnet is unaffected by this being
    ///      `false`. Flip it, in its own commit, when you intend to upgrade a live router and have checked
    ///      the layout — or route the upgrade through `UpgradeCalldata.s.sol` for a Safe to execute.
    ///
    ///      ⚠️ `AsseteraPrimarySales` has NO linear storage today, every region being ERC-7201 namespaced
    ///      (see `script/storage-layout.sh`), so a slot-shift break is less likely here than on the
    ///      exchange. Less likely is not the same as guarded.
    bool internal constant PRIMARY_INPLACE_UPGRADE_ALLOWED = false;

    /// @dev Human-readable refusal reason for the primary-sales router, shared by both scripts.
    string internal constant PRIMARY_INPLACE_UPGRADE_REFUSAL =
        "refusing in-place upgrade of AsseteraPrimarySales: an in-place upgrade of a live router must be deliberate. Check the storage layout, then either set PRIMARY_INPLACE_UPGRADE_ALLOWED in its own commit, or bump PRIMARY_SALT_VERSION for a fresh deploy at a new address.";

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
    ///      ⚠️ An earlier version of this comment said `AsseteraPrimarySales.*` deliberately had no version
    ///      of its own because it had never been deployed. That was true when written and is no longer:
    ///      the router is live on Amoy and Sepolia, so it now has an address to rotate away from, and it has
    ///      `PRIMARY_SALT_VERSION`. Introducing that constant did not move the address — see its NatSpec.
    function _saltVersion(string memory name) internal pure returns (string memory) {
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("AsseteraECS.proxy") || h == keccak256("AsseteraECS.impl")) {
            return EXCHANGE_SALT_VERSION;
        }
        if (h == keccak256("AsseteraPrimarySales.proxy") || h == keccak256("AsseteraPrimarySales.impl")) {
            return PRIMARY_SALT_VERSION;
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

        // ⚠️ A DRY RUN MUST NOT TOUCH THE REAL RECORD. `forge script` without `--broadcast` still executes
        //    this function, so the previous revision overwrote the committed deployment file with the
        //    addresses of contracts that were never deployed — turning "let me check what this would do"
        //    into a silent corruption of the SDK's source of truth. The file is what every consumer reads,
        //    so the damage outlives the terminal it happened in.
        //
        //    The dry-run output still goes somewhere, because seeing it is the point of a dry run: `out/` is
        //    build output and gitignored, so it can be diffed against the real record without any chance of
        //    being committed.
        if (vm.isContext(VmSafe.ForgeContext.ScriptDryRun)) {
            string memory dryPath = string.concat("out/deployment-", vm.toString(chainId), ".dryrun.json");
            vm.writeJson(rootJson, dryPath);
            console2.log("DRY RUN - the deployment record was NOT modified.");
            console2.log("  would have written:", deploymentPath);
            console2.log("  wrote preview to:  ", dryPath);
        } else {
            vm.writeJson(rootJson, deploymentPath);
            console2.log("Deployment written to:", deploymentPath);
        }
    }
}
