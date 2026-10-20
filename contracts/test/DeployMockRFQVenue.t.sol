// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DeployMockRFQVenue} from "../script/DeployMockRFQVenue.s.sol";
import {FaucetToken} from "./mocks/FaucetToken.sol";
import {MockRFQVenue} from "./mocks/MockRFQVenue.sol";

/// @notice Drives the fixture deploy script's body against a THROWAWAY record path, so the test
///         never touches the committed deployment artifacts.
contract DeployMockRFQVenueHarness is DeployMockRFQVenue {
    function prepare() external withCreateX {}

    function runAt(string calldata path, address signer) external {
        _initPaths();
        deploymentPath = path;
        _deployFixtures(signer);
    }

    function addressFor(address deployer, string calldata label) external pure returns (address) {
        return computeCreate3Address(_salt(deployer, label), deployer);
    }

    /// The harness is the deployer, and therefore the venue's owner: this is the owner-only call the
    /// script's CREATE3 deployment must leave reachable.
    function rotateQuoteSigner(address venue, address newSigner) external {
        MockRFQVenue(venue).setQuoteSigner(newSigner);
    }

    /// No broadcast in a test: the harness itself is the account CreateX sees, so the CREATE3
    /// address it computes is the one `_fixtureDeployer` must return.
    function _startBroadcast() internal override {}

    function _stopBroadcast() internal override {}

    function _fixtureDeployer() internal view override returns (address) {
        return address(this);
    }
}

