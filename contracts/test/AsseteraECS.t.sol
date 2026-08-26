// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {AsseteraECS} from "../src/AsseteraECS.sol";
import {ExchangeTypes} from "../src/types/ExchangeTypes.sol";
import {GateTypes} from "../src/types/GateTypes.sol";
import {ExchangeStorage} from "../src/storage/ExchangeStorage.sol";
import {GateStorage} from "../src/gates/GateStorage.sol";
import {IKycGate} from "../src/interfaces/IKycGate.sol";
import {IFeeGate} from "../src/interfaces/IFeeGate.sol";
import {OrderBook} from "../src/core/OrderBook.sol";
import {OfferBook} from "../src/core/OfferBook.sol";
import {PermitRelay} from "../src/core/PermitRelay.sol";
import {ExchangeAdmin} from "../src/admin/ExchangeAdmin.sol";
import {FaucetToken} from "./mocks/FaucetToken.sol";
import {AsseteraECSV2} from "./mocks/AsseteraECSV2.sol";
import {ReentrantToken} from "./mocks/ReentrantToken.sol";
import {DivergentDomainToken} from "./mocks/DivergentDomainToken.sol";
import {FeeOnTransferToken} from "./mocks/FeeOnTransferToken.sol";
import {RebasingToken} from "./mocks/RebasingToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

