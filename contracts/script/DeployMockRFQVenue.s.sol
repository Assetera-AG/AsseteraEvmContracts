// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2, VmSafe} from "forge-std/Script.sol";
import {DeployBase} from "./DeployBase.sol";
import {FaucetToken} from "../test/mocks/FaucetToken.sol";
import {MockRFQVenue} from "../test/mocks/MockRFQVenue.sol";

/// @notice Deploys the two testnet fixtures that let `AsseteraPrimarySales` buy and sell against
///         an RFQ venue on a chain where no real issuer is deployed: the mock stock `mAAPL`
///         (`FaucetToken`, 18 decimals) and the issuer-agnostic `MockRFQVenue`.
///
///         **Testnet only.** The script refuses any chain id that is not local anvil (31337),
///         Polygon Amoy (80002) or Ethereum Sepolia (11155111), the same set `DeployBase`
///         uses for the open-mint faucet tokens. `mAAPL` has a permissionless `mint`, and the
///         venue mints through it, so neither may exist on a mainnet.
///
/// @dev    Both fixtures use CREATE3 with their own salt labels, exactly as `MockUSDC`/`MockRWA`
///         do in `Deploy.s.sol`. That gives them a stable address per deployer, makes a re-run a
///         true no-op, and lets the committed deployment record name the address before the
///         first broadcast. The venue's salt label is `MockRFQVenue`; changing it moves the
///         address and orphans the recorded one, so treat it as frozen.
///
///         The addresses are appended to `packages/sdk/src/deployments/<chainId>.json` under
///         `contracts` as `mAAPL` and `mockRfqVenue`, next to the existing fixtures. Every other
///         key in the record is preserved. A dry run prints what it would write and leaves the
///         record untouched, mirroring `DeployBase._save`.
///
///         Usage — fixtures are deployed separately from the platform stack, through the same
///         keystore-signing wrapper:
///
///           MOCK_RFQ_QUOTE_SIGNER=0x<off-chain test RFQ provider> \
///           ALLOW_DEPLOYER_AS_ADMIN=1 \
///           FORGE_SCRIPT=DeployMockRFQVenue.s.sol:DeployMockRFQVenue \
///             bash scripts/deploy.sh sepolia --broadcast
///
///         `ALLOW_DEPLOYER_AS_ADMIN=1` is required only because the wrapper's admin check belongs
///         to the proxy stack; this script deploys no proxy and grants no admin role. The venue's
///         owner is the deployer, and the deployer can rotate the quote signer with
///         `setQuoteSigner`.
///
///         Env:
///           MOCK_RFQ_QUOTE_SIGNER  required — the address whose EIP-712 signature fills quotes
///           PRIVATE_KEY            optional — falls back to the sender, as in `Deploy.s.sol`
contract DeployMockRFQVenue is DeployBase {
    string internal constant AAPL_NAME = "Mock Apple";
    string internal constant AAPL_SYMBOL = "mAAPL";
    uint8 internal constant AAPL_DECIMALS = 18;

    /// @dev The CREATE3 salt labels. They are part of the address, not documentation — see the
    ///      contract NatSpec.
    string internal constant AAPL_LABEL = "mAAPL";
    string internal constant VENUE_LABEL = "MockRFQVenue";

    /// @dev Ensures the CreateX factory is available: etched on a local anvil, already present on
    ///      every live chain. Same shape as `Deploy.s.sol`.
    function setUp() public withCreateX {}

    function run() external {
        _initPaths();
        _deployFixtures(vm.envAddress("MOCK_RFQ_QUOTE_SIGNER"));
    }

    /// @dev The body, split out so a test harness can drive it against a throwaway record path
    ///      and an explicit provider, without mutating the process environment.
    function _deployFixtures(address signer) internal {
        uint256 id = block.chainid;
        require(_isTestnet(id), "refusing: the mock RFQ venue and mAAPL are testnet fixtures");
        require(vm.exists(deploymentPath), "no deployment record for this chain: run Deploy.s.sol first");
        require(signer != address(0), "MOCK_RFQ_QUOTE_SIGNER must not be the zero address");

        address deployer = _fixtureDeployer();
        _startBroadcast();

        (address aapl, bool aaplCreated) = _deploy3(
            deployer,
            AAPL_LABEL,
            abi.encodePacked(type(FaucetToken).creationCode, abi.encode(AAPL_NAME, AAPL_SYMBOL, AAPL_DECIMALS))
        );
        console2.log(aaplCreated ? "mAAPL deployed:" : "mAAPL reused: ", aapl);

        (address venue, bool venueCreated) =
            _deploy3(deployer, VENUE_LABEL, abi.encodePacked(type(MockRFQVenue).creationCode, abi.encode(signer)));
        console2.log(venueCreated ? "MockRFQVenue deployed:" : "MockRFQVenue reused: ", venue);

        _stopBroadcast();

        // A re-run must not silently leave the recorded venue on a different provider than the
        // one this run was told to use. Rotating the signer is an owner transaction, not a
        // deploy-time side effect, so refuse and say what to call.
        if (!venueCreated) {
            require(
                MockRFQVenue(venue).quoteSigner() == signer,
                "existing MockRFQVenue has a different quoteSigner: call setQuoteSigner as owner"
            );
        }

        console2.log("  quoteSigner:", signer);
        console2.log("  owner       :", deployer);
        _record(aapl, venue);
    }

    /// @dev The account the fixtures are deployed from. A real run uses `PRIVATE_KEY` when set
    ///      and otherwise the sender forge was invoked with. Virtual so the test harness can pin
    ///      it to the harness address, which is what CreateX sees when no broadcast is active.
    function _fixtureDeployer() internal view virtual returns (address) {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        return pk != 0 ? vm.addr(pk) : msg.sender;
    }

    /// @dev Broadcast start/stop, virtual for the same reason as `_fixtureDeployer`.
    function _startBroadcast() internal virtual {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();
    }

    function _stopBroadcast() internal virtual {
        vm.stopBroadcast();
    }

    /// @dev Append the two fixture addresses to the chain's record, preserving every other key.
    function _record(address aapl, address venue) internal {
        if (vm.isContext(VmSafe.ForgeContext.ScriptDryRun)) {
            console2.log("DRY RUN - the deployment record was NOT modified.");
            console2.log("  would write .contracts.mAAPL       =", aapl);
            console2.log("  would write .contracts.mockRfqVenue =", venue);
            console2.log("  to", deploymentPath);
            return;
        }

        string memory json = vm.readFile(deploymentPath);
        require(vm.keyExistsJson(json, ".contracts"), "deployment record has no contracts section");
        _writeAddress(".contracts.mAAPL", aapl);
        _writeAddress(".contracts.mockRfqVenue", venue);
        console2.log("Deployment written to:", deploymentPath);
    }

    /// @dev `vm.writeJson`'s keyed form writes a serialized VALUE at the key, so the value is
    ///      quoted here rather than wrapped in a one-key object.
    function _writeAddress(string memory key, address value) private {
        vm.writeJson(string.concat("\"", vm.toString(value), "\""), deploymentPath, key);
    }
}