/// @title DeployMockRFQVenueTest
/// @notice The deploy script for the testnet RFQ fixtures, run on a local chain: it refuses a
///         mainnet chain id, deploys mAAPL and the venue, and merges both addresses into an
///         existing deployment record without touching the rest of it.
contract DeployMockRFQVenueTest is Test {
    /// The deployer recorded on the committed Sepolia and Amoy records. Used to check that the
    /// addresses committed for those chains are the ones this script will deploy.
    address internal constant RECORDED_DEPLOYER = 0xDEaDFA8BC247c921745a2D4B6216eFaAdece9D27;

    DeployMockRFQVenueHarness internal script;
    address internal quoteSigner = makeAddr("quoteSigner");

    function setUp() public {
        script = new DeployMockRFQVenueHarness();
        script.prepare();
    }

    /// Each test gets its own file: forge runs tests concurrently against one filesystem.
    function _recordPath(string memory name) internal returns (string memory path) {
        path = string.concat(vm.projectRoot(), "/out/mock-rfq-venue-", name, ".json");
        if (vm.exists(path)) vm.removeFile(path);
        vm.writeFile(
            path,
            "{\"caip2\":\"eip155:31337\",\"chainId\":31337,\"contracts\":{\"AsseteraECS\":\"0x00000000000000000000000000000000000000AA\"},\"namespace\":\"eip155\"}"
        );
    }

    function _run(string memory path) internal {
        script.runAt(path, quoteSigner);
    }

    function test_RefusesAMainnetChainId() public {
        string memory path = _recordPath("mainnet");
        vm.chainId(1);

        vm.expectRevert("refusing: the mock RFQ venue and mAAPL are testnet fixtures");
        script.runAt(path, quoteSigner);

        // Leave the shared test EVM on the chain the rest of the suite expects.
        vm.chainId(31337);
    }

    /// mAAPL is the quoted mock stock, and the venue records the configured provider.
    function test_DeploysAndRecordsBothFixtures() public {
        string memory path = _recordPath("deploy");
        _run(path);

        string memory json = vm.readFile(path);
        address aapl = vm.parseJsonAddress(json, ".contracts.mAAPL");
        address venue = vm.parseJsonAddress(json, ".contracts.mockRfqVenue");
        assertTrue(aapl != address(0), "mAAPL was not recorded");
        assertTrue(venue != address(0), "the venue was not recorded");

        assertEq(FaucetToken(aapl).name(), "Mock Apple", "mAAPL name");
        assertEq(FaucetToken(aapl).symbol(), "mAAPL", "mAAPL symbol");
        assertEq(FaucetToken(aapl).decimals(), 18, "mAAPL decimals");
        assertEq(MockRFQVenue(venue).quoteSigner(), quoteSigner, "the venue's quote signer");
        // 🔴 The CREATE3 deployment makes the constructor's `msg.sender` the CREATE3 proxy, so the
        // owner must be the account the script deployed from. If this ever reads the proxy address
        // (or zero), `setQuoteSigner` is unreachable and the fixture is dead.
        assertEq(MockRFQVenue(venue).owner(), address(script), "the owner is not the deployer the script used");

        // Everything already in the record is preserved.
        assertEq(vm.parseJsonAddress(json, ".contracts.AsseteraECS"), address(0xAA), "an existing key was disturbed");
        assertEq(vm.parseJsonUint(json, ".chainId"), 31337, "the chain id was disturbed");
    }

    /// 🔴 The whole point of passing the owner explicitly: after the CREATE3 deployment the account
    /// the script deployed from can rotate the quote signer, and nobody else can. Without the
    /// explicit owner the deployment would be owned by the CREATE3 proxy and this call would revert
    /// for everyone, forever.
    function test_OnlyTheDeployerCanRotateTheQuoteSigner() public {
        string memory path = _recordPath("owner");
        _run(path);
        address venue = vm.parseJsonAddress(vm.readFile(path), ".contracts.mockRfqVenue");

        address newSigner = makeAddr("newSigner");
        script.rotateQuoteSigner(venue, newSigner);
        assertEq(MockRFQVenue(venue).quoteSigner(), newSigner, "the deployer, as owner, could not rotate the signer");

        address stranger = makeAddr("stranger");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        MockRFQVenue(venue).setQuoteSigner(stranger);
    }

    /// A re-run reuses the same two addresses rather than deploying a second set of fixtures.
    function test_RerunReusesTheRecordedFixtures() public {
        string memory path = _recordPath("rerun");
        _run(path);
        string memory first = vm.readFile(path);

        _run(path);
        string memory second = vm.readFile(path);

        assertEq(
            vm.parseJsonAddress(second, ".contracts.mAAPL"),
            vm.parseJsonAddress(first, ".contracts.mAAPL"),
            "mAAPL moved on a re-run"
        );
        assertEq(
            vm.parseJsonAddress(second, ".contracts.mockRfqVenue"),
            vm.parseJsonAddress(first, ".contracts.mockRfqVenue"),
            "the venue moved on a re-run"
        );
    }

    /// A re-run with a different provider must not silently leave the recorded venue signing for
    /// the old one; rotating it is an owner transaction.
    function test_RerunWithADifferentQuoteSignerIsRefused() public {
        string memory path = _recordPath("rotated");
        _run(path);

        vm.expectRevert("existing MockRFQVenue has a different quoteSigner: call setQuoteSigner as owner");
        script.runAt(path, makeAddr("otherSigner"));
    }

    /// The Sepolia and Amoy records already name the addresses this script will produce, so the
    /// SDK never publishes an address the deploy would not land on. The mock USDC check is the
    /// control: the same derivation must reproduce an address the repo has already deployed.
    function test_CommittedTestnetAddressesMatchTheDerivation() public view {
        assertEq(
            script.addressFor(RECORDED_DEPLOYER, "MockUSDC"),
            0x85D7B2569b3d69320F05A4FFB140Ca4521989A15,
            "the derivation does not reproduce an address deployed by the stack"
        );

        _assertRecorded(11155111);
        _assertRecorded(80002);
    }

    function _assertRecorded(uint256 chainId) internal view {
        string memory path =
            string.concat(vm.projectRoot(), "/../packages/sdk/src/deployments/", vm.toString(chainId), ".json");
        string memory json = vm.readFile(path);

        assertEq(
            vm.parseJsonAddress(json, ".contracts.mAAPL"),
            script.addressFor(RECORDED_DEPLOYER, "mAAPL"),
            "recorded mAAPL is not the address the script deploys"
        );
        assertEq(
            vm.parseJsonAddress(json, ".contracts.mockRfqVenue"),
            script.addressFor(RECORDED_DEPLOYER, "MockRFQVenue"),
            "recorded mockRfqVenue is not the address the script deploys"
        );
    }
}
