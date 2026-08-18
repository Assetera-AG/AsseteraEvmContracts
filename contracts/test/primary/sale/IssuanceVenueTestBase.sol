// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AsseteraIssuanceVenue} from "../../../src/primary/sale/AsseteraIssuanceVenue.sol";
import {IAsseteraIssuanceVenue} from "../../../src/primary/sale/IAsseteraIssuanceVenue.sol";
import {FaucetToken} from "../../mocks/FaucetToken.sol";
import {IssuerAssetToken} from "./mocks/IssuanceVenueMocks.sol";

/// @title IssuanceVenueTestBase
/// @notice The fixture every `AsseteraIssuanceVenue` suite builds on: the real pair this contract
///         exists for — a six-decimal settlement currency and an eighteen-decimal asset — a venue
///         priced in that currency, and the issuer's grant of the minting right.
///
///         **The router is an EOA here, on purpose.** The unit and adversarial suites are about
///         the venue's own economics, and driving them through a real
///         `AsseteraPrimarySales` settlement would mean four signatures and three nonces standing
///         between the test and the line it is asserting. The real router is used where it is the
///         subject rather than the scaffolding: `IssuanceVenueRouterE2E.t.sol`.
///
/// @dev    ⚠️ **The numbers here are the worked example from the contract's own units table**, and
///         they are chosen so that a decimals bug cannot pass unnoticed: the price is 12.50 mUSDC
///         per whole mRWA, so 125 mUSDC must buy exactly 10 mRWA. Get the scaling wrong in either
///         direction and the answer is out by six or eighteen orders of magnitude, not by a
///         rounding step.
abstract contract IssuanceVenueTestBase is Test {
    AsseteraIssuanceVenue internal venue;
    FaucetToken internal currency;
    IssuerAssetToken internal asset;

    address internal admin = makeAddr("admin");
    address internal rateSetter = makeAddr("rateSetter");
    address internal pauser = makeAddr("pauser");
    address internal treasurer = makeAddr("treasurer");
    address internal issuer = makeAddr("issuer");
    address internal router = makeAddr("router");
    address internal buyer = makeAddr("buyer");
    address internal stranger = makeAddr("stranger");

    /// 12.50 mUSDC buys one whole mRWA. Six decimals, so twelve and a half million raw units.
    uint256 internal constant UNIT_PRICE = 12_500_000;
    /// One euro-cent, the smallest price the offering may ever carry.
    uint256 internal constant MIN_UNIT_PRICE = 10_000;
    /// Ten thousand mUSDC per token, the highest.
    uint256 internal constant MAX_UNIT_PRICE = 10_000_000_000;
    /// The per-purchase cap, in whole mUSDC. Far above any test's purchase, so a test that fails
    /// on the cap has failed for the reason it names.
    uint256 internal constant CAP_WHOLE = 100_000;

    /// 125 mUSDC — the worked example. At `UNIT_PRICE` it buys exactly ten whole mRWA.
    uint256 internal constant SPEND = 125_000_000;
    /// The ten mRWA that must come back. Written as `10e18` rather than as an expression over
    /// `SPEND` and `UNIT_PRICE`, so the assertion is independent of the arithmetic under test.
    uint256 internal constant EXPECT_OUT = 10e18;

    function setUp() public virtual {
        currency = new FaucetToken("Mock USD Coin", "mUSDC", 6);
        asset = new IssuerAssetToken("Mock Tokenised RWA", "mRWA", issuer);

        venue = new AsseteraIssuanceVenue(_config());

        // The ISSUER grants the minting right, not us and not the router. This one line is the
        // whole custody story of the design: the router never holds it, we never hold it, and the
        // venue holds it only for as long as the issuer leaves it there.
        //
        // ⚠️ The role constant is read into a local FIRST. `vm.prank` applies to the next call
        // only, and `asset.MINTER_ROLE()` is a call — inlining it silently spends the prank and
        // sends `grantRole` from the test contract, which has no admin role.
        bytes32 minter = asset.MINTER_ROLE();
        vm.prank(issuer);
        asset.grantRole(minter, address(venue));

        // The router is funded and approves per call in the real flow; here it holds a float and
        // an exact allowance is set by `_approveExact`, so a test that starts needing more than
        // it asked for fails rather than passing on a standing grant.
        currency.mint(router, 1_000_000e6);
    }

    /// The deployment configuration under test. Overridable in one place so a suite can vary a
    /// single field without restating eleven.
    function _config() internal view virtual returns (IAsseteraIssuanceVenue.SaleConfig memory) {
        return IAsseteraIssuanceVenue.SaleConfig({
            admin: admin,
            rateSetter: rateSetter,
            pauser: pauser,
            treasurer: treasurer,
            router: router,
            settlementToken: address(currency),
            assetToken: address(asset),
            unitPrice: UNIT_PRICE,
            minUnitPrice: MIN_UNIT_PRICE,
            maxUnitPrice: MAX_UNIT_PRICE,
            maxSettlementPerPurchaseWholeUnits: CAP_WHOLE
        });
    }

    // ── calls ─────────────────────────────────────────────────────────────────────────────

    /// Approve exactly one purchase's worth and no more. Exact rather than unlimited for the same
    /// reason the router's own suite does it: every test here would pass with an unlimited
    /// allowance, so an exact one is the only way the suite notices if the venue ever starts
    /// taking more than it was offered.
    function _approveExact(uint256 amount) internal {
        vm.prank(router);
        currency.approve(address(venue), amount);
    }

    /// The whole happy path: approve, then buy as the router.
    function _purchase(uint256 settlementIn, uint256 minAssetOut)
        internal
        returns (uint256 assetMinted, uint256 settlementCharged)
    {
        _approveExact(settlementIn);
        vm.prank(router);
        return venue.purchase(buyer, settlementIn, minAssetOut);
    }

    /// Buy without touching the allowance, so allowance behaviour can be varied and so
    /// `vm.expectRevert` lands on the purchase rather than on an `approve`.
    function _purchaseNoApprove(uint256 settlementIn, uint256 minAssetOut) internal {
        vm.prank(router);
        venue.purchase(buyer, settlementIn, minAssetOut);
    }

    /// The venue's settlement-currency balance — the offering's accumulated proceeds.
    function _proceeds() internal view returns (uint256) {
        return IERC20(address(currency)).balanceOf(address(venue));
    }
}
