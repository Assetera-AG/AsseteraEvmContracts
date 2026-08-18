// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ISettlementLimits} from "../src/primary/interfaces/ISettlementLimits.sol";
import {DeploymentFile} from "./DeploymentFile.sol";

/// @notice Prints the post-deploy admin transactions the stack needs before it can do anything, as calldata
///         ready to paste into a multisig and as `cast send` lines ready to run from an EOA.
///
///         The deploy script CANNOT do these itself. Both calls are `DEFAULT_ADMIN_ROLE`, and on any
///         deployment worth having, admin is not the deployer — it is a multisig, or at least a key that
///         did not just sign a broadcast. So the deploy necessarily ends with a stack that is wired but
///         inert, and somebody has to send these separately. That gap is where a deployment silently sits
///         "finished" and broken, so the calldata is generated rather than hand-assembled.
///
///         What is needed, and why nothing works without it:
///           1. `setSettlementCap(token, wholeUnits)` on the router. An unset cap reads as zero and zero
///              means "this currency cannot be settled in at all". The router therefore deploys CLOSED, and
///              every settlement in every currency reverts until this is sent once per currency.
///           2. `setAllowedCollector(collector, true)` on the router and on the exchange. Fees name a
///              recipient, and an unlisted recipient is refused.
///
///         Usage:
///           FEE_COLLECTOR_ADDRESS=0x… SETTLEMENT_CAP_WHOLE=100000 \
///             forge script script/AdminCalldata.s.sol:AdminCalldata --rpc-url <network> -vv
///
///         Env:
///           FEE_COLLECTOR_ADDRESS — the fee recipient to allowlist. Required.
///           SETTLEMENT_TOKEN      — settlement currency to cap. Defaults to the record's MockUSDC on a
///                                   testnet; required on any chain without one.
///           SETTLEMENT_CAP_WHOLE  — the per-transaction cap in WHOLE tokens, not raw units. Required.
///
/// @dev Read-only: never broadcasts. It prints what to send and deliberately does not send it, because the
///      key that may send these is by construction not the key running this script.
contract AdminCalldata is Script {
    using stdJson for string;

    function run() external view {
        string memory path = DeploymentFile.pathFor(block.chainid);
        require(vm.isFile(path), string.concat("no deployment file at ", path));
        string memory json = vm.readFile(path);

        address collector = vm.envAddress("FEE_COLLECTOR_ADDRESS");
        require(collector != address(0), "FEE_COLLECTOR_ADDRESS must not be the zero address");

        // Whole tokens, not raw units. The router converts once, on this call, using the token's decimals,
        // precisely so that the number a human reads before signing is the number they meant. Passing raw
        // units here would reintroduce the decimals mistake the cap exists to catch.
        uint256 capWhole = vm.envUint("SETTLEMENT_CAP_WHOLE");
        require(capWhole > 0, "SETTLEMENT_CAP_WHOLE of 0 CLOSES the currency - omit the call instead");

        address token = vm.envOr("SETTLEMENT_TOKEN", address(0));
        if (token == address(0)) {
            require(
                vm.keyExistsJson(json, ".contracts.MockUSDC"),
                "set SETTLEMENT_TOKEN: this chain has no MockUSDC to default to"
            );
            token = json.readAddress(".contracts.MockUSDC");
        }

        address exchange = json.readAddress(".contracts.AsseteraECS");
        address router = vm.keyExistsJson(json, ".contracts.AsseteraPrimarySales")
            ? json.readAddress(".contracts.AsseteraPrimarySales")
            : address(0);
        address admin = json.readAddress(".metadata.admin");

        console2.log("");
        console2.log("=== Post-deploy admin transactions (chain %s) ===", block.chainid);
        console2.log("Send these FROM the admin:", admin);
        console2.log("");

        if (router != address(0)) {
            _emit(
                "1. Open the settlement currency on the router (without this, every settlement reverts)",
                router,
                abi.encodeCall(ISettlementLimits.setSettlementCap, (token, capWhole))
            );
            console2.log("   token:", token);
            console2.log("   cap (whole tokens):", capWhole);
            console2.log("");

            _emit(
                "2. Allowlist the fee collector on the router",
                router,
                abi.encodeWithSignature("setAllowedCollector(address,bool)", collector, true)
            );
            console2.log("   collector:", collector);
            console2.log("");
        } else {
            console2.log("AsseteraPrimarySales is not in this deployment record - skipping its two calls.");
            console2.log("");
        }

        _emit(
            "3. Allowlist the fee collector on the exchange",
            exchange,
            abi.encodeWithSignature("setAllowedCollector(address,bool)", collector, true)
        );
        console2.log("   collector:", collector);

        console2.log("");
        console2.log("Multisig: New Transaction > Contract Interaction, paste the To and the Data, value 0.");
        console2.log("EOA:      the cast lines above, with --rpc-url and the admin key.");
        console2.log("");
        console2.log("Then re-run Verify.s.sol - it reports an unset cap explicitly.");
    }

    /// @dev One transaction, in both forms an operator might need: the multisig fields, and a runnable
    ///      `cast send`. Printing only one of the two guarantees somebody hand-converts it under pressure.
    function _emit(string memory label, address to, bytes memory data) internal view {
        console2.log(label);
        console2.log("   To:   ", to);
        console2.log("   Value: 0");
        console2.log("   Data:");
        console2.logBytes(data);
        console2.log("   cast send %s %s --rpc-url <rpc> --private-key <admin>", vm.toString(to), vm.toString(data));
    }
}
