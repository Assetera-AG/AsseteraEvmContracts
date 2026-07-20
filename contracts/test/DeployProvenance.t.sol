// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployBase} from "../script/DeployBase.sol";

/// Exposes DeployBase's internal provenance logic + a `deploymentPath` setter so it can be exercised against a
/// throwaway fixture file (no on-chain deploy needed).
contract DeployBaseHarness is DeployBase {
    function setPath(string calldata p) external {
        deploymentPath = p;
    }

    function provenance(bool proxyCreated) external view returns (uint256 deployBlock, uint256 deployTimestamp) {
        return _provenance(proxyCreated);
    }
}

/// Regression for AC-665: an implementation upgrade (proxy NOT created this run) must PRESERVE the recorded
/// proxy-creation block/timestamp, while a genuine fresh proxy deploy stamps the current block. The old
/// `_save` wrote `block.number` unconditionally, pushing the indexer's start cursor forward on every upgrade.
contract DeployProvenanceTest is Test {
    // The real proxy-creation values recorded at first deployment (Amoy 80002), and the later upgrade block
    // that the buggy script wrongly re-stamped onto them.
    uint256 internal constant CREATION_BLOCK = 42134204;
    uint256 internal constant CREATION_TS = 1783952602;
    uint256 internal constant UPGRADE_BLOCK = 42470077;
    uint256 internal constant UPGRADE_TS = 1784288475;

    // Each test gets its OWN harness + fixture path — forge runs test methods concurrently and they share the
    // real filesystem, so a single shared path would race.
    function _harness(string memory name) internal returns (DeployBaseHarness h, string memory path) {
        h = new DeployBaseHarness();
        path = string.concat(vm.projectRoot(), "/out/deploy-provenance-", name, ".json");
        h.setPath(path);
        if (vm.exists(path)) vm.removeFile(path);
    }

    function _writeFixture(string memory path, uint256 blk, uint256 ts) internal {
        vm.writeFile(
            path,
            string.concat('{"metadata":{"deployBlock":', vm.toString(blk), ',"deployTimestamp":', vm.toString(ts), "}}")
        );
    }

    /// Upgrade re-run: preserve the existing creation block/timestamp, ignoring the current (upgrade) block.
    function test_preservesCreationProvenanceOnUpgrade() public {
        (DeployBaseHarness h, string memory path) = _harness("upgrade");
        _writeFixture(path, CREATION_BLOCK, CREATION_TS);
        vm.roll(UPGRADE_BLOCK);
        vm.warp(UPGRADE_TS);

        (uint256 blk, uint256 ts) = h.provenance(false);
        assertEq(blk, CREATION_BLOCK, "deployBlock must stay at proxy creation across an upgrade");
        assertEq(ts, CREATION_TS, "deployTimestamp must stay at proxy creation across an upgrade");
        vm.removeFile(path);
    }

    /// Fresh proxy deploy: stamp the current block/timestamp even if a stale file happens to exist.
    function test_stampsCurrentBlockOnFreshProxy() public {
        (DeployBaseHarness h, string memory path) = _harness("fresh");
        _writeFixture(path, CREATION_BLOCK, CREATION_TS);
        vm.roll(99);
        vm.warp(1234);

        (uint256 blk, uint256 ts) = h.provenance(true);
        assertEq(blk, 99, "a fresh proxy deploy stamps the current block");
        assertEq(ts, 1234, "a fresh proxy deploy stamps the current timestamp");
        vm.removeFile(path);
    }

    /// No prior file (first-ever save, not a fresh-proxy flag): fall back to the current block.
    function test_stampsCurrentBlockWhenNoPriorFile() public {
        (DeployBaseHarness h,) = _harness("nofile");
        vm.roll(55);
        vm.warp(777);

        (uint256 blk, uint256 ts) = h.provenance(false);
        assertEq(blk, 55, "no prior record -> current block");
        assertEq(ts, 777, "no prior record -> current timestamp");
    }
}
