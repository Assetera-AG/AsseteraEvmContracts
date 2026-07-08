// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {DeployBase} from "./DeployBase.sol";
import {AsseteraExchange} from "../src/AsseteraExchange.sol";
import {FaucetToken} from "../src/FaucetToken.sol";

/// @notice Deterministically deploys (or upgrades) the exchange stack via CreateX and records the
///         addresses in `packages/sdk/src/deployments/<chainId>.json` (ADR-0026). The proxy and forwarder
///         get the **same address on every chain** for a given deployer (CREATE3), so consumers can treat
///         them as constants. Re-running upgrades the proxy in place; its address never changes.
///
/// Usage (local):
///   anvil &
///   forge script script/Deploy.s.sol:Deploy --rpc-url local --broadcast \
///     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
///
/// Usage (testnet — CreateX must already be deployed on the chain, which it is on Amoy/mainnet/etc.):
///   forge script script/Deploy.s.sol:Deploy --rpc-url amoy --broadcast --verify
///
/// Env (optional; all default to the deployer for local/testnet):
///   ADMIN_ADDRESS      — DEFAULT_ADMIN_ROLE (upgrade + role admin); use the Safe multisig in prod
///   OPERATOR_ADDRESS   — OPERATOR_ROLE (settle/refund/pause)
///   KYC_SIGNER_ADDRESS — KYC_OPERATOR_ROLE (signs KYC attestations)
///   FEE_SIGNER_ADDRESS — FEE_OPERATOR_ROLE (signs fee attestations; the fee service)
///   RELAYER_ADDRESS    — recorded for reference (the gasless relayer EOA)
contract Deploy is DeployBase {
    /// @dev Ensures the CreateX factory is available (etched on anvil; already present on live chains).
    function setUp() public withCreateX {}

    function run() external {
        _initPaths();

        // PRIVATE_KEY in the env keeps the deployer key out of shell history; falls back to msg.sender
        // so local anvil runs work with a CLI --private-key.
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer = pk != 0 ? vm.addr(pk) : msg.sender;

        admin = vm.envOr("ADMIN_ADDRESS", deployer);
        operator = vm.envOr("OPERATOR_ADDRESS", deployer);
        kycSigner = vm.envOr("KYC_SIGNER_ADDRESS", deployer);
        feeSigner = vm.envOr("FEE_SIGNER_ADDRESS", deployer);
        relayer = vm.envOr("RELAYER_ADDRESS", deployer);

        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();

        bool created;

        // 1. ERC-2771 forwarder (gasless entrypoint) — CREATE3 stable address.
        (forwarder, created) = _deploy3(
            deployer,
            "Forwarder",
            abi.encodePacked(type(ERC2771Forwarder).creationCode, abi.encode("AsseteraForwarder"))
        );
        console2.log(created ? "Forwarder deployed:" : "Forwarder reused: ", forwarder);

        // 2. Test tokens — CREATE3 stable addresses (testnet helpers only).
        (usdc, created) = _deploy3(
            deployer,
            "MockUSDC",
            abi.encodePacked(type(FaucetToken).creationCode, abi.encode("Mock USD Coin", "mUSDC", uint8(6)))
        );
        console2.log(created ? "MockUSDC deployed:" : "MockUSDC reused: ", usdc);
        (rwa, created) = _deploy3(
            deployer,
            "MockRWA",
            abi.encodePacked(type(FaucetToken).creationCode, abi.encode("Mock RWA Token", "mRWA", uint8(18)))
        );
        console2.log(created ? "MockRWA deployed:" : "MockRWA reused: ", rwa);

        // 3. Exchange implementation — CREATE2 keyed on the initcode, so unchanged bytecode maps to the same
        //    address (re-run is a true no-op) and changed bytecode yields a new impl (→ the upgrade path
        //    below). The forwarder is baked in as an immutable; the impl address is not consumer-facing.
        (exchangeImpl, created) = _deploy2(
            deployer,
            "AsseteraExchange.impl",
            abi.encodePacked(type(AsseteraExchange).creationCode, abi.encode(forwarder))
        );
        console2.log(created ? "AsseteraExchange impl deployed:" : "AsseteraExchange impl reused: ", exchangeImpl);

        // 4. Exchange proxy — CREATE3 stable address, initialized atomically in the constructor (initData is
        //    part of the initcode, but CREATE3 makes the address initcode-independent, so there is no
        //    front-run window and the address is identical across chains and across future upgrades).
        bytes32 proxySalt = _salt(deployer, "AsseteraExchange.proxy");
        exchangeProxy = computeCreate3Address(proxySalt, deployer);
        if (!_hasCode(exchangeProxy)) {
            bytes memory initData = abi.encodeCall(AsseteraExchange.initialize, (admin, operator, kycSigner, feeSigner));
            bytes memory proxyInit =
                abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(exchangeImpl, initData));
            address deployed = create3(proxySalt, proxyInit);
            require(deployed == exchangeProxy, "proxy create3 mismatch");
            console2.log("AsseteraExchange proxy deployed:", exchangeProxy);
            console2.log("  admin:", admin);
        } else if (_currentImpl(exchangeProxy) != exchangeImpl) {
            // Re-run with new impl bytecode: upgrade in place (requires the caller to hold admin — true for
            // local/testnet where admin == deployer; prod upgrades go through the Safe via UpgradeCalldata).
            AsseteraExchange(exchangeProxy).upgradeToAndCall(exchangeImpl, "");
            console2.log("AsseteraExchange proxy upgraded ->", exchangeImpl);
        } else {
            console2.log("AsseteraExchange proxy impl unchanged");
        }

        vm.stopBroadcast();

        _save(deployer);

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
        return address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
    }
}
