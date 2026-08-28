// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {AsseteraIssuanceVenue} from "../src/primary/sale/AsseteraIssuanceVenue.sol";
import {IAsseteraIssuanceVenue} from "../src/primary/sale/IAsseteraIssuanceVenue.sol";

/// @notice Deploys ONE offering's `AsseteraIssuanceVenue` — the per-token primary sale contract
///         that `AsseteraPrimarySales` settles against when the asset is our own issuance.
///
/// ⚠️ **Deliberately separate from `Deploy.s.sol`, and deliberately not part of it.** That script
///    deploys the platform stack: two proxies at CREATE3 addresses that are the same on every
///    chain, recorded in the SDK's deployment file because every consumer needs them as
///    constants. A sale venue is the opposite kind of thing — one per offering, deployed during
///    issuer onboarding, with a lifetime shorter than the platform's and an address that belongs
///    in the catalogue row for that offering rather than in a per-chain manifest. Bundling it
///    would put an offering's parameters in the platform's deploy path and make every routine
///    stack redeploy read like an issuance event.
///
/// ⚠️ **Plain `new`, not CREATE3.** The stack uses CREATE3 so one address serves every chain; a
///    venue has no such requirement (it is named in one catalogue row, on one chain) and giving
///    it a salt would mean minting a per-offering salt label. This repo treats a salt label as
///    the address it computes, so inventing one per offering is a hazard with no benefit here.
///
/// ⚠️ **Nothing is written to `packages/sdk/src/deployments/`.** The address printed below goes
///    into the offering's catalogue row (`primary_sale_contract`), not into the SDK manifest.
///
/// Usage:
///   forge script script/DeployIssuanceVenue.s.sol:DeployIssuanceVenue --rpc-url amoy --broadcast --verify
///
/// Env — all required unless noted:
///   PRIVATE_KEY                  deployer key (falls back to msg.sender for local runs)
///   VENUE_SETTLEMENT_TOKEN       the currency the offering is sold in (e.g. mUSDC)
///   VENUE_ASSET_TOKEN            the asset this venue mints (e.g. mRWA)
///   VENUE_UNIT_PRICE             price of ONE WHOLE asset token, in SETTLEMENT-token units
///   VENUE_MIN_UNIT_PRICE         inclusive floor for that price, same units, non-zero
///   VENUE_MAX_UNIT_PRICE         inclusive ceiling for that price, same units
///   VENUE_MAX_SETTLEMENT_WHOLE   per-purchase cap, in WHOLE settlement tokens (0 deploys CLOSED)
///   VENUE_ROUTER                 optional — the AsseteraPrimarySales proxy. Defaults to the
///                                address in the SDK deployment file for this chain, which is
///                                where it is already recorded; set it only to override.
///   VENUE_ADMIN / VENUE_RATE_SETTER / VENUE_PAUSER / VENUE_TREASURY
///                                optional — each defaults to the deployer, which is fine for a
///                                testnet dry run and is NOT fine for a real offering.
///
/// ⚠️ **The three prices are RAW settlement-token amounts, not decimals.** With a 6-decimal
///    mUSDC, 12.50 per token is `12500000`, a floor of one cent is `10000` and a ceiling of ten
///    thousand is `10000000000`. Getting this wrong by a factor of a million is the single most
///    likely deployment mistake, which is why the venue also carries a per-purchase cap.
contract DeployIssuanceVenue is Script {
    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer = pk != 0 ? vm.addr(pk) : msg.sender;

        IAsseteraIssuanceVenue.SaleConfig memory config = IAsseteraIssuanceVenue.SaleConfig({
            admin: vm.envOr("VENUE_ADMIN", deployer),
            rateSetter: vm.envOr("VENUE_RATE_SETTER", deployer),
            pauser: vm.envOr("VENUE_PAUSER", deployer),
            treasurer: vm.envOr("VENUE_TREASURY", deployer),
            router: vm.envOr("VENUE_ROUTER", _routerFromDeploymentFile()),
            settlementToken: vm.envAddress("VENUE_SETTLEMENT_TOKEN"),
            assetToken: vm.envAddress("VENUE_ASSET_TOKEN"),
            unitPrice: vm.envUint("VENUE_UNIT_PRICE"),
            minUnitPrice: vm.envUint("VENUE_MIN_UNIT_PRICE"),
            maxUnitPrice: vm.envUint("VENUE_MAX_UNIT_PRICE"),
            maxSettlementPerPurchaseWholeUnits: vm.envUint("VENUE_MAX_SETTLEMENT_WHOLE")
        });

        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();

        AsseteraIssuanceVenue venue = new AsseteraIssuanceVenue(config);

        vm.stopBroadcast();

        console2.log("AsseteraIssuanceVenue deployed:", address(venue));
        console2.log("  router          :", config.router);
        console2.log("  settlementToken :", config.settlementToken);
        console2.log("  assetToken      :", config.assetToken);
        console2.log("  unitPrice       :", config.unitPrice);
        console2.log("  price bounds    :", config.minUnitPrice, "..", config.maxUnitPrice);
        console2.log("  per-purchase cap (whole tokens):", config.maxSettlementPerPurchaseWholeUnits);

        // ⚠️ Three things stand between this deployment and a working sale, and none of them can
        //    be done from here: two are transactions on contracts this script does not own, and
        //    one is a database row. A venue that skipped any of them fails at the first purchase.
        console2.log("");
        console2.log("Still to do, in this order:");
        console2.log("  1. ISSUER grants this address the minting right on the asset token.");
        console2.log("  2. Router admin: setSettlementCap(settlementToken, wholeUnits) on AsseteraPrimarySales,");
        console2.log("     which reads an unset cap as 'this currency cannot settle at all'.");
        console2.log("  3. Catalogue: point the offering's primary_sale_contract at the address above.");
        if (config.maxSettlementPerPurchaseWholeUnits == 0) {
            console2.log(
                "  4. This venue was deployed CLOSED (cap 0). Call setMaxSettlementPerPurchase before selling."
            );
        }
    }

    /// @dev The router address already recorded for this chain by `Deploy.s.sol`. Read rather
    ///      than retyped because a venue pointed at the wrong router is a venue that can never
    ///      sell, and the manifest is the estate's source of truth for that address (it is what
    ///      the SDK, the indexer and the signer service all read). Returns the zero address when
    ///      no manifest exists, which lets `vm.envOr` fall through to an explicit `VENUE_ROUTER`
    ///      and lets the constructor's own `ZeroAddress` check catch a run that set neither.
    function _routerFromDeploymentFile() private view returns (address) {
        string memory path = string.concat("../packages/sdk/src/deployments/", vm.toString(block.chainid), ".json");
        if (!vm.exists(path)) return address(0);

        string memory json = vm.readFile(path);
        if (!vm.keyExistsJson(json, ".contracts.AsseteraPrimarySales")) return address(0);
        return vm.parseJsonAddress(json, ".contracts.AsseteraPrimarySales");
    }
}
