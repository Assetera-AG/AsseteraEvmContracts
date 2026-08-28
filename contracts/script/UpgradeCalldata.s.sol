// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {AsseteraECS} from "../src/AsseteraECS.sol";
import {AsseteraPrimarySales} from "../src/primary/AsseteraPrimarySales.sol";
import {DeployBase} from "./DeployBase.sol";
import {DeploymentFile} from "./DeploymentFile.sol";

/// @notice Deploys a new implementation and prints the Safe transaction
///         calldata needed to upgrade the proxy. No broadcast of the upgrade
///         itself - that goes through the Safe multisig.
///
/// Usage:
///   TARGET=ecs     forge script script/UpgradeCalldata.s.sol:UpgradeCalldata \
///     --rpc-url <network> --broadcast --private-key $DEPLOYER_PK
///   TARGET=primary forge script script/UpgradeCalldata.s.sol:UpgradeCalldata \
///     --rpc-url <network> --broadcast --private-key $DEPLOYER_PK
///
/// `TARGET` selects which proxy to upgrade and defaults to `ecs`, which is what this script did before it
/// learned about the router. There are TWO upgradeable proxies and each has its own guard constant, so an
/// unrecognised value is refused rather than silently defaulting — picking the wrong proxy here means
/// proposing a Safe transaction that installs one contract's logic on the other.
///
/// Then paste the printed calldata into app.safe.global, New Transaction,
/// Contract Interaction, target: proxy address.
/// ⚠️ Inherits `DeployBase` only to share the in-place-upgrade guard constants with `Deploy.s.sol`, so the
///    two scripts cannot disagree about whether the current commit is safe to install on a live proxy.
contract UpgradeCalldata is DeployBase {
    using stdJson for string;

    function run() external {
        string memory target = vm.envOr("TARGET", string("ecs"));
        bytes32 t = keccak256(bytes(target));
        bool isPrimary = t == keccak256("primary");
        require(isPrimary || t == keccak256("ecs"), "TARGET must be 'ecs' or 'primary'");

        // A commit that breaks the storage layout must not be proposable to the Safe either. Checked before
        // anything else so the script cannot even deploy the implementation it would then tell you to install.
        // Each proxy has its own guard: the exchange's tracks the AO-514 layout break, the router's defaults
        // closed so that upgrading a live router is always a deliberate act.
        if (isPrimary) {
            require(PRIMARY_INPLACE_UPGRADE_ALLOWED, PRIMARY_INPLACE_UPGRADE_REFUSAL);
        } else {
            require(INPLACE_UPGRADE_ALLOWED, INPLACE_UPGRADE_REFUSAL);
        }

        string memory path = DeploymentFile.pathFor(block.chainid);
        require(vm.isFile(path), string.concat("no deployment file at ", path));

        string memory json = vm.readFile(path);
        address proxy = json.readAddress(isPrimary ? ".contracts.AsseteraPrimarySales" : ".contracts.AsseteraECS");
        address forwarderAddr = json.readAddress(".contracts.Forwarder");
        console2.log("Target:", target);
        console2.log("Proxy: ", proxy);

        // 1. Read current implementation from the proxy storage slot.
        bytes32 raw = vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT);
        address currentImpl = address(uint160(uint256(raw)));
        console2.log("Current impl:", currentImpl);

        // 2. Deploy the new implementation (deployer pays gas for this part).
        vm.startBroadcast();
        address newImpl =
            isPrimary ? address(new AsseteraPrimarySales(forwarderAddr)) : address(new AsseteraECS(forwarderAddr));
        vm.stopBroadcast();
        console2.log("New impl deployed:", newImpl);

        // 🔴 RECORD IT, or the deployment file keeps naming the OLD implementation forever.
        //
        //    Nothing else will do this. The Safe executes `upgradeToAndCall` directly on the proxy and
        //    never runs a script, and `Deploy.s.sol._save` only runs on a deploy. So without this write
        //    the record goes stale the moment the Safe transaction executes, and it stays stale silently.
        //
        //    That became worse once `packages/sdk/src/generated/` started being committed: the stale
        //    address is now baked into `deployments.gen.ts` and PUBLISHED in the package rather than only
        //    generated at publish time.
        //
        //    ⚠️ A TARGETED key write, not `_save`. `_save` rebuilds the whole file from in-memory state
        //    that this script never populates — it knows one implementation address and nothing else — so
        //    calling it here would blank every other field with zeros.
        //
        //    ⚠️ DRY RUN MUST NOT TOUCH THE REAL RECORD, the same rule `_save` already documents: `forge
        //    script` without `--broadcast` still executes every line above, including the `new` that
        //    produces `newImpl`, but that contract was never actually deployed. Writing its address would
        //    turn "let me see what this would do" into a silent corruption of the file every consumer
        //    reads. The preview goes to `out/`, which is gitignored.
        string memory implKey = isPrimary ? ".implementations.AsseteraPrimarySales" : ".implementations.AsseteraECS";
        if (vm.isContext(VmSafe.ForgeContext.ScriptDryRun)) {
            console2.log("DRY RUN - the deployment record was NOT modified.");
            console2.log("  would have set:", implKey);
            console2.log("  to:            ", newImpl);
        } else {
            vm.writeJson(vm.toString(newImpl), path, implKey);
            console2.log("Deployment record updated:", path);
            console2.log("  %s = %s", implKey, vm.toString(newImpl));
            console2.log("  NOTE: commit this file, and re-run `npm run generate` so the SDK picks it up.");
        }

        if (newImpl == currentImpl) {
            console2.log("Implementation bytecode unchanged - nothing to upgrade.");
            return;
        }

        // 3. Build the upgradeToAndCall calldata (Safe will call this on the proxy).
        bytes memory upgradeCalldata = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", newImpl, bytes(""));

        console2.log("");
        console2.log("=== Safe transaction to propose ===");
        console2.log("To (proxy):  ", proxy);
        console2.log("Value:        0");
        console2.log("Calldata:");
        console2.logBytes(upgradeCalldata);
        console2.log("");
        console2.log("Steps:");
        console2.log("1. Open app.safe.global and navigate to your Safe");
        console2.log("2. New Transaction > Contract Interaction");
        console2.log("3. Paste 'To' address and calldata above");
        console2.log("4. Collect required signatures from signers");
        console2.log("5. Execute - the proxy will point to the new impl");
        console2.log("6. Verify: `npm run verify:<network>` checks the live impl slot against the record");
        console2.log("7. Commit the updated deployment file, and regenerate the SDK");
    }
}
