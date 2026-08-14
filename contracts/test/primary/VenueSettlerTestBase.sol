// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AsseteraPrimarySales} from "../../src/primary/AsseteraPrimarySales.sol";
import {PrimaryTypes} from "../../src/primary/types/PrimaryTypes.sol";
import {FaucetToken} from "../mocks/FaucetToken.sol";
import {DinariLikeVenue} from "../mocks/DinariLikeVenue.sol";
import {CappedPrimarySalesHarness} from "./mocks/CappedPrimarySalesHarness.sol";
import {PrimarySalesTestBase} from "./PrimarySalesTestBase.sol";

/// @title VenueSettlerTestBase
/// @notice The fixture `VenueSettler` needs and `PrimarySalesTestBase` deliberately does not
///         have:
///         two REAL ERC-20s and a real venue. The shared base uses codeless placeholder
///         addresses because the skeleton packet never reached a transfer; the venue suites are
///         nothing but transfers.
///
/// @dev    A THIRD proxy, alongside the base's `sales` and `harness`. It runs the real
///         `VenueSettler` with a mock `ISettlementLimits` behind it, so nothing here waits on
///         AO-517. Every signing helper comes from the shared base — this file adds fixtures,
///         not a second harness.
///
///         ⚠️ Extracted from `VenueSettler.t.sol` so that the adversarial suites (AO-551) build
///         on the SAME fixture the happy-path suites do rather than on a second copy of it. A
///         hostile-behaviour test whose fixture had drifted from the one the happy path uses
///         would be proving something about its own fixture. `VenueSettlerHostile.t.sol` and
///         `PrimarySalesAdversarial.t.sol` extend this file; the money path they attack is the
///         one `VenueSettler.t.sol` shows working.
abstract contract VenueSettlerTestBase is PrimarySalesTestBase {
    CappedPrimarySalesHarness internal router;
    FaucetToken internal currency;
    FaucetToken internal asset;
    DinariLikeVenue internal venue;

    /// A USDC-shaped quote: six decimals, so a fee that does not divide exactly is reachable
    /// with realistic numbers rather than only with wei-sized ones.
    uint256 internal constant QUOTE = 1_000e6;
    /// 50 bps of `QUOTE`, which divides exactly. The rounding policy is pinned separately.
    uint256 internal constant FEE = 5e6;
    uint16 internal constant TAKER_BPS = 50;
    uint256 internal constant MAX_IN_VENUE = QUOTE + FEE;
    uint256 internal constant MIN_OUT = 40e18;
    /// What the venue delivers on the happy path — comfortably above the floor, so a test that
    /// fails on delivery has failed for the reason it names.
    uint256 internal constant ASSET_OUT = 41e18;

    function setUp() public virtual override {
        super.setUp();

        currency = new FaucetToken("Mock USD Coin", "mUSDC", 6);
        asset = new FaucetToken("Mock Tokenised Equity", "mEQ", 18);
        venue = new DinariLikeVenue();

        CappedPrimarySalesHarness impl = new CappedPrimarySalesHarness(address(forwarder));
        bytes memory initData =
            abi.encodeCall(AsseteraPrimarySales.initialize, (admin, kycSigner, feeSigner, settlementSigner));
        router = CappedPrimarySalesHarness(address(new ERC1967Proxy(address(impl), initData)));

        vm.prank(admin);
        router.setAllowedCollector(collector, true);

        currency.mint(buyer, 10_000e6);
    }

    // ── fixtures ──────────────────────────────────────────────────────────────────────────

    /// The opaque bytes the venue is handed. The router never interprets them; only their hash
    /// and first four bytes are ever compared to anything.
    function _venueCalldata(uint256 paymentAmount, uint256 assetAmount) internal view returns (bytes memory) {
        return abi.encodeCall(
            DinariLikeVenue.requestOrder,
            (DinariLikeVenue.Order({
                    paymentToken: address(currency),
                    paymentAmount: paymentAmount,
                    assetToken: address(asset),
                    assetAmount: assetAmount,
                    recipient: buyer
                }))
        );
    }

    /// A settlement intent over the real fixtures, with every amount overridable so a single
    /// helper covers the happy path and every revert.
    function _venueIntent(bytes memory venueCalldata, uint256 quote, uint256 buyerFee, address feeCollector)
        internal
        view
        returns (PrimaryTypes.SettlementIntent memory)
    {
        return PrimaryTypes.SettlementIntent({
            buyer: buyer,
            assetToken: address(asset),
            minAssetOut: MIN_OUT,
            settlementToken: address(currency),
            venueQuoteIn: quote,
            buyerFee: buyerFee,
            maxSettlementIn: quote + buyerFee,
            feeCollector: feeCollector,
            venue: address(venue),
            selector: DinariLikeVenue.requestOrder.selector,
            calldataHash: keccak256(venueCalldata),
            supplierReference: SUPPLIER_REF,
            nonce: INTENT_NONCE,
            deadline: block.timestamp + 3 minutes
        });
    }

    /// The default intent: the venue consumes the whole quote and delivers above the floor.
    function _happyPath() internal view returns (bytes memory data, PrimaryTypes.SettlementIntent memory intent) {
        data = _venueCalldata(QUOTE, ASSET_OUT);
        intent = _venueIntent(data, QUOTE, FEE, collector);
    }

    // ── calls ─────────────────────────────────────────────────────────────────────────────

    /// Approve exactly this settlement's debit and submit it. The approval is EXACT on purpose:
    /// every test in this file would still pass with an unlimited one, so an exact grant is the
    /// only way the suite notices if the settler ever starts needing more than it was signed
    /// for.
    function _settleVenueWith(bytes memory data, PrimaryTypes.SettlementIntent memory intent, uint16 takerBps)
        internal
    {
        _approveExact(intent);
        _submit(data, intent, takerBps);
    }

    /// The buyer's allowance for exactly one settlement and no more. Split out of
    /// `_settleVenueWith` because `vm.expectRevert` and `vm.expectEmit` apply to the NEXT call,
    /// and the `approve` must not be the call they land on.
    function _approveExact(PrimaryTypes.SettlementIntent memory intent) internal {
        _approveExactTo(address(router), intent);
    }

    /// The same, against a router other than the mock-capped one.
    function _approveExactTo(address spender, PrimaryTypes.SettlementIntent memory intent) internal {
        vm.prank(buyer);
        currency.approve(spender, intent.venueQuoteIn + intent.buyerFee);
    }

    /// Submit without touching the buyer's allowance, so allowance behaviour can be varied.
    function _submit(bytes memory data, PrimaryTypes.SettlementIntent memory intent, uint16 takerBps) internal {
        _submitTo(AsseteraPrimarySales(address(router)), data, intent, takerBps);
    }

    /// The same, against a router other than the mock-capped one. Every payload is signed for
    /// `target`, because the EIP-712 verifying contract is part of each digest — a settlement
    /// assembled for one proxy is refused by another by construction.
    function _submitTo(
        AsseteraPrimarySales target,
        bytes memory data,
        PrimaryTypes.SettlementIntent memory intent,
        uint16 takerBps
    ) internal {
        bytes32 paramsHash = _paramsHash(intent);
        vm.prank(buyer);
        target.settlePrimary(
            data,
            intent,
            _signIntent(address(target), intent),
            _signBuyerConsent(address(target), intent),
            _kyc(address(target), paramsHash),
            _fee(address(target), paramsHash, 0, takerBps, intent.feeCollector, address(currency))
        );
    }
}
