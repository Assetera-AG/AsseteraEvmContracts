// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AsseteraPrimarySales} from "../../../src/primary/AsseteraPrimarySales.sol";
import {PrimaryTypes} from "../../../src/primary/types/PrimaryTypes.sol";
import {ISettler} from "../../../src/primary/interfaces/ISettler.sol";
import {IIntentGate} from "../../../src/primary/interfaces/IIntentGate.sol";
import {AsseteraIssuanceVenue} from "../../../src/primary/sale/AsseteraIssuanceVenue.sol";
import {IAsseteraIssuanceVenue} from "../../../src/primary/sale/IAsseteraIssuanceVenue.sol";
import {FaucetToken} from "../../mocks/FaucetToken.sol";
import {IssuerAssetToken} from "./mocks/IssuanceVenueMocks.sol";
import {GateTypes} from "../../../src/types/GateTypes.sol";
import {PrimarySalesTestBase} from "../PrimarySalesTestBase.sol";

/// @title IssuanceVenueRouterE2ETest
/// @notice 🔴 **The acceptance criterion for this whole packet**: one real primary sale, end to
///         end, through the real `AsseteraPrimarySales` proxy — mUSDC in, mRWA minted out.
///
///         Nothing here is stubbed. The router is the deployed contract with its real gates, its
///         real caps module and its real venue settler. Four signatures are produced and
///         verified (compliance, fee, settlement operator, buyer), three nonces are burned, the
///         per-transaction settlement cap is charged, the buyer's exact allowance is pulled, the
///         venue is called with calldata bound by hash and selector, the fee goes to an
///         allowlisted collector and the router asserts its own measured balance deltas
///         afterwards. The venue under test is the per-token sale contract, and to the router it
///         is an address in a signed intent like Dinari would be.
///
/// @dev    **The numbers, so a failure is legible.** The offering is priced at 12.50 mUSDC per
///         whole mRWA. A buyer pays a 1 000 mUSDC quote plus a 50 bps fee of 5 mUSDC, so 1 005
///         mUSDC leaves the buyer, 1 000 reaches the sale contract, 5 reach the collector and
///         80 mRWA are minted to the buyer. Every one of those is asserted against a literal.
///
///         ⚠️ **The venue is deployed with the ROUTER PROXY as its one caller**, which is the
///         production arrangement: the venue trusts the proxy address, not an implementation and
///         not an EOA. That is also what makes the router's address immutable on the venue a
///         redeploy question rather than a configuration one.
contract IssuanceVenueRouterE2ETest is PrimarySalesTestBase {
    AsseteraPrimarySales internal live;
    AsseteraIssuanceVenue internal saleVenue;
    FaucetToken internal usdc;
    IssuerAssetToken internal rwa;

    address internal issuer = makeAddr("issuer");
    address internal rateSetter = makeAddr("rateSetter");
    address internal venuePauser = makeAddr("venuePauser");

    /// 12.50 mUSDC buys one whole mRWA.
    uint256 internal constant PRICE = 12_500_000;
    /// The venue's firm quote for this settlement: 1 000 mUSDC.
    uint256 internal constant QUOTE = 1_000e6;
    /// 50 bps of the quote, which divides exactly.
    uint16 internal constant TAKER_BPS = 50;
    uint256 internal constant FEE = 5e6;
    /// 1 000 mUSDC at 12.50 a token is exactly 80 whole mRWA.
    uint256 internal constant MIN_OUT = 80e18;

    function setUp() public virtual override {
        super.setUp();

        usdc = new FaucetToken("Mock USD Coin", "mUSDC", 6);
        rwa = new IssuerAssetToken("Mock Tokenised RWA", "mRWA", issuer);

        // The real router, freshly deployed, not a harness.
        AsseteraPrimarySales impl = new AsseteraPrimarySales(address(forwarder));
        bytes memory initData =
            abi.encodeCall(AsseteraPrimarySales.initialize, (admin, kycSigner, feeSigner, settlementSigner));
        live = AsseteraPrimarySales(address(new ERC1967Proxy(address(impl), initData)));

        saleVenue = new AsseteraIssuanceVenue(
            IAsseteraIssuanceVenue.SaleConfig({
                admin: admin,
                rateSetter: rateSetter,
                pauser: venuePauser,
                treasurer: issuer,
                router: address(live),
                settlementToken: address(usdc),
                assetToken: address(rwa),
                unitPrice: PRICE,
                minUnitPrice: 10_000,
                maxUnitPrice: 10_000_000_000,
                maxSettlementPerPurchaseWholeUnits: 100_000
            })
        );

        // The ISSUER grants the minting right — to the sale contract, never to the router.
        bytes32 minter = rwa.MINTER_ROLE();
        vm.prank(issuer);
        rwa.grantRole(minter, address(saleVenue));

        // The two post-deploy admin steps on the router. Without the cap the currency cannot be
        // settled in at all, which is the intended fail-closed default and not a bug to route
        // around.
        vm.startPrank(admin);
        live.setAllowedCollector(collector, true);
        live.setSettlementCap(address(usdc), 100_000);
        vm.stopPrank();

        usdc.mint(buyer, 10_000e6);
    }

    // ── fixtures ──────────────────────────────────────────────────────────────────────────

    /// The opaque bytes the router hands the venue. The router never interprets them; it compares
    /// their hash and their first four bytes against the signed intent and nothing else.
    function _calldataFor(address to, uint256 spend, uint256 floor) internal pure returns (bytes memory) {
        return abi.encodeCall(AsseteraIssuanceVenue.purchase, (to, spend, floor));
    }

    function _intentFor(bytes memory venueCalldata, uint256 quote, uint256 buyerFee, uint256 minOut)
        internal
        view
        returns (PrimaryTypes.SettlementIntent memory)
    {
        return PrimaryTypes.SettlementIntent({
            buyer: buyer,
            assetToken: address(rwa),
            accountingMode: uint8(PrimaryTypes.AssetAccountingMode.Erc20Balance),
            minAssetOut: minOut,
            settlementToken: address(usdc),
            venueQuoteIn: quote,
            buyerFee: buyerFee,
            maxSettlementIn: quote + buyerFee,
            feeCollector: collector,
            venue: address(saleVenue),
            selector: AsseteraIssuanceVenue.purchase.selector,
            calldataHash: keccak256(venueCalldata),
            supplierReference: keccak256("offering:series-a:order:1"),
            nonce: INTENT_NONCE,
            deadline: block.timestamp + 3 minutes
        });
    }

    /// The default settlement: buy 80 mRWA for 1 000 mUSDC plus a 5 mUSDC fee.
    function _standard() internal view returns (bytes memory data, PrimaryTypes.SettlementIntent memory intent) {
        data = _calldataFor(buyer, QUOTE, MIN_OUT);
        intent = _intentFor(data, QUOTE, FEE, MIN_OUT);
    }

    /// The buyer's allowance to the ROUTER, exact for one settlement. Never unlimited: it is the
    /// structural ceiling on what a compromised settlement signer can move.
    function _approveRouter(PrimaryTypes.SettlementIntent memory intent) internal {
        vm.prank(buyer);
        usdc.approve(address(live), intent.venueQuoteIn + intent.buyerFee);
    }

    function _submit(bytes memory data, PrimaryTypes.SettlementIntent memory intent) internal {
        bytes32 paramsHash = _paramsHash(intent);
        vm.prank(buyer);
        live.settlePrimary(
            data,
            intent,
            _signIntent(address(live), intent),
            _signBuyerConsent(address(live), intent),
            _kyc(address(live), paramsHash),
            _fee(address(live), paramsHash, 0, TAKER_BPS, intent.feeCollector, address(usdc))
        );
    }

    /// The same, with all three nonces shifted, so one buyer can settle twice.
    ///
    /// ⚠️ The shared base pins one nonce per namespace, which is right for a suite that settles
    /// once. Three independent single-use counters mean a second settlement needs three fresh
    /// numbers, so the attestations are rebuilt here rather than by mutating the base's
    /// constants — the digests have to be re-signed either way.
    function _submitWithNonceOffset(bytes memory data, PrimaryTypes.SettlementIntent memory intent, uint256 offset)
        internal
    {
        intent.nonce = INTENT_NONCE + offset;
        bytes32 paramsHash = _paramsHash(intent);
        uint256 deadline = block.timestamp + 3 minutes;

        GateTypes.KycAttestation memory kyc = GateTypes.KycAttestation({
            account: buyer,
            action: uint8(PrimaryTypes.Action.SettleVenue),
            orderId: 0,
            nonce: KYC_NONCE + offset,
            deadline: deadline,
            paramsHash: paramsHash,
            signature: ""
        });
        kyc.signature = _sign(
            kycSignerPk,
            _digest(
                PRIMARY_DOMAIN_NAME,
                address(live),
                keccak256(abi.encode(KYC_TYPEHASH, buyer, kyc.action, uint256(0), kyc.nonce, deadline, paramsHash))
            )
        );

        GateTypes.FeeAttestation memory fee = GateTypes.FeeAttestation({
            account: buyer,
            action: uint8(PrimaryTypes.Action.SettleVenue),
            nonce: FEE_NONCE + offset,
            deadline: deadline,
            paramsHash: paramsHash,
            makerFeeBps: 0,
            takerFeeBps: TAKER_BPS,
            feeCollector: intent.feeCollector,
            feeToken: address(usdc),
            signature: ""
        });
        fee.signature = _sign(
            feeSignerPk,
            _digest(
                PRIMARY_DOMAIN_NAME,
                address(live),
                keccak256(
                    abi.encode(
                        FEE_TYPEHASH,
                        buyer,
                        fee.action,
                        fee.nonce,
                        deadline,
                        paramsHash,
                        uint16(0),
                        TAKER_BPS,
                        fee.feeCollector,
                        address(usdc)
                    )
                )
            )
        );

        vm.prank(buyer);
        live.settlePrimary(
            data, intent, _signIntent(address(live), intent), _signBuyerConsent(address(live), intent), kyc, fee
        );
    }

    // ── the acceptance criterion ──────────────────────────────────────────────────────────

    /// 🔴 One primary sale, end to end. Every number is a literal.
    function test_E2E_MintsRwaAgainstUsdcThroughTheRouter() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _standard();
        _approveRouter(intent);

        uint256 buyerUsdcBefore = usdc.balanceOf(buyer);

        _submit(data, intent);

        // The buyer
        assertEq(buyerUsdcBefore - usdc.balanceOf(buyer), 1_005e6, "the buyer paid the quote plus the fee");
        assertEq(rwa.balanceOf(buyer), 80e18, "and received eighty whole mRWA");

        // The offering
        assertEq(usdc.balanceOf(address(saleVenue)), 1_000e6, "the sale contract kept the quote");
        assertEq(rwa.totalSupply(), 80e18, "and minted nothing beyond the sale");

        // Us
        assertEq(usdc.balanceOf(collector), 5e6, "the fee reached the allowlisted collector");

        // 🔴 The router's invariants: no standing balance, no standing approval, on either token.
        assertEq(usdc.balanceOf(address(live)), 0, "the router holds no settlement currency");
        assertEq(rwa.balanceOf(address(live)), 0, "and no asset");
        assertEq(usdc.allowance(address(live), address(saleVenue)), 0, "and left no approval behind");
        assertEq(usdc.allowance(buyer, address(live)), 0, "the buyer's exact allowance was fully consumed");
    }

    /// 🔴 The router's own event, built from what it MEASURED. This is the leg the indexer and
    /// the activity ledger read, and it must be right without any knowledge of the venue.
    function test_E2E_TheRouterReportsWhatItMeasured() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _standard();
        _approveRouter(intent);

        vm.expectEmit(true, true, true, true, address(live));
        emit ISettler.PrimarySettled(
            buyer,
            address(rwa),
            address(saleVenue),
            80e18, // assetDelivered, measured on the buyer
            address(usdc),
            1_000e6, // venueIn, measured as the sale contract's consumption
            0, // refund: this venue consumes the whole quote in this decimals configuration
            5e6, // fee
            collector,
            intent.supplierReference,
            INTENT_NONCE
        );

        _submit(data, intent);
    }

    /// 🔴 And the venue's own event, from the other side of the same transaction. The two join on
    /// the transaction hash and must agree about the money.
    function test_E2E_TheVenueReportsTheSameMoney() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _standard();
        _approveRouter(intent);

        vm.expectEmit(true, true, true, true, address(saleVenue));
        emit IAsseteraIssuanceVenue.IssuanceMinted(buyer, address(rwa), 80e18, address(usdc), 1_000e6, PRICE);

        _submit(data, intent);
    }

    /// The proceeds are the issuer's, and the way they leave is the treasury role.
    function test_E2E_TheIssuerWithdrawsTheProceeds() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _standard();
        _approveRouter(intent);
        _submit(data, intent);

        vm.prank(issuer);
        saleVenue.withdraw(issuer, 1_000e6);

        assertEq(usdc.balanceOf(issuer), 1_000e6, "the issuer has the round's proceeds");
        assertEq(usdc.balanceOf(address(saleVenue)), 0, "and the venue is empty");
    }

    // ── what the arrangement is FOR ───────────────────────────────────────────────────────

    /// 🔴 **The security property the whole arrangement rests on: the price is enforced by a
    /// contract, not by a signature.**
    ///
    /// Every field of the intent belongs to the settlement operator, the delivery floor included,
    /// so a compromised operator can make `minAssetOut` vacuous and the router's delivery
    /// assertion along with it. This test writes exactly that intent — a full-sized quote with a
    /// floor of one wei — and asserts the buyer receives the FULL priced quantity anyway. The
    /// venue never consults the floor when deciding what to mint; it consults the price the
    /// compliance officers set. There is no field of the intent that turns 1 000 mUSDC into less
    /// than eighty mRWA.
    function test_E2E_AVacuousDeliveryFloorStillFillsAtThePrice() public {
        bytes memory data = _calldataFor(buyer, QUOTE, 1);
        PrimaryTypes.SettlementIntent memory intent = _intentFor(data, QUOTE, FEE, 1);
        _approveRouter(intent);

        _submit(data, intent);

        assertEq(rwa.balanceOf(buyer), 80e18, "priced by the venue, not by the signed floor");
        assertEq(usdc.balanceOf(address(saleVenue)), 1_000e6, "and paid for in full");
    }

    /// 🔴 The other half: the signer cannot mint WITHOUT paying. The smallest settlement the
    /// gates will carry — one raw unit of mUSDC, since `IntentGate` refuses a zero quote and a
    /// zero floor outright — buys exactly one raw unit's worth and not a wei more.
    function test_E2E_ASignerWhoUnderpaysGetsOnlyWhatTheyPaidFor() public {
        bytes memory data = _calldataFor(buyer, 1, 1);
        PrimaryTypes.SettlementIntent memory intent = _intentFor(data, 1, 0, 1);
        vm.prank(buyer);
        usdc.approve(address(live), 1);

        _submit(data, intent);

        // One raw mUSDC unit at 12.50 a token is 8e10 wei of mRWA — 0.00000008 tokens.
        assertEq(rwa.balanceOf(buyer), 8e10, "priced, not granted");
        assertEq(rwa.totalSupply(), 8e10, "and that is the entire issuance");
        assertEq(usdc.balanceOf(address(saleVenue)), 1, "paid for, to the raw unit");
    }

    /// The mirror of the same property from the buyer's side: calldata that mints to somebody
    /// other than the signed buyer passes the venue, and is then refused by the ROUTER, whose
    /// delivery assertion is made on the buyer named in four signatures.
    function test_E2E_CalldataThatDeliversElsewhereIsRefusedByTheRouter() public {
        bytes memory data = _calldataFor(stranger, QUOTE, MIN_OUT);
        PrimaryTypes.SettlementIntent memory intent = _intentFor(data, QUOTE, FEE, MIN_OUT);
        _approveRouter(intent);

        vm.expectRevert(abi.encodeWithSelector(ISettler.InsufficientAssetDelivered.selector, 0, MIN_OUT));
        _submit(data, intent);

        assertEq(rwa.totalSupply(), 0, "the whole transaction reverted, so nothing was minted");
    }

    // ── the two contracts failing together ────────────────────────────────────────────────

    /// A repricing between the intent being signed and the transaction landing: the venue refuses
    /// at its own floor, and the router turns that into one deterministic error.
    function test_E2E_ARepricingAgainstTheBuyerRevertsTheSettlement() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _standard();
        _approveRouter(intent);

        vm.prank(rateSetter);
        saleVenue.setUnitPrice(PRICE * 2);

        vm.expectRevert(ISettler.VenueCallFailed.selector);
        _submit(data, intent);

        assertEq(usdc.balanceOf(buyer), 10_000e6, "the buyer paid nothing");
        assertEq(rwa.totalSupply(), 0, "and nothing was minted");
    }

    /// 🔴 The venue's pause is an independent lever from the router's. Pausing the offering stops
    /// its sales without touching any other offering or the router itself.
    function test_E2E_PausingTheVenueStopsThatOfferingOnly() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _standard();
        _approveRouter(intent);

        vm.prank(venuePauser);
        saleVenue.pause();

        vm.expectRevert(ISettler.VenueCallFailed.selector);
        _submit(data, intent);

        assertFalse(live.paused(), "the router is untouched");

        vm.prank(admin);
        saleVenue.unpause();
        _submit(data, intent);
        assertEq(rwa.balanceOf(buyer), 80e18, "and the sale resumes");
    }

    /// The venue closed by its own cap is refused the same way, which matters because the two
    /// caps are independent: the router's is per settlement currency across every venue, the
    /// venue's is per purchase within one offering.
    function test_E2E_ClosingTheVenuesCapStopsItsSales() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _standard();
        _approveRouter(intent);

        vm.prank(admin);
        saleVenue.setMaxSettlementPerPurchase(0);

        vm.expectRevert(ISettler.VenueCallFailed.selector);
        _submit(data, intent);
    }

    /// One intent, one settlement. The nonce is burned before the venue is ever called, so a
    /// replay cannot reach the money path at all.
    function test_E2E_AnIntentCannotBeReplayed() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _standard();
        _approveRouter(intent);
        _submit(data, intent);

        _approveRouter(intent);
        vm.expectRevert(abi.encodeWithSelector(IIntentGate.IntentNonceUsed.selector, buyer, INTENT_NONCE));
        _submit(data, intent);

        assertEq(rwa.balanceOf(buyer), 80e18, "one settlement, one delivery");
    }

    /// 🔴 Nobody but the router can reach the venue, even with a perfectly good payment. This is
    /// what makes the router's KYC and fee gates unavoidable: there is no second door into the
    /// offering.
    function test_E2E_TheVenueCannotBeBoughtFromDirectly() public {
        usdc.mint(stranger, QUOTE);
        vm.prank(stranger);
        usdc.approve(address(saleVenue), QUOTE);

        vm.expectRevert(abi.encodeWithSelector(IAsseteraIssuanceVenue.CallerNotRouter.selector, stranger));
        vm.prank(stranger);
        saleVenue.purchase(stranger, QUOTE, MIN_OUT);
    }

    /// Two settlements in a row: the proceeds accumulate in the venue and the router still ends
    /// each one holding nothing.
    function test_E2E_TwoSettlementsAccumulateInTheVenue() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _standard();
        _approveRouter(intent);
        _submit(data, intent);

        _approveRouter(intent);
        _submitWithNonceOffset(data, intent, 10);

        assertEq(usdc.balanceOf(address(saleVenue)), 2_000e6, "both quotes are held by the offering");
        assertEq(usdc.balanceOf(collector), 10e6, "both fees reached the collector");
        assertEq(rwa.balanceOf(buyer), 160e18, "and the buyer holds both fills");
        assertEq(usdc.balanceOf(address(live)), 0, "the router still holds nothing");
    }

    /// A gasless primary sale: the buyer signs a `ForwardRequest` and a relayer pays. The venue
    /// is unaffected — it only ever sees the router as its caller — which is the point of the
    /// identity resolution living entirely in the router.
    function test_E2E_WorksGaslesslyThroughTheForwarder() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) = _standard();
        _approveRouter(intent);
        bytes32 paramsHash = _paramsHash(intent);

        _relay(
            buyerPk,
            buyer,
            address(live),
            abi.encodeCall(
                AsseteraPrimarySales.settlePrimary,
                (
                    data,
                    intent,
                    _signIntent(address(live), intent),
                    _signBuyerConsent(address(live), intent),
                    _kyc(address(live), paramsHash),
                    _fee(address(live), paramsHash, 0, TAKER_BPS, intent.feeCollector, address(usdc))
                )
            )
        );

        assertEq(rwa.balanceOf(buyer), 80e18, "the buyer received the asset");
        assertEq(IERC20(address(usdc)).balanceOf(relayer), 0, "and the relayer touched no money");
    }
}
