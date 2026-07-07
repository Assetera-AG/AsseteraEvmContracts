// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {DeployBase} from "./DeployBase.sol";
import {AsseteraExchange} from "../src/AsseteraExchange.sol";
import {FaucetToken} from "../src/FaucetToken.sol";

/// @notice Deploys (or upgrades) the full demo stack and records addresses in
///         deployments/<chainId>.json. Re-running upgrades the exchange proxy
///         in place when the implementation bytecode changed, and reuses
///         already-deployed tokens.
///
/// Usage (local):
///   anvil &
///   forge script script/Deploy.s.sol:Deploy \
///     --rpc-url local --broadcast \
///     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
///
/// Env (optional):
///   ADMIN_ADDRESS      — address granted DEFAULT_ADMIN_ROLE; use Safe multisig in prod (defaults to deployer)
///   OPERATOR_ADDRESS   — address granted OPERATOR_ROLE (defaults to deployer)
///   KYC_SIGNER_ADDRESS — address granted KYC_OPERATOR_ROLE (defaults to deployer)
///   RELAYER_ADDRESS    — recorded for reference (the gasless relayer EOA)
contract Deploy is DeployBase {
    function run() external {
        _initPaths();
        _loadExisting();

        // If PRIVATE_KEY is in the environment, broadcast with it (avoids passing
        // the key on the CLI where it ends up in shell history).
        // Falls back to msg.sender so `anvil` local runs still work without a key.
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer = pk != 0 ? vm.addr(pk) : msg.sender;

        // ADMIN_ADDRESS should be the Safe multisig on production networks.
        // Defaults to the deployer EOA so local / CI runs work without extra config.
        address admin = vm.envOr("ADMIN_ADDRESS", deployer);
        operator = vm.envOr("OPERATOR_ADDRESS", deployer);
        kycSigner = vm.envOr("KYC_SIGNER_ADDRESS", deployer);
        relayer = vm.envOr("RELAYER_ADDRESS", deployer);

        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();

        // 1. Test tokens — reuse if already deployed on this network.
        if (!_hasCode(usdc)) {
            usdc = address(new FaucetToken("Mock USD Coin", "mUSDC", 6));
            console2.log("MockUSDC deployed:", usdc);
        } else {
            console2.log("MockUSDC reused:", usdc);
        }
        if (!_hasCode(rwa)) {
            rwa = address(new FaucetToken("Mock RWA Token", "mRWA", 18));
            console2.log("MockRWA deployed:", rwa);
        } else {
            console2.log("MockRWA reused:", rwa);
        }

        // 2. ERC-2771 forwarder (gasless relayer entrypoint) — reuse if present.
        if (!_hasCode(forwarder)) {
            forwarder = address(new ERC2771Forwarder("AsseteraForwarder"));
            console2.log("ERC2771Forwarder deployed:", forwarder);
        } else {
            console2.log("ERC2771Forwarder reused:", forwarder);
        }

        // 3. Exchange implementation — always (re)deploy; cheap and lets us diff.
        //    Forwarder is immutable in the impl bytecode (proxy-safe).
        address newImpl = address(new AsseteraExchange(forwarder));
        console2.log("AsseteraExchange impl deployed:", newImpl);

        // 4. Proxy: fresh deploy + init, or upgrade-in-place if it already exists.
        //    A recorded address only counts as the proxy if it's actually a UUPS
        //    proxy (non-empty ERC-1967 impl slot) — guards against a stale
        //    manifest after a chain reset, where a shifted nonce could land the
        //    old proxy address on a freshly-deployed non-proxy contract.
        bool isProxy = _hasCode(exchangeProxy) && _currentImpl(exchangeProxy) != address(0);
        if (!isProxy) {
            bytes memory initData = abi.encodeCall(AsseteraExchange.initialize, (admin, operator, kycSigner));
            exchangeProxy = address(new ERC1967Proxy(newImpl, initData));
            console2.log("AsseteraExchange proxy deployed:", exchangeProxy);
            console2.log("  admin (DEFAULT_ADMIN_ROLE):", admin);
            console2.log("  operator:", operator);
            console2.log("  kycSigner:", kycSigner);
        } else {
            address current = _currentImpl(exchangeProxy);
            if (current != newImpl) {
                AsseteraExchange(exchangeProxy).upgradeToAndCall(newImpl, "");
                console2.log("AsseteraExchange proxy upgraded ->", newImpl);
            } else {
                console2.log("AsseteraExchange proxy impl unchanged");
            }
        }
        exchangeImpl = newImpl;

        vm.stopBroadcast();

        _save(deployer, admin);

        console2.log("");
        console2.log("=== Deployment summary (chainId %s) ===", chainId);
        console2.log("AsseteraExchange (proxy):", exchangeProxy);
        console2.log("AsseteraExchange (impl): ", exchangeImpl);
        console2.log("Forwarder:", forwarder);
        console2.log("MockUSDC:", usdc);
        console2.log("MockRWA: ", rwa);
    }

    /// @dev Read the ERC-1967 implementation slot of a proxy.
    function _currentImpl(address proxy) private view returns (address) {
        bytes32 raw = vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT);
        return address(uint160(uint256(raw)));
    }
}
