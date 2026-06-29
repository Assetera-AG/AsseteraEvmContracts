// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {AsseteraExchange} from "../src/AsseteraExchange.sol";

/// @notice Read-only post-deployment verification. Checks every governance
///         invariant: proxy wiring, role assignments, Safe as admin.
///
/// Usage:
///   forge script script/Verify.s.sol:Verify --rpc-url <network> -vv
///
/// Reads deployments/<chainId>.json — no broadcast needed.
contract Verify is Script {
    using stdJson for string;

    bool internal _failed;

    function run() external view {
        uint256 chainId = block.chainid;
        string memory path = string.concat("deployments/", vm.toString(chainId), ".json");
        require(vm.isFile(path), string.concat("no deployment file for chain ", vm.toString(chainId)));

        string memory json = vm.readFile(path);

        address proxy     = json.readAddress(".contracts.AsseteraExchange");
        address impl      = json.readAddress(".implementations.AsseteraExchange");
        address adminAddr = json.readAddress(".metadata.admin");
        address opAddr    = json.readAddress(".metadata.operator");
        address kycAddr   = json.readAddress(".metadata.kycSigner");

        AsseteraExchange exchange = AsseteraExchange(proxy);

        console2.log("");
        console2.log("=== Verify: AsseteraExchange (chain %s) ===", chainId);
        console2.log("Proxy  :", proxy);
        console2.log("Impl   :", impl);
        console2.log("Admin  :", adminAddr);

        // 1. Implementation slot matches recorded impl.
        bytes32 raw = vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT);
        address liveImpl = address(uint160(uint256(raw)));
        _check("impl slot == recorded impl", liveImpl == impl,
            string.concat("  got ", vm.toString(liveImpl)));

        // 2. Version readable (proxy is live).
        string memory ver = exchange.version();
        _check("version() readable", bytes(ver).length > 0, "  version() reverted");
        console2.log("  version:", ver);

        // 3. Admin role is held by the Safe (ADMIN_ADDRESS).
        bytes32 adminRole = exchange.DEFAULT_ADMIN_ROLE();
        _check("Safe holds DEFAULT_ADMIN_ROLE",
            exchange.hasRole(adminRole, adminAddr),
            string.concat("  ", vm.toString(adminAddr), " does NOT hold DEFAULT_ADMIN_ROLE"));

        // 4. Deployer EOA does NOT hold admin role (if admin != deployer).
        address deployer = json.readAddress(".metadata.deployer");
        if (deployer != adminAddr) {
            _check("Deployer EOA does NOT hold DEFAULT_ADMIN_ROLE",
                !exchange.hasRole(adminRole, deployer),
                "  deployer still holds DEFAULT_ADMIN_ROLE - revoke it from the Safe");
        }

        // 5. Operator holds OPERATOR_ROLE.
        _check("operator holds OPERATOR_ROLE",
            exchange.hasRole(exchange.OPERATOR_ROLE(), opAddr),
            string.concat("  ", vm.toString(opAddr), " does NOT hold OPERATOR_ROLE"));

        // 6. KYC signer holds KYC_OPERATOR_ROLE.
        _check("kycSigner holds KYC_OPERATOR_ROLE",
            exchange.hasRole(exchange.KYC_OPERATOR_ROLE(), kycAddr),
            string.concat("  ", vm.toString(kycAddr), " does NOT hold KYC_OPERATOR_ROLE"));

        // 7. Compliance gating is on for all actions by default.
        bool placeGated  = exchange.complianceRequired(AsseteraExchange.Action.Place);
        bool fillGated   = exchange.complianceRequired(AsseteraExchange.Action.Fill);
        bool settleGated = exchange.complianceRequired(AsseteraExchange.Action.Settle);
        bool cancelGated = exchange.complianceRequired(AsseteraExchange.Action.Cancel);
        _check("all actions KYC-gated by default",
            placeGated && fillGated && settleGated && cancelGated,
            "  one or more actions not gated");

        // 8. Contract is not paused after deploy.
        _check("contract not paused", !exchange.paused(), "  contract is paused");

        console2.log("");
        if (!_failed) {
            console2.log("All checks passed.");
        } else {
            console2.log("One or more checks FAILED - see output above.");
            // revert so CI marks the step red
            revert("verification failed");
        }
    }

    function _check(string memory label, bool ok, string memory detail) internal pure {
        if (ok) {
            console2.log("[PASS] %s", label);
        } else {
            console2.log("[FAIL] %s", label);
            console2.log(detail);
            // Can't mutate state in a view function, so we revert immediately on failure.
            revert(string.concat("FAIL: ", label));
        }
    }
}
