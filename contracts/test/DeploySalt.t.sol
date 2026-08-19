// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployBase} from "../script/DeployBase.sol";
import {CREATEX_ADDRESS, CREATEX_BYTECODE} from "createx-forge/script/CreateX.d.sol";

/// Exposes DeployBase's internal salt derivation so the CREATE3 addresses it produces can be asserted
/// without deploying anything. `computeCreate3Address` is inherited from `CreateXScript` and is `pure`.
contract DeploySaltHarness is DeployBase {
    function saltFor(address deployer, string calldata name) external pure returns (bytes32) {
        return _salt(deployer, name);
    }

    function addressFor(address deployer, string calldata name) external pure returns (address) {
        return computeCreate3Address(_salt(deployer, name), deployer);
    }

    function saltVersionFor(string calldata name) external pure returns (string memory) {
        return _saltVersion(name);
    }

    function defaultSaltVersion() external pure returns (string memory) {
        return SALT_VERSION;
    }

    function primarySaltVersion() external pure returns (string memory) {
        return PRIMARY_SALT_VERSION;
    }

    /// The salt as it was derived BEFORE `PRIMARY_SALT_VERSION` existed: every label that was not an
    /// exchange label fell through to `SALT_VERSION`. Reproduced here rather than referenced, so the test
    /// compares against the old formula rather than against the new one restating itself.
    function legacyDefaultVersionSalt(address deployer, string calldata name) external pure returns (bytes32) {
        bytes11 entropy = bytes11(keccak256(abi.encodePacked("assetera.evm.", name, ".", SALT_VERSION)));
        return bytes32(abi.encodePacked(bytes20(deployer), bytes1(0x00), entropy));
    }
}

/// Pins the CREATE3 addresses the deploy script derives.
///
/// The reason this file exists: `AsseteraPrimarySales` was given its own salt version
/// (`PRIMARY_SALT_VERSION`) so its address can be rotated without also moving the forwarder and the faucet
/// mocks. Introducing that constant MUST NOT have moved the address, because the router is already live on
/// Polygon Amoy and Ethereum Sepolia. These tests are the evidence for that claim, asserted against the
/// addresses actually recorded in `packages/sdk/src/deployments/80002.json` rather than against the code's
/// own restatement of its formula.
contract DeploySaltTest is Test {
    DeploySaltHarness internal h;

    /// Values copied from `packages/sdk/src/deployments/80002.json` (Polygon Amoy), the live record.
    address internal constant AMOY_DEPLOYER = 0xDEaDFA8BC247c921745a2D4B6216eFaAdece9D27;
    address internal constant AMOY_PRIMARY_PROXY = 0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc;
    address internal constant AMOY_ECS_PROXY = 0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad;
    address internal constant AMOY_FORWARDER = 0x2244B33a97f91284D53d0A12d42F237927C3DBf7;

    string internal constant PRIMARY_PROXY_LABEL = "AsseteraPrimarySales.proxy";
    string internal constant PRIMARY_IMPL_LABEL = "AsseteraPrimarySales.impl";

    function setUp() public {
        h = new DeploySaltHarness();
        // `computeCreate3Address` staticcalls the CreateX factory, which has no code in a bare test EVM.
        // Etch the canonical bytecode at the canonical address — the same thing `setUpCreateXFactory` does
        // on a chain that is missing it. Verified present on all six production chains at this address.
        vm.etch(CREATEX_ADDRESS, CREATEX_BYTECODE);
    }

    /// 🔴 The load-bearing one. If this fails, the primary-sales proxy address has moved and every chain the
    /// router is already live on would need a redeploy.
    function test_Salt_PrimaryProxyAddressMatchesLiveAmoyDeployment() public view {
        assertEq(
            h.addressFor(AMOY_DEPLOYER, PRIMARY_PROXY_LABEL),
            AMOY_PRIMARY_PROXY,
            "primary-sales proxy address moved away from the live Amoy deployment"
        );
    }

    /// Introducing `PRIMARY_SALT_VERSION` must be a no-op on the salt while its value equals the default.
    /// Compares against the OLD formula, not against the new one.
    function test_Salt_PrimaryVersionIntroductionIsAddressNeutral() public view {
        assertEq(
            h.saltFor(AMOY_DEPLOYER, PRIMARY_PROXY_LABEL),
            h.legacyDefaultVersionSalt(AMOY_DEPLOYER, PRIMARY_PROXY_LABEL),
            "primary proxy salt diverged from the pre-PRIMARY_SALT_VERSION derivation"
        );
        assertEq(
            h.saltFor(AMOY_DEPLOYER, PRIMARY_IMPL_LABEL),
            h.legacyDefaultVersionSalt(AMOY_DEPLOYER, PRIMARY_IMPL_LABEL),
            "primary impl salt diverged from the pre-PRIMARY_SALT_VERSION derivation"
        );
        assertEq(h.primarySaltVersion(), h.defaultSaltVersion(), "the two versions must match for neutrality");
    }

    /// The knob is actually wired: both primary labels resolve through `PRIMARY_SALT_VERSION`, so bumping it
    /// rotates the router and nothing else. Without this, the constant could be dead code and the tests above
    /// would still pass.
    function test_Salt_PrimaryLabelsResolveThroughTheirOwnVersion() public view {
        assertEq(h.saltVersionFor(PRIMARY_PROXY_LABEL), h.primarySaltVersion(), "proxy label ignores its version");
        assertEq(h.saltVersionFor(PRIMARY_IMPL_LABEL), h.primarySaltVersion(), "impl label ignores its version");
    }

    /// Regression: adding a branch to `_saltVersion` must not have disturbed anything else that falls
    /// through to the default. The forwarder is the one that matters, because a global bump moving it is the
    /// original reason per-component versions exist.
    function test_Salt_ExchangeAndForwarderAddressesUnchanged() public view {
        assertEq(h.addressFor(AMOY_DEPLOYER, "AsseteraECS.proxy"), AMOY_ECS_PROXY, "exchange proxy address moved");
        assertEq(h.addressFor(AMOY_DEPLOYER, "Forwarder"), AMOY_FORWARDER, "forwarder address moved");
    }

    /// A label that matches neither surface still falls through to the default version.
    function test_Salt_UnknownLabelFallsThroughToDefault() public view {
        assertEq(h.saltVersionFor("SomethingElse"), h.defaultSaltVersion(), "unknown label lost the default");
    }
}
