// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {AsseteraECS} from "../src/AsseteraECS.sol";
import {AsseteraPrimarySales} from "../src/primary/AsseteraPrimarySales.sol";
import {ExchangeTypes} from "../src/types/ExchangeTypes.sol";
import {PrimaryTypes} from "../src/primary/types/PrimaryTypes.sol";
import {DeploymentFile} from "./DeploymentFile.sol";

/// @dev The fee-collector allowlist, which the exchange and the router each carry their own copy of.
interface IAllowedCollectors {
    function allowedCollectors(address collector) external view returns (bool);
}

/// @notice Read-only post-deployment verification. Checks the governance invariants of the deployed stack:
///         proxy wiring, role assignments, who is admin, and whether the router is still closed.
///
///         Usage:
///           forge script script/Verify.s.sol:Verify --rpc-url <network> -vv
///
///         Reads the deployment record; no broadcast, so it never sends a transaction.
///
/// ⚠️ **This reports what the RECORD claims and what the CHAIN says, and they are not the same thing.**
///    The record's `metadata` captures the addresses passed to the deploy script at initialization. Roles
///    granted or revoked afterwards never appear in it. A role check failing here means one of two things,
///    and the script cannot tell them apart: either the deployment is wrong, or the record is stale. Both
///    are worth knowing, which is why a failure prints the address it expected.
///
/// @dev Every check is recorded and the run reverts at the END if any failed, rather than reverting on the
///      first one. Verification exists to tell an operator everything that is wrong with a live deployment
///      in one pass; stopping at the first failure turns that into a guessing game where each fix reveals
///      exactly one more problem. (The previous revision reverted inside the check helper, which also made
///      its own pass/fail summary unreachable.)
contract Verify is Script {
    using stdJson for string;

    uint256 internal _failures;

    function run() external {
        uint256 chainId = block.chainid;
        string memory path = DeploymentFile.pathFor(chainId);
        require(vm.isFile(path), string.concat("no deployment file at ", path));

        string memory json = vm.readFile(path);

        _verifyExchange(json, chainId);
        _verifyPrimarySales(json);

        console2.log("");
        if (_failures == 0) {
            console2.log("All checks passed.");
        } else {
            console2.log("%s check(s) FAILED - see output above.", _failures);
            revert("verification failed");
        }
    }

    // --------------------------------------------------------------------- //
    //                              The exchange                              //
    // --------------------------------------------------------------------- //

    function _verifyExchange(string memory json, uint256 chainId) internal {
        address proxy = json.readAddress(".contracts.AsseteraECS");
        address impl = json.readAddress(".implementations.AsseteraECS");
        address adminAddr = json.readAddress(".metadata.admin");
        address deployer = json.readAddress(".metadata.deployer");
        address kycAddr = json.readAddress(".metadata.kycSigner");
        address feeAddr = json.readAddress(".metadata.feeSigner");

        AsseteraECS exchange = AsseteraECS(proxy);

        console2.log("");
        console2.log("=== Verify: AsseteraECS (chain %s) ===", chainId);
        console2.log("Proxy  :", proxy);
        console2.log("Impl   :", impl);
        console2.log("Admin  :", adminAddr);

        address liveImpl = _implOf(proxy);
        _check("impl slot == recorded impl", liveImpl == impl, string.concat("  got ", vm.toString(liveImpl)));

        string memory ver = exchange.version();
        _check("version() readable", bytes(ver).length > 0, "  version() reverted");
        console2.log("  version:", ver);

        bytes32 adminRole = exchange.DEFAULT_ADMIN_ROLE();
        _check(
            "recorded admin holds DEFAULT_ADMIN_ROLE",
            exchange.hasRole(adminRole, adminAddr),
            string.concat("  ", vm.toString(adminAddr), " does NOT hold DEFAULT_ADMIN_ROLE")
        );

        // The deployer is a hot key that signed the deploy transaction. It must not retain upgrade
        // authority afterwards. Skipped when admin IS the deployer, which is the intended local/anvil shape.
        if (deployer != adminAddr) {
            _check(
                "deployer EOA does NOT hold DEFAULT_ADMIN_ROLE",
                !exchange.hasRole(adminRole, deployer),
                string.concat("  ", vm.toString(deployer), " still holds DEFAULT_ADMIN_ROLE - revoke it")
            );
        }

        // OPERATOR_ROLE is parked and deliberately not granted; nothing to assert while that holds.

        _check(
            "kycSigner holds KYC_OPERATOR_ROLE",
            exchange.hasRole(exchange.KYC_OPERATOR_ROLE(), kycAddr),
            string.concat("  ", vm.toString(kycAddr), " does NOT hold KYC_OPERATOR_ROLE")
        );
        _check(
            "feeSigner holds FEE_OPERATOR_ROLE",
            exchange.hasRole(exchange.FEE_OPERATOR_ROLE(), feeAddr),
            string.concat("  ", vm.toString(feeAddr), " does NOT hold FEE_OPERATOR_ROLE")
        );

        bool placeGated = exchange.complianceRequired(uint8(ExchangeTypes.Action.Place));
        bool fillGated = exchange.complianceRequired(uint8(ExchangeTypes.Action.Fill));
        bool settleGated = exchange.complianceRequired(uint8(ExchangeTypes.Action.Settle));
        _check(
            "all actions KYC-gated by default",
            placeGated && fillGated && settleGated,
            "  one or more actions not gated"
        );

        _check("contract not paused", !exchange.paused(), "  contract is paused");

        _checkCollectors(proxy, "exchange");
    }

    // --------------------------------------------------------------------- //
    //                          The primary-sales router                      //
    // --------------------------------------------------------------------- //

    /// @dev Skipped entirely when the record has no `AsseteraPrimarySales` entry, so this script still runs
    ///      against a deployment made before the router existed. Absence is reported, not treated as a
    ///      failure: an old record is a fact about that chain, not a defect in it.
    function _verifyPrimarySales(string memory json) internal {
        if (!vm.keyExistsJson(json, ".contracts.AsseteraPrimarySales")) {
            console2.log("");
            console2.log("=== AsseteraPrimarySales: not in this deployment record - skipped ===");
            return;
        }

        address proxy = json.readAddress(".contracts.AsseteraPrimarySales");
        address impl = json.readAddress(".implementations.AsseteraPrimarySales");
        address adminAddr = json.readAddress(".metadata.admin");
        address deployer = json.readAddress(".metadata.deployer");
        address kycAddr = json.readAddress(".metadata.kycSigner");
        address feeAddr = json.readAddress(".metadata.feeSigner");

        AsseteraPrimarySales router = AsseteraPrimarySales(proxy);

        console2.log("");
        console2.log("=== Verify: AsseteraPrimarySales ===");
        console2.log("Proxy  :", proxy);
        console2.log("Impl   :", impl);

        address liveImpl = _implOf(proxy);
        _check("primary impl slot == recorded impl", liveImpl == impl, string.concat("  got ", vm.toString(liveImpl)));

        string memory ver = router.version();
        _check("primary version() readable", bytes(ver).length > 0, "  version() reverted");
        console2.log("  version:", ver);

        bytes32 adminRole = router.DEFAULT_ADMIN_ROLE();
        _check(
            "recorded admin holds DEFAULT_ADMIN_ROLE on the router",
            router.hasRole(adminRole, adminAddr),
            string.concat("  ", vm.toString(adminAddr), " does NOT hold DEFAULT_ADMIN_ROLE")
        );
        if (deployer != adminAddr) {
            _check(
                "deployer EOA does NOT hold DEFAULT_ADMIN_ROLE on the router",
                !router.hasRole(adminRole, deployer),
                string.concat("  ", vm.toString(deployer), " still holds DEFAULT_ADMIN_ROLE - revoke it")
            );
        }

        _check(
            "kycSigner holds KYC_OPERATOR_ROLE on the router",
            router.hasRole(router.KYC_OPERATOR_ROLE(), kycAddr),
            string.concat("  ", vm.toString(kycAddr), " does NOT hold KYC_OPERATOR_ROLE")
        );
        _check(
            "feeSigner holds FEE_OPERATOR_ROLE on the router",
            router.hasRole(router.FEE_OPERATOR_ROLE(), feeAddr),
            string.concat("  ", vm.toString(feeAddr), " does NOT hold FEE_OPERATOR_ROLE")
        );

        // The settlement signer is the only one of the three operator roles that can cause a transfer, so
        // it gets its own check AND its own warning: sharing a key with the KYC or fee signer is not a
        // contract error, it is a provisioning gap, and it will not surface anywhere else.
        address settlementAddr = vm.keyExistsJson(json, ".metadata.settlementSigner")
            ? json.readAddress(".metadata.settlementSigner")
            : address(0);
        _check(
            "settlementSigner recorded",
            settlementAddr != address(0),
            "  no metadata.settlementSigner in the deployment record"
        );
        if (settlementAddr != address(0)) {
            _check(
                "settlementSigner holds SETTLEMENT_OPERATOR_ROLE",
                router.hasRole(router.SETTLEMENT_OPERATOR_ROLE(), settlementAddr),
                string.concat("  ", vm.toString(settlementAddr), " does NOT hold SETTLEMENT_OPERATOR_ROLE")
            );
            if (settlementAddr == kycAddr || settlementAddr == feeAddr) {
                console2.log("[WARN] settlementSigner shares a key with the KYC or fee signer");
                console2.log("       the settlement key is the one that can move funds - give it its own");
            }
        }

        bool venueGated = router.complianceRequired(uint8(PrimaryTypes.Action.SettleVenue));
        _check("SettleVenue is KYC-gated", venueGated, "  SettleVenue is not gated");

        _check("router not paused", !router.paused(), "  router is paused");

        _checkCollectors(proxy, "router");

        // The router deploys CLOSED: an unset cap means the currency cannot be settled at all. Report the
        // caps for the settlement tokens this chain knows about rather than asserting a value, because the
        // right answer differs before and after the post-deploy admin steps. Reporting it is the point:
        // "why does every settlement revert" and "nobody ran setSettlementCap" are the same question.
        _reportCap(router, json, "MockUSDC");
    }

    function _reportCap(AsseteraPrimarySales router, string memory json, string memory key) internal view {
        if (!vm.keyExistsJson(json, string.concat(".contracts.", key))) return;
        address token = json.readAddress(string.concat(".contracts.", key));
        uint256 whole = router.perTxCapWholeUnits(token);
        if (whole == 0) {
            console2.log("[INFO] %s settlement cap is UNSET - settlement in it reverts (closed by default)", key);
            console2.log("       ", token);
        } else {
            console2.log("[INFO] %s per-tx settlement cap: %s whole units", key, whole);
        }
    }

    // --------------------------------------------------------------------- //
    //                                Helpers                                 //
    // --------------------------------------------------------------------- //

    /// @dev Check that each address in `EXPECTED_COLLECTORS` is allowlisted on `target`.
    ///
    ///      ⚠️ **The exchange and the router keep SEPARATE allowlists**, and the same is true of their role
    ///      grants. Every post-deploy runbook is therefore a list of calls to two addresses, and sending one
    ///      contract's half while missing the other's produces a deployment that verifies clean and then
    ///      refuses every settlement naming a collector, because an unlisted recipient is refused. That is a
    ///      long way from the mistake to the symptom, so it is checked here.
    ///
    ///      The allowlist is a mapping and cannot be enumerated on chain, and the deployment record does not
    ///      name collectors, so the expected set has to be supplied:
    ///
    ///        EXPECTED_COLLECTORS=0xabc...,0xdef... forge script script/Verify.s.sol:Verify --rpc-url amoy
    ///
    ///      Unset is reported rather than passed. A check that silently does nothing when its input is
    ///      missing is worse than no check, because the run still ends in "All checks passed".
    function _checkCollectors(address target, string memory label) internal {
        address[] memory expected = vm.envOr("EXPECTED_COLLECTORS", ",", new address[](0));
        if (expected.length == 0) {
            console2.log("[INFO] %s: collector allowlist NOT checked (set EXPECTED_COLLECTORS to check it)", label);
            return;
        }
        for (uint256 i = 0; i < expected.length; i++) {
            _check(
                string.concat(label, ": collector ", vm.toString(expected[i]), " is allowlisted"),
                IAllowedCollectors(target).allowedCollectors(expected[i]),
                "  NOT allowlisted - a fee naming this recipient is refused"
            );
        }
    }

    /// @dev Read the ERC-1967 implementation slot of a proxy.
    function _implOf(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
    }

    /// @dev Record a check. Does NOT revert: see the note on the contract.
    function _check(string memory label, bool ok, string memory detail) internal {
        if (ok) {
            console2.log("[PASS] %s", label);
        } else {
            console2.log("[FAIL] %s", label);
            console2.log(detail);
            _failures++;
        }
    }
}