contract AsseteraECSTest is Test {
    AsseteraECS internal exchange;
    ERC2771Forwarder internal forwarder;
    FaucetToken internal usdc; // 6 dec
    FaucetToken internal rwa; // 18 dec

    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal alice = makeAddr("alice"); // maker
    address internal bob = makeAddr("bob"); // taker / counter-maker
    address internal carol = makeAddr("carol");
    address internal relayer = makeAddr("relayer");

    uint256 internal kycSignerPk = 0xACE1;
    address internal kycSigner; // = vm.addr(kycSignerPk)

    uint256 internal feeSignerPk = 0xFEE1;
    address internal feeSigner; // = vm.addr(feeSignerPk)

    bytes32 internal KYC_OPERATOR_ROLE;
    bytes32 internal FEE_OPERATOR_ROLE;
    bytes32 internal ADMIN_ROLE;

    uint256 internal constant SELL_RWA = 10e18;
    uint256 internal constant WANT_USDC = 1_000e6;

    uint256 internal _nonceCtr;

    bytes32 internal constant KYC_TYPEHASH = keccak256(
        "KycAttestation(address account,uint8 action,uint256 orderId,uint256 nonce,uint256 deadline,bytes32 paramsHash)"
    );

    bytes32 internal constant FEE_TYPEHASH = keccak256(
        "FeeAttestation(address account,uint8 action,uint256 nonce,uint256 deadline,bytes32 paramsHash,uint16 makerFeeBps,uint16 takerFeeBps,address feeCollector,address feeToken)"
    );

    event OrderPlaced(
        uint256 indexed id,
        address indexed maker,
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 buyAmount,
        uint64 expireTs,
        uint16 makerFeeBps,
        uint16 takerFeeBps,
        address feeCollector,
        address feeToken
    );
    event OrderForceCancelled(uint256 indexed id, address indexed maker, address recipient, address indexed admin);

    function setUp() public {
        kycSigner = vm.addr(kycSignerPk);
        feeSigner = vm.addr(feeSignerPk);

        usdc = new FaucetToken("Mock USD Coin", "mUSDC", 6);
        rwa = new FaucetToken("Mock RWA Token", "mRWA", 18);
        forwarder = new ERC2771Forwarder("AsseteraForwarder");

        AsseteraECS impl = new AsseteraECS(address(forwarder));
        bytes memory initData = abi.encodeCall(AsseteraECS.initialize, (admin, kycSigner, feeSigner));
        exchange = AsseteraECS(address(new ERC1967Proxy(address(impl), initData)));

        KYC_OPERATOR_ROLE = exchange.KYC_OPERATOR_ROLE();
        FEE_OPERATOR_ROLE = exchange.FEE_OPERATOR_ROLE();
        ADMIN_ROLE = exchange.DEFAULT_ADMIN_ROLE();

        for (uint256 i; i < 3; i++) {
            address a = [alice, bob, carol][i];
            rwa.mint(a, 1_000e18);
            usdc.mint(a, 1_000_000e6);
        }
    }

    // ===================================================================== //
    //                          attestation helpers                          //
    // ===================================================================== //

    function _freshNonce() internal returns (uint256) {
        return ++_nonceCtr;
    }

    /// Sign a KYC attestation with an arbitrary key (for negative tests).
    function _signAtt(
        uint256 signerPk,
        address account,
        AsseteraECS.Action action,
        uint256 orderId,
        uint256 nonce,
        uint256 deadline,
        bytes32 paramsHash
    ) internal view returns (AsseteraECS.KycAttestation memory att) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                // EIP-712 domain name — intentionally still "AsseteraExchange" (see AsseteraECS.sol:initialize).
                keccak256(bytes("AsseteraExchange")),
                keccak256(bytes("1")),
                block.chainid,
                address(exchange)
            )
        );
        bytes32 structHash =
            keccak256(abi.encode(KYC_TYPEHASH, account, uint8(action), orderId, nonce, deadline, paramsHash));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        att = GateTypes.KycAttestation({
            account: account,
            action: uint8(action),
            orderId: orderId,
            nonce: nonce,
            deadline: deadline,
            paramsHash: paramsHash,
            signature: abi.encodePacked(r, s, v)
        });
    }

    /// Sign a fee attestation with an arbitrary key (for negative tests). Fee attestations
    /// carry no orderId — they only ever authorise Place/MakeOffer (orderId is always 0 there).
    function _signFeeAtt(
        uint256 signerPk,
        address account,
        AsseteraECS.Action action,
        uint256 nonce,
        uint256 deadline,
        bytes32 paramsHash,
        uint16 makerFeeBps,
        uint16 takerFeeBps,
        address feeCollector,
        address feeToken
    ) internal view returns (AsseteraECS.FeeAttestation memory att) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                // EIP-712 domain name — intentionally still "AsseteraExchange" (see AsseteraECS.sol:initialize).
                keccak256(bytes("AsseteraExchange")),
                keccak256(bytes("1")),
                block.chainid,
                address(exchange)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                FEE_TYPEHASH,
                account,
                uint8(action),
                nonce,
                deadline,
                paramsHash,
                makerFeeBps,
                takerFeeBps,
                feeCollector,
                feeToken
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        att = GateTypes.FeeAttestation({
            account: account,
            action: uint8(action),
            nonce: nonce,
            deadline: deadline,
            paramsHash: paramsHash,
            makerFeeBps: makerFeeBps,
            takerFeeBps: takerFeeBps,
            feeCollector: feeCollector,
            feeToken: feeToken,
            signature: abi.encodePacked(r, s, v)
        });
    }

    /// The settlement currency for a token pair in these fixtures: `usdc` is the money
    /// leg whenever it's present (AC-833 requires `feeToken` ∈ {legA, legB} on EVERY
    /// order, zero-fee included), otherwise fall back to the counter-leg.
    function _defaultFeeToken(address legA, address legB) internal view returns (address) {
        if (legA == address(usdc) || legB == address(usdc)) return address(usdc);
        return legB;
    }

    /// A valid, fresh attestation for non-Place actions (paramsHash = 0).
    function _attest(address account, AsseteraECS.Action action, uint256 orderId)
        internal
        returns (AsseteraECS.KycAttestation memory)
    {
        return _signAtt(kycSignerPk, account, action, orderId, _freshNonce(), block.timestamp + 3 minutes, bytes32(0));
    }

    /// A valid, fresh KYC attestation for Place actions (paramsHash bound to order params).
    function _attestPlace(address account, address sellToken, uint256 sellAmount, address buyToken, uint256 buyAmount)
        internal
        returns (AsseteraECS.KycAttestation memory)
    {
        bytes32 ph = keccak256(abi.encode(sellToken, sellAmount, buyToken, buyAmount));
        return
            _signAtt(
                kycSignerPk, account, ExchangeTypes.Action.Place, 0, _freshNonce(), block.timestamp + 3 minutes, ph
            );
    }

    /// A valid, fresh zero-fee Fee attestation for Place actions.
    function _feePlace(address account, address sellToken, uint256 sellAmount, address buyToken, uint256 buyAmount)
        internal
        returns (AsseteraECS.FeeAttestation memory)
    {
        return _feePlaceWithFee(account, sellToken, sellAmount, buyToken, buyAmount, 0, 0, address(0));
    }

    /// A valid, fresh Place-bound Fee attestation with explicit fee parameters, using
    /// the fixtures' default settlement currency.
    function _feePlaceWithFee(
        address account,
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 buyAmount,
        uint16 makerFeeBps,
        uint16 takerFeeBps,
        address feeCollector
    ) internal returns (AsseteraECS.FeeAttestation memory) {
        return _feePlaceWithFeeToken(
            account,
            sellToken,
            sellAmount,
            buyToken,
            buyAmount,
            makerFeeBps,
            takerFeeBps,
            feeCollector,
            _defaultFeeToken(sellToken, buyToken)
        );
    }

    /// As `_feePlaceWithFee`, but with an explicit settlement currency — for the AC-833
    /// tests that pin the fee denomination or deliberately attest a bad one.
    function _feePlaceWithFeeToken(
        address account,
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 buyAmount,
        uint16 makerFeeBps,
        uint16 takerFeeBps,
        address feeCollector,
        address feeToken
    ) internal returns (AsseteraECS.FeeAttestation memory) {
        bytes32 ph = keccak256(abi.encode(sellToken, sellAmount, buyToken, buyAmount));
        return _signFeeAtt(
            feeSignerPk,
            account,
            ExchangeTypes.Action.Place,
            _freshNonce(),
            block.timestamp + 3 minutes,
            ph,
            makerFeeBps,
            takerFeeBps,
            feeCollector,
            feeToken
        );
    }

    function _placeRwaForUsdc(address maker) internal returns (uint256 id) {
        AsseteraECS.KycAttestation memory att = _attestPlace(maker, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(maker, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(maker);
        rwa.approve(address(exchange), SELL_RWA);
        id = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function _placeUsdcForRwa(address maker, uint256 usdcAmt, uint256 rwaWant) internal returns (uint256 id) {
        AsseteraECS.KycAttestation memory att = _attestPlace(maker, address(usdc), usdcAmt, address(rwa), rwaWant);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(maker, address(usdc), usdcAmt, address(rwa), rwaWant);
        vm.startPrank(maker);
        usdc.approve(address(exchange), usdcAmt);
        id = exchange.placeOrder(address(usdc), usdcAmt, address(rwa), rwaWant, 0, att, feeAtt);
        vm.stopPrank();
    }

    // ===================================================================== //
    //                              initialize                               //
    // ===================================================================== //

    function test_Initialize_GrantsRolesAndDefaults() public view {
        assertTrue(exchange.hasRole(ADMIN_ROLE, admin));
        // OPERATOR_ROLE is parked (AC-246) — not granted, no getter to assert against.
        assertTrue(exchange.hasRole(KYC_OPERATOR_ROLE, kycSigner));
        assertTrue(exchange.hasRole(FEE_OPERATOR_ROLE, feeSigner));
        assertEq(exchange.version(), "4.1.0");
        assertEq(exchange.trustedForwarder(), address(forwarder));
    }

    /// @dev The gate mapping is fail-OPEN: an action nobody enabled is not gated at all. `AsseteraECS` is
    ///      safe only because `initialize` enables each action it defines, so that list is pinned here.
    ///      Anything added to `ExchangeTypes.Action` must either appear below or be justified above.
    function test_Initialize_GatesEveryDeclaredAction() public view {
        assertTrue(exchange.complianceRequired(uint8(ExchangeTypes.Action.Place)), "Place");
        assertTrue(exchange.complianceRequired(uint8(ExchangeTypes.Action.Fill)), "Fill");
        assertTrue(exchange.complianceRequired(uint8(ExchangeTypes.Action.Settle)), "Settle");
        assertTrue(exchange.complianceRequired(uint8(ExchangeTypes.Action.MakeOffer)), "MakeOffer");
        assertTrue(exchange.complianceRequired(uint8(ExchangeTypes.Action.ReplaceOffer)), "ReplaceOffer");
        assertTrue(exchange.complianceRequired(uint8(ExchangeTypes.Action.AcceptOffer)), "AcceptOffer");
        assertTrue(exchange.complianceRequired(uint8(ExchangeTypes.Action.CancelOffer)), "CancelOffer");
        // Action.SettleOffer is deliberately NOT enabled: it is unused (AC-246), acceptOffer settles
        // atomically under AcceptOffer's gate. Asserted false so re-introducing it forces a decision here.
        assertFalse(exchange.complianceRequired(uint8(ExchangeTypes.Action.SettleOffer)), "SettleOffer");
    }

    function test_Initialize_RevertsOnZeroKycSigner() public {
        AsseteraECS impl = new AsseteraECS(address(forwarder));
        bytes memory initData = abi.encodeCall(AsseteraECS.initialize, (admin, address(0), feeSigner));
        vm.expectRevert(GateStorage.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertsOnZeroFeeSigner() public {
        AsseteraECS impl = new AsseteraECS(address(forwarder));
        bytes memory initData = abi.encodeCall(AsseteraECS.initialize, (admin, kycSigner, address(0)));
        vm.expectRevert(GateStorage.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_CannotReinitialize() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        exchange.initialize(alice, carol, makeAddr("newFeeSigner"));
    }

    // ===================================================================== //
    //                              placeOrder                               //
    // ===================================================================== //

    function test_PlaceOrder_HappyPath() public {
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectEmit(true, true, false, true, address(exchange));
        emit OrderPlaced(1, alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, 0, 0, address(0), address(usdc));
        uint256 id = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();

        assertEq(id, 1);
        assertEq(rwa.balanceOf(address(exchange)), SELL_RWA);
        assertEq(uint8(exchange.getOrder(1).status), uint8(ExchangeTypes.OrderStatus.Open));
        assertEq(exchange.getOrder(1).remainingQuantity, SELL_RWA);
        assertEq(exchange.getOrder(1).expireTs, 0);
    }

    function test_PlaceOrder_WithExpiry() public {
        uint64 expireTs = uint64(block.timestamp + 1 hours);
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        uint256 id = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, expireTs, att, feeAtt);
        vm.stopPrank();

        assertEq(exchange.getOrder(id).expireTs, expireTs);
    }

    function test_PlaceOrder_RevertsOnInvalidExpiry() public {
        // Forge default block.timestamp is 1; warp forward so block.timestamp - 1 != 0
        // (0 is the "no expiry" sentinel and would not trigger InvalidExpiry).
        vm.warp(1 hours);
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(ExchangeStorage.InvalidExpiry.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, uint64(block.timestamp - 1), att, feeAtt);
        vm.stopPrank();
    }

    function test_PlaceOrder_RevertsWithoutAttestation_BadSigner() public {
        // Signed by a key that does NOT hold KYC_OPERATOR_ROLE.
        bytes32 ph = keccak256(abi.encode(address(rwa), SELL_RWA, address(usdc), WANT_USDC));
        AsseteraECS.KycAttestation memory att =
            _signAtt(0xBAD, alice, ExchangeTypes.Action.Place, 0, _freshNonce(), block.timestamp + 3 minutes, ph);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(IKycGate.KycBadSigner.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_PlaceOrder_RevertsOnExpiredAttestation() public {
        bytes32 ph = keccak256(abi.encode(address(rwa), SELL_RWA, address(usdc), WANT_USDC));
        AsseteraECS.KycAttestation memory att =
            _signAtt(kycSignerPk, alice, ExchangeTypes.Action.Place, 0, _freshNonce(), block.timestamp + 100, ph);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.warp(block.timestamp + 101);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(IKycGate.KycExpired.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_PlaceOrder_RevertsOnTtlTooLong() public {
        bytes32 ph = keccak256(abi.encode(address(rwa), SELL_RWA, address(usdc), WANT_USDC));
        AsseteraECS.KycAttestation memory att = _signAtt(
            kycSignerPk, alice, ExchangeTypes.Action.Place, 0, _freshNonce(), block.timestamp + 16 minutes, ph
        );
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(IKycGate.KycTtlTooLong.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_PlaceOrder_RevertsOnAccountMismatch() public {
        // Attestation is for bob, but alice is acting.
        AsseteraECS.KycAttestation memory att = _attestPlace(bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(IKycGate.KycAccountMismatch.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_PlaceOrder_RevertsOnActionMismatch() public {
        // Attestation carries the correct paramsHash but wrong action (Fill vs Place).
        // paramsHash check passes; KycActionMismatch fires inside _consumeKyc.
        bytes32 ph = keccak256(abi.encode(address(rwa), SELL_RWA, address(usdc), WANT_USDC));
        AsseteraECS.KycAttestation memory att =
            _signAtt(kycSignerPk, alice, ExchangeTypes.Action.Fill, 0, _freshNonce(), block.timestamp + 3 minutes, ph);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(IKycGate.KycActionMismatch.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_PlaceOrder_RevertsOnNonceReuse() public {
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA * 2);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        // Same attestation (same nonce) again -> consumed.
        vm.expectRevert(IKycGate.KycNonceUsed.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_PlaceOrder_RevertsWhenPaused() public {
        vm.prank(admin);
        exchange.pause();
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    // ===================================================================== //
    //        AC-884: the KYC toggle does NOT gate fee verification          //
    // ===================================================================== //
    //
    // `complianceRequired` is a KYC control. Before AC-884 `_verifyFee` shared it,
    // so `setComplianceRequired(Place, false)` also switched off signature, deadline
    // and nonce checking on the FEE attestation — any caller could then hand-craft an
    // unsigned zero-fee attestation and place a permanently fee-free order. Fee
    // verification is now unconditional; fee-free trading stays reachable the honest
    // way, by the fee service signing `makerFeeBps == takerFeeBps == 0`.

    /// With `Place` gating off the KYC attestation may be empty, but the fee
    /// attestation must still be signed by a `FEE_OPERATOR_ROLE` holder — and its
    /// single-use nonce burns even though no KYC nonce does.
    function test_PlaceOrder_GatingOff_KycSkippedButFeeStillVerified() public {
        vm.prank(admin);
        exchange.setComplianceRequired(ExchangeTypes.Action.Place, false);

        AsseteraECS.KycAttestation memory empty; // garbage / empty — KYC gating is off
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);

        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        uint256 id = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, empty, feeAtt);
        vm.stopPrank();

        assertEq(id, 1);
        assertEq(exchange.getOrder(id).feeToken, address(usdc));
        assertTrue(exchange.usedFeeNonce(alice, feeAtt.nonce), "fee nonce must burn with KYC gating off");
        assertFalse(exchange.usedNonce(alice, empty.nonce), "no KYC nonce is burned with KYC gating off");
    }

    /// THE AC-884 regression. `Place` gating off, a perfectly formed zero-fee
    /// attestation with NO signature — the exact hand-crafted payload that used to
    /// mint a permanently fee-free order. It must revert, and no order may exist.
    function test_PlaceOrder_GatingOff_UnsignedFeeAttestationReverts() public {
        vm.prank(admin);
        exchange.setComplianceRequired(ExchangeTypes.Action.Place, false);

        AsseteraECS.FeeAttestation memory forged = GateTypes.FeeAttestation({
            account: alice,
            action: uint8(ExchangeTypes.Action.Place),
            nonce: 1,
            deadline: block.timestamp + 3 minutes,
            paramsHash: keccak256(abi.encode(address(rwa), SELL_RWA, address(usdc), WANT_USDC)),
            makerFeeBps: 0,
            takerFeeBps: 0,
            feeCollector: address(0),
            feeToken: address(usdc),
            signature: "" // unsigned
        });
        AsseteraECS.KycAttestation memory empty;

        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(abi.encodeWithSignature("ECDSAInvalidSignatureLength(uint256)", 0));
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, empty, forged);
        vm.stopPrank();

        assertEq(exchange.totalOrders(), 0, "no order may have been created");
    }

    /// Same attack, self-signed rather than unsigned, so it reaches the role check.
    function test_PlaceOrder_GatingOff_SelfSignedFeeAttestationReverts() public {
        uint256 attackerPk = 0xBAD1;
        address attacker = vm.addr(attackerPk);
        rwa.mint(attacker, SELL_RWA);

        vm.prank(admin);
        exchange.setComplianceRequired(ExchangeTypes.Action.Place, false);

        AsseteraECS.FeeAttestation memory forged = _signFeeAtt(
            attackerPk,
            attacker,
            ExchangeTypes.Action.Place,
            _freshNonce(),
            block.timestamp + 3 minutes,
            keccak256(abi.encode(address(rwa), SELL_RWA, address(usdc), WANT_USDC)),
            0,
            0,
            address(0),
            address(usdc)
        );
        AsseteraECS.KycAttestation memory empty;

        vm.startPrank(attacker);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(IFeeGate.FeeBadSigner.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, empty, forged);
        vm.stopPrank();
    }

    /// The fee nonce is single-use regardless of the KYC toggle — otherwise one signed
    /// attestation would be replayable for as long as gating stayed off.
    function test_PlaceOrder_GatingOff_FeeNonceIsStillSingleUse() public {
        vm.prank(admin);
        exchange.setComplianceRequired(ExchangeTypes.Action.Place, false);

        AsseteraECS.KycAttestation memory empty;
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);

        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA * 2);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, empty, feeAtt);
        vm.expectRevert(IFeeGate.FeeNonceUsed.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, empty, feeAtt);
        vm.stopPrank();
    }

    /// The fee attestation's `paramsHash` binding is unconditional too: a fee
    /// attestation signed for different order params must not be reusable here.
    function test_PlaceOrder_GatingOff_FeeParamsHashIsStillBound() public {
        vm.prank(admin);
        exchange.setComplianceRequired(ExchangeTypes.Action.Place, false);

        AsseteraECS.FeeAttestation memory feeAtt =
            _feePlace(alice, address(rwa), SELL_RWA / 2, address(usdc), WANT_USDC);
        AsseteraECS.KycAttestation memory empty;

        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(GateStorage.ParamsHashMismatch.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, empty, feeAtt);
        vm.stopPrank();
    }

    /// The offer path shares `_verifyFee`, so it must behave identically.
    function test_MakeOffer_GatingOff_UnsignedFeeAttestationReverts() public {
        vm.prank(admin);
        exchange.setComplianceRequired(ExchangeTypes.Action.MakeOffer, false);

        AsseteraECS.FeeAttestation memory forged = GateTypes.FeeAttestation({
            account: alice,
            action: uint8(ExchangeTypes.Action.MakeOffer),
            nonce: 1,
            deadline: block.timestamp + 3 minutes,
            paramsHash: keccak256(abi.encodePacked(bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC)),
            makerFeeBps: 0,
            takerFeeBps: 0,
            feeCollector: address(0),
            feeToken: address(usdc),
            signature: "" // unsigned
        });
        AsseteraECS.KycAttestation memory empty;

        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(abi.encodeWithSignature("ECDSAInvalidSignatureLength(uint256)", 0));
        exchange.makeOffer(0, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, empty, forged);
        vm.stopPrank();

        assertEq(exchange.totalOffers(), 0, "no offer may have been created");
    }

    function test_PlaceOrder_RevertsOnZeroAmount() public {
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), 0, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), 0, address(usdc), WANT_USDC);
        vm.prank(alice);
        vm.expectRevert(ExchangeStorage.ZeroAmount.selector);
        exchange.placeOrder(address(rwa), 0, address(usdc), WANT_USDC, 0, att, feeAtt);
    }

    // ===================================================================== //
    //                              cancelOrder                              //
    // ===================================================================== //

    function test_CancelOrder_HappyPath() public {
        uint256 id = _placeRwaForUsdc(alice);
        uint256 bal = rwa.balanceOf(alice);

        vm.prank(alice);
        exchange.cancelOrder(id);

        assertEq(uint8(exchange.getOrder(id).status), uint8(ExchangeTypes.OrderStatus.Cancelled));
        assertEq(rwa.balanceOf(alice), bal + SELL_RWA);
    }

    function test_CancelOrder_ReturnsRemainingAfterPartialFill() public {
        uint256 id = _placeRwaForUsdc(alice);

        // Bob partially fills half
        uint256 halfRwa = SELL_RWA / 2;
        uint256 halfUsdc = (halfRwa * WANT_USDC + SELL_RWA - 1) / SELL_RWA; // ceiling
        vm.prank(admin);
        exchange.setComplianceRequired(ExchangeTypes.Action.Fill, false);
        vm.startPrank(bob);
        usdc.approve(address(exchange), halfUsdc);
        exchange.fillOrder(
            id,
            halfRwa,
            GateTypes.KycAttestation({
                account: address(0),
                action: uint8(ExchangeTypes.Action.None),
                orderId: 0,
                nonce: 0,
                deadline: 0,
                paramsHash: bytes32(0),
                signature: ""
            })
        );
        vm.stopPrank();

        // Alice cancels with remaining half
        uint256 aliceRwa = rwa.balanceOf(alice);
        vm.prank(alice);
        exchange.cancelOrder(id);

        assertEq(rwa.balanceOf(alice), aliceRwa + halfRwa);
    }

    function test_CancelOrder_RevertsIfNotMaker() public {
        uint256 id = _placeRwaForUsdc(alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.NotMaker.selector, id));
        exchange.cancelOrder(id);
    }

    function test_CancelOrder_RevertsIfNotOpen() public {
        uint256 id = _placeRwaForUsdc(alice);
        vm.prank(alice);
        exchange.cancelOrder(id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ExchangeStorage.OrderNotOpen.selector, id));
        exchange.cancelOrder(id);
    }

    // ===================================================================== //
    //               fillOrder — self-trade prevention, partial fills        //
    // ===================================================================== //

    function test_FillOrder_HappyPath() public {
        uint256 id = _placeRwaForUsdc(alice);
        uint256 aliceUsdc = usdc.balanceOf(alice);
        uint256 bobRwa = rwa.balanceOf(bob);
        AsseteraECS.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.fillOrder(id, SELL_RWA, att);
        vm.stopPrank();

        assertEq(uint8(exchange.getOrder(id).status), uint8(ExchangeTypes.OrderStatus.Filled));
        assertEq(exchange.getOrder(id).remainingQuantity, 0);
        assertEq(usdc.balanceOf(alice), aliceUsdc + WANT_USDC);
        assertEq(rwa.balanceOf(bob), bobRwa + SELL_RWA);
    }

    function test_FillOrder_PartialFill_HappyPath() public {
        uint256 id = _placeRwaForUsdc(alice);
        uint256 halfRwa = SELL_RWA / 2;
        uint256 halfUsdc = (halfRwa * WANT_USDC + SELL_RWA - 1) / SELL_RWA; // ceiling

        AsseteraECS.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), halfUsdc);
        exchange.fillOrder(id, halfRwa, att);
        vm.stopPrank();

        // Order stays Open with half remaining
        assertEq(uint8(exchange.getOrder(id).status), uint8(ExchangeTypes.OrderStatus.Open));
        assertEq(exchange.getOrder(id).remainingQuantity, SELL_RWA - halfRwa);
    }

    function test_FillOrder_PartialFill_ThenFullFill() public {
        uint256 id = _placeRwaForUsdc(alice);
        uint256 halfRwa = SELL_RWA / 2;

        vm.prank(admin);
        exchange.setComplianceRequired(ExchangeTypes.Action.Fill, false);

        AsseteraECS.KycAttestation memory empty;
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.fillOrder(id, halfRwa, empty);
        assertEq(uint8(exchange.getOrder(id).status), uint8(ExchangeTypes.OrderStatus.Open));
        // Fill remaining half
        exchange.fillOrder(id, SELL_RWA - halfRwa, empty);
        vm.stopPrank();

        assertEq(uint8(exchange.getOrder(id).status), uint8(ExchangeTypes.OrderStatus.Filled));
        assertEq(exchange.getOrder(id).remainingQuantity, 0);
    }

    function test_FillOrder_SelfTradePrevention() public {
        // Maker cannot fill their own order (self-trade prevention).
        uint256 id = _placeRwaForUsdc(alice);
        vm.prank(admin);
        exchange.setComplianceRequired(ExchangeTypes.Action.Fill, false);

        AsseteraECS.KycAttestation memory empty;
        vm.startPrank(alice);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.SelfTrade.selector, id));
        exchange.fillOrder(id, SELL_RWA, empty);
        vm.stopPrank();
    }

    function test_FillOrder_RevertsOnExpiredOrder() public {
        // Filling an expired order must revert.
        uint64 expireTs = uint64(block.timestamp + 1 hours);
        AsseteraECS.KycAttestation memory placeAtt =
            _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory placeFeeAtt =
            _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        uint256 id =
            exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, expireTs, placeAtt, placeFeeAtt);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 hours);
        vm.prank(admin);
        exchange.setComplianceRequired(ExchangeTypes.Action.Fill, false);

        AsseteraECS.KycAttestation memory empty;
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.OrderIsExpired.selector, id));
        exchange.fillOrder(id, SELL_RWA, empty);
        vm.stopPrank();
    }

    function test_FillOrder_RevertsOnFillAmountZero() public {
        uint256 id = _placeRwaForUsdc(alice);
        AsseteraECS.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectRevert(OrderBook.FillAmountZero.selector);
        exchange.fillOrder(id, 0, att);
        vm.stopPrank();
    }

    function test_FillOrder_RevertsOnFillExceedsRemaining() public {
        uint256 id = _placeRwaForUsdc(alice);
        AsseteraECS.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC * 2);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.FillExceedsRemaining.selector, id, SELL_RWA));
        exchange.fillOrder(id, SELL_RWA + 1, att);
        vm.stopPrank();
    }

    function test_FillOrder_RevertsWithoutValidAttestation() public {
        uint256 id = _placeRwaForUsdc(alice);
        AsseteraECS.KycAttestation memory att =
            _signAtt(0xBAD, bob, ExchangeTypes.Action.Fill, id, _freshNonce(), block.timestamp + 3 minutes, bytes32(0));
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectRevert(IKycGate.KycBadSigner.selector);
        exchange.fillOrder(id, SELL_RWA, att);
        vm.stopPrank();
    }

    function test_FillOrder_RevertsOnWrongOrderIdBinding() public {
        uint256 id = _placeRwaForUsdc(alice);
        // Attestation bound to a different order id.
        AsseteraECS.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id + 99);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectRevert(IKycGate.KycOrderMismatch.selector);
        exchange.fillOrder(id, SELL_RWA, att);
        vm.stopPrank();
    }

    // ===================================================================== //
    //              settle — self-trade, expiry, partial settlement          //
    // ===================================================================== //

    function test_SweepExpired_RefundsEscrow() public {
        uint64 expireTs = uint64(block.timestamp + 1 hours);
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        uint256 id = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, expireTs, att, feeAtt);
        vm.stopPrank();

        uint256 aliceRwa = rwa.balanceOf(alice);
        vm.warp(block.timestamp + 2 hours);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        exchange.sweepExpired(ids);

        assertEq(uint8(exchange.getOrder(id).status), uint8(ExchangeTypes.OrderStatus.Expired));
        assertEq(rwa.balanceOf(alice), aliceRwa + SELL_RWA);
    }

    function test_SweepExpired_SkipsNonExpiredAndNonOpen() public {
        // Order 1: no expiry (skipped)
        uint256 id1 = _placeRwaForUsdc(alice);
        // Order 2: expiry in future (skipped)
        uint64 future = uint64(block.timestamp + 2 hours);
        AsseteraECS.KycAttestation memory att2 = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt2 = _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        uint256 id2 = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, future, att2, feeAtt2);
        vm.stopPrank();
        // Order 3: expiry in past (swept)
        uint64 past = uint64(block.timestamp + 1 hours);
        AsseteraECS.KycAttestation memory att3 = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt3 = _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        uint256 id3 = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, past, att3, feeAtt3);
        vm.stopPrank();

        vm.warp(block.timestamp + 90 minutes); // id3 expired, id2 not yet

        uint256[] memory ids = new uint256[](3);
        ids[0] = id1;
        ids[1] = id2;
        ids[2] = id3;
        exchange.sweepExpired(ids);

        assertEq(uint8(exchange.getOrder(id1).status), uint8(ExchangeTypes.OrderStatus.Open));
        assertEq(uint8(exchange.getOrder(id2).status), uint8(ExchangeTypes.OrderStatus.Open));
        assertEq(uint8(exchange.getOrder(id3).status), uint8(ExchangeTypes.OrderStatus.Expired));
    }

    function test_SweepExpired_CannotSweepTwice() public {
        uint64 expireTs = uint64(block.timestamp + 1 hours);
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        uint256 id = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, expireTs, att, feeAtt);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 hours);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        exchange.sweepExpired(ids); // first sweep
        uint256 bal = rwa.balanceOf(alice);
        exchange.sweepExpired(ids); // second sweep — silently skipped (status != Open)
        assertEq(rwa.balanceOf(alice), bal); // no double-refund
    }

    // ===================================================================== //
    //                       refund / cancelOrderForUser                     //
    // ===================================================================== //

    function test_CancelOrderForUser_RoutesToRecipient() public {
        uint256 id = _placeRwaForUsdc(alice);
        uint256 carolBal = rwa.balanceOf(carol);

        vm.expectEmit(true, true, false, true, address(exchange));
        emit OrderForceCancelled(id, alice, carol, admin);
        vm.prank(admin);
        exchange.cancelOrderForUser(id, carol); // route to a compliance-chosen address

        assertEq(uint8(exchange.getOrder(id).status), uint8(ExchangeTypes.OrderStatus.ForceCancelled));
        assertEq(rwa.balanceOf(carol), carolBal + SELL_RWA);
    }

    function test_CancelOrderForUser_RevertsIfNotAdmin() public {
        uint256 id = _placeRwaForUsdc(alice);
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", operator, ADMIN_ROLE)
        );
        exchange.cancelOrderForUser(id, alice);
    }

    function test_CancelOrderForUser_RevertsOnZeroRecipient() public {
        uint256 id = _placeRwaForUsdc(alice);
        vm.prank(admin);
        vm.expectRevert(GateStorage.ZeroAddress.selector);
        exchange.cancelOrderForUser(id, address(0));
    }

    // ===================================================================== //
    //                        setComplianceRequired                          //
    // ===================================================================== //

    function test_SetComplianceRequired_OnlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, ADMIN_ROLE));
        exchange.setComplianceRequired(ExchangeTypes.Action.Fill, false);
    }

    // ===================================================================== //
    //                     gasless meta-tx (ERC-2771)                        //
    // ===================================================================== //

    function test_MetaTx_GaslessPlaceOrder_IdentityIsUserNotRelayer() public {
        uint256 userPk = 0xF00D;
        address user = vm.addr(userPk);
        rwa.mint(user, SELL_RWA);
        vm.deal(user, 0); // user has NO ETH — fully gasless

        // permit (gasless approval) for RWA
        uint256 permitDeadline = block.timestamp + 1 hours;
        (uint8 pv, bytes32 pr, bytes32 ps) = _signPermit(rwa, userPk, user, address(exchange), SELL_RWA, permitDeadline);
        // KYC + fee attestations for the user
        AsseteraECS.KycAttestation memory att = _attestPlace(user, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(user, address(rwa), SELL_RWA, address(usdc), WANT_USDC);

        bytes memory callData = abi.encodeCall(
            OrderBook.placeOrderWithPermit,
            (address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, permitDeadline, pv, pr, ps, att, feeAtt)
        );

        // Relayer submits via the forwarder, paying gas.
        _relay(userPk, user, address(exchange), callData);

        // Order belongs to the user, not the relayer.
        AsseteraECS.Order memory o = exchange.getOrder(1);
        assertEq(o.maker, user);
        assertEq(rwa.balanceOf(address(exchange)), SELL_RWA);
        assertEq(user.balance, 0); // still no ETH
    }

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
        bytes32 fwdDomain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("AsseteraForwarder")),
                keccak256(bytes("1")),
                block.chainid,
                address(forwarder)
            )
        );
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
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", fwdDomain, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(fromPk, digest);
        req.signature = abi.encodePacked(r, s, v);

        vm.prank(relayer);
        forwarder.execute(req);
    }

    // ===================================================================== //
    //                              UUPS upgrade                             //
    // ===================================================================== //

    function test_Upgrade_PreservesStateAndForwarder() public {
        uint256 id = _placeRwaForUsdc(alice);
        AsseteraECSV2 implV2 = new AsseteraECSV2(address(forwarder));
        vm.prank(admin);
        exchange.upgradeToAndCall(address(implV2), "");

        assertEq(exchange.version(), "4.1.0");
        assertTrue(AsseteraECSV2(address(exchange)).isUpgraded());
        assertEq(exchange.getOrder(id).maker, alice);
        assertEq(exchange.trustedForwarder(), address(forwarder));
    }

    /// @notice Upgrade-safety proof: fill every storage class with non-default
    ///         values, upgrade the implementation, and assert every slot is
    ///         preserved byte-for-byte — then that the new impl's appended
    ///         storage is independently writable without disturbing the old.
    ///         This is the behavioural counterpart to the static storage-layout
    ///         snapshot guard (`script/storage-layout.sh`): together they make
    ///         "does this upgrade / dependency bump preserve state?" a proven,
    ///         not assumed, property.
    function test_Upgrade_PreservesAllStorageAcrossEverySlot() public {
        // ---- 1. Populate every storage class with non-default state --------- //

        // _orders / totalOrders (+ alice's KYC & fee nonces via the helper).
        uint256 orderId = _placeRwaForUsdc(alice);

        // A second order placed with *known* nonces so we can assert the two
        // nonce mappings (usedNonce / usedFeeNonce) directly after the upgrade.
        uint256 kycNonce = 424242;
        uint256 feeNonce = 535353;
        {
            bytes32 ph = keccak256(abi.encode(address(rwa), SELL_RWA, address(usdc), WANT_USDC));
            AsseteraECS.KycAttestation memory att =
                _signAtt(kycSignerPk, carol, ExchangeTypes.Action.Place, 0, kycNonce, block.timestamp + 3 minutes, ph);
            AsseteraECS.FeeAttestation memory feeAtt = _signFeeAtt(
                feeSignerPk,
                carol,
                ExchangeTypes.Action.Place,
                feeNonce,
                block.timestamp + 3 minutes,
                ph,
                0,
                0,
                address(0),
                address(usdc)
            );
            vm.startPrank(carol);
            rwa.approve(address(exchange), SELL_RWA);
            exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
            vm.stopPrank();
        }

        // _offers / totalOffers.
        uint256 offerId = _makeOffer(alice, bob, address(usdc), 500e6, address(rwa), 5e18);

        // Admin-managed state: move it away from the initializer defaults.
        vm.startPrank(admin);
        exchange.setAllowedCollector(carol, true); // allowedCollectors mapping
        exchange.setComplianceRequired(ExchangeTypes.Action.Fill, false); // toggle a default-true off
        exchange.pause(); // Pausable inherited (namespaced) state — do last, gates placement
        vm.stopPrank();

        // ---- 2. Snapshot everything readable ------------------------------- //
        uint256 snapTotalOrders = exchange.totalOrders();
        uint256 snapTotalOffers = exchange.totalOffers();
        ExchangeTypes.Order memory snapOrder = exchange.getOrder(orderId);
        ExchangeTypes.Offer memory snapOffer = exchange.getOffer(offerId);

        // ---- 3. Upgrade the implementation --------------------------------- //
        AsseteraECSV2 implV2 = new AsseteraECSV2(address(forwarder));
        vm.prank(admin);
        exchange.upgradeToAndCall(address(implV2), "");
        AsseteraECSV2 v2 = AsseteraECSV2(address(exchange));
        assertEq(v2.version(), "4.1.0", "impl not swapped");
        assertTrue(v2.isUpgraded(), "V2 logic not live");

        // ---- 4. Every pre-upgrade slot survived unchanged ------------------ //
        assertEq(v2.totalOrders(), snapTotalOrders, "totalOrders");
        assertEq(v2.totalOffers(), snapTotalOffers, "totalOffers");

        ExchangeTypes.Order memory o = v2.getOrder(orderId);
        assertEq(o.id, snapOrder.id, "order.id");
        assertEq(o.maker, snapOrder.maker, "order.maker");
        assertEq(o.sellToken, snapOrder.sellToken, "order.sellToken");
        assertEq(o.sellAmount, snapOrder.sellAmount, "order.sellAmount");
        assertEq(o.buyToken, snapOrder.buyToken, "order.buyToken");
        assertEq(o.buyAmount, snapOrder.buyAmount, "order.buyAmount");
        assertEq(uint8(o.status), uint8(snapOrder.status), "order.status");
        assertEq(o.createdAt, snapOrder.createdAt, "order.createdAt");
        assertEq(o.remainingQuantity, snapOrder.remainingQuantity, "order.remainingQuantity");
        assertEq(o.expireTs, snapOrder.expireTs, "order.expireTs");
        assertEq(o.makerFeeBps, snapOrder.makerFeeBps, "order.makerFeeBps");
        assertEq(o.takerFeeBps, snapOrder.takerFeeBps, "order.takerFeeBps");
        assertEq(o.feeCollector, snapOrder.feeCollector, "order.feeCollector");

        ExchangeTypes.Offer memory offer = v2.getOffer(offerId);
        assertEq(offer.id, snapOffer.id, "offer.id");
        assertEq(offer.maker, snapOffer.maker, "offer.maker");
        assertEq(offer.taker, snapOffer.taker, "offer.taker");
        assertEq(offer.makerToken, snapOffer.makerToken, "offer.makerToken");
        assertEq(offer.makerAmount, snapOffer.makerAmount, "offer.makerAmount");
        assertEq(offer.takerToken, snapOffer.takerToken, "offer.takerToken");
        assertEq(offer.takerAmount, snapOffer.takerAmount, "offer.takerAmount");
        assertEq(uint8(offer.status), uint8(snapOffer.status), "offer.status");
        assertEq(offer.proposedBy, snapOffer.proposedBy, "offer.proposedBy");
        assertEq(offer.feeCollector, snapOffer.feeCollector, "offer.feeCollector");

        // Mappings (both nonce namespaces, allowlist, per-action compliance toggle).
        assertTrue(v2.usedNonce(carol, kycNonce), "usedNonce preserved");
        assertTrue(v2.usedFeeNonce(carol, feeNonce), "usedFeeNonce preserved");
        assertTrue(v2.allowedCollectors(carol), "allowedCollectors preserved");
        assertFalse(v2.complianceRequired(uint8(ExchangeTypes.Action.Fill)), "toggled-off compliance preserved");
        assertTrue(v2.complianceRequired(uint8(ExchangeTypes.Action.Place)), "untouched compliance default preserved");

        // Inherited OZ (ERC-7201 namespaced) state must also survive the dep.
        assertTrue(v2.hasRole(ADMIN_ROLE, admin), "admin role preserved");
        assertTrue(v2.hasRole(KYC_OPERATOR_ROLE, kycSigner), "kyc role preserved");
        assertTrue(v2.hasRole(FEE_OPERATOR_ROLE, feeSigner), "fee role preserved");
        assertTrue(v2.paused(), "paused state preserved");

        // ---- 5. New impl storage is writable and isolated ------------------ //
        v2.setUpgradeNote(0xC0FFEE);
        assertEq(v2.upgradeNote(), 0xC0FFEE, "new V2 storage slot not writable");
        // Writing the new slot must not have clobbered any pre-existing slot.
        assertEq(v2.totalOrders(), snapTotalOrders, "old storage corrupted by new write");
        assertEq(v2.getOrder(orderId).sellAmount, snapOrder.sellAmount, "old order corrupted by new write");
    }

    function test_Upgrade_RevertsIfNotAdmin() public {
        AsseteraECSV2 implV2 = new AsseteraECSV2(address(forwarder));
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", operator, ADMIN_ROLE)
        );
        exchange.upgradeToAndCall(address(implV2), "");
    }

    // ===================================================================== //
    //                              reentrancy                               //
    // ===================================================================== //

    function test_FillOrder_ReentrancyGuarded() public {
        // Disable Fill gating so the empty attestation in the reentrant call
        // reaches the guard rather than failing KYC first.
        vm.prank(admin);
        exchange.setComplianceRequired(ExchangeTypes.Action.Fill, false);

        ReentrantToken evil = new ReentrantToken();
        evil.mint(bob, 1_000e18);

        uint256 id;
        {
            AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(evil), 100e18);
            AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), SELL_RWA, address(evil), 100e18);
            vm.startPrank(alice);
            rwa.approve(address(exchange), SELL_RWA);
            id = exchange.placeOrder(address(rwa), SELL_RWA, address(evil), 100e18, 0, att, feeAtt);
            vm.stopPrank();
        }
        AsseteraECS.KycAttestation memory empty;
        // 1 = minimal fill to hit the guard.
        evil.arm(address(exchange), abi.encodeCall(OrderBook.fillOrder, (id, 1, empty)));

        vm.startPrank(bob);
        evil.approve(address(exchange), type(uint256).max);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        exchange.fillOrder(id, SELL_RWA, empty);
        vm.stopPrank();
    }

    // ===================================================================== //
    //                                fuzz                                   //
    // ===================================================================== //

    function testFuzz_PlaceAndFill(uint256 sellAmt, uint256 buyAmt) public {
        sellAmt = bound(sellAmt, 1, 1_000e18);
        buyAmt = bound(buyAmt, 1, 1_000_000e6);

        AsseteraECS.KycAttestation memory pAtt = _attestPlace(alice, address(rwa), sellAmt, address(usdc), buyAmt);
        AsseteraECS.FeeAttestation memory pFeeAtt = _feePlace(alice, address(rwa), sellAmt, address(usdc), buyAmt);
        vm.startPrank(alice);
        rwa.approve(address(exchange), sellAmt);
        uint256 id = exchange.placeOrder(address(rwa), sellAmt, address(usdc), buyAmt, 0, pAtt, pFeeAtt);
        vm.stopPrank();

        AsseteraECS.KycAttestation memory fAtt = _attest(bob, ExchangeTypes.Action.Fill, id);
        uint256 aliceUsdc = usdc.balanceOf(alice);
        vm.startPrank(bob);
        usdc.approve(address(exchange), buyAmt);
        exchange.fillOrder(id, sellAmt, fAtt);
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), aliceUsdc + buyAmt);
    }

    /// @notice I-2(b): fillOrder's ceiling division must never round in the
    ///         taker's favor — the maker always receives at least the exact
    ///         proportional buyAmount for a partial fill, never less.
    function testFuzz_FillOrder_CeilDivNeverShortchangesMaker(uint256 sellAmt, uint256 buyAmt, uint256 fillAmt) public {
        sellAmt = bound(sellAmt, 1, 1_000e18);
        buyAmt = bound(buyAmt, 1, 1_000_000e6);
        fillAmt = bound(fillAmt, 1, sellAmt);

        AsseteraECS.KycAttestation memory pAtt = _attestPlace(alice, address(rwa), sellAmt, address(usdc), buyAmt);
        AsseteraECS.FeeAttestation memory pFeeAtt = _feePlace(alice, address(rwa), sellAmt, address(usdc), buyAmt);
        vm.startPrank(alice);
        rwa.approve(address(exchange), sellAmt);
        uint256 id = exchange.placeOrder(address(rwa), sellAmt, address(usdc), buyAmt, 0, pAtt, pFeeAtt);
        vm.stopPrank();

        // Expected buyAmountDue via the same ceiling-division formula as FeeMath.ceilDiv, computed
        // independently of the contract under test.
        uint256 expectedBuyAmountDue = (fillAmt * buyAmt + sellAmt - 1) / sellAmt;
        assertGe(expectedBuyAmountDue * sellAmt, fillAmt * buyAmt, "ceiling must never round down");

        AsseteraECS.KycAttestation memory fAtt = _attest(bob, ExchangeTypes.Action.Fill, id);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.startPrank(bob);
        usdc.approve(address(exchange), expectedBuyAmountDue);
        exchange.fillOrder(id, fillAmt, fAtt);
        vm.stopPrank();

        assertEq(
            usdc.balanceOf(alice),
            aliceUsdcBefore + expectedBuyAmountDue,
            "maker receives exactly the ceiling-division amount, never less"
        );
    }

    // ===================================================================== //
    //                       additional coverage                             //
    // ===================================================================== //

    function test_Initialize_RevertsOnZeroAdmin() public {
        AsseteraECS impl = new AsseteraECS(address(forwarder));
        bytes memory initData = abi.encodeCall(AsseteraECS.initialize, (address(0), kycSigner, feeSigner));
        vm.expectRevert(GateStorage.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_PlaceOrderWithPermit_Direct() public {
        uint256 pk = 0xBEEF;
        address maker = vm.addr(pk);
        rwa.mint(maker, SELL_RWA);
        uint256 dl = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(rwa, pk, maker, address(exchange), SELL_RWA, dl);
        AsseteraECS.KycAttestation memory att = _attestPlace(maker, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(maker, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.prank(maker);
        uint256 id = exchange.placeOrderWithPermit(
            address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, dl, v, r, s, att, feeAtt
        );
        assertEq(id, 1);
        assertEq(rwa.balanceOf(address(exchange)), SELL_RWA);
    }

    function test_PlaceOrder_RevertsOnZeroSellToken() public {
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(0), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(0), SELL_RWA, address(usdc), WANT_USDC);
        vm.prank(alice);
        vm.expectRevert(GateStorage.ZeroAddress.selector);
        exchange.placeOrder(address(0), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
    }

    function test_PlaceOrder_RevertsOnSameToken() public {
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(rwa), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), SELL_RWA, address(rwa), WANT_USDC);
        vm.prank(alice);
        vm.expectRevert(ExchangeStorage.SameToken.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(rwa), WANT_USDC, 0, att, feeAtt);
    }

    function test_PlaceOrder_RevertsOnOrderIdMismatch() public {
        // Attestation carries the correct paramsHash but wrong orderId (7 vs required 0 for Place).
        // paramsHash check passes; KycOrderMismatch fires inside _consumeKyc.
        bytes32 ph = keccak256(abi.encode(address(rwa), SELL_RWA, address(usdc), WANT_USDC));
        AsseteraECS.KycAttestation memory att =
            _signAtt(kycSignerPk, alice, ExchangeTypes.Action.Place, 7, _freshNonce(), block.timestamp + 3 minutes, ph);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(IKycGate.KycOrderMismatch.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_FillOrder_RevertsIfNotOpen() public {
        uint256 id = _placeRwaForUsdc(alice);
        vm.prank(alice);
        exchange.cancelOrder(id);
        AsseteraECS.KycAttestation memory f = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectRevert(abi.encodeWithSelector(ExchangeStorage.OrderNotOpen.selector, id));
        exchange.fillOrder(id, SELL_RWA, f);
        vm.stopPrank();
    }

    function test_FillOrder_RevertsWhenPaused() public {
        uint256 id = _placeRwaForUsdc(alice);
        vm.prank(admin);
        exchange.pause();
        AsseteraECS.KycAttestation memory f = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        exchange.fillOrder(id, SELL_RWA, f);
        vm.stopPrank();
    }

    function test_Pause_Unpause_Cycle() public {
        vm.prank(admin);
        exchange.pause();
        assertTrue(exchange.paused());
        vm.prank(admin);
        exchange.unpause();
        assertFalse(exchange.paused());
        _placeRwaForUsdc(alice); // works again
    }

    function test_Pause_RevertsIfNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, ADMIN_ROLE));
        exchange.pause();
    }

    function test_Unpause_RevertsIfNotAdmin() public {
        vm.prank(admin);
        exchange.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, ADMIN_ROLE));
        exchange.unpause();
    }

    function test_CancelOrderForUser_RevertsIfNotOpen() public {
        uint256 id = _placeRwaForUsdc(alice);
        vm.prank(admin);
        exchange.cancelOrderForUser(id, alice);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ExchangeStorage.OrderNotOpen.selector, id));
        exchange.cancelOrderForUser(id, alice);
    }

    function test_SetComplianceRequired_TogglesGating() public {
        vm.prank(admin);
        exchange.setComplianceRequired(ExchangeTypes.Action.Fill, false);
        assertFalse(exchange.complianceRequired(uint8(ExchangeTypes.Action.Fill)));
        // fill now works with an empty attestation
        uint256 id = _placeRwaForUsdc(alice);
        AsseteraECS.KycAttestation memory empty;
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.fillOrder(id, SELL_RWA, empty);
        vm.stopPrank();
        assertEq(uint8(exchange.getOrder(id).status), uint8(ExchangeTypes.OrderStatus.Filled));
    }

    // ===================================================================== //
    //                         paramsHash binding                            //
    // ===================================================================== //

    function test_PlaceOrder_RevertsOnParamsHashMismatch() public {
        // Sign attestation for (rwa, SELL_RWA, usdc, WANT_USDC) but call with different buyAmount.
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(GateStorage.ParamsHashMismatch.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC + 1, 0, att, feeAtt);
        vm.stopPrank();
    }

    // ===================================================================== //
    //                       missing-coverage additions                       //
    // ===================================================================== //

    // --- M-1 invariant: nonce NOT burned when param validation fails ----- //

    function test_PlaceOrder_NonceSurvivedAfterParamValidationFailure() public {
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);

        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);

        // InvalidExpiry fires before _consumeKycAndFee — neither nonce may be burned.
        // expireTs <= block.timestamp triggers InvalidExpiry (zero means "no expiry").
        uint64 past = uint64(block.timestamp);
        vm.expectRevert(ExchangeStorage.InvalidExpiry.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, past, att, feeAtt);

        // Same attestations (same nonces) succeed on retry with a valid expiry.
        uint256 id = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();

        assertEq(exchange.getOrder(id).maker, alice);
    }

    // --- cancelOrder has no whenNotPaused modifier ----------------------- //

    function test_CancelOrder_WorksWhenPaused() public {
        uint256 id = _placeRwaForUsdc(alice);
        uint256 bal = rwa.balanceOf(alice);

        vm.prank(admin);
        exchange.pause();
        assertTrue(exchange.paused());

        vm.prank(alice);
        exchange.cancelOrder(id);

        assertEq(uint8(exchange.getOrder(id).status), uint8(ExchangeTypes.OrderStatus.Cancelled));
        assertEq(rwa.balanceOf(alice), bal + SELL_RWA);
    }

    // --- zero buyAmount and zero buyToken -------------------------------- //

    function test_PlaceOrder_RevertsOnZeroBuyAmount() public {
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), 0);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), SELL_RWA, address(usdc), 0);
        vm.prank(alice);
        vm.expectRevert(ExchangeStorage.ZeroAmount.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), 0, 0, att, feeAtt);
    }

    function test_PlaceOrder_RevertsOnZeroBuyToken() public {
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(0), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), SELL_RWA, address(0), WANT_USDC);
        vm.prank(alice);
        vm.expectRevert(GateStorage.ZeroAddress.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(0), WANT_USDC, 0, att, feeAtt);
    }

    // --- sweepExpired returns only remainingQuantity for partial fills --- //

    function test_SweepExpired_PartiallyFilledOrder() public {
        uint64 expireTs = uint64(block.timestamp + 1 hours);
        AsseteraECS.KycAttestation memory placeAtt =
            _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory placeFeeAtt =
            _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        uint256 id =
            exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, expireTs, placeAtt, placeFeeAtt);
        vm.stopPrank();

        vm.prank(admin);
        exchange.setComplianceRequired(ExchangeTypes.Action.Fill, false);

        uint256 halfRwa = SELL_RWA / 2;
        uint256 halfUsdc = (halfRwa * WANT_USDC + SELL_RWA - 1) / SELL_RWA;
        AsseteraECS.KycAttestation memory empty;
        vm.startPrank(bob);
        usdc.approve(address(exchange), halfUsdc);
        exchange.fillOrder(id, halfRwa, empty);
        vm.stopPrank();

        uint256 aliceRwaBefore = rwa.balanceOf(alice);
        vm.warp(block.timestamp + 2 hours);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        exchange.sweepExpired(ids);

        assertEq(uint8(exchange.getOrder(id).status), uint8(ExchangeTypes.OrderStatus.Expired));
        assertEq(rwa.balanceOf(alice), aliceRwaBefore + (SELL_RWA - halfRwa));
    }

    function test_FillOrder_RevertsOnNonZeroParamsHash() public {
        uint256 id = _placeRwaForUsdc(alice);
        // A Fill attestation signed with a non-zero paramsHash must be rejected.
        AsseteraECS.KycAttestation memory att = _signAtt(
            kycSignerPk,
            bob,
            ExchangeTypes.Action.Fill,
            id,
            _freshNonce(),
            block.timestamp + 3 minutes,
            keccak256("nonzero")
        );
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectRevert(GateStorage.ParamsHashMismatch.selector);
        exchange.fillOrder(id, SELL_RWA, att);
        vm.stopPrank();
    }

    function _attestMakeOffer(
        address maker,
        address taker,
        address makerToken,
        uint256 makerAmt,
        address takerToken,
        uint256 takerAmt
    ) internal returns (AsseteraECS.KycAttestation memory) {
        bytes32 ph = keccak256(abi.encodePacked(taker, makerToken, makerAmt, takerToken, takerAmt));
        return
            _signAtt(
                kycSignerPk, maker, ExchangeTypes.Action.MakeOffer, 0, _freshNonce(), block.timestamp + 3 minutes, ph
            );
    }

    /// A valid, fresh zero-fee Fee attestation for MakeOffer actions.
    function _feeMakeOffer(
        address maker,
        address taker,
        address makerToken,
        uint256 makerAmt,
        address takerToken,
        uint256 takerAmt
    ) internal returns (AsseteraECS.FeeAttestation memory) {
        return _feeMakeOfferWithFee(maker, taker, makerToken, makerAmt, takerToken, takerAmt, 0, 0, address(0));
    }

    /// A valid, fresh MakeOffer-bound Fee attestation with explicit fee parameters,
    /// using the fixtures' default settlement currency.
    function _feeMakeOfferWithFee(
        address maker,
        address taker,
        address makerToken,
        uint256 makerAmt,
        address takerToken,
        uint256 takerAmt,
        uint16 makerFeeBps,
        uint16 takerFeeBps,
        address feeCollector
    ) internal returns (AsseteraECS.FeeAttestation memory) {
        return _feeMakeOfferWithFeeToken(
            maker,
            taker,
            makerToken,
            makerAmt,
            takerToken,
            takerAmt,
            makerFeeBps,
            takerFeeBps,
            feeCollector,
            _defaultFeeToken(makerToken, takerToken)
        );
    }

    /// As `_feeMakeOfferWithFee`, but with an explicit settlement currency (AC-833).
    function _feeMakeOfferWithFeeToken(
        address maker,
        address taker,
        address makerToken,
        uint256 makerAmt,
        address takerToken,
        uint256 takerAmt,
        uint16 makerFeeBps,
        uint16 takerFeeBps,
        address feeCollector,
        address feeToken
    ) internal returns (AsseteraECS.FeeAttestation memory) {
        bytes32 ph = keccak256(abi.encodePacked(taker, makerToken, makerAmt, takerToken, takerAmt));
        return _signFeeAtt(
            feeSignerPk,
            maker,
            ExchangeTypes.Action.MakeOffer,
            _freshNonce(),
            block.timestamp + 3 minutes,
            ph,
            makerFeeBps,
            takerFeeBps,
            feeCollector,
            feeToken
        );
    }

    function _attestReplaceOffer(address caller, uint256 offerId, uint256 newMakerAmt, uint256 newTakerAmt)
        internal
        returns (AsseteraECS.KycAttestation memory)
    {
        bytes32 ph = keccak256(abi.encodePacked(offerId, newMakerAmt, newTakerAmt));
        return _signAtt(
            kycSignerPk,
            caller,
            ExchangeTypes.Action.ReplaceOffer,
            offerId,
            _freshNonce(),
            block.timestamp + 3 minutes,
            ph
        );
    }

    function _attestAcceptOffer(address caller, uint256 offerId, uint256 makerAmt, uint256 takerAmt)
        internal
        returns (AsseteraECS.KycAttestation memory)
    {
        bytes32 ph = keccak256(abi.encodePacked(offerId, makerAmt, takerAmt));
        return _signAtt(
            kycSignerPk,
            caller,
            ExchangeTypes.Action.AcceptOffer,
            offerId,
            _freshNonce(),
            block.timestamp + 3 minutes,
            ph
        );
    }

    function _attestCancelOffer(address caller, uint256 offerId, uint256 makerAmt, uint256 takerAmt)
        internal
        returns (AsseteraECS.KycAttestation memory)
    {
        bytes32 ph = keccak256(abi.encodePacked(offerId, makerAmt, takerAmt));
        return _signAtt(
            kycSignerPk,
            caller,
            ExchangeTypes.Action.CancelOffer,
            offerId,
            _freshNonce(),
            block.timestamp + 3 minutes,
            ph
        );
    }

    function _makeOffer(
        address maker,
        address taker,
        address makerToken,
        uint256 makerAmt,
        address takerToken,
        uint256 takerAmt
    ) internal returns (uint256 id) {
        return _makeOfferWithExpiry(maker, taker, makerToken, makerAmt, takerToken, takerAmt, 0);
    }

    function _makeOfferWithExpiry(
        address maker,
        address taker,
        address makerToken,
        uint256 makerAmt,
        address takerToken,
        uint256 takerAmt,
        uint64 expireTs
    ) internal returns (uint256 id) {
        AsseteraECS.KycAttestation memory att =
            _attestMakeOffer(maker, taker, makerToken, makerAmt, takerToken, takerAmt);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feeMakeOffer(maker, taker, makerToken, makerAmt, takerToken, takerAmt);
        vm.startPrank(maker);
        FaucetToken(makerToken).approve(address(exchange), makerAmt);
        id = exchange.makeOffer(0, taker, makerToken, makerAmt, takerToken, takerAmt, expireTs, att, feeAtt);
        vm.stopPrank();
    }

    function _makeOfferWithFee(
        address maker,
        address taker,
        address makerToken,
        uint256 makerAmt,
        address takerToken,
        uint256 takerAmt,
        uint16 makerFeeBps,
        uint16 takerFeeBps,
        address feeCollector
    ) internal returns (uint256 id) {
        AsseteraECS.KycAttestation memory att =
            _attestMakeOffer(maker, taker, makerToken, makerAmt, takerToken, takerAmt);
        AsseteraECS.FeeAttestation memory feeAtt = _feeMakeOfferWithFee(
            maker, taker, makerToken, makerAmt, takerToken, takerAmt, makerFeeBps, takerFeeBps, feeCollector
        );
        vm.startPrank(maker);
        // AC-833: when the maker proposes the CURRENCY leg they are the currency payer,
        // so the escrow is makerAmt + their own fee. Approving only makerAmt is exactly
        // the shortfall the front-ends have to fix too.
        FaucetToken(makerToken).approve(address(exchange), makerAmt + (makerAmt * makerFeeBps) / 10_000);
        id = exchange.makeOffer(0, taker, makerToken, makerAmt, takerToken, takerAmt, 0, att, feeAtt);
        vm.stopPrank();
    }

    // FeeGate._verifyFee negative-path
    function test_PlaceOrder_RevertsOnFeeAccountMismatch() public {
        // Fee attestation is for bob, but alice is acting.
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(IFeeGate.FeeAccountMismatch.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_PlaceOrder_RevertsOnFeeActionMismatch() public {
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        bytes32 ph = keccak256(abi.encode(address(rwa), SELL_RWA, address(usdc), WANT_USDC));
        AsseteraECS.FeeAttestation memory feeAtt = _signFeeAtt(
            feeSignerPk,
            alice,
            ExchangeTypes.Action.Fill,
            _freshNonce(),
            block.timestamp + 3 minutes,
            ph,
            0,
            0,
            address(0),
            address(usdc)
        );
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(IFeeGate.FeeActionMismatch.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_PlaceOrder_RevertsOnFeeExpiredAttestation() public {
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        bytes32 ph = keccak256(abi.encode(address(rwa), SELL_RWA, address(usdc), WANT_USDC));
        AsseteraECS.FeeAttestation memory feeAtt = _signFeeAtt(
            feeSignerPk,
            alice,
            ExchangeTypes.Action.Place,
            _freshNonce(),
            block.timestamp + 100,
            ph,
            0,
            0,
            address(0),
            address(usdc)
        );
        vm.warp(block.timestamp + 101);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(IFeeGate.FeeExpired.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_PlaceOrder_RevertsOnFeeTtlTooLong() public {
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        bytes32 ph = keccak256(abi.encode(address(rwa), SELL_RWA, address(usdc), WANT_USDC));
        AsseteraECS.FeeAttestation memory feeAtt = _signFeeAtt(
            feeSignerPk,
            alice,
            ExchangeTypes.Action.Place,
            _freshNonce(),
            block.timestamp + 16 minutes,
            ph,
            0,
            0,
            address(0),
            address(usdc)
        );
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(IFeeGate.FeeTtlTooLong.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_PlaceOrder_RevertsOnFeeNonceReuse() public {
        AsseteraECS.KycAttestation memory att1 = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA * 2);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att1, feeAtt);

        // Fresh KYC attestation (new nonce) but the SAME fee attestation, already consumed above.
        AsseteraECS.KycAttestation memory att2 = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.expectRevert(IFeeGate.FeeNonceUsed.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att2, feeAtt);
        vm.stopPrank();
    }

    // ===================================================================== //
    //     placeOrder / placeOrderWithPermit missing-branch coverage (I-2)   //
    // ===================================================================== //

    function test_PlaceOrder_RevertsOnFeeParamsHashMismatch() public {
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        // Fee attestation signed for a different buyAmount than the actual call.
        AsseteraECS.FeeAttestation memory feeAtt =
            _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC + 1);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(GateStorage.ParamsHashMismatch.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_PlaceOrderWithPermit_RevertsOnZeroSellToken() public {
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(0), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(0), SELL_RWA, address(usdc), WANT_USDC);
        vm.prank(alice);
        vm.expectRevert(GateStorage.ZeroAddress.selector);
        exchange.placeOrderWithPermit(
            address(0), SELL_RWA, address(usdc), WANT_USDC, 0, 0, 0, bytes32(0), bytes32(0), att, feeAtt
        );
    }

    function test_PlaceOrderWithPermit_RevertsOnZeroAmount() public {
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), 0, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), 0, address(usdc), WANT_USDC);
        vm.prank(alice);
        vm.expectRevert(ExchangeStorage.ZeroAmount.selector);
        exchange.placeOrderWithPermit(
            address(rwa), 0, address(usdc), WANT_USDC, 0, 0, 0, bytes32(0), bytes32(0), att, feeAtt
        );
    }

    function test_PlaceOrderWithPermit_RevertsOnSameToken() public {
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(rwa), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), SELL_RWA, address(rwa), WANT_USDC);
        vm.prank(alice);
        vm.expectRevert(ExchangeStorage.SameToken.selector);
        exchange.placeOrderWithPermit(
            address(rwa), SELL_RWA, address(rwa), WANT_USDC, 0, 0, 0, bytes32(0), bytes32(0), att, feeAtt
        );
    }

    function test_PlaceOrderWithPermit_RevertsOnInvalidExpiry() public {
        vm.warp(1 hours);
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.prank(alice);
        vm.expectRevert(ExchangeStorage.InvalidExpiry.selector);
        exchange.placeOrderWithPermit(
            address(rwa),
            SELL_RWA,
            address(usdc),
            WANT_USDC,
            uint64(block.timestamp - 1),
            0,
            0,
            bytes32(0),
            bytes32(0),
            att,
            feeAtt
        );
    }

    function test_PlaceOrderWithPermit_RevertsOnParamsHashMismatch() public {
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.prank(alice);
        vm.expectRevert(GateStorage.ParamsHashMismatch.selector);
        exchange.placeOrderWithPermit(
            address(rwa), SELL_RWA, address(usdc), WANT_USDC + 1, 0, 0, 0, bytes32(0), bytes32(0), att, feeAtt
        );
    }

    function test_PlaceOrderWithPermit_RevertsOnFeeParamsHashMismatch() public {
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC + 1);
        vm.prank(alice);
        vm.expectRevert(GateStorage.ParamsHashMismatch.selector);
        exchange.placeOrderWithPermit(
            address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, 0, 0, bytes32(0), bytes32(0), att, feeAtt
        );
    }

    // ── Happy paths ────────────────────────────────────────────────────── //

    function test_Offer_MultipleRounds_MakerCounterCounters() public {
        // Alice offers → Bob counters → Alice counter-counters → Bob accepts → settle.
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);

        uint256 round2Usdc = 800e6;
        uint256 round3Usdc = 900e6;

        // Round 2: Bob counters with 800 USDC.
        AsseteraECS.KycAttestation memory r2 = _attestReplaceOffer(bob, id, SELL_RWA, round2Usdc);
        vm.startPrank(bob);
        usdc.approve(address(exchange), round2Usdc);
        exchange.replaceOffer(id, SELL_RWA, round2Usdc, 0, r2);
        vm.stopPrank();

        assertEq(exchange.getOffer(id).proposedBy, bob);
        assertEq(exchange.getOffer(id).takerAmount, round2Usdc);

        // Round 3: Alice counter-counters with 900 USDC (returns Bob's 800 USDC).
        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        AsseteraECS.KycAttestation memory r3 = _attestReplaceOffer(alice, id, SELL_RWA, round3Usdc);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        exchange.replaceOffer(id, SELL_RWA, round3Usdc, 0, r3);
        vm.stopPrank();

        assertEq(exchange.getOffer(id).proposedBy, alice);
        assertEq(exchange.getOffer(id).takerAmount, round3Usdc);
        assertEq(usdc.balanceOf(bob), bobUsdcBefore + round2Usdc); // Bob's USDC returned

        // Bob accepts Alice's 900 USDC counter — settles atomically in the same
        // call (AC-246): no separate operator step, multi-round countering
        // ends in a completed trade.
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 bobRwaBefore = rwa.balanceOf(bob);
        AsseteraECS.KycAttestation memory acceptAtt = _attestAcceptOffer(bob, id, SELL_RWA, round3Usdc);
        vm.startPrank(bob);
        usdc.approve(address(exchange), round3Usdc);
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();

        assertEq(uint8(exchange.getOffer(id).status), uint8(ExchangeTypes.OfferStatus.Settled));
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + round3Usdc);
        assertEq(rwa.balanceOf(bob), bobRwaBefore + SELL_RWA);
        assertEq(rwa.balanceOf(address(exchange)), 0, "exchange holds no RWA");
        assertEq(usdc.balanceOf(address(exchange)), 0, "exchange holds no USDC");
    }

    function test_Offer_CancelOpenOffer_MakerGetEscrowBack() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        uint256 aliceRwaBefore = rwa.balanceOf(alice);

        AsseteraECS.KycAttestation memory att = _attestCancelOffer(alice, id, SELL_RWA, WANT_USDC);
        vm.prank(alice);
        exchange.cancelOffer(id, att);

        assertEq(uint8(exchange.getOffer(id).status), uint8(ExchangeTypes.OfferStatus.Cancelled));
        assertEq(rwa.balanceOf(alice), aliceRwaBefore + SELL_RWA);
    }

    function test_Offer_TakerCancelsAfterCounter_TakerGetEscrowBack() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);

        // Bob counters — Bob now holds the escrow.
        AsseteraECS.KycAttestation memory replaceAtt = _attestReplaceOffer(bob, id, SELL_RWA, 800e6);
        vm.startPrank(bob);
        usdc.approve(address(exchange), 800e6);
        exchange.replaceOffer(id, SELL_RWA, 800e6, 0, replaceAtt);
        vm.stopPrank();

        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        AsseteraECS.KycAttestation memory cancelAtt = _attestCancelOffer(bob, id, SELL_RWA, 800e6);
        vm.prank(bob);
        exchange.cancelOffer(id, cancelAtt);

        assertEq(uint8(exchange.getOffer(id).status), uint8(ExchangeTypes.OfferStatus.Cancelled));
        assertEq(usdc.balanceOf(bob), bobUsdcBefore + 800e6); // Bob's USDC returned
    }

    // ── Compliance flags ───────────────────────────────────────────────── //

    function test_Offer_ComplianceFlagsSetOnDeploy() public view {
        assertTrue(exchange.complianceRequired(uint8(ExchangeTypes.Action.MakeOffer)));
        assertTrue(exchange.complianceRequired(uint8(ExchangeTypes.Action.ReplaceOffer)));
        assertTrue(exchange.complianceRequired(uint8(ExchangeTypes.Action.AcceptOffer)));
        assertTrue(exchange.complianceRequired(uint8(ExchangeTypes.Action.CancelOffer)));
        // Action.SettleOffer is unused (AC-246) — acceptOffer settles atomically
        // under AcceptOffer's own gate, so this default is intentionally left unset.
        assertFalse(exchange.complianceRequired(uint8(ExchangeTypes.Action.SettleOffer)));
    }

    // ── Event shape ───────────────────────────────────────────────────── //

    function test_Offer_EmitsOfferAccepted_WithTerms() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.KycAttestation memory att = _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);

        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectEmit(true, true, false, true);
        emit OfferBook.OfferAccepted(id, bob, SELL_RWA, WANT_USDC, 0);
        exchange.acceptOffer(id, att);
        vm.stopPrank();
    }

    function test_Offer_EmitsOfferSettled_WithFeeTerms() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);
        uint256 id = _makeOfferWithFee(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 100, 50, carol);

        // AC-833: BOTH fees are charged on the currency leg (usdc), never on the asset.
        // The event now reports GROSS leg amounts — net is gross − that party's own fee.
        uint256 makerFeeAmt = (WANT_USDC * 100) / 10_000;
        uint256 takerFeeAmt = (WANT_USDC * 50) / 10_000;
        AsseteraECS.KycAttestation memory att = _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);

        vm.startPrank(bob);
        // Bob is the currency payer: he owes the notional PLUS his own fee.
        usdc.approve(address(exchange), WANT_USDC + takerFeeAmt);
        vm.expectEmit(true, true, false, true);
        emit OfferBook.OfferSettled(id, bob, SELL_RWA, WANT_USDC, makerFeeAmt, takerFeeAmt, carol, address(usdc));
        exchange.acceptOffer(id, att);
        vm.stopPrank();
    }

    function test_Offer_MakerAcceptsCounter_SettlesCorrectly() public {
        // Taker counters (proposedBy flips to taker); maker then accepts —
        // exercises the "caller == maker" branch of acceptOffer's atomic
        // settle (AC-246), distinct from every other acceptOffer test in this
        // file where the taker is the one accepting.
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);

        uint256 counterUsdc = 900e6;
        AsseteraECS.KycAttestation memory counterAtt = _attestReplaceOffer(bob, id, SELL_RWA, counterUsdc);
        vm.startPrank(bob);
        usdc.approve(address(exchange), counterUsdc);
        exchange.replaceOffer(id, SELL_RWA, counterUsdc, 0, counterAtt);
        vm.stopPrank();
        assertEq(exchange.getOffer(id).proposedBy, bob);

        // Bob's counter returned alice's original RWA escrow to her wallet
        // (replaceOffer always returns the *previous* proposer's side) — her
        // first approval was already consumed by that original transferFrom,
        // so she must re-approve before her own accepting pull can succeed.
        uint256 aliceRwaBefore = rwa.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 bobRwaBefore = rwa.balanceOf(bob);

        AsseteraECS.KycAttestation memory acceptAtt = _attestAcceptOffer(alice, id, SELL_RWA, counterUsdc);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();

        assertEq(uint8(exchange.getOffer(id).status), uint8(ExchangeTypes.OfferStatus.Settled));
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + counterUsdc, "maker (accepting) receives USDC");
        assertEq(rwa.balanceOf(bob), bobRwaBefore + SELL_RWA, "taker (proposer) receives RWA");
        assertEq(rwa.balanceOf(alice), aliceRwaBefore - SELL_RWA, "alice's re-escrowed RWA leaves on accept");
        assertEq(rwa.balanceOf(address(exchange)), 0, "exchange holds no RWA");
        assertEq(usdc.balanceOf(address(exchange)), 0, "exchange holds no USDC");
    }

    function test_AcceptOffer_ReentrancyGuarded() public {
        // Unlike test_FillOrder_ReentrancyGuarded, no gating needs disabling
        // here: acceptOffer's own attestation is real and valid, and the
        // nested fillOrder call reverts at the nonReentrant guard (a modifier,
        // evaluated before the function body) regardless of Fill gating state.
        ReentrantToken evil = new ReentrantToken();
        evil.mint(bob, 1_000e18);

        uint256 id;
        {
            AsseteraECS.KycAttestation memory att =
                _attestMakeOffer(alice, bob, address(rwa), SELL_RWA, address(evil), 100e18);
            AsseteraECS.FeeAttestation memory feeAtt =
                _feeMakeOffer(alice, bob, address(rwa), SELL_RWA, address(evil), 100e18);
            vm.startPrank(alice);
            rwa.approve(address(exchange), SELL_RWA);
            id = exchange.makeOffer(0, bob, address(rwa), SELL_RWA, address(evil), 100e18, 0, att, feeAtt);
            vm.stopPrank();
        }
        // targetOrderId (1) is unreachable — the reentrant fillOrder call reverts
        // at the nonReentrant guard before ever touching order data.
        AsseteraECS.KycAttestation memory empty;
        evil.arm(address(exchange), abi.encodeCall(OrderBook.fillOrder, (1, 1, empty)));

        AsseteraECS.KycAttestation memory acceptAtt = _attestAcceptOffer(bob, id, SELL_RWA, 100e18);
        vm.startPrank(bob);
        evil.approve(address(exchange), type(uint256).max);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();
    }

    // ===================================================================== //
    //     I-2(c): reentrancy across every funds-custody entry point         //
    // ===================================================================== //
    // Each test uses ReentrantToken as one of the trade's tokens and arms it
    // to attempt a nested call into cancelOrder(999) (a nonexistent order —
    // irrelevant, since the shared nonReentrant guard reverts before the
    // reentrant call body ever runs). Together with test_FillOrder_ReentrancyGuarded
    // and test_AcceptOffer_ReentrancyGuarded above, this exercises every
    // state-changing, token-moving entry point on the exchange.

    function test_PlaceOrder_ReentrancyGuarded() public {
        ReentrantToken evil = new ReentrantToken();
        evil.mint(alice, 1_000e18);

        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(evil), 100e18, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(evil), 100e18, address(usdc), WANT_USDC);
        evil.arm(address(exchange), abi.encodeCall(OrderBook.cancelOrder, (999)));

        vm.startPrank(alice);
        evil.approve(address(exchange), type(uint256).max);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        exchange.placeOrder(address(evil), 100e18, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_PlaceOrderWithPermit_ReentrancyGuarded() public {
        ReentrantToken evil = new ReentrantToken();
        evil.mint(alice, 1_000e18);

        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(evil), 100e18, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(evil), 100e18, address(usdc), WANT_USDC);
        evil.arm(address(exchange), abi.encodeCall(OrderBook.cancelOrder, (999)));

        // ReentrantToken has no permit — _tryPermit's try/catch swallows the
        // revert and falls through to safeTransferFrom, same as I-3.
        vm.startPrank(alice);
        evil.approve(address(exchange), type(uint256).max);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        exchange.placeOrderWithPermit(
            address(evil), 100e18, address(usdc), WANT_USDC, 0, 0, 0, bytes32(0), bytes32(0), att, feeAtt
        );
        vm.stopPrank();
    }

    function test_CancelOrder_ReentrancyGuarded() public {
        ReentrantToken evil = new ReentrantToken();
        evil.mint(alice, 1_000e18);

        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(evil), 100e18, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(evil), 100e18, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        evil.approve(address(exchange), type(uint256).max);
        uint256 id = exchange.placeOrder(address(evil), 100e18, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();

        evil.arm(address(exchange), abi.encodeCall(OrderBook.cancelOrder, (999)));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        exchange.cancelOrder(id);
    }

    function test_SweepExpired_ReentrancyGuarded() public {
        ReentrantToken evil = new ReentrantToken();
        evil.mint(alice, 1_000e18);

        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(evil), 100e18, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(evil), 100e18, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        evil.approve(address(exchange), type(uint256).max);
        uint256 id = exchange.placeOrder(
            address(evil), 100e18, address(usdc), WANT_USDC, uint64(block.timestamp + 1), att, feeAtt
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 2);
        evil.arm(address(exchange), abi.encodeCall(OrderBook.cancelOrder, (999)));

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        exchange.sweepExpired(ids);
    }

    function test_MakeOffer_ReentrancyGuarded() public {
        ReentrantToken evil = new ReentrantToken();
        evil.mint(alice, 1_000e18);

        AsseteraECS.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(evil), 100e18, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, bob, address(evil), 100e18, address(usdc), WANT_USDC);
        evil.arm(address(exchange), abi.encodeCall(OrderBook.cancelOrder, (999)));

        vm.startPrank(alice);
        evil.approve(address(exchange), type(uint256).max);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        exchange.makeOffer(0, bob, address(evil), 100e18, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_ReplaceOffer_ReentrancyGuarded() public {
        ReentrantToken evil = new ReentrantToken();
        evil.mint(alice, 1_000e18);

        AsseteraECS.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(evil), 100e18, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, bob, address(evil), 100e18, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        evil.approve(address(exchange), type(uint256).max);
        uint256 id = exchange.makeOffer(0, bob, address(evil), 100e18, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();

        // Bob's counter first returns alice's evil-token escrow — that's the
        // leg we hook. His usdc leg would come after, never reached.
        evil.arm(address(exchange), abi.encodeCall(OrderBook.cancelOrder, (999)));

        AsseteraECS.KycAttestation memory replaceAtt = _attestReplaceOffer(bob, id, 100e18, WANT_USDC + 1);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC + 1);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        exchange.replaceOffer(id, 100e18, WANT_USDC + 1, 0, replaceAtt);
        vm.stopPrank();
    }

    function test_CancelOffer_ReentrancyGuarded() public {
        ReentrantToken evil = new ReentrantToken();
        evil.mint(alice, 1_000e18);

        AsseteraECS.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(evil), 100e18, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, bob, address(evil), 100e18, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        evil.approve(address(exchange), type(uint256).max);
        uint256 id = exchange.makeOffer(0, bob, address(evil), 100e18, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();

        evil.arm(address(exchange), abi.encodeCall(OrderBook.cancelOrder, (999)));

        AsseteraECS.KycAttestation memory cancelAtt = _attestCancelOffer(alice, id, 100e18, WANT_USDC);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        exchange.cancelOffer(id, cancelAtt);
    }

    function test_SweepExpiredOffers_ReentrancyGuarded() public {
        ReentrantToken evil = new ReentrantToken();
        evil.mint(alice, 1_000e18);

        AsseteraECS.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(evil), 100e18, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, bob, address(evil), 100e18, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        evil.approve(address(exchange), type(uint256).max);
        uint256 id = exchange.makeOffer(
            0, bob, address(evil), 100e18, address(usdc), WANT_USDC, uint64(block.timestamp + 1), att, feeAtt
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 2);
        evil.arm(address(exchange), abi.encodeCall(OrderBook.cancelOrder, (999)));

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        exchange.sweepExpiredOffers(ids);
    }

    function test_CancelOrderForUser_ReentrancyGuarded() public {
        ReentrantToken evil = new ReentrantToken();
        evil.mint(alice, 1_000e18);

        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(evil), 100e18, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(evil), 100e18, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        evil.approve(address(exchange), type(uint256).max);
        uint256 id = exchange.placeOrder(address(evil), 100e18, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();

        evil.arm(address(exchange), abi.encodeCall(OrderBook.cancelOrder, (999)));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        exchange.cancelOrderForUser(id, carol);
    }

    function test_CancelOfferForUser_ReentrancyGuarded() public {
        ReentrantToken evil = new ReentrantToken();
        evil.mint(alice, 1_000e18);

        AsseteraECS.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(evil), 100e18, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, bob, address(evil), 100e18, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        evil.approve(address(exchange), type(uint256).max);
        uint256 id = exchange.makeOffer(0, bob, address(evil), 100e18, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();

        evil.arm(address(exchange), abi.encodeCall(OrderBook.cancelOrder, (999)));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        exchange.cancelOfferForUser(id, carol, carol);
    }

    function test_Offer_EmitsOfferCancelled_WithTerms() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.KycAttestation memory att = _attestCancelOffer(alice, id, SELL_RWA, WANT_USDC);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit OfferBook.OfferCancelled(id, alice, SELL_RWA, WANT_USDC);
        exchange.cancelOffer(id, att);
    }

    // ── Sad paths ──────────────────────────────────────────────────────── //

    function test_Offer_RevertsOnSelfTarget() public {
        AsseteraECS.KycAttestation memory att =
            _attestMakeOffer(alice, alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(OfferBook.OfferSelfTarget.selector);
        exchange.makeOffer(0, alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_Offer_ReplaceRevertsForThirdParty() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.KycAttestation memory att = _attestReplaceOffer(carol, id, SELL_RWA, 800e6);
        vm.startPrank(carol);
        usdc.approve(address(exchange), 800e6);
        vm.expectRevert(abi.encodeWithSelector(OfferBook.NotOfferParty.selector, id));
        exchange.replaceOffer(id, SELL_RWA, 800e6, 0, att);
        vm.stopPrank();
    }

    function test_Offer_AcceptRevertsIfProposerTriesToAcceptOwnOffer() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.KycAttestation memory att = _attestAcceptOffer(alice, id, SELL_RWA, WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(abi.encodeWithSelector(OfferBook.AcceptorIsProposer.selector, id));
        exchange.acceptOffer(id, att);
        vm.stopPrank();
    }

    function test_Offer_CancelRevertsAfterAccept() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);

        AsseteraECS.KycAttestation memory acceptAtt = _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();

        AsseteraECS.KycAttestation memory cancelAtt = _attest(alice, ExchangeTypes.Action.CancelOffer, id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ExchangeStorage.OfferNotOpen.selector, id));
        exchange.cancelOffer(id, cancelAtt);
    }

    function test_Offer_AcceptRevertsIfExpired() public {
        AsseteraECS.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        uint64 expireTs = uint64(block.timestamp + 1 hours);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        uint256 id = exchange.makeOffer(0, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, expireTs, att, feeAtt);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 hours);

        AsseteraECS.KycAttestation memory acceptAtt = _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectRevert(abi.encodeWithSelector(OfferBook.OfferIsExpired.selector, id));
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();
    }

    function test_Offer_MakeRevertsOnWrongParamsHash() public {
        // Sign with mismatched takerAmount in paramsHash.
        bytes32 badHash = keccak256(abi.encodePacked(bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC + 1));
        AsseteraECS.KycAttestation memory att = _signAtt(
            kycSignerPk, alice, ExchangeTypes.Action.MakeOffer, 0, _freshNonce(), block.timestamp + 3 minutes, badHash
        );
        AsseteraECS.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(GateStorage.ParamsHashMismatch.selector);
        exchange.makeOffer(0, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_Offer_ReplaceRevertsOnWrongParamsHash() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        // Sign with a different newTakerAmount than what will be passed.
        bytes32 badHash = keccak256(abi.encodePacked(id, SELL_RWA, uint256(800e6 + 1)));
        AsseteraECS.KycAttestation memory att = _signAtt(
            kycSignerPk, bob, ExchangeTypes.Action.ReplaceOffer, id, _freshNonce(), block.timestamp + 3 minutes, badHash
        );
        vm.startPrank(bob);
        usdc.approve(address(exchange), 800e6);
        vm.expectRevert(GateStorage.ParamsHashMismatch.selector);
        exchange.replaceOffer(id, SELL_RWA, 800e6, 0, att);
        vm.stopPrank();
    }

    function test_Offer_AcceptRevertsOnWrongParamsHash() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        // Attestation signed with mismatched takerAmount.
        bytes32 badHash = keccak256(abi.encodePacked(id, SELL_RWA, WANT_USDC + 1));
        AsseteraECS.KycAttestation memory att = _signAtt(
            kycSignerPk, bob, ExchangeTypes.Action.AcceptOffer, id, _freshNonce(), block.timestamp + 3 minutes, badHash
        );
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectRevert(GateStorage.ParamsHashMismatch.selector);
        exchange.acceptOffer(id, att);
        vm.stopPrank();
    }

    function test_Offer_CancelRevertsOnWrongParamsHash() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        // Attestation signed with mismatched makerAmount.
        bytes32 badHash = keccak256(abi.encodePacked(id, SELL_RWA + 1, WANT_USDC));
        AsseteraECS.KycAttestation memory att = _signAtt(
            kycSignerPk,
            alice,
            ExchangeTypes.Action.CancelOffer,
            id,
            _freshNonce(),
            block.timestamp + 3 minutes,
            badHash
        );
        vm.prank(alice);
        vm.expectRevert(GateStorage.ParamsHashMismatch.selector);
        exchange.cancelOffer(id, att);
    }

    function test_Offer_MakeRevertsOnNonceReplay() public {
        AsseteraECS.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA * 2);
        exchange.makeOffer(0, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.expectRevert(IKycGate.KycNonceUsed.selector);
        exchange.makeOffer(0, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_Offer_RevertsOnNonExistentOffer() public {
        AsseteraECS.KycAttestation memory att = _attest(alice, ExchangeTypes.Action.CancelOffer, 999);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ExchangeStorage.OfferNotFound.selector, 999));
        exchange.cancelOffer(999, att);
    }

    // makeOffer / replaceOffer / cancelOffer / acceptOffer

    function test_Offer_MakeRevertsOnZeroAddress() public {
        AsseteraECS.KycAttestation memory att =
            _attestMakeOffer(alice, address(0), address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, address(0), address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(GateStorage.ZeroAddress.selector);
        exchange.makeOffer(0, address(0), address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_Offer_MakeRevertsOnZeroAmount() public {
        AsseteraECS.KycAttestation memory att = _attestMakeOffer(alice, bob, address(rwa), 0, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feeMakeOffer(alice, bob, address(rwa), 0, address(usdc), WANT_USDC);
        vm.prank(alice);
        vm.expectRevert(ExchangeStorage.ZeroAmount.selector);
        exchange.makeOffer(0, bob, address(rwa), 0, address(usdc), WANT_USDC, 0, att, feeAtt);
    }

    function test_Offer_MakeRevertsOnSameToken() public {
        AsseteraECS.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(rwa), SELL_RWA, address(rwa), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, bob, address(rwa), SELL_RWA, address(rwa), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(ExchangeStorage.SameToken.selector);
        exchange.makeOffer(0, bob, address(rwa), SELL_RWA, address(rwa), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_Offer_MakeRevertsOnInvalidExpiry() public {
        vm.warp(1 hours);
        AsseteraECS.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(ExchangeStorage.InvalidExpiry.selector);
        exchange.makeOffer(
            0, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, uint64(block.timestamp - 1), att, feeAtt
        );
        vm.stopPrank();
    }

    function test_Offer_MakeRevertsOnFeeParamsHashMismatch() public {
        AsseteraECS.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        // Fee attestation signed for a different takerAmount than the actual call.
        AsseteraECS.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC + 1);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(GateStorage.ParamsHashMismatch.selector);
        exchange.makeOffer(0, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_Offer_ReplaceRevertsOnNonExistentOffer() public {
        AsseteraECS.KycAttestation memory att = _attestReplaceOffer(alice, 999, SELL_RWA, WANT_USDC);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ExchangeStorage.OfferNotFound.selector, 999));
        exchange.replaceOffer(999, SELL_RWA, WANT_USDC, 0, att);
    }

    function test_Offer_ReplaceRevertsIfNotOpen() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.KycAttestation memory acceptAtt = _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.acceptOffer(id, acceptAtt); // -> Settled, no longer Open/Countered.
        vm.stopPrank();

        AsseteraECS.KycAttestation memory att = _attestReplaceOffer(alice, id, SELL_RWA, 800e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ExchangeStorage.OfferNotOpen.selector, id));
        exchange.replaceOffer(id, SELL_RWA, 800e6, 0, att);
    }

    function test_Offer_ReplaceRevertsIfExpired() public {
        uint64 expireTs = uint64(block.timestamp + 1 hours);
        uint256 id = _makeOfferWithExpiry(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, expireTs);
        vm.warp(block.timestamp + 2 hours);

        AsseteraECS.KycAttestation memory att = _attestReplaceOffer(bob, id, SELL_RWA, 800e6);
        vm.startPrank(bob);
        usdc.approve(address(exchange), 800e6);
        vm.expectRevert(abi.encodeWithSelector(OfferBook.OfferIsExpired.selector, id));
        exchange.replaceOffer(id, SELL_RWA, 800e6, 0, att);
        vm.stopPrank();
    }

    function test_Offer_ReplaceRevertsOnZeroAmount() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.KycAttestation memory att = _attestReplaceOffer(bob, id, 0, 800e6);
        vm.prank(bob);
        vm.expectRevert(ExchangeStorage.ZeroAmount.selector);
        exchange.replaceOffer(id, 0, 800e6, 0, att);
    }

    function test_Offer_ReplaceRevertsOnInvalidExpiry() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.warp(1 hours);
        AsseteraECS.KycAttestation memory att = _attestReplaceOffer(bob, id, SELL_RWA, 800e6);
        vm.prank(bob);
        vm.expectRevert(ExchangeStorage.InvalidExpiry.selector);
        exchange.replaceOffer(id, SELL_RWA, 800e6, uint64(block.timestamp - 1), att);
    }

    function test_Offer_CancelRevertsForThirdParty() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.KycAttestation memory att = _attestCancelOffer(carol, id, SELL_RWA, WANT_USDC);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(OfferBook.NotOfferParty.selector, id));
        exchange.cancelOffer(id, att);
    }

    function test_Offer_AcceptRevertsOnNonExistentOffer() public {
        AsseteraECS.KycAttestation memory att = _attestAcceptOffer(alice, 999, SELL_RWA, WANT_USDC);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ExchangeStorage.OfferNotFound.selector, 999));
        exchange.acceptOffer(999, att);
    }

    function test_Offer_AcceptRevertsIfNotOpen() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.KycAttestation memory firstAtt = _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.acceptOffer(id, firstAtt); // -> Settled
        vm.stopPrank();

        AsseteraECS.KycAttestation memory secondAtt = _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ExchangeStorage.OfferNotOpen.selector, id));
        exchange.acceptOffer(id, secondAtt);
    }

    function test_Offer_AcceptRevertsForThirdParty() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.KycAttestation memory att = _attestAcceptOffer(carol, id, SELL_RWA, WANT_USDC);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(OfferBook.NotOfferParty.selector, id));
        exchange.acceptOffer(id, att);
    }

    // --- cancelOfferForUser ---

    function test_CancelOfferForUser_OpenOffer_ReturnsMakerEscrow() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);

        uint256 aliceBefore = rwa.balanceOf(alice);
        vm.prank(admin);
        exchange.cancelOfferForUser(id, alice, bob);

        assertEq(rwa.balanceOf(alice), aliceBefore + SELL_RWA);
        assertEq(uint8(exchange.getOffer(id).status), uint8(ExchangeTypes.OfferStatus.ForceCancelled));
    }

    function test_CancelOfferForUser_CounteredOffer_ReturnsTakerEscrow() public {
        // Bob counters: Bob's takerToken is now escrowed (proposedBy = bob).
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.KycAttestation memory replaceAtt = _attestReplaceOffer(bob, id, SELL_RWA, WANT_USDC * 2);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC * 2);
        exchange.replaceOffer(id, SELL_RWA, WANT_USDC * 2, 0, replaceAtt);
        vm.stopPrank();

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(admin);
        exchange.cancelOfferForUser(id, alice, bob);

        assertEq(usdc.balanceOf(bob), bobBefore + WANT_USDC * 2);
    }

    function test_CancelOfferForUser_RevertsOnAlreadySettledOffer() public {
        // acceptOffer settles atomically (AC-246) — there's no window where an
        // offer sits Accepted-but-unswept for admin to "rescue"; cancelOfferForUser
        // now only accepts Open/Countered.
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.KycAttestation memory acceptAtt = _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();

        assertEq(uint8(exchange.getOffer(id).status), uint8(ExchangeTypes.OfferStatus.Settled));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ExchangeStorage.OfferNotOpen.selector, id));
        exchange.cancelOfferForUser(id, alice, bob);
    }

    function test_CancelOfferForUser_RevertsIfNotAdmin() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.prank(alice);
        vm.expectRevert();
        exchange.cancelOfferForUser(id, alice, bob);
    }

    function test_CancelOfferForUser_RevertsOnExpiredOffer() public {
        // Regression: cancelOfferForUser on an already-swept offer must revert,
        // not drain another user's escrowed tokens from the contract.
        uint64 expiry = uint64(block.timestamp + 1 hours);
        uint256 id = _makeOfferWithExpiry(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, expiry);

        // Sweep the expired offer — alice's RWA returned, status = Expired.
        vm.warp(block.timestamp + 1 hours + 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        exchange.sweepExpiredOffers(ids);
        assertEq(uint8(exchange.getOffer(id).status), uint8(ExchangeTypes.OfferStatus.Expired));

        // Admin calling cancelOfferForUser on an Expired offer must revert.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ExchangeStorage.OfferNotOpen.selector, id));
        exchange.cancelOfferForUser(id, alice, bob);
    }

    function test_CancelOfferForUser_RevertsOnZeroRecipient() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.prank(admin);
        vm.expectRevert(GateStorage.ZeroAddress.selector);
        exchange.cancelOfferForUser(id, address(0), bob);
    }

    function test_CancelOfferForUser_RevertsOnNonExistentOffer() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ExchangeStorage.OfferNotFound.selector, 999));
        exchange.cancelOfferForUser(999, alice, bob);
    }

    function test_CancelOfferForUser_EmitsOfferForceCancelled() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.prank(admin);
        vm.expectEmit(true, true, false, true);
        emit ExchangeAdmin.OfferForceCancelled(id, alice, alice, bob, admin);
        exchange.cancelOfferForUser(id, alice, bob);
    }

    // --- sweepExpiredOffers ---

    function test_SweepExpiredOffers_ReturnsMakerEscrow() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);
        uint256 id = _makeOfferWithExpiry(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, expiry);

        vm.warp(block.timestamp + 1 hours + 1);
        uint256 aliceBefore = rwa.balanceOf(alice);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        exchange.sweepExpiredOffers(ids);

        assertEq(rwa.balanceOf(alice), aliceBefore + SELL_RWA);
        assertEq(uint8(exchange.getOffer(id).status), uint8(ExchangeTypes.OfferStatus.Expired));
    }

    function test_SweepExpiredOffers_CounteredOffer_ReturnsTakerEscrow() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);
        uint256 id = _makeOfferWithExpiry(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, expiry);

        // Bob counters — Bob's takerToken is now escrowed, new expiry set by Bob.
        uint64 newExpiry = uint64(block.timestamp + 2 hours);
        AsseteraECS.KycAttestation memory replaceAtt = _attestReplaceOffer(bob, id, SELL_RWA, WANT_USDC * 2);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC * 2);
        exchange.replaceOffer(id, SELL_RWA, WANT_USDC * 2, newExpiry, replaceAtt);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 hours + 1);
        uint256 bobBefore = usdc.balanceOf(bob);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        exchange.sweepExpiredOffers(ids);

        assertEq(usdc.balanceOf(bob), bobBefore + WANT_USDC * 2);
        assertEq(uint8(exchange.getOffer(id).status), uint8(ExchangeTypes.OfferStatus.Expired));
    }

    function test_SweepExpiredOffers_SkipsNonExpired() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);
        uint256 id = _makeOfferWithExpiry(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, expiry);

        // Not yet expired — should be a no-op.
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        exchange.sweepExpiredOffers(ids);

        assertEq(uint8(exchange.getOffer(id).status), uint8(ExchangeTypes.OfferStatus.Open));
    }

    function test_SweepExpiredOffers_SkipsNoExpiry() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC); // expireTs=0

        vm.warp(block.timestamp + 365 days);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        exchange.sweepExpiredOffers(ids);

        assertEq(uint8(exchange.getOffer(id).status), uint8(ExchangeTypes.OfferStatus.Open));
    }

    function test_SweepExpiredOffers_SkipsSettledOffer() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);
        uint256 id = _makeOfferWithExpiry(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, expiry);

        // Bob accepts before expiry — settles atomically (AC-246), no window
        // where the offer sits Accepted-but-unswept.
        AsseteraECS.KycAttestation memory acceptAtt = _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();

        assertEq(uint8(exchange.getOffer(id).status), uint8(ExchangeTypes.OfferStatus.Settled));

        vm.warp(block.timestamp + 1 hours + 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        exchange.sweepExpiredOffers(ids); // silent skip — Settled is not Open/Countered

        assertEq(uint8(exchange.getOffer(id).status), uint8(ExchangeTypes.OfferStatus.Settled));
    }

    function test_SweepExpiredOffers_CannotSweepTwice() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);
        uint256 id = _makeOfferWithExpiry(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, expiry);

        vm.warp(block.timestamp + 1 hours + 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        exchange.sweepExpiredOffers(ids);
        uint256 aliceAfterFirst = rwa.balanceOf(alice);

        exchange.sweepExpiredOffers(ids); // second call is a no-op
        assertEq(rwa.balanceOf(alice), aliceAfterFirst);
    }

    function test_SweepExpiredOffers_EmitsOfferExpired() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);
        uint256 id = _makeOfferWithExpiry(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, expiry);

        vm.warp(block.timestamp + 1 hours + 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.expectEmit(true, true, false, true);
        emit OfferBook.OfferExpired(id, alice, SELL_RWA);
        exchange.sweepExpiredOffers(ids);
    }

    // ===================================================================== //
    //     fee snapshotting, allowlist, deduction, rounding                   //
    // ===================================================================== //

    // Helper: place RWA-for-USDC with explicit fee params; assumes collector already allowlisted.
    function _placeRwaForUsdcWithFee(address maker, uint16 makerFeeBps, uint16 takerFeeBps, address feeCollector)
        internal
        returns (uint256 id)
    {
        AsseteraECS.KycAttestation memory att = _attestPlace(maker, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlaceWithFee(
            maker, address(rwa), SELL_RWA, address(usdc), WANT_USDC, makerFeeBps, takerFeeBps, feeCollector
        );
        vm.startPrank(maker);
        rwa.approve(address(exchange), SELL_RWA);
        id = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    // --- collector allowlist --------------------------------------------- //

    function test_Fee_CollectorNotAllowlisted_Reverts() public {
        // carol is not in the allowlist — placing an order with her as collector must revert.
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feePlaceWithFee(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 50, 30, carol);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(abi.encodeWithSelector(IFeeGate.FeeCollectorNotAllowed.selector, carol));
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_Fee_AllowlistAdd_EnablesCollector() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);
        assertTrue(exchange.allowedCollectors(carol));
        // Should not revert now.
        _placeRwaForUsdcWithFee(alice, 50, 30, carol);
    }

    function test_Fee_AllowlistRevoke_BlocksNewOrders() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);
        vm.prank(admin);
        exchange.setAllowedCollector(carol, false);

        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feePlaceWithFee(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 50, 30, carol);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(abi.encodeWithSelector(IFeeGate.FeeCollectorNotAllowed.selector, carol));
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_Fee_AllowlistOnlyAdmin() public {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", operator, ADMIN_ROLE)
        );
        exchange.setAllowedCollector(carol, true);
    }

    function test_Fee_ZeroFeesDoNotRequireAllowlistedCollector() public {
        // Zero fees + zero collector is the default path — must not revert even if allowlist is empty.
        _placeRwaForUsdc(alice); // uses _feePlace which sends 0 fees and address(0) collector
    }

    function test_Fee_NonZeroFeeWithZeroCollectorReverts() public {
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feePlaceWithFee(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 50, 0, address(0));
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(GateStorage.ZeroAddress.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_Fee_InvalidFee_Reverts() public {
        // makerFeeBps > 10_000 must revert.
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feePlaceWithFee(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 10_001, 0, carol);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(IFeeGate.InvalidFee.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_Fee_EmitsCollectorAllowed() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit ExchangeAdmin.CollectorAllowed(carol, true);
        exchange.setAllowedCollector(carol, true);
    }

    // --- snapshot immutability ------------------------------------------- //

    function test_Fee_SnapshotImmutability_RevokeAfterPlace() public {
        // Even if the collector is later removed from the allowlist, the snapshotted
        // fees on an already-placed order remain and the fill must still succeed.
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        uint256 id = _placeRwaForUsdcWithFee(alice, 50, 30, carol);

        // Verify snapshot stored on order.
        AsseteraECS.Order memory o = exchange.getOrder(id);
        assertEq(o.makerFeeBps, 50);
        assertEq(o.takerFeeBps, 30);
        assertEq(o.feeCollector, carol);

        // Revoke carol from allowlist.
        vm.prank(admin);
        exchange.setAllowedCollector(carol, false);

        // Fill should still work using the snapshotted fees/collector.
        uint256 carolUsdc = usdc.balanceOf(carol);
        uint256 carolRwa = rwa.balanceOf(carol);
        AsseteraECS.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC + (WANT_USDC * 30) / 10_000);
        exchange.fillOrder(id, SELL_RWA, att);
        vm.stopPrank();

        // Carol received BOTH fees even after allowlist removal — and both in USDC,
        // the settlement currency. The collector never touches the security token.
        assertEq(usdc.balanceOf(carol), carolUsdc + (WANT_USDC * 80) / 10_000, "both fees in USDC");
        assertEq(rwa.balanceOf(carol), carolRwa, "collector holds zero RWA");
    }

    // --- fill fee deduction ---------------------------------------------- //

    /// AC-833 — the canonical assertion, and the exact inversion of the old
    /// `test_Fee_Fill_MakerAndTakerFeesDeducted`, which asserted that each party's fee
    /// was skimmed off the leg they RECEIVED (so the collector ended up holding RWA).
    /// Both fees are charged on the notional, in the settlement currency, and are
    /// exclusive on the payer: the taker pays MORE, rather than receiving less.
    function test_Fee_Fill_BothFeesInSettlementCurrency_ExclusiveOnTaker() public {
        // makerFeeBps = 50 (0.5%), takerFeeBps = 30 (0.3%) — BOTH on the USDC notional.
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        uint256 id = _placeRwaForUsdcWithFee(alice, 50, 30, carol);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 bobRwaBefore = rwa.balanceOf(bob);
        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        uint256 carolUsdcBefore = usdc.balanceOf(carol);
        uint256 carolRwaBefore = rwa.balanceOf(carol);

        uint256 expectedMakerFee = (WANT_USDC * 50) / 10_000; // 0.5% of the notional
        uint256 expectedTakerFee = (WANT_USDC * 30) / 10_000; // 0.3% of the notional

        AsseteraECS.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.startPrank(bob);
        // The taker must approve notional + their OWN fee. Approving only the notional
        // is exactly the bug this model change surfaces in the front-ends.
        usdc.approve(address(exchange), WANT_USDC + expectedTakerFee);
        exchange.fillOrder(id, SELL_RWA, att);
        vm.stopPrank();

        // Maker: receives notional − own fee, gives the asset gross.
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + WANT_USDC - expectedMakerFee, "maker USDC net");
        // Taker: pays notional + own fee, receives the asset GROSS — no RWA skim.
        assertEq(usdc.balanceOf(bob), bobUsdcBefore - WANT_USDC - expectedTakerFee, "taker USDC paid");
        assertEq(rwa.balanceOf(bob), bobRwaBefore + SELL_RWA, "taker receives full RWA");
        // Collector: both fees, one currency, zero security-token dust.
        assertEq(usdc.balanceOf(carol), carolUsdcBefore + expectedMakerFee + expectedTakerFee, "both fees in USDC");
        assertEq(rwa.balanceOf(carol), carolRwaBefore, "collector holds zero RWA");
    }

    function test_Fee_Fill_ZeroFees_NoCollectorTransfer() public {
        uint256 id = _placeRwaForUsdc(alice); // zero fees

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 bobRwaBefore = rwa.balanceOf(bob);

        AsseteraECS.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.fillOrder(id, SELL_RWA, att);
        vm.stopPrank();

        // Full amounts reach maker and taker — no deduction.
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + WANT_USDC);
        assertEq(rwa.balanceOf(bob), bobRwaBefore + SELL_RWA);
    }

    function test_Fee_Fill_OnlyMakerFee() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        uint256 id = _placeRwaForUsdcWithFee(alice, 100, 0, carol); // 1% maker, 0 taker

        uint256 carolUsdcBefore = usdc.balanceOf(carol);
        uint256 carolRwaBefore = rwa.balanceOf(carol);

        AsseteraECS.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.fillOrder(id, SELL_RWA, att);
        vm.stopPrank();

        uint256 expectedMakerFee = (WANT_USDC * 100) / 10_000;
        assertEq(usdc.balanceOf(carol), carolUsdcBefore + expectedMakerFee, "makerFee in USDC");
        assertEq(rwa.balanceOf(carol), carolRwaBefore, "no takerFee (RWA)");
    }

    function test_Fee_Fill_OnlyTakerFee() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        uint256 id = _placeRwaForUsdcWithFee(alice, 0, 100, carol); // 0 maker, 1% taker

        uint256 carolUsdcBefore = usdc.balanceOf(carol);
        uint256 carolRwaBefore = rwa.balanceOf(carol);

        // AC-833: the taker fee is denominated in USDC and paid ON TOP of the notional.
        uint256 expectedTakerFee = (WANT_USDC * 100) / 10_000;

        AsseteraECS.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC + expectedTakerFee);
        exchange.fillOrder(id, SELL_RWA, att);
        vm.stopPrank();

        assertEq(usdc.balanceOf(carol), carolUsdcBefore + expectedTakerFee, "takerFee in USDC");
        assertEq(rwa.balanceOf(carol), carolRwaBefore, "never in RWA");
    }

    function test_Fee_PartialFill_FeesProportional() public {
        // Fill half the order — fees apply proportionally to the filled portion only.
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        uint256 id = _placeRwaForUsdcWithFee(alice, 50, 30, carol);

        uint256 halfRwa = SELL_RWA / 2;
        uint256 halfUsdc = (halfRwa * WANT_USDC + SELL_RWA - 1) / SELL_RWA; // ceiling

        uint256 carolUsdcBefore = usdc.balanceOf(carol);
        uint256 carolRwaBefore = rwa.balanceOf(carol);
        uint256 bobRwaBefore = rwa.balanceOf(bob);

        // AC-833: both fees scale with THIS fill's notional, both in USDC.
        uint256 expectedMakerFee = (halfUsdc * 50) / 10_000;
        uint256 expectedTakerFee = (halfUsdc * 30) / 10_000;

        AsseteraECS.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), halfUsdc + expectedTakerFee);
        exchange.fillOrder(id, halfRwa, att);
        vm.stopPrank();

        assertEq(usdc.balanceOf(carol), carolUsdcBefore + expectedMakerFee + expectedTakerFee, "both fees in USDC");
        assertEq(rwa.balanceOf(carol), carolRwaBefore, "collector holds zero RWA");
        assertEq(rwa.balanceOf(bob), bobRwaBefore + halfRwa, "taker receives the filled RWA gross");
        // Order stays Open.
        assertEq(uint8(exchange.getOrder(id).status), uint8(ExchangeTypes.OrderStatus.Open));
    }

    function test_Fee_Fill_Rounding_FloorFavorsMakerAndTaker() public {
        // 1 bps on 1 wei = 0.0001 wei → floored to 0; collector receives nothing.
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        AsseteraECS.KycAttestation memory placeAtt = _attestPlace(alice, address(rwa), 1, address(usdc), 1);
        AsseteraECS.FeeAttestation memory placeFeeAtt =
            _feePlaceWithFee(alice, address(rwa), 1, address(usdc), 1, 1, 1, carol);
        vm.startPrank(alice);
        rwa.approve(address(exchange), 1);
        uint256 id = exchange.placeOrder(address(rwa), 1, address(usdc), 1, 0, placeAtt, placeFeeAtt);
        vm.stopPrank();

        uint256 carolUsdcBefore = usdc.balanceOf(carol);
        uint256 carolRwaBefore = rwa.balanceOf(carol);

        vm.prank(admin);
        exchange.setComplianceRequired(ExchangeTypes.Action.Fill, false);

        AsseteraECS.KycAttestation memory empty;
        vm.startPrank(bob);
        usdc.approve(address(exchange), 1);
        exchange.fillOrder(id, 1, empty);
        vm.stopPrank();

        // (1 * 1) / 10_000 = 0 — floor division, collector receives nothing.
        assertEq(usdc.balanceOf(carol), carolUsdcBefore, "no USDC fee (floored to 0)");
        assertEq(rwa.balanceOf(carol), carolRwaBefore, "no RWA fee (floored to 0)");
    }

    function test_Fee_InvalidFee_TakerBpsExceedsMax_Reverts() public {
        // takerFeeBps > 10_000 must also revert (right branch of the || condition).
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feePlaceWithFee(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, 10_001, carol);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(IFeeGate.InvalidFee.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    // --- placeOrderWithPermit + fee params ------------------------------- //

    function test_Fee_PlaceOrderWithPermit_FeeParams_HappyAndSadPath() public {
        uint256 pk = 0xBEEF;
        address maker = vm.addr(pk);
        rwa.mint(maker, SELL_RWA);
        uint256 dl = block.timestamp + 1 hours;

        // Sad: carol not yet allowlisted — must revert before consuming permit.
        AsseteraECS.KycAttestation memory att = _attestPlace(maker, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feePlaceWithFee(maker, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 50, 30, carol);
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(rwa, pk, maker, address(exchange), SELL_RWA, dl);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(IFeeGate.FeeCollectorNotAllowed.selector, carol));
        exchange.placeOrderWithPermit(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, dl, v, r, s, att, feeAtt);

        // Happy: allowlist carol, then permit + fees succeed.
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);
        // Fresh attestations (new nonces) and fresh permit sig (ERC-2612 nonce still 0 since first call reverted).
        att = _attestPlace(maker, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        feeAtt = _feePlaceWithFee(maker, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 50, 30, carol);
        (v, r, s) = _signPermit(rwa, pk, maker, address(exchange), SELL_RWA, dl);
        vm.prank(maker);
        uint256 id = exchange.placeOrderWithPermit(
            address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, dl, v, r, s, att, feeAtt
        );
        AsseteraECS.Order memory o = exchange.getOrder(id);
        assertEq(o.makerFeeBps, 50, "makerFeeBps snapshotted");
        assertEq(o.takerFeeBps, 30, "takerFeeBps snapshotted");
        assertEq(o.feeCollector, carol, "feeCollector snapshotted");
    }

    // --- event fields ---------------------------------------------------- //

    function test_Fee_Fill_EmitsOrderFilledWithFeeFields() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);
        uint256 id = _placeRwaForUsdcWithFee(alice, 50, 30, carol);

        // AC-833: both fees are charged on the notional, in usdc — the taker fee is no
        // longer skimmed off the RWA the taker receives.
        uint256 expectedMakerFee = (WANT_USDC * 50) / 10_000;
        uint256 expectedTakerFee = (WANT_USDC * 30) / 10_000;

        AsseteraECS.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC + expectedTakerFee);
        vm.expectEmit(true, true, true, true);
        emit OrderBook.OrderFilled(
            id, alice, bob, SELL_RWA, WANT_USDC, expectedMakerFee, expectedTakerFee, carol, address(usdc)
        );
        exchange.fillOrder(id, SELL_RWA, att);
        vm.stopPrank();
    }

    function test_Fee_PartialFill_EmitsOrderPartiallyFilledWithFeeFields() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);
        uint256 id = _placeRwaForUsdcWithFee(alice, 50, 30, carol);

        uint256 halfRwa = SELL_RWA / 2;
        uint256 halfUsdc = (halfRwa * WANT_USDC + SELL_RWA - 1) / SELL_RWA;
        // AC-833: both fees are on this fill's notional (halfUsdc), in usdc.
        uint256 expectedMakerFee = (halfUsdc * 50) / 10_000;
        uint256 expectedTakerFee = (halfUsdc * 30) / 10_000;
        uint256 expectedRemaining = SELL_RWA - halfRwa;

        AsseteraECS.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), halfUsdc + expectedTakerFee);
        vm.expectEmit(true, true, true, true);
        // The event now carries filledBuyAmount, so consumers don't re-derive the ceil-div.
        emit OrderBook.OrderPartiallyFilled(
            id,
            alice,
            bob,
            halfRwa,
            halfUsdc,
            expectedRemaining,
            expectedMakerFee,
            expectedTakerFee,
            carol,
            address(usdc)
        );
        exchange.fillOrder(id, halfRwa, att);
        vm.stopPrank();
    }

    function test_Fee_TwoSequentialPartialFills_FeesAccumulate() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);
        uint256 id = _placeRwaForUsdcWithFee(alice, 50, 30, carol);

        uint256 halfRwa = SELL_RWA / 2;
        uint256 halfUsdc = (halfRwa * WANT_USDC + SELL_RWA - 1) / SELL_RWA;

        uint256 carolUsdcBefore = usdc.balanceOf(carol);
        uint256 carolRwaBefore = rwa.balanceOf(carol);

        // First half.
        AsseteraECS.KycAttestation memory att1 = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.startPrank(bob);
        // Covers both fills, fee-inclusive (AC-833): the taker pays notional + own fee.
        usdc.approve(address(exchange), WANT_USDC + (WANT_USDC * 30) / 10_000);
        exchange.fillOrder(id, halfRwa, att1);
        vm.stopPrank();

        assertEq(uint8(exchange.getOrder(id).status), uint8(ExchangeTypes.OrderStatus.Open), "still open");

        // Second half (clears the order).
        AsseteraECS.KycAttestation memory att2 = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.prank(bob);
        exchange.fillOrder(id, halfRwa, att2);

        assertEq(uint8(exchange.getOrder(id).status), uint8(ExchangeTypes.OrderStatus.Filled), "fully filled");

        // Both fees accrue per fill, both in USDC, both on that fill's notional.
        uint256 totalMakerFee = 2 * ((halfUsdc * 50) / 10_000);
        uint256 totalTakerFee = 2 * ((halfUsdc * 30) / 10_000);

        assertEq(usdc.balanceOf(carol), carolUsdcBefore + totalMakerFee + totalTakerFee, "accumulated fees in USDC");
        assertEq(rwa.balanceOf(carol), carolRwaBefore, "collector holds zero RWA");
    }

    function test_Fee_TamperedFeeBps_Reverts() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        // Sign with makerFeeBps = 50, then inflate it after signing.
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feePlaceWithFee(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 50, 30, carol);
        feeAtt.makerFeeBps = 5_000; // tamper — sig now covers a different struct hash

        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(IFeeGate.FeeBadSigner.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    // --- boundary: 100% fee (10_000 bps) -------------------------------- //

    function test_Fee_MaxFeeBps_MakerReceivesZero() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        // makerFeeBps = 10_000 (100%): entire buyToken amount goes to the collector.
        uint256 id = _placeRwaForUsdcWithFee(alice, 10_000, 0, carol);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 carolUsdcBefore = usdc.balanceOf(carol);
        uint256 bobRwaBefore = rwa.balanceOf(bob);

        AsseteraECS.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.fillOrder(id, SELL_RWA, att);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), aliceUsdcBefore, "maker receives 0 (100% fee)");
        assertEq(usdc.balanceOf(carol), carolUsdcBefore + WANT_USDC, "collector receives 100% of buyToken");
        assertEq(rwa.balanceOf(bob), bobRwaBefore + SELL_RWA, "taker receives full sellToken (zero taker fee)");
    }

    // --- offer fee deduction (v3.1.0) ------------------------------------ //

    function test_Offer_Fee_CollectorNotAllowlisted_Reverts() public {
        AsseteraECS.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feeMakeOfferWithFee(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 100, 50, carol);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(abi.encodeWithSelector(IFeeGate.FeeCollectorNotAllowed.selector, carol));
        exchange.makeOffer(0, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_Offer_Fee_InvalidFee_Reverts() public {
        uint16 tooHigh = uint16(AsseteraECS(address(exchange)).MAX_FEE_BPS()) + 1;
        AsseteraECS.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feeMakeOfferWithFee(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, tooHigh, 0, carol);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(IFeeGate.InvalidFee.selector);
        exchange.makeOffer(0, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_Offer_Fee_ZeroFees_NoCollectorRequired() public {
        // Zero fees should succeed without an allowlisted collector (matches order behaviour).
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.Offer memory o = exchange.getOffer(id);
        assertEq(o.makerFeeBps, 0);
        assertEq(o.takerFeeBps, 0);
        assertEq(o.feeCollector, address(0));
    }

    function test_Offer_Fee_StoredInStruct() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);
        uint256 id = _makeOfferWithFee(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 100, 50, carol);
        AsseteraECS.Offer memory o = exchange.getOffer(id);
        assertEq(o.makerFeeBps, 100, "makerFeeBps stored");
        assertEq(o.takerFeeBps, 50, "takerFeeBps stored");
        assertEq(o.feeCollector, carol, "feeCollector stored");
    }

    // --- fee deduction on accept (settles atomically, AC-246) ------------ //

    function test_Offer_Fee_AcceptSettles_FeesDeducted() public {
        // AC-833: BOTH fees are charged on the currency leg (USDC = takerAmount here),
        // exclusive on whoever pays currency. The RWA leg moves gross either way.
        uint16 makerFeeBps = 100;
        uint16 takerFeeBps = 50;

        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        uint256 id = _makeOfferWithFee(
            alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, makerFeeBps, takerFeeBps, carol
        );

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 bobRwaBefore = rwa.balanceOf(bob);
        uint256 carolUsdcBefore = usdc.balanceOf(carol);
        uint256 carolRwaBefore = rwa.balanceOf(carol);

        uint256 makerFeeAmt = (WANT_USDC * makerFeeBps) / 10_000;
        uint256 takerFeeAmt = (WANT_USDC * takerFeeBps) / 10_000;

        // Bob accepts — settles atomically, no separate operator step. He is the
        // currency payer, so he brings notional + his OWN fee.
        AsseteraECS.KycAttestation memory acceptAtt = _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC + takerFeeAmt);
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();

        assertEq(uint8(exchange.getOffer(id).status), uint8(ExchangeTypes.OfferStatus.Settled));
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + WANT_USDC - makerFeeAmt, "maker receives USDC minus own fee");
        assertEq(rwa.balanceOf(bob), bobRwaBefore + SELL_RWA, "taker receives RWA GROSS");
        assertEq(usdc.balanceOf(carol), carolUsdcBefore + makerFeeAmt + takerFeeAmt, "carol receives both fees in USDC");
        assertEq(rwa.balanceOf(carol), carolRwaBefore, "carol receives zero RWA");
        assertEq(rwa.balanceOf(address(exchange)), 0, "exchange holds no RWA");
        assertEq(usdc.balanceOf(address(exchange)), 0, "exchange holds no USDC");
    }

    function test_Offer_Fee_AcceptSettles_OnlyMakerFee() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        uint256 id = _makeOfferWithFee(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 200, 0, carol);
        uint256 bobRwaBefore = rwa.balanceOf(bob);
        uint256 carolUsdcBefore = usdc.balanceOf(carol);
        uint256 carolRwaBefore = rwa.balanceOf(carol);

        AsseteraECS.KycAttestation memory acceptAtt = _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();

        uint256 makerFeeAmt = (WANT_USDC * 200) / 10_000;
        assertEq(usdc.balanceOf(carol) - carolUsdcBefore, makerFeeAmt, "carol gets maker fee in USDC");
        assertEq(rwa.balanceOf(carol) - carolRwaBefore, 0, "carol gets no RWA (no taker fee)");
        assertEq(rwa.balanceOf(bob), bobRwaBefore + SELL_RWA, "taker receives full RWA");
    }

    function test_Offer_Fee_AcceptSettles_OnlyTakerFee() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        uint256 id = _makeOfferWithFee(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, 150, carol);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 carolRwaBefore = rwa.balanceOf(carol);
        uint256 carolUsdcBefore = usdc.balanceOf(carol);

        // AC-833: the taker's fee is in USDC and paid ON TOP — never skimmed off the RWA.
        uint256 takerFeeAmt = (WANT_USDC * 150) / 10_000;

        AsseteraECS.KycAttestation memory acceptAtt = _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC + takerFeeAmt);
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();

        assertEq(usdc.balanceOf(carol) - carolUsdcBefore, takerFeeAmt, "carol gets taker fee in USDC");
        assertEq(rwa.balanceOf(carol) - carolRwaBefore, 0, "carol gets no RWA");
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + WANT_USDC, "maker receives full USDC (no maker fee)");
    }

    // ===================================================================== //
    //     AC-833 — currency-denominated, payer-exclusive fee model          //
    // ===================================================================== //

    uint256 internal constant AC833_RWA = 10e18; // the asset leg
    uint256 internal constant AC833_USDC = 100e6; // the notional, in settlement currency
    uint16 internal constant AC833_BPS = 100; // 1 %

    /// Place a BUY-SIDE order: the maker sells the CURRENCY and buys the asset, which
    /// makes them the currency payer — so placement must escrow notional + maker fee.
    function _placeUsdcForRwaWithFee(
        address maker,
        uint256 usdcAmt,
        uint256 rwaWant,
        uint16 makerFeeBps,
        uint16 takerFeeBps,
        address feeCollector
    ) internal returns (uint256 id) {
        AsseteraECS.KycAttestation memory att = _attestPlace(maker, address(usdc), usdcAmt, address(rwa), rwaWant);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlaceWithFee(
            maker, address(usdc), usdcAmt, address(rwa), rwaWant, makerFeeBps, takerFeeBps, feeCollector
        );
        vm.startPrank(maker);
        usdc.approve(address(exchange), usdcAmt + (usdcAmt * makerFeeBps) / 10_000);
        id = exchange.placeOrder(address(usdc), usdcAmt, address(rwa), rwaWant, 0, att, feeAtt);
        vm.stopPrank();
    }

    /// The worked example from the ticket, asserted to the wei on every account.
    /// Maker sells 10 mRWA wanting 100 mUSDC, 1 % / 1 %, taker fills fully.
    function test_AC833_CanonicalExample_ExactLedgerOnEveryAccount() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        AsseteraECS.KycAttestation memory placeAtt =
            _attestPlace(alice, address(rwa), AC833_RWA, address(usdc), AC833_USDC);
        AsseteraECS.FeeAttestation memory placeFee =
            _feePlaceWithFee(alice, address(rwa), AC833_RWA, address(usdc), AC833_USDC, AC833_BPS, AC833_BPS, carol);
        vm.startPrank(alice);
        rwa.approve(address(exchange), AC833_RWA);
        uint256 id = exchange.placeOrder(address(rwa), AC833_RWA, address(usdc), AC833_USDC, 0, placeAtt, placeFee);
        vm.stopPrank();

        uint256 aliceUsdc = usdc.balanceOf(alice);
        uint256 aliceRwa = rwa.balanceOf(alice);
        uint256 bobUsdc = usdc.balanceOf(bob);
        uint256 bobRwa = rwa.balanceOf(bob);
        uint256 carolUsdc = usdc.balanceOf(carol);
        uint256 carolRwa = rwa.balanceOf(carol);

        AsseteraECS.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), 101e6);
        exchange.fillOrder(id, AC833_RWA, att);
        vm.stopPrank();

        // maker +99 USDC / −10 RWA (the RWA left escrow at placement, so no delta here)
        assertEq(usdc.balanceOf(alice), aliceUsdc + 99e6, "maker +99 USDC");
        assertEq(rwa.balanceOf(alice), aliceRwa, "maker RWA already escrowed");
        // taker −101 USDC / +10 RWA
        assertEq(usdc.balanceOf(bob), bobUsdc - 101e6, "taker -101 USDC");
        assertEq(rwa.balanceOf(bob), bobRwa + 10e18, "taker +10 RWA");
        // collector +2 USDC / +0 RWA — the whole point of the ticket
        assertEq(usdc.balanceOf(carol), carolUsdc + 2e6, "collector +2 USDC");
        assertEq(rwa.balanceOf(carol), carolRwa, "collector +0 RWA");
        // and the venue keeps nothing
        assertEq(usdc.balanceOf(address(exchange)), 0, "no USDC residue");
        assertEq(rwa.balanceOf(address(exchange)), 0, "no RWA residue");
    }

    function test_AC833_BuySideOrder_EscrowsNotionalPlusMakerFee() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        uint256 before = usdc.balanceOf(alice);
        uint256 id = _placeUsdcForRwaWithFee(alice, AC833_USDC, AC833_RWA, AC833_BPS, AC833_BPS, carol);

        assertEq(usdc.balanceOf(alice), before - AC833_USDC - 1e6, "maker paid notional + own fee");
        assertEq(usdc.balanceOf(address(exchange)), AC833_USDC + 1e6, "exchange holds both");
        assertEq(exchange.getOrder(id).escrowedFee, 1e6, "escrowedFee tracked explicitly");
        assertEq(exchange.getOrder(id).remainingQuantity, AC833_USDC, "notional unchanged by the fee");
    }

    /// The mirror image of the canonical case: the MAKER is the currency payer.
    function test_AC833_BuySideOrder_Fill_AssetGross_CurrencyNetToTaker() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);
        uint256 id = _placeUsdcForRwaWithFee(alice, AC833_USDC, AC833_RWA, AC833_BPS, AC833_BPS, carol);

        uint256 aliceRwa = rwa.balanceOf(alice);
        uint256 bobUsdc = usdc.balanceOf(bob);
        uint256 bobRwa = rwa.balanceOf(bob);
        uint256 carolUsdc = usdc.balanceOf(carol);

        AsseteraECS.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.startPrank(bob);
        rwa.approve(address(exchange), AC833_RWA);
        exchange.fillOrder(id, AC833_USDC, att); // fill is denominated in the sell leg = USDC
        vm.stopPrank();

        assertEq(rwa.balanceOf(alice), aliceRwa + AC833_RWA, "maker receives the asset GROSS");
        assertEq(rwa.balanceOf(bob), bobRwa - AC833_RWA, "taker gave the asset gross");
        assertEq(usdc.balanceOf(bob), bobUsdc + 99e6, "taker receives notional - own fee");
        assertEq(usdc.balanceOf(carol), carolUsdc + 2e6, "collector takes both fees in USDC");
        assertEq(usdc.balanceOf(address(exchange)), 0, "escrow fully drained, no fee residue");
        assertEq(rwa.balanceOf(address(exchange)), 0, "no asset residue");
    }

    /// The acceptance criterion: an untouched buy-side order returns the maker to
    /// their EXACT starting balance — the escrowed fee is theirs until a fill earns it.
    function test_AC833_BuySideOrder_CancelUntouched_ReturnsExactStartingBalance() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        uint256 before = usdc.balanceOf(alice);
        uint256 id = _placeUsdcForRwaWithFee(alice, AC833_USDC, AC833_RWA, AC833_BPS, AC833_BPS, carol);
        assertLt(usdc.balanceOf(alice), before, "escrow really moved");

        vm.prank(alice);
        exchange.cancelOrder(id);

        assertEq(usdc.balanceOf(alice), before, "maker made whole to the wei");
        assertEq(usdc.balanceOf(address(exchange)), 0, "contract holds no residue");
        assertEq(exchange.getOrder(id).escrowedFee, 0, "escrowedFee cleared");
    }

    function test_AC833_BuySideOrder_SweepExpired_RefundsEscrowedFee() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        uint256 before = usdc.balanceOf(alice);
        uint64 expireTs = uint64(block.timestamp + 1 hours);
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(usdc), AC833_USDC, address(rwa), AC833_RWA);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feePlaceWithFee(alice, address(usdc), AC833_USDC, address(rwa), AC833_RWA, AC833_BPS, AC833_BPS, carol);
        vm.startPrank(alice);
        usdc.approve(address(exchange), AC833_USDC + 1e6);
        uint256 id = exchange.placeOrder(address(usdc), AC833_USDC, address(rwa), AC833_RWA, expireTs, att, feeAtt);
        vm.stopPrank();

        vm.warp(expireTs + 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        exchange.sweepExpired(ids);

        assertEq(usdc.balanceOf(alice), before, "sweep made the maker whole");
        assertEq(usdc.balanceOf(address(exchange)), 0, "no residue after sweep");
    }

    function test_AC833_BuySideOrder_ForceCancel_RefundsEscrowedFee() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);
        uint256 id = _placeUsdcForRwaWithFee(alice, AC833_USDC, AC833_RWA, AC833_BPS, AC833_BPS, carol);

        address recipient = makeAddr("ac833-compliance-recipient");
        uint256 recipientBefore = usdc.balanceOf(recipient);
        vm.prank(admin);
        exchange.cancelOrderForUser(id, recipient);

        assertEq(usdc.balanceOf(recipient), recipientBefore + AC833_USDC + 1e6, "full escrow incl. fee released");
        assertEq(usdc.balanceOf(address(exchange)), 0, "nothing stranded");
    }

    /// Conservation across an arbitrary partial-fill sequence: whatever the rounding
    /// does, the contract must end holding nothing and the maker must not be short.
    function test_AC833_BuySideOrder_PartialFillsThenCancel_NoResidueNoShortfall() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        // Amounts chosen so the per-fill fee floors and leaves dust in escrow.
        uint256 notional = 333e6;
        uint256 makerFeeTotal = (notional * AC833_BPS) / 10_000;
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 id = _placeUsdcForRwaWithFee(alice, notional, AC833_RWA, AC833_BPS, AC833_BPS, carol);

        // Three uneven partial fills, then cancel the remainder.
        uint256[3] memory fills = [uint256(7e6), 111e6, 5e6];
        for (uint256 i = 0; i < fills.length; i++) {
            AsseteraECS.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
            vm.startPrank(bob);
            rwa.approve(address(exchange), AC833_RWA);
            exchange.fillOrder(id, fills[i], att);
            vm.stopPrank();
        }
        vm.prank(alice);
        exchange.cancelOrder(id);

        // The maker's total outlay is the filled notional plus ONLY the fee actually
        // earned on it — never more than the fee they escrowed.
        uint256 filled = fills[0] + fills[1] + fills[2];
        uint256 feePaid = aliceBefore - usdc.balanceOf(alice) - filled;
        assertLe(feePaid, makerFeeTotal, "maker never overpays the escrowed fee");
        assertEq(
            feePaid,
            (fills[0] * AC833_BPS) / 10_000 + (fills[1] * AC833_BPS) / 10_000 + (fills[2] * AC833_BPS) / 10_000,
            "maker paid exactly the per-fill fees"
        );
        assertEq(usdc.balanceOf(address(exchange)), 0, "contract holds no residue");
        assertEq(rwa.balanceOf(address(exchange)), 0, "contract holds no asset residue");
    }

    /// A full fill leaves rounding dust in the fee escrow; it must go back to the maker.
    function test_AC833_BuySideOrder_FullFillInParts_ReturnsFeeDustToMaker() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        // 1 bps on small odd fills floors to zero repeatedly, stranding dust.
        uint256 notional = 20_000;
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 id = _placeUsdcForRwaWithFee(alice, notional, AC833_RWA, 1, 1, carol);
        uint256 escrowed = exchange.getOrder(id).escrowedFee;
        assertEq(escrowed, 2, "1 bps of 20000 = 2");

        for (uint256 i = 0; i < 4; i++) {
            AsseteraECS.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
            vm.startPrank(bob);
            rwa.approve(address(exchange), AC833_RWA);
            exchange.fillOrder(id, notional / 4, att); // 5000 each → 1 bps floors to 0
            vm.stopPrank();
        }

        assertEq(uint8(exchange.getOrder(id).status), uint8(ExchangeTypes.OrderStatus.Filled), "fully filled");
        assertEq(exchange.getOrder(id).escrowedFee, 0, "escrow cleared");
        assertEq(usdc.balanceOf(address(exchange)), 0, "dust not retained by the contract");
        // Maker paid the notional and, because every per-fill fee floored to zero, no fee.
        assertEq(aliceBefore - usdc.balanceOf(alice), notional, "unearned fee dust returned");
    }

    function test_AC833_FeeTokenNotALeg_Reverts() public {
        address notALeg = makeAddr("some-other-token");
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feePlaceWithFeeToken(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, 0, address(0), notALeg);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(abi.encodeWithSelector(IFeeGate.FeeTokenNotALeg.selector, notALeg));
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_AC833_FeeTokenIsSignedOverAndCannotBeTampered() public {
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        // Swap the denomination to the OTHER leg after signing — still a valid leg, so
        // it passes _validateFees and can only be caught by the signature itself.
        feeAtt.feeToken = address(rwa);

        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(IFeeGate.FeeBadSigner.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    /// Orders written under the pre-AC-833 layout read `feeToken == address(0)`. They
    /// must be un-fillable (their fees have no denomination) but still fully exitable.
    /// The order is aged by zeroing that one field in storage — `_orders` is slot 0 and
    /// `feeToken` is the 10th word of the struct; the read-back asserts we hit it.
    function test_AC833_LegacyOrder_CannotBeFilled_ButCanStillBeCancelled() public {
        uint256 id = _placeRwaForUsdc(alice);
        bytes32 base = keccak256(abi.encode(id, uint256(0)));
        vm.store(address(exchange), bytes32(uint256(base) + 9), bytes32(0));

        AsseteraECS.Order memory o = exchange.getOrder(id);
        assertEq(o.feeToken, address(0), "poked the feeToken field");
        assertEq(o.remainingQuantity, SELL_RWA, "and nothing else");
        assertEq(o.maker, alice, "and nothing else");

        AsseteraECS.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.LegacyOrderMustBeUnwound.selector, id));
        exchange.fillOrder(id, SELL_RWA, att);
        vm.stopPrank();

        // …but the maker can always get their money out.
        uint256 rwaBefore = rwa.balanceOf(alice);
        vm.prank(alice);
        exchange.cancelOrder(id);
        assertEq(rwa.balanceOf(alice), rwaBefore + SELL_RWA, "legacy order still exitable");
    }

    /// Offers: the fee follows the CURRENCY leg, not the maker/taker role. Here the
    /// maker proposes the currency side, so the maker escrows notional + their own fee.
    function test_AC833_Offer_MakerProposesCurrency_EscrowsOwnFee_AndRefundsOnCancel() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        uint256 before = usdc.balanceOf(alice);
        uint256 id = _makeOfferWithFee(
            alice, bob, address(usdc), AC833_USDC, address(rwa), AC833_RWA, AC833_BPS, AC833_BPS, carol
        );

        assertEq(exchange.getOffer(id).escrowedFee, 1e6, "proposer escrowed their own fee");
        assertEq(usdc.balanceOf(alice), before - AC833_USDC - 1e6, "notional + fee left the maker");

        AsseteraECS.KycAttestation memory att = _attestCancelOffer(alice, id, AC833_USDC, AC833_RWA);
        vm.prank(alice);
        exchange.cancelOffer(id, att);

        assertEq(usdc.balanceOf(alice), before, "cancel returns the maker to their exact balance");
        assertEq(usdc.balanceOf(address(exchange)), 0, "no residue");
    }

    /// `replaceOffer` swaps BOTH halves — it refunds the outgoing proposer's escrowed
    /// fee and escrows a fresh one for the incoming proposer at the new amounts.
    function test_AC833_Offer_Replace_RefundsOldFeeEscrow_AndTakesNew() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 id = _makeOfferWithFee(
            alice, bob, address(usdc), AC833_USDC, address(rwa), AC833_RWA, AC833_BPS, AC833_BPS, carol
        );

        // Bob counters: he now proposes, escrowing the ASSET leg — which carries no fee.
        uint256 newUsdc = 200e6;
        AsseteraECS.KycAttestation memory att = _attestReplaceOffer(bob, id, newUsdc, AC833_RWA);
        vm.startPrank(bob);
        rwa.approve(address(exchange), AC833_RWA);
        exchange.replaceOffer(id, newUsdc, AC833_RWA, 0, att);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), aliceBefore, "outgoing proposer fully refunded, fee included");
        assertEq(exchange.getOffer(id).escrowedFee, 0, "asset-side proposer escrows no fee");
        assertEq(usdc.balanceOf(address(exchange)), 0, "no currency left in escrow");
        assertEq(rwa.balanceOf(address(exchange)), AC833_RWA, "asset leg now escrowed");
    }

    function _signPermit(
        FaucetToken token,
        uint256 ownerPk,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 PERMIT_TYPEHASH = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        uint256 nonce = token.nonces(owner);
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(ownerPk, digest);
    }

    // ===================================================================== //
    //         token safety — fee-on-transfer / rebasing (M-1 / I-2)         //
    // ===================================================================== //
    // These tests document and prove the M-1 security-review finding: the
    // pooled OrderBook/OfferBook escrow assumes a token's transferFrom/
    // transfer delivers exactly the nominal amount requested. They are
    // expected to demonstrate insolvency/reverts with non-standard tokens —
    // that is the point, not a bug in these tests. A standard FaucetToken
    // never hits these paths (see the escrow-conservation invariant suite in
    // test/invariants/ for the positive-case regression guard).

    function test_TokenSafety_FeeOnTransfer_EscrowOverstatedAtPlacement() public {
        FeeOnTransferToken fot = new FeeOnTransferToken("Fee Token", "FOT", 100); // 1%
        fot.mint(alice, 10_000e18);

        uint256 sellAmt = 1_000e18;
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(fot), sellAmt, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(alice, address(fot), sellAmt, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        fot.approve(address(exchange), sellAmt);
        uint256 id = exchange.placeOrder(address(fot), sellAmt, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();

        // Order records the full nominal sellAmount as escrowed...
        assertEq(exchange.getOrder(id).remainingQuantity, sellAmt, "records nominal amount");
        // ...but the contract actually received 1% less: recorded escrow overstates real holdings.
        uint256 actualHeld = sellAmt - (sellAmt * 100) / 10_000;
        assertEq(fot.balanceOf(address(exchange)), actualHeld, "actual balance short by the transfer fee");
        assertLt(fot.balanceOf(address(exchange)), exchange.getOrder(id).remainingQuantity);
    }

    function test_TokenSafety_FeeOnTransfer_PoolInsolvency_LastCancellerReverts() public {
        FeeOnTransferToken fot = new FeeOnTransferToken("Fee Token", "FOT", 100); // 1%
        fot.mint(alice, 10_000e18);
        fot.mint(bob, 10_000e18);

        uint256 sellAmt = 1_000e18;

        AsseteraECS.KycAttestation memory aAtt = _attestPlace(alice, address(fot), sellAmt, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory aFeeAtt = _feePlace(alice, address(fot), sellAmt, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        fot.approve(address(exchange), sellAmt);
        uint256 aliceId = exchange.placeOrder(address(fot), sellAmt, address(usdc), WANT_USDC, 0, aAtt, aFeeAtt);
        vm.stopPrank();

        AsseteraECS.KycAttestation memory bAtt = _attestPlace(bob, address(fot), sellAmt, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory bFeeAtt = _feePlace(bob, address(fot), sellAmt, address(usdc), WANT_USDC);
        vm.startPrank(bob);
        fot.approve(address(exchange), sellAmt);
        uint256 bobId = exchange.placeOrder(address(fot), sellAmt, address(usdc), WANT_USDC, 0, bAtt, bFeeAtt);
        vm.stopPrank();

        // Pool actually holds 2 * 990e18 = 1_980e18, but recorded escrow already sums to 2_000e18.
        assertEq(fot.balanceOf(address(exchange)), 1_980e18);

        // Alice cancels first: the contract is debited the full recorded 1_000e18 (she nets 990e18
        // after her own incoming-transfer haircut is re-applied on the way out).
        vm.prank(alice);
        exchange.cancelOrder(aliceId);
        assertEq(fot.balanceOf(address(exchange)), 980e18);

        // Bob's cancel requests his full recorded 1_000e18 — Alice's cancel already drew down the
        // shared pool below what's needed to cover Bob's nominal escrow, so his cancel reverts. The
        // FOT mock itself splits that 1_000e18 transfer into a 990e18 payout leg + a 10e18 burn leg
        // (each its own balance check), so the shortfall surfaces on the payout leg at 990e18, not
        // the full nominal 1_000e18.
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(exchange), 980e18, 990e18)
        );
        exchange.cancelOrder(bobId);
    }

    function test_TokenSafety_Rebasing_NegativeRebaseCausesInsolvency() public {
        RebasingToken rebasing = new RebasingToken("Rebasing Token", "RBT");
        rebasing.mint(alice, 10_000e18);
        rebasing.mint(bob, 10_000e18);

        uint256 sellAmt = 1_000e18;

        AsseteraECS.KycAttestation memory aAtt =
            _attestPlace(alice, address(rebasing), sellAmt, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory aFeeAtt =
            _feePlace(alice, address(rebasing), sellAmt, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rebasing.approve(address(exchange), sellAmt);
        uint256 aliceId = exchange.placeOrder(address(rebasing), sellAmt, address(usdc), WANT_USDC, 0, aAtt, aFeeAtt);
        vm.stopPrank();

        AsseteraECS.KycAttestation memory bAtt = _attestPlace(bob, address(rebasing), sellAmt, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory bFeeAtt = _feePlace(bob, address(rebasing), sellAmt, address(usdc), WANT_USDC);
        vm.startPrank(bob);
        rebasing.approve(address(exchange), sellAmt);
        uint256 bobId = exchange.placeOrder(address(rebasing), sellAmt, address(usdc), WANT_USDC, 0, bAtt, bFeeAtt);
        vm.stopPrank();

        // Standard transfer semantics at placement: recorded escrow matches actual balance so far.
        assertEq(rebasing.balanceOf(address(exchange)), 2_000e18);

        // A negative rebase shrinks the exchange's actual holdings without any transfer — the
        // remainingQuantity fixed at placement never tracks this.
        rebasing.rebase(address(exchange), -1000); // -10%
        assertEq(rebasing.balanceOf(address(exchange)), 1_800e18);

        vm.prank(alice);
        exchange.cancelOrder(aliceId);
        assertEq(rebasing.balanceOf(address(exchange)), 800e18);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(exchange), 800e18, 1_000e18)
        );
        exchange.cancelOrder(bobId);
    }

    function test_TokenSafety_FeeOnTransfer_AcceptOfferShortfall() public {
        FeeOnTransferToken fot = new FeeOnTransferToken("Fee Token", "FOT", 100); // 1%
        fot.mint(alice, 10_000e18);

        uint256 makerAmt = 1_000e18;
        uint256 takerAmt = WANT_USDC;

        AsseteraECS.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(fot), makerAmt, address(usdc), takerAmt);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, bob, address(fot), makerAmt, address(usdc), takerAmt);
        vm.startPrank(alice);
        fot.approve(address(exchange), makerAmt);
        uint256 id = exchange.makeOffer(0, bob, address(fot), makerAmt, address(usdc), takerAmt, 0, att, feeAtt);
        vm.stopPrank();

        // The offer records the nominal makerAmount, but the contract only ever received 99% of it.
        uint256 actualHeld = makerAmt - (makerAmt * 100) / 10_000;
        assertEq(fot.balanceOf(address(exchange)), actualHeld);

        AsseteraECS.KycAttestation memory acceptAtt = _attestAcceptOffer(bob, id, makerAmt, takerAmt);
        vm.startPrank(bob);
        usdc.approve(address(exchange), takerAmt);
        // acceptOffer tries to release the full nominal makerAmount (zero protocol taker fee here) to
        // bob. The FOT mock splits that payout into a (makerAmt - transferFee) leg to bob — which
        // exactly drains the contract's actualHeld balance to zero and succeeds — followed by a
        // transferFee burn leg that then reverts against a zero balance, instead of silently
        // under-paying the taker.
        uint256 transferFee = makerAmt - actualHeld;
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(exchange), 0, transferFee)
        );
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();
    }

    // ===================================================================== //
    //          permitAndCall — approve + trade in one tx (AO-298)           //
    // ===================================================================== //
    // Before this, `placeOrderWithPermit` was the only permit-carrying entry
    // point, so only the maker placing an order could avoid a separate
    // `approve` transaction. These pin the four call sites that could not:
    // the taker on a fill, and both parties across makeOffer / replaceOffer /
    // acceptOffer. Plus the failure modes that real settlement currencies
    // actually hit, which the faucet tokens on playground cannot reproduce.

    /// Sign an ERC-2612 permit against whatever domain separator the token itself reports.
    /// This is the correct client behaviour; `_signPermitAgainstName` below is the naive one.
    function _permitSig(address token, uint256 ownerPk, address owner, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        return _permitSigWithDomain(token, ownerPk, owner, value, deadline, IERC20Permit(token).DOMAIN_SEPARATOR());
    }

    /// Sign a permit against a domain separator built from an arbitrary name — how a client
    /// that assumes `domain.name == token.name()` behaves. Correct for the faucet tokens,
    /// wrong for EUROP.
    function _signPermitAgainstName(
        address token,
        uint256 ownerPk,
        address owner,
        uint256 value,
        uint256 deadline,
        string memory domainName
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(domainName)),
                keccak256(bytes("1")),
                block.chainid,
                token
            )
        );
        return _permitSigWithDomain(token, ownerPk, owner, value, deadline, domain);
    }

    function _permitSigWithDomain(
        address token,
        uint256 ownerPk,
        address owner,
        uint256 value,
        uint256 deadline,
        bytes32 domainSeparator
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                address(exchange),
                value,
                IERC20Permit(token).nonces(owner),
                deadline
            )
        );
        (v, r, s) = vm.sign(ownerPk, keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash)));
    }

    /// A funded actor with a key we can sign permits with.
    function _funded(string memory name) internal returns (address who, uint256 pk) {
        (who, pk) = makeAddrAndKey(name);
        rwa.mint(who, 1_000e18);
        usdc.mint(who, 1_000_000e6);
    }

    // ---- the four call sites that had no permit path ---------------------- //

    function test_PermitAndCall_FillOrder_WithNoPriorAllowance() public {
        uint256 id = _placeRwaForUsdc(alice);
        (address dave, uint256 davePk) = _funded("dave-fill");
        uint256 dl = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(address(usdc), davePk, dave, WANT_USDC, dl);

        assertEq(usdc.allowance(dave, address(exchange)), 0, "starts with no allowance");

        AsseteraECS.KycAttestation memory att = _attest(dave, ExchangeTypes.Action.Fill, id);
        vm.prank(dave);
        (bool permitAccepted,) = exchange.permitAndCall(
            address(usdc), WANT_USDC, dl, v, r, s, abi.encodeCall(OrderBook.fillOrder, (id, SELL_RWA, att))
        );

        assertTrue(permitAccepted);
        assertEq(uint8(exchange.getOrder(id).status), uint8(ExchangeTypes.OrderStatus.Filled));
        // The fill is credited to the caller, not to the exchange: the self-delegatecall
        // preserved `_msgSender()`.
        assertEq(rwa.balanceOf(dave), 1_000e18 + SELL_RWA);
        assertEq(usdc.balanceOf(alice), 1_000_000e6 + WANT_USDC);
    }

    function test_PermitAndCall_MakeOffer_WithNoPriorAllowance() public {
        (address dave, uint256 davePk) = _funded("dave-make");
        uint256 dl = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(address(rwa), davePk, dave, SELL_RWA, dl);

        AsseteraECS.KycAttestation memory att =
            _attestMakeOffer(dave, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feeMakeOffer(dave, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);

        vm.prank(dave);
        exchange.permitAndCall(
            address(rwa),
            SELL_RWA,
            dl,
            v,
            r,
            s,
            abi.encodeCall(
                OfferBook.makeOffer, (0, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt)
            )
        );

        AsseteraECS.Offer memory o = exchange.getOffer(1);
        assertEq(o.maker, dave);
        assertEq(rwa.balanceOf(address(exchange)), SELL_RWA);
    }

    function test_PermitAndCall_ReplaceOffer_WithNoPriorAllowance() public {
        (address dave, uint256 davePk) = _funded("dave-replace");
        uint256 id = _makeOffer(alice, dave, address(rwa), SELL_RWA, address(usdc), WANT_USDC);

        // Dave counters, which makes him the proposer and escrows HIS leg (usdc).
        uint256 counter = 800e6;
        uint256 dl = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(address(usdc), davePk, dave, counter, dl);
        AsseteraECS.KycAttestation memory att = _attestReplaceOffer(dave, id, SELL_RWA, counter);

        vm.prank(dave);
        exchange.permitAndCall(
            address(usdc), counter, dl, v, r, s, abi.encodeCall(OfferBook.replaceOffer, (id, SELL_RWA, counter, 0, att))
        );

        AsseteraECS.Offer memory o = exchange.getOffer(id);
        assertEq(o.proposedBy, dave);
        assertEq(o.takerAmount, counter);
        assertEq(usdc.balanceOf(address(exchange)), counter);
    }

    function test_PermitAndCall_AcceptOffer_WithNoPriorAllowance() public {
        (address dave, uint256 davePk) = _funded("dave-accept");
        uint256 id = _makeOffer(alice, dave, address(rwa), SELL_RWA, address(usdc), WANT_USDC);

        uint256 dl = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(address(usdc), davePk, dave, WANT_USDC, dl);
        AsseteraECS.KycAttestation memory att = _attestAcceptOffer(dave, id, SELL_RWA, WANT_USDC);

        vm.prank(dave);
        exchange.permitAndCall(address(usdc), WANT_USDC, dl, v, r, s, abi.encodeCall(OfferBook.acceptOffer, (id, att)));

        assertEq(uint8(exchange.getOffer(id).status), uint8(ExchangeTypes.OfferStatus.Settled));
        assertEq(rwa.balanceOf(dave), 1_000e18 + SELL_RWA);
    }

    /// The generic path also covers what `placeOrderWithPermit` covers, so no future
    /// token-pulling function needs its own `…WithPermit` twin.
    function test_PermitAndCall_PlaceOrder_WithNoPriorAllowance() public {
        (address dave, uint256 davePk) = _funded("dave-place");
        uint256 dl = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(address(rwa), davePk, dave, SELL_RWA, dl);
        AsseteraECS.KycAttestation memory att = _attestPlace(dave, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlace(dave, address(rwa), SELL_RWA, address(usdc), WANT_USDC);

        vm.prank(dave);
        exchange.permitAndCall(
            address(rwa),
            SELL_RWA,
            dl,
            v,
            r,
            s,
            abi.encodeCall(OrderBook.placeOrder, (address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt))
        );

        assertEq(exchange.getOrder(1).maker, dave);
    }

    // ---- identity, through the relayer and against escalation ------------- //

    function test_PermitAndCall_Relayed_IdentityIsUserNotRelayer() public {
        uint256 id = _placeRwaForUsdc(alice);
        (address dave, uint256 davePk) = _funded("dave-relayed");
        vm.deal(dave, 0); // no ETH: the relayer pays

        uint256 dl = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(address(usdc), davePk, dave, WANT_USDC, dl);
        AsseteraECS.KycAttestation memory att = _attest(dave, ExchangeTypes.Action.Fill, id);

        bytes memory inner = abi.encodeCall(OrderBook.fillOrder, (id, SELL_RWA, att));
        bytes memory outer = abi.encodeCall(PermitRelay.permitAndCall, (address(usdc), WANT_USDC, dl, v, r, s, inner));

        _relay(davePk, dave, address(exchange), outer);

        // Both the permit owner and the fill were resolved as dave, not as the forwarder
        // and not as the relayer — the ERC-2771 suffix survived the self-delegatecall.
        assertEq(uint8(exchange.getOrder(id).status), uint8(ExchangeTypes.OrderStatus.Filled));
        assertEq(rwa.balanceOf(dave), 1_000e18 + SELL_RWA);
        assertEq(dave.balance, 0);
    }

    /// The self-delegatecall must not lend the caller the contract's own authority.
    function test_PermitAndCall_CannotReachAdminFunctionsWithoutTheRole() public {
        (address dave, uint256 davePk) = _funded("dave-escalate");
        uint256 dl = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(address(usdc), davePk, dave, 1, dl);

        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", dave, ADMIN_ROLE));
        exchange.permitAndCall(
            address(usdc),
            1,
            dl,
            v,
            r,
            s,
            abi.encodeCall(ExchangeAdmin.setComplianceRequired, (ExchangeTypes.Action.Fill, false))
        );
    }

    /// A permit signed by someone else does not recover to the caller, so the token
    /// rejects it. It cannot be redirected into an allowance for the caller.
    function test_PermitAndCall_CannotUseAnotherAccountsPermit() public {
        uint256 id = _placeRwaForUsdc(alice);
        (address victim, uint256 victimPk) = _funded("victim");
        (address thief,) = _funded("thief");
        uint256 dl = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(address(usdc), victimPk, victim, WANT_USDC, dl);

        AsseteraECS.KycAttestation memory att = _attest(thief, ExchangeTypes.Action.Fill, id);
        vm.prank(thief);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(exchange), 0, WANT_USDC)
        );
        exchange.permitAndCall(
            address(usdc), WANT_USDC, dl, v, r, s, abi.encodeCall(OrderBook.fillOrder, (id, SELL_RWA, att))
        );
        assertEq(usdc.allowance(victim, address(exchange)), 0, "victim's allowance was never set");
    }

    // ---- the fallback path: permit does not land -------------------------- //

    /// A token with no ERC-2612 at all. `_tryPermit` swallows the failure and the trade
    /// runs on the allowance the user set the old way — the behaviour AO-298 must not break.
    function test_PermitAndCall_TokenWithoutErc2612_FallsBackToAllowance() public {
        ReentrantToken plain = new ReentrantToken(); // never armed: a plain ERC-20, no permit
        (address dave, uint256 davePk) = _funded("dave-noperm");
        plain.mint(dave, 1_000e18);

        // Order: alice sells rwa, wants `plain`. `plain` is the settlement currency leg.
        uint256 want = 500e18;
        AsseteraECS.KycAttestation memory pAtt = _attestPlace(alice, address(rwa), SELL_RWA, address(plain), want);
        AsseteraECS.FeeAttestation memory pFee = _feePlaceWithFeeToken(
            alice, address(rwa), SELL_RWA, address(plain), want, 0, 0, address(0), address(plain)
        );
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        uint256 id = exchange.placeOrder(address(rwa), SELL_RWA, address(plain), want, 0, pAtt, pFee);
        vm.stopPrank();

        uint256 dl = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(davePk, keccak256("not a permit this token understands"));

        AsseteraECS.KycAttestation memory att = _attest(dave, ExchangeTypes.Action.Fill, id);
        vm.startPrank(dave);
        plain.approve(address(exchange), want); // the old two-transaction way
        (bool permitAccepted,) = exchange.permitAndCall(
            address(plain), want, dl, v, r, s, abi.encodeCall(OrderBook.fillOrder, (id, SELL_RWA, att))
        );
        vm.stopPrank();

        assertFalse(permitAccepted, "no ERC-2612: the permit is reported as not accepted");
        assertEq(uint8(exchange.getOrder(id).status), uint8(ExchangeTypes.OrderStatus.Filled), "trade still settles");
    }

    /// Set up an order whose settlement-currency leg is a token whose EIP-712 domain a
    /// client cannot derive from `name()`.
    function _orderPricedIn(DivergentDomainToken token, address taker, uint256 want) internal returns (uint256 id) {
        token.mint(taker, 1_000e18);
        AsseteraECS.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(token), want);
        AsseteraECS.FeeAttestation memory feeAtt = _feePlaceWithFeeToken(
            alice, address(rwa), SELL_RWA, address(token), want, 0, 0, address(0), address(token)
        );
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        id = exchange.placeOrder(address(rwa), SELL_RWA, address(token), want, 0, att, feeAtt);
        vm.stopPrank();
    }

    /// EUROP's shape: `name()` is not the EIP-712 domain name. A client that signs against
    /// `name()` produces a signature the token rejects. Nothing on playground reproduces
    /// this, because the faucet tokens pass their own `name()` to `ERC20Permit`.
    function test_PermitAndCall_DivergentDomain_SigningAgainstNameDoesNotLand() public {
        DivergentDomainToken eurp = new DivergentDomainToken("EUROP", "EURP", "EUR CoinVertible", false);
        (address dave, uint256 davePk) = _funded("dave-eurp");
        uint256 want = 500e18;
        uint256 id = _orderPricedIn(eurp, dave, want);
        uint256 dl = block.timestamp + 1 hours;

        assertTrue(
            eurp.DOMAIN_SEPARATOR()
                != keccak256(
                    abi.encode(
                        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                        keccak256(bytes(eurp.name())),
                        keccak256(bytes("1")),
                        block.chainid,
                        address(eurp)
                    )
                ),
            "fixture must actually diverge"
        );

        (uint8 v, bytes32 r, bytes32 s) = _signPermitAgainstName(address(eurp), davePk, dave, want, dl, eurp.name());
        AsseteraECS.KycAttestation memory att = _attest(dave, ExchangeTypes.Action.Fill, id);

        // With no allowance to fall back on, the trade reverts on the transfer — loudly, and
        // without having burned the KYC nonce, because the whole transaction is rolled back.
        vm.prank(dave);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(exchange), 0, want)
        );
        exchange.permitAndCall(
            address(eurp), want, dl, v, r, s, abi.encodeCall(OrderBook.fillOrder, (id, SELL_RWA, att))
        );
    }

    /// Same divergent token, but the user already has an allowance. The bad permit must not
    /// take the trade down with it, and `permitAccepted == false` tells the client why a
    /// user without an allowance would have failed.
    function test_PermitAndCall_DivergentDomain_FallsBackToAllowance() public {
        DivergentDomainToken eurp = new DivergentDomainToken("EUROP", "EURP", "EUR CoinVertible", false);
        (address dave, uint256 davePk) = _funded("dave-eurp2");
        uint256 want = 500e18;
        uint256 id = _orderPricedIn(eurp, dave, want);
        uint256 dl = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) = _signPermitAgainstName(address(eurp), davePk, dave, want, dl, eurp.name());
        AsseteraECS.KycAttestation memory att = _attest(dave, ExchangeTypes.Action.Fill, id);

        vm.startPrank(dave);
        eurp.approve(address(exchange), want);
        (bool permitAccepted,) = exchange.permitAndCall(
            address(eurp), want, dl, v, r, s, abi.encodeCall(OrderBook.fillOrder, (id, SELL_RWA, att))
        );
        vm.stopPrank();

        assertFalse(permitAccepted, "permit rejected: signed against name(), not the real domain");
        assertEq(uint8(exchange.getOrder(id).status), uint8(ExchangeTypes.OrderStatus.Filled));
    }

    /// The same token, signed against the domain separator the token itself reports. This is
    /// what the client has to do, and it is the only reliable way: read `DOMAIN_SEPARATOR()`
    /// and match candidate names against it.
    function test_PermitAndCall_DivergentDomain_SigningAgainstRealDomainWorks() public {
        DivergentDomainToken eurp = new DivergentDomainToken("EUROP", "EURP", "EUR CoinVertible", false);
        (address dave, uint256 davePk) = _funded("dave-eurp3");
        uint256 want = 500e18;
        uint256 id = _orderPricedIn(eurp, dave, want);
        uint256 dl = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) = _permitSig(address(eurp), davePk, dave, want, dl);
        AsseteraECS.KycAttestation memory att = _attest(dave, ExchangeTypes.Action.Fill, id);

        vm.prank(dave);
        (bool permitAccepted,) = exchange.permitAndCall(
            address(eurp), want, dl, v, r, s, abi.encodeCall(OrderBook.fillOrder, (id, SELL_RWA, att))
        );

        assertTrue(permitAccepted);
        assertEq(uint8(exchange.getOrder(id).status), uint8(ExchangeTypes.OrderStatus.Filled));
        assertEq(eurp.allowance(dave, address(exchange)), 0, "permit allowance was consumed exactly");
    }

    /// USDC's shape: no ERC-5267, so `eip712Domain()` reverts and a client cannot ask the
    /// token what its domain is. Permit itself still works when signed against
    /// `DOMAIN_SEPARATOR()`, which is what the client must fall back to reading.
    function test_PermitAndCall_TokenWithoutErc5267_StillPermits() public {
        DivergentDomainToken usdcLike = new DivergentDomainToken("USD Coin", "USDC", "USD Coin", true);
        (address dave, uint256 davePk) = _funded("dave-5267");
        uint256 want = 500e18;
        uint256 id = _orderPricedIn(usdcLike, dave, want);
        uint256 dl = block.timestamp + 1 hours;

        vm.expectRevert(DivergentDomainToken.Eip712DomainUnsupported.selector);
        usdcLike.eip712Domain();

        (uint8 v, bytes32 r, bytes32 s) = _permitSig(address(usdcLike), davePk, dave, want, dl);
        AsseteraECS.KycAttestation memory att = _attest(dave, ExchangeTypes.Action.Fill, id);

        vm.prank(dave);
        (bool permitAccepted,) = exchange.permitAndCall(
            address(usdcLike), want, dl, v, r, s, abi.encodeCall(OrderBook.fillOrder, (id, SELL_RWA, att))
        );

        assertTrue(permitAccepted);
        assertEq(uint8(exchange.getOrder(id).status), uint8(ExchangeTypes.OrderStatus.Filled));
    }

    // ---- guards ----------------------------------------------------------- //

    /// The inner call's revert is bubbled unchanged, so callers keep the error they would
    /// have got had they called the function directly.
    function test_PermitAndCall_BubblesTheInnerRevert() public {
        uint256 id = _placeRwaForUsdc(alice);
        (address dave, uint256 davePk) = _funded("dave-bubble");
        uint256 dl = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(address(usdc), davePk, dave, WANT_USDC, dl);
        AsseteraECS.KycAttestation memory att = _attest(dave, ExchangeTypes.Action.Fill, id);

        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.FillExceedsRemaining.selector, id, SELL_RWA));
        exchange.permitAndCall(
            address(usdc), WANT_USDC, dl, v, r, s, abi.encodeCall(OrderBook.fillOrder, (id, SELL_RWA + 1, att))
        );
    }

    /// The one permit failure that is NOT swallowed: a `token` address with no code. Solidity
    /// performs the `extcodesize` check outside the `try`, so it reverts the whole call. This is
    /// unchanged from `placeOrderWithPermit`, and it is a caller bug rather than a token quirk,
    /// but it is worth pinning so nobody assumes `_tryPermit` can never revert.
    function test_PermitAndCall_CodelessTokenAddressReverts() public {
        uint256 id = _placeRwaForUsdc(alice);
        (address dave, uint256 davePk) = _funded("dave-codeless");
        uint256 dl = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(davePk, keccak256("junk"));
        AsseteraECS.KycAttestation memory att = _attest(dave, ExchangeTypes.Action.Fill, id);

        vm.prank(dave);
        vm.expectRevert();
        exchange.permitAndCall(
            makeAddr("not-a-contract"), WANT_USDC, dl, v, r, s, abi.encodeCall(OrderBook.fillOrder, (id, SELL_RWA, att))
        );
    }

    /// `permitAndCall` is deliberately not `nonReentrant` — taking the guard would make the
    /// inner call revert. The guard on the inner call is what must hold, including when the
    /// token used for the permit is the one re-entering.
    function test_PermitAndCall_ReentrantTokenCannotReenterGuardedCall() public {
        ReentrantToken evil = new ReentrantToken();
        (address dave, uint256 davePk) = _funded("dave-reenter");
        evil.mint(dave, 1_000e18);

        uint256 want = 500e18;
        AsseteraECS.KycAttestation memory pAtt = _attestPlace(alice, address(rwa), SELL_RWA, address(evil), want);
        AsseteraECS.FeeAttestation memory pFee =
            _feePlaceWithFeeToken(alice, address(rwa), SELL_RWA, address(evil), want, 0, 0, address(0), address(evil));
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        uint256 id = exchange.placeOrder(address(rwa), SELL_RWA, address(evil), want, 0, pAtt, pFee);
        vm.stopPrank();

        uint256 dl = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(davePk, keccak256("junk"));
        AsseteraECS.KycAttestation memory att = _attest(dave, ExchangeTypes.Action.Fill, id);

        vm.startPrank(dave);
        evil.approve(address(exchange), want);
        evil.arm(address(exchange), abi.encodeCall(OrderBook.sweepExpired, (new uint256[](0))));
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        exchange.permitAndCall(
            address(evil), want, dl, v, r, s, abi.encodeCall(OrderBook.fillOrder, (id, SELL_RWA, att))
        );
        vm.stopPrank();
    }

    // ===================================================================== //
    //        AO-746 — an offer raised against an order closes it            //
    // ===================================================================== //
    //
    // Orders and offers are two books with two id spaces behind one proxy. Until AO-746 an
    // offer carried no order id, so accepting one left the order it was negotiated over
    // Open and fillable by a third party, and the maker had to escrow their side TWICE —
    // once for the listing and again for the negotiation. `Offer.orderId` links them: the
    // order's own maker funds their leg out of the order's escrow, and settling the offer
    // closes the order once its quantity is consumed.

    /// @dev A third token, so a linked order can sell something neither leg of the offer trades.
    function _thirdToken() internal returns (FaucetToken t) {
        t = new FaucetToken("Mock Other", "mOTH", 18);
        t.mint(alice, 1_000e18);
        t.mint(bob, 1_000e18);
    }

    /// @dev `approveAmt` is the assertion, not plumbing: pass 0 and the call can only succeed
    ///      if the leg was funded entirely from the linked order, because any `transferFrom`
    ///      would revert on allowance.
    function _makeOfferOn(
        uint256 orderId,
        address maker,
        address taker,
        address makerToken,
        uint256 makerAmt,
        address takerToken,
        uint256 takerAmt,
        uint256 approveAmt
    ) internal returns (uint256 id) {
        AsseteraECS.KycAttestation memory att =
            _attestMakeOffer(maker, taker, makerToken, makerAmt, takerToken, takerAmt);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feeMakeOffer(maker, taker, makerToken, makerAmt, takerToken, takerAmt);
        vm.startPrank(maker);
        FaucetToken(makerToken).approve(address(exchange), approveAmt);
        id = exchange.makeOffer(orderId, taker, makerToken, makerAmt, takerToken, takerAmt, 0, att, feeAtt);
        vm.stopPrank();
    }

    function _acceptOfferWithApproval(
        address caller,
        uint256 offerId,
        uint256 makerAmt,
        uint256 takerAmt,
        address callerToken,
        uint256 approveAmt
    ) internal {
        AsseteraECS.KycAttestation memory att = _attestAcceptOffer(caller, offerId, makerAmt, takerAmt);
        vm.startPrank(caller);
        FaucetToken(callerToken).approve(address(exchange), approveAmt);
        exchange.acceptOffer(offerId, att);
        vm.stopPrank();
    }

    function _replaceOfferWithApproval(
        address caller,
        uint256 offerId,
        uint256 newMakerAmt,
        uint256 newTakerAmt,
        address callerToken,
        uint256 approveAmt
    ) internal {
        AsseteraECS.KycAttestation memory att = _attestReplaceOffer(caller, offerId, newMakerAmt, newTakerAmt);
        vm.startPrank(caller);
        FaucetToken(callerToken).approve(address(exchange), approveAmt);
        exchange.replaceOffer(offerId, newMakerAmt, newTakerAmt, 0, att);
        vm.stopPrank();
    }

    /// THE DEFECT. Observed four times on Amoy (orders 32-35): the offer settled and the order
    /// stayed Open, still fillable by anyone else.
    function test_AO746_AcceptedOfferClosesTheOrderItWasRaisedAgainst() public {
        uint256 orderId = _placeRwaForUsdc(alice);
        uint256 offerId = _makeOfferOn(orderId, alice, bob, address(rwa), SELL_RWA, address(usdc), 900e6, 0);

        _acceptOfferWithApproval(bob, offerId, SELL_RWA, 900e6, address(usdc), 900e6);

        AsseteraECS.Order memory o = exchange.getOrder(orderId);
        assertEq(uint8(o.status), uint8(ExchangeTypes.OrderStatus.Filled), "order left open by an accepted offer");
        assertEq(o.remainingQuantity, 0, "order still carries quantity");

        // And the stale order is no longer a second, fillable claim on the same asset.
        AsseteraECS.KycAttestation memory att = _attest(carol, ExchangeTypes.Action.Fill, orderId);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(ExchangeStorage.OrderNotOpen.selector, orderId));
        exchange.fillOrder(orderId, SELL_RWA, att);
    }

    /// The maker's collateral is committed ONCE. Approving zero proves it: the offer's leg can
    /// only have come from the order's escrow.
    function test_AO746_MakerFundsTheOfferFromTheOrderNotTwice() public {
        uint256 orderId = _placeRwaForUsdc(alice);
        uint256 aliceRwaBefore = rwa.balanceOf(alice);
        uint256 venueRwaBefore = rwa.balanceOf(address(exchange));

        AsseteraECS.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), 900e6);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), 900e6);
        vm.startPrank(alice);
        vm.expectEmit(true, true, false, true);
        emit OfferBook.OrderEscrowDrawn(orderId, 1, SELL_RWA, 0);
        uint256 offerId = exchange.makeOffer(orderId, bob, address(rwa), SELL_RWA, address(usdc), 900e6, 0, att, feeAtt);
        vm.stopPrank();

        assertEq(rwa.balanceOf(alice), aliceRwaBefore, "maker paid a second time for the same asset");
        assertEq(rwa.balanceOf(address(exchange)), venueRwaBefore, "a draw must move no tokens");
        assertEq(exchange.getOrder(orderId).remainingQuantity, 0, "order escrow not reduced by the draw");
        assertEq(exchange.getOffer(offerId).orderId, orderId, "offer did not record its order");
    }

    /// "Countering an offer on your own listing requires holding a second copy of the asset."
    /// It does not any more: alice counters bob's proposal with a zero allowance.
    function test_AO746_CounteringOnYourOwnListingDrawsFromIt() public {
        uint256 orderId = _placeRwaForUsdc(alice);
        // Bob proposes against alice's listing. He is not the order's maker, so his currency
        // leg comes from his wallet exactly as before.
        uint256 offerId = _makeOfferOn(orderId, bob, alice, address(usdc), 900e6, address(rwa), SELL_RWA, 900e6);

        uint256 aliceRwaBefore = rwa.balanceOf(alice);
        _replaceOfferWithApproval(alice, offerId, 950e6, SELL_RWA, address(rwa), 0);

        assertEq(rwa.balanceOf(alice), aliceRwaBefore, "countering cost the maker a second copy of the asset");
        assertEq(exchange.getOrder(orderId).remainingQuantity, 0, "counter did not draw on the order");
        assertEq(exchange.getOffer(offerId).proposedBy, alice, "counter did not change the proposer");
    }

    /// The acceptor's leg is drawn too, so the whole "buyer proposes, seller accepts" path
    /// runs on one commitment.
    function test_AO746_AcceptorDrawsTheirLegFromTheirOwnOrder() public {
        uint256 orderId = _placeRwaForUsdc(alice);
        uint256 offerId = _makeOfferOn(orderId, bob, alice, address(usdc), 900e6, address(rwa), SELL_RWA, 900e6);

        uint256 aliceRwaBefore = rwa.balanceOf(alice);
        _acceptOfferWithApproval(alice, offerId, 900e6, SELL_RWA, address(rwa), 0);

        assertEq(rwa.balanceOf(alice), aliceRwaBefore, "acceptor paid a second time");
        assertEq(rwa.balanceOf(bob), 1_000e18 + SELL_RWA, "asset did not reach the buyer");
        AsseteraECS.Order memory o = exchange.getOrder(orderId);
        assertEq(uint8(o.status), uint8(ExchangeTypes.OrderStatus.Filled), "order not closed on settlement");
    }

    /// Negotiating three of ten does not retire the other seven.
    function test_AO746_PartialNegotiationLeavesTheRestListed() public {
        uint256 orderId = _placeRwaForUsdc(alice); // 10 RWA listed
        uint256 offerId = _makeOfferOn(orderId, alice, bob, address(rwa), 3e18, address(usdc), 270e6, 0);
        _acceptOfferWithApproval(bob, offerId, 3e18, 270e6, address(usdc), 270e6);

        AsseteraECS.Order memory o = exchange.getOrder(orderId);
        assertEq(uint8(o.status), uint8(ExchangeTypes.OrderStatus.Open), "a partly negotiated listing must stay open");
        assertEq(o.remainingQuantity, SELL_RWA - 3e18, "remaining quantity wrong after a partial draw");

        // The remainder is still genuinely fillable by someone else.
        AsseteraECS.KycAttestation memory att = _attest(carol, ExchangeTypes.Action.Fill, orderId);
        vm.startPrank(carol);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.fillOrder(orderId, SELL_RWA - 3e18, att);
        vm.stopPrank();
        assertEq(
            uint8(exchange.getOrder(orderId).status), uint8(ExchangeTypes.OrderStatus.Filled), "remainder unfilled"
        );
    }

    /// Raising your price above what you listed must never become un-fundable: the order pays
    /// what it can and the wallet covers the shortfall.
    function test_AO746_NegotiatingMoreThanListedTopsUpFromTheWallet() public {
        uint256 orderId = _placeRwaForUsdc(alice); // 10 RWA listed
        uint256 aliceRwaBefore = rwa.balanceOf(alice);

        uint256 shortfall = 2e18;
        uint256 offerId =
            _makeOfferOn(orderId, alice, bob, address(rwa), SELL_RWA + shortfall, address(usdc), 1_200e6, shortfall);

        assertEq(rwa.balanceOf(alice), aliceRwaBefore - shortfall, "wallet covered the wrong amount");
        assertEq(exchange.getOrder(orderId).remainingQuantity, 0, "order not fully drawn");

        _acceptOfferWithApproval(bob, offerId, SELL_RWA + shortfall, 1_200e6, address(usdc), 1_200e6);
        assertEq(uint8(exchange.getOrder(orderId).status), uint8(ExchangeTypes.OrderStatus.Filled), "order not closed");
    }

    /// An order neither party owns can never fund this offer, so naming it is a data error,
    /// not a link.
    function test_AO746_RevertsWhenTheOrderIsNotOwnedByAPartyToTheOffer() public {
        uint256 carolsOrder = _placeRwaForUsdc(carol);
        AsseteraECS.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), 900e6);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), 900e6);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(abi.encodeWithSelector(OfferBook.OrderNotLinkable.selector, carolsOrder));
        exchange.makeOffer(carolsOrder, bob, address(rwa), SELL_RWA, address(usdc), 900e6, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_AO746_RevertsWhenTheOrderIsAlreadyCancelled() public {
        uint256 orderId = _placeRwaForUsdc(alice);
        vm.prank(alice);
        exchange.cancelOrder(orderId);

        AsseteraECS.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), 900e6);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), 900e6);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(abi.encodeWithSelector(ExchangeStorage.OrderNotOpen.selector, orderId));
        exchange.makeOffer(orderId, bob, address(rwa), SELL_RWA, address(usdc), 900e6, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_AO746_RevertsWhenTheOrderIsAlreadyFilled() public {
        uint256 orderId = _placeRwaForUsdc(alice);
        AsseteraECS.KycAttestation memory fillAtt = _attest(bob, ExchangeTypes.Action.Fill, orderId);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.fillOrder(orderId, SELL_RWA, fillAtt);
        vm.stopPrank();

        AsseteraECS.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), 900e6);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), 900e6);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(abi.encodeWithSelector(ExchangeStorage.OrderNotOpen.selector, orderId));
        exchange.makeOffer(orderId, bob, address(rwa), SELL_RWA, address(usdc), 900e6, 0, att, feeAtt);
        vm.stopPrank();
    }

    /// An order selling something neither leg trades could never satisfy the draw predicate,
    /// so the link would be a label the contract never honours.
    function test_AO746_RevertsWhenTheOrderTradesNeitherLeg() public {
        FaucetToken other = _thirdToken();
        AsseteraECS.KycAttestation memory pAtt = _attestPlace(alice, address(other), 5e18, address(usdc), 500e6);
        AsseteraECS.FeeAttestation memory pFee = _feePlace(alice, address(other), 5e18, address(usdc), 500e6);
        vm.startPrank(alice);
        other.approve(address(exchange), 5e18);
        uint256 orderId = exchange.placeOrder(address(other), 5e18, address(usdc), 500e6, 0, pAtt, pFee);
        vm.stopPrank();

        AsseteraECS.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), 900e6);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), 900e6);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(abi.encodeWithSelector(OfferBook.OrderNotLinkable.selector, orderId));
        exchange.makeOffer(orderId, bob, address(rwa), SELL_RWA, address(usdc), 900e6, 0, att, feeAtt);
        vm.stopPrank();
    }

    /// A standalone offer — the shape every offer had before AO-746 — must keep working, and
    /// must not touch the order book.
    function test_AO746_StandaloneOfferWithNoOrderIdStillSettles() public {
        uint256 offerId = _makeOfferOn(0, alice, bob, address(rwa), SELL_RWA, address(usdc), 900e6, SELL_RWA);
        assertEq(exchange.getOffer(offerId).orderId, 0, "a standalone offer must carry no order id");

        _acceptOfferWithApproval(bob, offerId, SELL_RWA, 900e6, address(usdc), 900e6);

        assertEq(uint8(exchange.getOffer(offerId).status), uint8(ExchangeTypes.OfferStatus.Settled), "offer unsettled");
        assertEq(exchange.totalOrders(), 0, "a standalone offer must not touch the order book");
        assertEq(rwa.balanceOf(bob), 1_000e18 + SELL_RWA, "asset did not reach the taker");
    }

    /// The draw is one-way. Unwinding the negotiation returns the asset to the maker's WALLET;
    /// it does not silently re-list it. Whether the listing comes back is the maker's decision.
    function test_AO746_CancellingADrawnOfferPaysTheWalletAndLeavesTheOrderReduced() public {
        uint256 orderId = _placeRwaForUsdc(alice);
        uint256 offerId = _makeOfferOn(orderId, alice, bob, address(rwa), SELL_RWA, address(usdc), 900e6, 0);

        uint256 aliceRwaBefore = rwa.balanceOf(alice);
        AsseteraECS.KycAttestation memory att = _attestCancelOffer(alice, offerId, SELL_RWA, 900e6);
        vm.prank(alice);
        exchange.cancelOffer(offerId, att);

        assertEq(rwa.balanceOf(alice), aliceRwaBefore + SELL_RWA, "unwind did not pay the wallet");
        AsseteraECS.Order memory o = exchange.getOrder(orderId);
        assertEq(o.remainingQuantity, 0, "unwind silently re-listed the asset");
        assertEq(uint8(o.status), uint8(ExchangeTypes.OrderStatus.Open), "cancelling an offer must not close the order");
        assertEq(rwa.balanceOf(address(exchange)), 0, "venue retained tokens after the unwind");
    }

    /// Closing the order returns the escrowed maker fee no fill ever earned. Nothing of it is
    /// owed to the collector: the trade that happened was the OFFER's, under the offer's terms.
    function test_AO746_ClosingTheOrderRefundsItsUnconsumedEscrowedFee() public {
        // A buy-side order: alice escrows the CURRENCY, so she also escrows her own fee.
        uint256 usdcAmt = 1_000e6;
        uint16 makerBps = 100; // 1 %
        uint256 orderFee = (usdcAmt * makerBps) / 10_000;
        AsseteraECS.KycAttestation memory pAtt = _attestPlace(alice, address(usdc), usdcAmt, address(rwa), SELL_RWA);
        AsseteraECS.FeeAttestation memory pFee =
            _feePlaceWithFee(alice, address(usdc), usdcAmt, address(rwa), SELL_RWA, makerBps, 0, carol);
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);
        vm.startPrank(alice);
        usdc.approve(address(exchange), usdcAmt + orderFee);
        uint256 orderId = exchange.placeOrder(address(usdc), usdcAmt, address(rwa), SELL_RWA, 0, pAtt, pFee);
        vm.stopPrank();
        assertEq(exchange.getOrder(orderId).escrowedFee, orderFee, "fixture did not escrow a fee");

        // Alice negotiates the same buy through an offer, funded entirely by the order.
        uint256 offerId = _makeOfferOn(orderId, alice, bob, address(usdc), usdcAmt, address(rwa), SELL_RWA, 0);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        AsseteraECS.KycAttestation memory aAtt = _attestAcceptOffer(bob, offerId, usdcAmt, SELL_RWA);
        vm.startPrank(bob);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectEmit(true, true, false, true);
        emit OfferBook.OrderClosedByOffer(orderId, offerId, orderFee);
        exchange.acceptOffer(offerId, aAtt);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + orderFee, "unearned order fee not returned");
        AsseteraECS.Order memory o = exchange.getOrder(orderId);
        assertEq(o.escrowedFee, 0, "escrowed fee left stranded on a closed order");
        assertEq(uint8(o.status), uint8(ExchangeTypes.OrderStatus.Filled), "order not closed");
        assertEq(usdc.balanceOf(address(exchange)), 0, "venue retained currency after settlement");
    }

    /// The link travels on the settlement log, not only on `OfferMade`, so a consumer
    /// projecting one event can attribute the trade to its order.
    function test_AO746_OfferAcceptedCarriesTheOrderId() public {
        uint256 orderId = _placeRwaForUsdc(alice);
        uint256 offerId = _makeOfferOn(orderId, alice, bob, address(rwa), SELL_RWA, address(usdc), 900e6, 0);

        AsseteraECS.KycAttestation memory att = _attestAcceptOffer(bob, offerId, SELL_RWA, 900e6);
        vm.startPrank(bob);
        usdc.approve(address(exchange), 900e6);
        vm.expectEmit(true, true, false, true);
        emit OfferBook.OfferAccepted(offerId, bob, SELL_RWA, 900e6, orderId);
        exchange.acceptOffer(offerId, att);
        vm.stopPrank();
    }

    /// Appending `orderId` to `Offer` is only upgrade-safe because `Offer` lives in a MAPPING:
    /// every entry sits at its own hashed base, so a thirteenth word extends into space that
    /// was previously unwritten rather than into the next entry. That is a claim about the
    /// layout, and the storage-layout snapshot only shows the NEW layout — so pin it against
    /// the OLD one directly.
    ///
    /// This writes an offer the way the pre-AO-746 implementation would have: twelve words at
    /// `keccak256(id, 2) + 0..11`, and NOTHING at word 12. Then it reads it back through the
    /// new implementation. If the append had shifted anything, a field would come back wrong;
    /// if the append had landed on occupied space, `orderId` would come back non-zero.
    function test_AO746_PreUpgradeOfferReadsBackIntactWithNoOrderId() public {
        uint256 id = 7;
        bytes32 base = keccak256(abi.encode(id, uint256(2))); // `_offers` is top-level slot 2

        // The twelve words a pre-AO-746 `Offer` occupied, in declaration order. Word 7 packs
        // status (uint8) + createdAt (uint64) + expireTs (uint64), exactly as it did before.
        uint64 createdAt = uint64(block.timestamp);
        uint64 expireTs = uint64(block.timestamp + 1 days);
        bytes32 packed = bytes32(
            uint256(uint8(ExchangeTypes.OfferStatus.Open)) | (uint256(createdAt) << 8) | (uint256(expireTs) << 72)
        );

        vm.store(address(exchange), bytes32(uint256(base) + 0), bytes32(id));
        vm.store(address(exchange), bytes32(uint256(base) + 1), bytes32(uint256(uint160(alice))));
        vm.store(address(exchange), bytes32(uint256(base) + 2), bytes32(uint256(uint160(bob))));
        vm.store(address(exchange), bytes32(uint256(base) + 3), bytes32(uint256(uint160(address(rwa)))));
        vm.store(address(exchange), bytes32(uint256(base) + 4), bytes32(SELL_RWA));
        vm.store(address(exchange), bytes32(uint256(base) + 5), bytes32(uint256(uint160(address(usdc)))));
        vm.store(address(exchange), bytes32(uint256(base) + 6), bytes32(WANT_USDC));
        vm.store(address(exchange), bytes32(uint256(base) + 7), packed);
        // Word 8 packs proposedBy (20 bytes) + makerFeeBps + takerFeeBps, as it did before.
        vm.store(
            address(exchange),
            bytes32(uint256(base) + 8),
            bytes32(uint256(uint160(alice)) | (uint256(100) << 160) | (uint256(50) << 176))
        );
        vm.store(address(exchange), bytes32(uint256(base) + 9), bytes32(uint256(uint160(carol)))); // feeCollector
        vm.store(address(exchange), bytes32(uint256(base) + 10), bytes32(uint256(uint160(address(usdc)))));
        vm.store(address(exchange), bytes32(uint256(base) + 11), bytes32(uint256(0)));
        // Word 12 (`orderId`) is deliberately NOT written — that is the whole point.

        AsseteraECS.Offer memory o = exchange.getOffer(id);
        assertEq(o.id, id, "id moved");
        assertEq(o.maker, alice, "maker moved");
        assertEq(o.taker, bob, "taker moved");
        assertEq(o.makerToken, address(rwa), "makerToken moved");
        assertEq(o.makerAmount, SELL_RWA, "makerAmount moved");
        assertEq(o.takerToken, address(usdc), "takerToken moved");
        assertEq(o.takerAmount, WANT_USDC, "takerAmount moved");
        assertEq(uint8(o.status), uint8(ExchangeTypes.OfferStatus.Open), "status moved");
        assertEq(o.createdAt, createdAt, "createdAt moved");
        assertEq(o.expireTs, expireTs, "expireTs moved");
        assertEq(o.proposedBy, alice, "proposedBy moved");
        assertEq(o.makerFeeBps, 100, "makerFeeBps moved");
        assertEq(o.takerFeeBps, 50, "takerFeeBps moved");
        assertEq(o.feeCollector, carol, "feeCollector moved");
        assertEq(o.feeToken, address(usdc), "feeToken moved");
        assertEq(o.escrowedFee, 0, "escrowedFee moved");
        assertEq(o.orderId, 0, "the appended word was not previously free");

        // The neighbouring entries must be untouched: the append must not have run into
        // `_offers[8]`, which shares nothing with `_offers[7]` precisely because each entry
        // is hashed independently.
        assertEq(exchange.getOffer(id + 1).id, 0, "the next offer entry was clobbered");
        assertEq(exchange.getOffer(id - 1).id, 0, "the previous offer entry was clobbered");

        // And a pre-upgrade offer still behaves: it settles under the new implementation,
        // touching no order because it carries no order id.
        AsseteraECS.KycAttestation memory att = _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
        rwa.mint(address(exchange), SELL_RWA); // the escrow the old implementation had taken
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC + (WANT_USDC * 50) / 10_000);
        exchange.acceptOffer(id, att);
        vm.stopPrank();
        assertEq(uint8(exchange.getOffer(id).status), uint8(ExchangeTypes.OfferStatus.Settled), "legacy offer stuck");
    }

    /// ⚠️ The sharpest edge in AO-746. Both parties may name the same order, and only ONE of
    /// them owns it. If the draw did not check ownership, the counterparty could fund their own
    /// leg out of the order maker's escrow — taking the maker's asset and keeping their own.
    /// Here bob's leg is the SAME token alice listed, so nothing but the ownership check stands
    /// between him and her escrow.
    function test_AO746_ACounterpartyCannotDrawOnTheOrderMakersEscrow() public {
        uint256 orderId = _placeRwaForUsdc(alice); // alice escrowed 10 RWA

        // Bob proposes RWA-for-USDC to alice, naming HER order. Same token as her listing.
        uint256 bobRwaBefore = rwa.balanceOf(bob);
        uint256 offerId = _makeOfferOn(orderId, bob, alice, address(rwa), 4e18, address(usdc), 400e6, 4e18);

        assertEq(rwa.balanceOf(bob), bobRwaBefore - 4e18, "the counterparty did not pay for their own leg");
        assertEq(exchange.getOrder(orderId).remainingQuantity, SELL_RWA, "the counterparty drew on the maker's escrow");
        assertEq(exchange.getOffer(offerId).orderId, orderId, "link not recorded");
    }

    /// Defence in depth, and the reason it is not optional. No path today leaves a closed order
    /// with quantity still on it — every close zeroes `remainingQuantity` before refunding — so
    /// this state can only be reached by forcing it. But if it ever were reached, drawing on it
    /// would hand an offer escrow the venue had ALREADY refunded: the accounting would balance
    /// on paper and the token transfer would fail, or worse, succeed out of another user's
    /// escrow. Both the link check and the draw check must refuse it, so pin both.
    function test_AO746_AClosedOrderWithStaleQuantityIsNeverDrawnOn() public {
        // (a) The link itself is refused up front.
        uint256 cancelled = _placeRwaForUsdc(alice);
        vm.prank(alice);
        exchange.cancelOrder(cancelled);
        bytes32 cancelledBase = keccak256(abi.encode(cancelled, uint256(0))); // `_orders` is slot 0
        vm.store(address(exchange), bytes32(uint256(cancelledBase) + 7), bytes32(SELL_RWA));

        AsseteraECS.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), 900e6);
        AsseteraECS.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), 900e6);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(abi.encodeWithSelector(ExchangeStorage.OrderNotOpen.selector, cancelled));
        exchange.makeOffer(cancelled, bob, address(rwa), SELL_RWA, address(usdc), 900e6, 0, att, feeAtt);
        vm.stopPrank();

        // (b) And so is a LATER draw. The link check ran when the order was still Open; the
        //     order closed underneath the negotiation, so only the draw's own status check is
        //     left. Bob proposes first (he owns nothing, so nothing is drawn on his behalf).
        uint256 orderId = _placeRwaForUsdc(alice);
        uint256 offerId = _makeOfferOn(orderId, bob, alice, address(usdc), 900e6, address(rwa), SELL_RWA, 900e6);
        vm.prank(alice);
        exchange.cancelOrder(orderId); // escrow refunded to alice; quantity zeroed
        bytes32 base = keccak256(abi.encode(orderId, uint256(0)));
        vm.store(address(exchange), bytes32(uint256(base) + 7), bytes32(SELL_RWA)); // forge the stale quantity

        // Alice counters with a zero allowance. Her leg must come from her wallet — the venue no
        // longer holds the escrow this "order" still claims — so the call must fail on allowance.
        AsseteraECS.KycAttestation memory rAtt = _attestReplaceOffer(alice, offerId, 950e6, SELL_RWA);
        vm.startPrank(alice);
        rwa.approve(address(exchange), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(exchange), 0, SELL_RWA)
        );
        exchange.replaceOffer(offerId, 950e6, SELL_RWA, 0, rAtt);
        vm.stopPrank();
    }

    /// Closing must never overwrite a compliance verdict. An order the admin force-cancelled
    /// while a negotiation was open has already been resolved by the multisig; settling that
    /// negotiation must not relabel it as a normal fill.
    function test_AO746_SettlementDoesNotReopenAnAdminForceCancelledOrder() public {
        uint256 orderId = _placeRwaForUsdc(alice);
        uint256 offerId = _makeOfferOn(orderId, alice, bob, address(rwa), SELL_RWA, address(usdc), 900e6, 0);
        assertEq(exchange.getOrder(orderId).remainingQuantity, 0, "fixture did not draw the whole order");

        vm.prank(admin);
        exchange.cancelOrderForUser(orderId, carol);
        assertEq(
            uint8(exchange.getOrder(orderId).status),
            uint8(ExchangeTypes.OrderStatus.ForceCancelled),
            "fixture did not force-cancel"
        );

        _acceptOfferWithApproval(bob, offerId, SELL_RWA, 900e6, address(usdc), 900e6);

        assertEq(
            uint8(exchange.getOrder(orderId).status),
            uint8(ExchangeTypes.OrderStatus.ForceCancelled),
            "settlement overwrote an admin decision"
        );
    }
}
