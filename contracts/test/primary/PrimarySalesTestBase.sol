// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {AsseteraPrimarySales} from "../../src/primary/AsseteraPrimarySales.sol";
import {PrimaryTypes} from "../../src/primary/types/PrimaryTypes.sol";
import {GateTypes} from "../../src/types/GateTypes.sol";
import {ISettlementLimits} from "../../src/primary/interfaces/ISettlementLimits.sol";
import {PrimarySalesHarness} from "./mocks/PrimarySalesHarness.sol";

/// @title PrimarySalesTestBase
/// @notice Fixtures and signing helpers shared by the primary-sale test contracts.
///
///         Two proxies are deployed on purpose:
///           * `sales` — the real `AsseteraPrimarySales`, in a settlement currency no admin has
///             ever sized. Everything up to the money path is exercised against this one, which
///             is then stopped by the caps module at the first line that would move anything.
///           * `harness` — the same contract with the settlement seam stubbed from outside
///             `src/`, so the three nonce burns and the settlement event, which live AFTER the
///             seam, can be observed without moving tokens.
///
/// @dev    ⚠️ Every struct LITERAL below names the contract that DECLARES the type
///         (`GateTypes.KycAttestation({…})`, `PrimaryTypes.SettlementIntent({…})`).
///         Inheritance carries a nested type into TYPE position only; in EXPRESSION position
///         Solidity resolves `Contract.Type` solely against the contract that declares it.
abstract contract PrimarySalesTestBase is Test {
    AsseteraPrimarySales internal sales;
    PrimarySalesHarness internal harness;
    ERC2771Forwarder internal forwarder;

    address internal admin = makeAddr("admin");
    address internal collector = makeAddr("collector");
    address internal relayer = makeAddr("relayer");
    address internal stranger = makeAddr("stranger");

    uint256 internal kycSignerPk = 0xACE1;
    uint256 internal feeSignerPk = 0xFEE1;
    uint256 internal settlementSignerPk = 0x5E771E;
    uint256 internal buyerPk = 0xB0B;

    address internal kycSigner;
    address internal feeSigner;
    address internal settlementSigner;
    address internal buyer;

    /// The three tokens are plain addresses: this packet never moves a token, and a settlement
    /// reverts at the seam before any transfer would be attempted.
    address internal constant ASSET = address(0xA55E7);
    address internal constant CURRENCY = address(0xC0FFEE);
    address internal constant VENUE = address(0xE0E0);

    /// Opaque venue calldata. Its first four bytes are the signed `selector`; the rest is
    /// whatever the supplier's router wanted, which this contract never interprets.
    bytes internal constant VENUE_CALLDATA =
        hex"a9059cbb0000000000000000000000000000000000000000000000000000000000000001";
    bytes4 internal constant VENUE_SELECTOR = 0xa9059cbb;

    uint256 internal constant QUOTE_IN = 1_000e6;
    uint256 internal constant BUYER_FEE = 5e6;
    uint256 internal constant MAX_IN = 1_005e6;
    uint256 internal constant MIN_ASSET_OUT = 40e18;
    bytes32 internal constant SUPPLIER_REF = keccak256("dinari:quote:42");

    /// The per-transaction cap opened on the `harness` fixture, in WHOLE tokens. Comfortably
    /// above one settlement, so it never bites and never becomes the reason a test passes.
    uint256 internal constant HARNESS_CAP_WHOLE = 10_000;

    uint256 internal constant INTENT_NONCE = 1;
    uint256 internal constant KYC_NONCE = 2;
    uint256 internal constant FEE_NONCE = 3;

    string internal constant PRIMARY_DOMAIN_NAME = "AsseteraPrimarySales";
    string internal constant EXCHANGE_DOMAIN_NAME = "AsseteraExchange";

    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 internal constant KYC_TYPEHASH = keccak256(
        "KycAttestation(address account,uint8 action,uint256 orderId,uint256 nonce,uint256 deadline,bytes32 paramsHash)"
    );
    bytes32 internal constant FEE_TYPEHASH = keccak256(
        "FeeAttestation(address account,uint8 action,uint256 nonce,uint256 deadline,bytes32 paramsHash,uint16 makerFeeBps,uint16 takerFeeBps,address feeCollector,address feeToken)"
    );

    /// Restated here rather than read from `PrimaryTypes`, so that every digest these tests
    /// build is derived independently of the contract under test. `PrimaryIntentVectorsTest`
    /// is what proves the two agree, and that both equal the pinned literal.
    string internal constant INTENT_TYPE_STRING =
        "SettlementIntent(address buyer,address assetToken,uint8 accountingMode,uint256 minAssetOut,address settlementToken,uint256 venueQuoteIn,uint256 buyerFee,uint256 maxSettlementIn,address feeCollector,address venue,bytes4 selector,bytes32 calldataHash,bytes32 supplierReference,uint256 nonce,uint256 deadline)";
    bytes32 internal constant INTENT_TYPEHASH = keccak256(bytes(INTENT_TYPE_STRING));

    /// The sell-back leg's payload, restated here for the same reason: every digest
    /// these tests build must be derived independently of the contract under test.
    string internal constant REDEMPTION_TYPE_STRING =
        "RedemptionIntent(address seller,address assetToken,uint8 accountingMode,uint256 maxAssetIn,address settlementToken,uint256 venueQuoteOut,uint256 sellerFee,uint256 minSettlementOut,address feeCollector,address venue,bytes4 selector,bytes32 calldataHash,bytes32 supplierReference,uint256 nonce,uint256 deadline)";
    bytes32 internal constant REDEMPTION_TYPEHASH = keccak256(bytes(REDEMPTION_TYPE_STRING));

    /// The sell-back leg's amounts, mirroring the buy's. ⚠️ `SELLER_FEE` is 50 bps of
    /// `QUOTE_OUT` and is carved OUT of it, so the seller's floor is `QUOTE_OUT - SELLER_FEE`
    /// and never `QUOTE_OUT`.
    uint256 internal constant MAX_ASSET_IN = 41e18;
    uint256 internal constant QUOTE_OUT = 1_000e6;
    uint256 internal constant SELLER_FEE = 5e6;
    uint256 internal constant MIN_SETTLEMENT_OUT = 995e6;

    function setUp() public virtual {
        kycSigner = vm.addr(kycSignerPk);
        feeSigner = vm.addr(feeSignerPk);
        settlementSigner = vm.addr(settlementSignerPk);
        buyer = vm.addr(buyerPk);

        forwarder = new ERC2771Forwarder("AsseteraForwarder");

        bytes memory initData =
            abi.encodeCall(AsseteraPrimarySales.initialize, (admin, kycSigner, feeSigner, settlementSigner));

        AsseteraPrimarySales impl = new AsseteraPrimarySales(address(forwarder));
        sales = AsseteraPrimarySales(address(new ERC1967Proxy(address(impl), initData)));

        PrimarySalesHarness harnessImpl = new PrimarySalesHarness(address(forwarder));
        harness = PrimarySalesHarness(address(new ERC1967Proxy(address(harnessImpl), initData)));

        // `CURRENCY` needs code and a `decimals()` answer before a cap can be sized against it.
        // Both are mocked because this base moves no tokens; what it needs is an address the cap
        // setter will accept.
        _mockDecimals(CURRENCY, 6);

        vm.startPrank(admin);
        sales.setAllowedCollector(collector, true);
        harness.setAllowedCollector(collector, true);
        // ⚠️ The cap is opened on `harness` and DELIBERATELY NOT on `sales`. The per-transaction
        //    cap is charged by the shared preamble every settler family runs, so an uncapped
        //    currency stops a settlement before the family is reached — which is exactly what
        //    `_expectReachesTheMoneyPath` relies on for `sales`, and exactly what would stop the
        //    `harness` suites from ever observing what happens after the seam.
        harness.setSettlementCap(CURRENCY, HARNESS_CAP_WHOLE);
        vm.stopPrank();
    }

    /// Give an address code and a `decimals()` answer. Both are needed: `setSettlementCap`
    /// refuses an address with no code before it ever calls, which is what makes a plain EOA
    /// fail closed.
    function _mockDecimals(address token, uint8 d) internal {
        vm.etch(token, hex"00");
        vm.mockCall(token, abi.encodeWithSignature("decimals()"), abi.encode(d));
    }

    // ── intent ────────────────────────────────────────────────────────────────────────────

    /// A well-formed intent that passes every check the entry point makes.
    function _intent() internal view returns (PrimaryTypes.SettlementIntent memory) {
        return PrimaryTypes.SettlementIntent({
            buyer: buyer,
            assetToken: ASSET,
            // The default everywhere: an ordinary ERC-20, measured with `balanceOf` and moved
            // with `transfer`. Share-accounting tests override this to `RebasingShares`.
            accountingMode: uint8(PrimaryTypes.AssetAccountingMode.Erc20Balance),
            minAssetOut: MIN_ASSET_OUT,
            settlementToken: CURRENCY,
            venueQuoteIn: QUOTE_IN,
            buyerFee: BUYER_FEE,
            maxSettlementIn: MAX_IN,
            feeCollector: collector,
            venue: VENUE,
            selector: VENUE_SELECTOR,
            calldataHash: keccak256(VENUE_CALLDATA),
            supplierReference: SUPPLIER_REF,
            nonce: INTENT_NONCE,
            deadline: block.timestamp + 3 minutes
        });
    }

    function _paramsHash(PrimaryTypes.SettlementIntent memory intent) internal pure returns (bytes32) {
        return keccak256(abi.encode(INTENT_TYPEHASH, intent));
    }

    // ── redemption intent ─────────────────────────────────────────────────────────────────
    //
    // ⚠️ The seller is the SAME account as the buyer. This fixture has one customer, the two
    //    legs share one nonce namespace keyed on that account, and `_kycForAction` /
    //    `_feeForAction` already sign attestations for it — so a second address would only make
    //    the suites longer without making any of them say anything more.

    /// A well-formed redemption intent that passes every check the entry point makes.
    function _redemption() internal view returns (PrimaryTypes.RedemptionIntent memory) {
        return PrimaryTypes.RedemptionIntent({
            seller: buyer,
            assetToken: ASSET,
            accountingMode: uint8(PrimaryTypes.AssetAccountingMode.Erc20Balance),
            maxAssetIn: MAX_ASSET_IN,
            settlementToken: CURRENCY,
            venueQuoteOut: QUOTE_OUT,
            sellerFee: SELLER_FEE,
            minSettlementOut: MIN_SETTLEMENT_OUT,
            feeCollector: collector,
            venue: VENUE,
            selector: VENUE_SELECTOR,
            calldataHash: keccak256(VENUE_CALLDATA),
            supplierReference: SUPPLIER_REF,
            nonce: INTENT_NONCE,
            deadline: block.timestamp + 3 minutes
        });
    }

    function _paramsHash(PrimaryTypes.RedemptionIntent memory intent) internal pure returns (bytes32) {
        return keccak256(abi.encode(REDEMPTION_TYPEHASH, intent));
    }

    function _signRedemption(address target, PrimaryTypes.RedemptionIntent memory intent)
        internal
        view
        returns (bytes memory)
    {
        return _signRedemptionWith(settlementSignerPk, target, intent);
    }

    function _signRedemptionWith(uint256 pk, address target, PrimaryTypes.RedemptionIntent memory intent)
        internal
        view
        returns (bytes memory)
    {
        return _sign(pk, _digest(PRIMARY_DOMAIN_NAME, target, _paramsHash(intent)));
    }

    /// The SELLER's own signature over the same digest. A separate helper from
    /// `_signRedemption` for the reason `_signBuyerConsent` is: which party signed is the whole
    /// subject of the consent tests.
    function _signSellerConsent(address target, PrimaryTypes.RedemptionIntent memory intent)
        internal
        view
        returns (bytes memory)
    {
        return _signRedemptionWith(buyerPk, target, intent);
    }

    /// A KYC attestation for the sell-back action.
    function _kycRedeem(address target, bytes32 paramsHash) internal view returns (GateTypes.KycAttestation memory) {
        return _kycForAction(uint8(PrimaryTypes.Action.RedeemVenue), PRIMARY_DOMAIN_NAME, target, 0, paramsHash);
    }

    /// A fee attestation for the sell-back action, at the same 50 bps the buy fixture uses.
    function _feeRedeem(address target, bytes32 paramsHash) internal view returns (GateTypes.FeeAttestation memory) {
        return _feeForAction(uint8(PrimaryTypes.Action.RedeemVenue), target, paramsHash, 0, 50, collector, CURRENCY);
    }

    // ── digests ───────────────────────────────────────────────────────────────────────────

    function _domainSeparator(string memory name, address verifyingContract) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH, keccak256(bytes(name)), keccak256(bytes("1")), block.chainid, verifyingContract
            )
        );
    }

    function _digest(string memory name, address verifyingContract, bytes32 structHash)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(name, verifyingContract), structHash));
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ── signatures ────────────────────────────────────────────────────────────────────────

    function _signIntent(address target, PrimaryTypes.SettlementIntent memory intent)
        internal
        view
        returns (bytes memory)
    {
        return _signIntentWith(settlementSignerPk, target, intent);
    }

    function _signIntentWith(uint256 pk, address target, PrimaryTypes.SettlementIntent memory intent)
        internal
        view
        returns (bytes memory)
    {
        return _sign(pk, _digest(PRIMARY_DOMAIN_NAME, target, _paramsHash(intent)));
    }

    /// The buyer's own signature over the SAME digest the settlement operator signs. A separate
    /// helper from `_signIntent` even though the body is one call, because which PARTY signed is
    /// the whole subject of the buyer-consent tests and `_signIntentWith(buyerPk, …)` at a call
    /// site reads like a typo rather than like a claim.
    function _signBuyerConsent(address target, PrimaryTypes.SettlementIntent memory intent)
        internal
        view
        returns (bytes memory)
    {
        return _signIntentWith(buyerPk, target, intent);
    }

    /// A KYC attestation for the venue-settlement action, signed under `domainName` for
    /// `target`. `domainName` is a parameter so the cross-contract replay test can mint one
    /// under the EXCHANGE's domain and prove it is refused here.
    function _kyc(string memory domainName, address target, uint256 orderId, bytes32 paramsHash)
        internal
        view
        returns (GateTypes.KycAttestation memory)
    {
        return _kycForAction(uint8(PrimaryTypes.Action.SettleVenue), domainName, target, orderId, paramsHash);
    }

    /// The same, for an arbitrary action ordinal. Needed by the tests that drive a second caller
    /// of the shared preamble — the attestation carries the action and `_verifyKyc` compares it,
    /// so a call under another ordinal cannot reuse a `SettleVenue` attestation.
    function _kycForAction(uint8 action, string memory domainName, address target, uint256 orderId, bytes32 paramsHash)
        internal
        view
        returns (GateTypes.KycAttestation memory)
    {
        uint256 deadline = block.timestamp + 3 minutes;
        bytes32 structHash =
            keccak256(abi.encode(KYC_TYPEHASH, buyer, action, orderId, KYC_NONCE, deadline, paramsHash));
        return GateTypes.KycAttestation({
            account: buyer,
            action: action,
            orderId: orderId,
            nonce: KYC_NONCE,
            deadline: deadline,
            paramsHash: paramsHash,
            signature: _sign(kycSignerPk, _digest(domainName, target, structHash))
        });
    }

    function _kyc(address target, bytes32 paramsHash) internal view returns (GateTypes.KycAttestation memory) {
        return _kyc(PRIMARY_DOMAIN_NAME, target, 0, paramsHash);
    }

    function _fee(address target, bytes32 paramsHash) internal view returns (GateTypes.FeeAttestation memory) {
        return _fee(target, paramsHash, 0, 50, collector, CURRENCY);
    }

    function _fee(
        address target,
        bytes32 paramsHash,
        uint16 makerFeeBps,
        uint16 takerFeeBps,
        address feeCollector,
        address feeToken
    ) internal view returns (GateTypes.FeeAttestation memory) {
        return _feeForAction(
            uint8(PrimaryTypes.Action.SettleVenue), target, paramsHash, makerFeeBps, takerFeeBps, feeCollector, feeToken
        );
    }

    /// The same, for an arbitrary action ordinal. See `_kycForAction`.
    function _feeForAction(
        uint8 action,
        address target,
        bytes32 paramsHash,
        uint16 makerFeeBps,
        uint16 takerFeeBps,
        address feeCollector,
        address feeToken
    ) internal view returns (GateTypes.FeeAttestation memory) {
        uint256 deadline = block.timestamp + 3 minutes;
        bytes32 structHash = keccak256(
            abi.encode(
                FEE_TYPEHASH,
                buyer,
                action,
                FEE_NONCE,
                deadline,
                paramsHash,
                makerFeeBps,
                takerFeeBps,
                feeCollector,
                feeToken
            )
        );
        return GateTypes.FeeAttestation({
            account: buyer,
            action: action,
            nonce: FEE_NONCE,
            deadline: deadline,
            paramsHash: paramsHash,
            makerFeeBps: makerFeeBps,
            takerFeeBps: takerFeeBps,
            feeCollector: feeCollector,
            feeToken: feeToken,
            signature: _sign(feeSignerPk, _digest(PRIMARY_DOMAIN_NAME, target, structHash))
        });
    }

    // ── calls ─────────────────────────────────────────────────────────────────────────────

    /// The whole happy path, assembled: a well-formed intent, both signatures over it and the
    /// two attestations bound to it, submitted by the buyer.
    function _settle(AsseteraPrimarySales target) internal {
        PrimaryTypes.SettlementIntent memory intent = _intent();
        bytes32 paramsHash = _paramsHash(intent);
        vm.prank(buyer);
        target.settlePrimary(
            VENUE_CALLDATA,
            intent,
            _signIntent(address(target), intent),
            _signBuyerConsent(address(target), intent),
            _kyc(address(target), paramsHash),
            _fee(address(target), paramsHash)
        );
    }

    /// 🔴 The revert a well-formed settlement against `sales` ends at, and the MARKER three
    /// suites use to mean "every signature and both attestations passed, and the settlement
    /// reached the last check before the money".
    ///
    /// `CURRENCY` is never given a cap on the `sales` fixture, and an unset cap is CLOSED, so
    /// the shared preamble refuses the settlement on its last line — after the three nonce
    /// burns, before the settler family is entered. The error is a stronger marker than the
    /// `SettlementLimitsNotImplemented` it replaced, because it is not a bare selector: it
    /// carries the settlement token and `QUOTE_IN + BUYER_FEE`, so it also proves the intent's
    /// own numbers survived every gate intact. A settlement that stopped anywhere earlier
    /// reverts with a different error.
    function _expectReachesTheMoneyPath() internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                ISettlementLimits.PerTxCapExceeded.selector, CURRENCY, QUOTE_IN + BUYER_FEE, uint256(0)
            )
        );
    }

    /// The whole sell-back happy path, assembled, submitted by the seller.
    function _redeem(AsseteraPrimarySales target) internal {
        PrimaryTypes.RedemptionIntent memory intent = _redemption();
        bytes32 paramsHash = _paramsHash(intent);
        vm.prank(buyer);
        target.redeemPrimary(
            VENUE_CALLDATA,
            intent,
            _signRedemption(address(target), intent),
            _signSellerConsent(address(target), intent),
            _kycRedeem(address(target), paramsHash),
            _feeRedeem(address(target), paramsHash)
        );
    }

    /// 🔴 The sell-back mirror of `_expectReachesTheMoneyPath`. The cap is charged on
    /// `venueQuoteOut` — the GROSS proceeds — so the amount in the error is `QUOTE_OUT` alone
    /// and not `QUOTE_OUT - SELLER_FEE`. That is itself part of what this marker proves.
    function _expectRedemptionReachesTheMoneyPath() internal {
        vm.expectRevert(
            abi.encodeWithSelector(ISettlementLimits.PerTxCapExceeded.selector, CURRENCY, QUOTE_OUT, uint256(0))
        );
    }

    /// Submit `data` to `to` through the trusted forwarder, paid for by the relayer, signed by
    /// `fromPk`. Mirrors `AsseteraECS.t.sol`'s helper so the two meta-transaction paths cannot
    /// drift apart.
    function _relay(uint256 fromPk, address from, address to, bytes memory data) internal {
        ERC2771Forwarder.ForwardRequestData memory req = ERC2771Forwarder.ForwardRequestData({
            from: from,
            to: to,
            value: 0,
            gas: 2_000_000,
            deadline: uint48(block.timestamp + 1 hours),
            data: data,
            signature: ""
        });
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)"
                ),
                req.from,
                req.to,
                req.value,
                req.gas,
                forwarder.nonces(from),
                req.deadline,
                keccak256(req.data)
            )
        );
        req.signature = _sign(fromPk, _digest("AsseteraForwarder", address(forwarder), structHash));

        vm.prank(relayer);
        forwarder.execute(req);
    }
}
