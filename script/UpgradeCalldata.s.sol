// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {AsseteraExchange} from "../src/AsseteraExchange.sol";

/// @notice Deploys a new implementation and prints the Safe transaction
///         calldata needed to upgrade the proxy. No broadcast of the upgrade
///         itself - that goes through the Safe multisig.
///
/// Usage:
///   forge script script/UpgradeCalldata.s.sol:UpgradeCalldata \
///     --rpc-url <network> --broadcast \
///     --private-key $DEPLOYER_PK
///
/// Then paste the printed calldata into app.safe.global, New Transaction,
/// Contract Interaction, target: proxy address.
contract UpgradeCalldata is Script {
    using stdJson for string;

    function run() external {
        uint256 chainId = block.chainid;
        string memory path = string.concat("deployments/", vm.toString(chainId), ".json");
        require(vm.isFile(path), "no deployment file for this chain");

        string memory json = vm.readFile(path);
        address proxy = json.readAddress(".contracts.AsseteraExchange");
        address forwarderAddr = json.readAddress(".contracts.Forwarder");

        // 1. Read current implementation from the proxy storage slot.
        bytes32 raw = vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT);
        address currentImpl = address(uint160(uint256(raw)));
        console2.log("Current impl:", currentImpl);

        // 2. Deploy the new implementation (deployer pays gas for this part).
        vm.startBroadcast();
        address newImpl = address(new AsseteraExchange(forwarderAddr));
        vm.stopBroadcast();
        console2.log("New impl deployed:", newImpl);

        if (newImpl == currentImpl) {
            console2.log("Implementation bytecode unchanged - nothing to upgrade.");
            return;
        }

        // 3. Build the upgradeToAndCall calldata (Safe will call this on the proxy).
        bytes memory upgradeCalldata = abi.encodeWithSignature(
            "upgradeToAndCall(address,bytes)", newImpl, bytes("")
        );

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
    }
}
