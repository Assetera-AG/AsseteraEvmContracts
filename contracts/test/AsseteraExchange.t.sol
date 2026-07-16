// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {AsseteraExchange} from "../src/AsseteraExchange.sol";
import {ExchangeTypes} from "../src/types/ExchangeTypes.sol";
import {ExchangeStorage} from "../src/storage/ExchangeStorage.sol";
import {IKycGate} from "../src/interfaces/IKycGate.sol";
import {IFeeGate} from "../src/interfaces/IFeeGate.sol";
import {OrderBook} from "../src/core/OrderBook.sol";
import {OfferBook} from "../src/core/OfferBook.sol";
import {ExchangeAdmin} from "../src/admin/ExchangeAdmin.sol";
import {FaucetToken} from "../src/FaucetToken.sol";
import {AsseteraExchangeV2} from "./mocks/AsseteraExchangeV2.sol";
import {ReentrantToken} from "./mocks/ReentrantToken.sol";
import {FeeOnTransferToken} from "./mocks/FeeOnTransferToken.sol";
import {RebasingToken} from "./mocks/RebasingToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract AsseteraExchangeTest is Test {
    AsseteraExchange internal exchange;
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
        "FeeAttestation(address account,uint8 action,uint256 nonce,uint256 deadline,bytes32 paramsHash,uint16 makerFeeBps,uint16 takerFeeBps,address feeCollector)"
    );

    event OrderPlaced(
        uint256 indexed id,
        address indexed maker,
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 buyAmount,
        uint64 expireTs
    );
    event OrderForceCancelled(uint256 indexed id, address indexed maker, address recipient, address indexed admin);

    function setUp() public {
        kycSigner = vm.addr(kycSignerPk);
        feeSigner = vm.addr(feeSignerPk);

        usdc = new FaucetToken("Mock USD Coin", "mUSDC", 6);
        rwa = new FaucetToken("Mock RWA Token", "mRWA", 18);
        forwarder = new ERC2771Forwarder("AsseteraForwarder");

        AsseteraExchange impl = new AsseteraExchange(address(forwarder));
        bytes memory initData = abi.encodeCall(AsseteraExchange.initialize, (admin, kycSigner, feeSigner));
        exchange = AsseteraExchange(address(new ERC1967Proxy(address(impl), initData)));

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
        AsseteraExchange.Action action,
        uint256 orderId,
        uint256 nonce,
        uint256 deadline,
        bytes32 paramsHash
    ) internal view returns (AsseteraExchange.KycAttestation memory att) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
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
        att = ExchangeTypes.KycAttestation({
            account: account,
            action: action,
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
        AsseteraExchange.Action action,
        uint256 nonce,
        uint256 deadline,
        bytes32 paramsHash,
        uint16 makerFeeBps,
        uint16 takerFeeBps,
        address feeCollector
    ) internal view returns (AsseteraExchange.FeeAttestation memory att) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
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
                feeCollector
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        att = ExchangeTypes.FeeAttestation({
            account: account,
            action: action,
            nonce: nonce,
            deadline: deadline,
            paramsHash: paramsHash,
            makerFeeBps: makerFeeBps,
            takerFeeBps: takerFeeBps,
            feeCollector: feeCollector,
            signature: abi.encodePacked(r, s, v)
        });
    }

    /// A valid, fresh attestation for non-Place actions (paramsHash = 0).
    function _attest(address account, AsseteraExchange.Action action, uint256 orderId)
        internal
        returns (AsseteraExchange.KycAttestation memory)
    {
        return _signAtt(kycSignerPk, account, action, orderId, _freshNonce(), block.timestamp + 3 minutes, bytes32(0));
    }

    /// A valid, fresh KYC attestation for Place actions (paramsHash bound to order params).
    function _attestPlace(address account, address sellToken, uint256 sellAmount, address buyToken, uint256 buyAmount)
        internal
        returns (AsseteraExchange.KycAttestation memory)
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
        returns (AsseteraExchange.FeeAttestation memory)
    {
        return _feePlaceWithFee(account, sellToken, sellAmount, buyToken, buyAmount, 0, 0, address(0));
    }

    /// A valid, fresh Place-bound Fee attestation with explicit fee parameters.
    function _feePlaceWithFee(
        address account,
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 buyAmount,
        uint16 makerFeeBps,
        uint16 takerFeeBps,
        address feeCollector
    ) internal returns (AsseteraExchange.FeeAttestation memory) {
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
            feeCollector
        );
    }

    function _placeRwaForUsdc(address maker) internal returns (uint256 id) {
        AsseteraExchange.KycAttestation memory att =
            _attestPlace(maker, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feePlace(maker, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(maker);
        rwa.approve(address(exchange), SELL_RWA);
        id = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function _placeUsdcForRwa(address maker, uint256 usdcAmt, uint256 rwaWant) internal returns (uint256 id) {
        AsseteraExchange.KycAttestation memory att = _attestPlace(maker, address(usdc), usdcAmt, address(rwa), rwaWant);
        AsseteraExchange.FeeAttestation memory feeAtt = _feePlace(maker, address(usdc), usdcAmt, address(rwa), rwaWant);
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
        assertEq(exchange.version(), "3.1.0");
        assertTrue(exchange.complianceRequired(ExchangeTypes.Action.Place));
        assertTrue(exchange.complianceRequired(ExchangeTypes.Action.Fill));
        assertTrue(exchange.complianceRequired(ExchangeTypes.Action.Settle));
        assertEq(exchange.trustedForwarder(), address(forwarder));
    }

    function test_Initialize_RevertsOnZeroKycSigner() public {
        AsseteraExchange impl = new AsseteraExchange(address(forwarder));
        bytes memory initData = abi.encodeCall(AsseteraExchange.initialize, (admin, address(0), feeSigner));
        vm.expectRevert(ExchangeStorage.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertsOnZeroFeeSigner() public {
        AsseteraExchange impl = new AsseteraExchange(address(forwarder));
        bytes memory initData = abi.encodeCall(AsseteraExchange.initialize, (admin, kycSigner, address(0)));
        vm.expectRevert(ExchangeStorage.ZeroAddress.selector);
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
        AsseteraExchange.KycAttestation memory att =
            _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectEmit(true, true, false, true, address(exchange));
        emit OrderPlaced(1, alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0);
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
        AsseteraExchange.KycAttestation memory att =
            _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
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
        AsseteraExchange.KycAttestation memory att =
            _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(ExchangeStorage.InvalidExpiry.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, uint64(block.timestamp - 1), att, feeAtt);
        vm.stopPrank();
    }

    function test_PlaceOrder_RevertsWithoutAttestation_BadSigner() public {
        // Signed by a key that does NOT hold KYC_OPERATOR_ROLE.
        bytes32 ph = keccak256(abi.encode(address(rwa), SELL_RWA, address(usdc), WANT_USDC));
        AsseteraExchange.KycAttestation memory att =
            _signAtt(0xBAD, alice, ExchangeTypes.Action.Place, 0, _freshNonce(), block.timestamp + 3 minutes, ph);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(IKycGate.KycBadSigner.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_PlaceOrder_RevertsOnExpiredAttestation() public {
        bytes32 ph = keccak256(abi.encode(address(rwa), SELL_RWA, address(usdc), WANT_USDC));
        AsseteraExchange.KycAttestation memory att =
            _signAtt(kycSignerPk, alice, ExchangeTypes.Action.Place, 0, _freshNonce(), block.timestamp + 100, ph);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.warp(block.timestamp + 101);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(IKycGate.KycExpired.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_PlaceOrder_RevertsOnTtlTooLong() public {
        bytes32 ph = keccak256(abi.encode(address(rwa), SELL_RWA, address(usdc), WANT_USDC));
        AsseteraExchange.KycAttestation memory att = _signAtt(
            kycSignerPk, alice, ExchangeTypes.Action.Place, 0, _freshNonce(), block.timestamp + 16 minutes, ph
        );
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(IKycGate.KycTtlTooLong.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_PlaceOrder_RevertsOnAccountMismatch() public {
        // Attestation is for bob, but alice is acting.
        AsseteraExchange.KycAttestation memory att = _attestPlace(bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
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
        AsseteraExchange.KycAttestation memory att =
            _signAtt(kycSignerPk, alice, ExchangeTypes.Action.Fill, 0, _freshNonce(), block.timestamp + 3 minutes, ph);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(IKycGate.KycActionMismatch.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_PlaceOrder_RevertsOnNonceReuse() public {
        AsseteraExchange.KycAttestation memory att =
            _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
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
        AsseteraExchange.KycAttestation memory att =
            _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_PlaceOrder_GatingOff_NoAttestationNeeded() public {
        vm.prank(admin);
        exchange.setComplianceRequired(ExchangeTypes.Action.Place, false);
        AsseteraExchange.KycAttestation memory empty; // garbage / empty
        AsseteraExchange.FeeAttestation memory emptyFee; // garbage / empty
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        uint256 id = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, empty, emptyFee);
        vm.stopPrank();
        assertEq(id, 1);
    }

    function test_PlaceOrder_RevertsOnZeroAmount() public {
        AsseteraExchange.KycAttestation memory att = _attestPlace(alice, address(rwa), 0, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), 0, address(usdc), WANT_USDC);
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
            ExchangeTypes.KycAttestation({
                account: address(0),
                action: ExchangeTypes.Action.None,
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
        AsseteraExchange.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
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

        AsseteraExchange.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
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

        AsseteraExchange.KycAttestation memory empty;
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

        AsseteraExchange.KycAttestation memory empty;
        vm.startPrank(alice);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.SelfTrade.selector, id));
        exchange.fillOrder(id, SELL_RWA, empty);
        vm.stopPrank();
    }

    function test_FillOrder_RevertsOnExpiredOrder() public {
        // Filling an expired order must revert.
        uint64 expireTs = uint64(block.timestamp + 1 hours);
        AsseteraExchange.KycAttestation memory placeAtt =
            _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory placeFeeAtt =
            _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        uint256 id =
            exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, expireTs, placeAtt, placeFeeAtt);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 hours);
        vm.prank(admin);
        exchange.setComplianceRequired(ExchangeTypes.Action.Fill, false);

        AsseteraExchange.KycAttestation memory empty;
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.OrderIsExpired.selector, id));
        exchange.fillOrder(id, SELL_RWA, empty);
        vm.stopPrank();
    }

    function test_FillOrder_RevertsOnFillAmountZero() public {
        uint256 id = _placeRwaForUsdc(alice);
        AsseteraExchange.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectRevert(OrderBook.FillAmountZero.selector);
        exchange.fillOrder(id, 0, att);
        vm.stopPrank();
    }

    function test_FillOrder_RevertsOnFillExceedsRemaining() public {
        uint256 id = _placeRwaForUsdc(alice);
        AsseteraExchange.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC * 2);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.FillExceedsRemaining.selector, id, SELL_RWA));
        exchange.fillOrder(id, SELL_RWA + 1, att);
        vm.stopPrank();
    }

    function test_FillOrder_RevertsWithoutValidAttestation() public {
        uint256 id = _placeRwaForUsdc(alice);
        AsseteraExchange.KycAttestation memory att =
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
        AsseteraExchange.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id + 99);
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
        AsseteraExchange.KycAttestation memory att =
            _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
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
        AsseteraExchange.KycAttestation memory att2 =
            _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt2 =
            _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        uint256 id2 = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, future, att2, feeAtt2);
        vm.stopPrank();
        // Order 3: expiry in past (swept)
        uint64 past = uint64(block.timestamp + 1 hours);
        AsseteraExchange.KycAttestation memory att3 =
            _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt3 =
            _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
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
        AsseteraExchange.KycAttestation memory att =
            _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
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
        vm.expectRevert(ExchangeStorage.ZeroAddress.selector);
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
        AsseteraExchange.KycAttestation memory att =
            _attestPlace(user, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feePlace(user, address(rwa), SELL_RWA, address(usdc), WANT_USDC);

        bytes memory callData = abi.encodeCall(
            OrderBook.placeOrderWithPermit,
            (address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, permitDeadline, pv, pr, ps, att, feeAtt)
        );

        // Relayer submits via the forwarder, paying gas.
        _relay(userPk, user, address(exchange), callData);

        // Order belongs to the user, not the relayer.
        AsseteraExchange.Order memory o = exchange.getOrder(1);
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
        AsseteraExchangeV2 implV2 = new AsseteraExchangeV2(address(forwarder));
        vm.prank(admin);
        exchange.upgradeToAndCall(address(implV2), "");

        assertEq(exchange.version(), "4.0.0");
        assertTrue(AsseteraExchangeV2(address(exchange)).isUpgraded());
        assertEq(exchange.getOrder(id).maker, alice);
        assertEq(exchange.trustedForwarder(), address(forwarder));
    }

    function test_Upgrade_RevertsIfNotAdmin() public {
        AsseteraExchangeV2 implV2 = new AsseteraExchangeV2(address(forwarder));
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
            AsseteraExchange.KycAttestation memory att =
                _attestPlace(alice, address(rwa), SELL_RWA, address(evil), 100e18);
            AsseteraExchange.FeeAttestation memory feeAtt =
                _feePlace(alice, address(rwa), SELL_RWA, address(evil), 100e18);
            vm.startPrank(alice);
            rwa.approve(address(exchange), SELL_RWA);
            id = exchange.placeOrder(address(rwa), SELL_RWA, address(evil), 100e18, 0, att, feeAtt);
            vm.stopPrank();
        }
        AsseteraExchange.KycAttestation memory empty;
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

        AsseteraExchange.KycAttestation memory pAtt = _attestPlace(alice, address(rwa), sellAmt, address(usdc), buyAmt);
        AsseteraExchange.FeeAttestation memory pFeeAtt = _feePlace(alice, address(rwa), sellAmt, address(usdc), buyAmt);
        vm.startPrank(alice);
        rwa.approve(address(exchange), sellAmt);
        uint256 id = exchange.placeOrder(address(rwa), sellAmt, address(usdc), buyAmt, 0, pAtt, pFeeAtt);
        vm.stopPrank();

        AsseteraExchange.KycAttestation memory fAtt = _attest(bob, ExchangeTypes.Action.Fill, id);
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

        AsseteraExchange.KycAttestation memory pAtt = _attestPlace(alice, address(rwa), sellAmt, address(usdc), buyAmt);
        AsseteraExchange.FeeAttestation memory pFeeAtt = _feePlace(alice, address(rwa), sellAmt, address(usdc), buyAmt);
        vm.startPrank(alice);
        rwa.approve(address(exchange), sellAmt);
        uint256 id = exchange.placeOrder(address(rwa), sellAmt, address(usdc), buyAmt, 0, pAtt, pFeeAtt);
        vm.stopPrank();

        // Expected buyAmountDue via the same ceiling-division formula as FeeMath.ceilDiv, computed
        // independently of the contract under test.
        uint256 expectedBuyAmountDue = (fillAmt * buyAmt + sellAmt - 1) / sellAmt;
        assertGe(expectedBuyAmountDue * sellAmt, fillAmt * buyAmt, "ceiling must never round down");

        AsseteraExchange.KycAttestation memory fAtt = _attest(bob, ExchangeTypes.Action.Fill, id);
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
        AsseteraExchange impl = new AsseteraExchange(address(forwarder));
        bytes memory initData = abi.encodeCall(AsseteraExchange.initialize, (address(0), kycSigner, feeSigner));
        vm.expectRevert(ExchangeStorage.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_PlaceOrderWithPermit_Direct() public {
        uint256 pk = 0xBEEF;
        address maker = vm.addr(pk);
        rwa.mint(maker, SELL_RWA);
        uint256 dl = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(rwa, pk, maker, address(exchange), SELL_RWA, dl);
        AsseteraExchange.KycAttestation memory att =
            _attestPlace(maker, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feePlace(maker, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.prank(maker);
        uint256 id = exchange.placeOrderWithPermit(
            address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, dl, v, r, s, att, feeAtt
        );
        assertEq(id, 1);
        assertEq(rwa.balanceOf(address(exchange)), SELL_RWA);
    }

    function test_PlaceOrder_RevertsOnZeroSellToken() public {
        AsseteraExchange.KycAttestation memory att = _attestPlace(alice, address(0), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt = _feePlace(alice, address(0), SELL_RWA, address(usdc), WANT_USDC);
        vm.prank(alice);
        vm.expectRevert(ExchangeStorage.ZeroAddress.selector);
        exchange.placeOrder(address(0), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
    }

    function test_PlaceOrder_RevertsOnSameToken() public {
        AsseteraExchange.KycAttestation memory att =
            _attestPlace(alice, address(rwa), SELL_RWA, address(rwa), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feePlace(alice, address(rwa), SELL_RWA, address(rwa), WANT_USDC);
        vm.prank(alice);
        vm.expectRevert(ExchangeStorage.SameToken.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(rwa), WANT_USDC, 0, att, feeAtt);
    }

    function test_PlaceOrder_RevertsOnOrderIdMismatch() public {
        // Attestation carries the correct paramsHash but wrong orderId (7 vs required 0 for Place).
        // paramsHash check passes; KycOrderMismatch fires inside _consumeKyc.
        bytes32 ph = keccak256(abi.encode(address(rwa), SELL_RWA, address(usdc), WANT_USDC));
        AsseteraExchange.KycAttestation memory att =
            _signAtt(kycSignerPk, alice, ExchangeTypes.Action.Place, 7, _freshNonce(), block.timestamp + 3 minutes, ph);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
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
        AsseteraExchange.KycAttestation memory f = _attest(bob, ExchangeTypes.Action.Fill, id);
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
        AsseteraExchange.KycAttestation memory f = _attest(bob, ExchangeTypes.Action.Fill, id);
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
        assertFalse(exchange.complianceRequired(ExchangeTypes.Action.Fill));
        // fill now works with an empty attestation
        uint256 id = _placeRwaForUsdc(alice);
        AsseteraExchange.KycAttestation memory empty;
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
        AsseteraExchange.KycAttestation memory att =
            _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(ExchangeStorage.ParamsHashMismatch.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC + 1, 0, att, feeAtt);
        vm.stopPrank();
    }

    // ===================================================================== //
    //                       missing-coverage additions                       //
    // ===================================================================== //

    // --- M-1 invariant: nonce NOT burned when param validation fails ----- //

    function test_PlaceOrder_NonceSurvivedAfterParamValidationFailure() public {
        AsseteraExchange.KycAttestation memory att =
            _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feePlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);

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
        AsseteraExchange.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), 0);
        AsseteraExchange.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), SELL_RWA, address(usdc), 0);
        vm.prank(alice);
        vm.expectRevert(ExchangeStorage.ZeroAmount.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), 0, 0, att, feeAtt);
    }

    function test_PlaceOrder_RevertsOnZeroBuyToken() public {
        AsseteraExchange.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(0), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt = _feePlace(alice, address(rwa), SELL_RWA, address(0), WANT_USDC);
        vm.prank(alice);
        vm.expectRevert(ExchangeStorage.ZeroAddress.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(0), WANT_USDC, 0, att, feeAtt);
    }

    // --- sweepExpired returns only remainingQuantity for partial fills --- //

    function test_SweepExpired_PartiallyFilledOrder() public {
        uint64 expireTs = uint64(block.timestamp + 1 hours);
        AsseteraExchange.KycAttestation memory placeAtt =
            _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory placeFeeAtt =
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
        AsseteraExchange.KycAttestation memory empty;
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
        AsseteraExchange.KycAttestation memory att = _signAtt(
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
        vm.expectRevert(ExchangeStorage.ParamsHashMismatch.selector);
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
    ) internal returns (AsseteraExchange.KycAttestation memory) {
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
    ) internal returns (AsseteraExchange.FeeAttestation memory) {
        return _feeMakeOfferWithFee(maker, taker, makerToken, makerAmt, takerToken, takerAmt, 0, 0, address(0));
    }

    /// A valid, fresh MakeOffer-bound Fee attestation with explicit fee parameters.
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
    ) internal returns (AsseteraExchange.FeeAttestation memory) {
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
            feeCollector
        );
    }

    function _attestReplaceOffer(address caller, uint256 offerId, uint256 newMakerAmt, uint256 newTakerAmt)
        internal
        returns (AsseteraExchange.KycAttestation memory)
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
        returns (AsseteraExchange.KycAttestation memory)
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
        returns (AsseteraExchange.KycAttestation memory)
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
        AsseteraExchange.KycAttestation memory att =
            _attestMakeOffer(maker, taker, makerToken, makerAmt, takerToken, takerAmt);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feeMakeOffer(maker, taker, makerToken, makerAmt, takerToken, takerAmt);
        vm.startPrank(maker);
        FaucetToken(makerToken).approve(address(exchange), makerAmt);
        id = exchange.makeOffer(taker, makerToken, makerAmt, takerToken, takerAmt, expireTs, att, feeAtt);
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
        AsseteraExchange.KycAttestation memory att =
            _attestMakeOffer(maker, taker, makerToken, makerAmt, takerToken, takerAmt);
        AsseteraExchange.FeeAttestation memory feeAtt = _feeMakeOfferWithFee(
            maker, taker, makerToken, makerAmt, takerToken, takerAmt, makerFeeBps, takerFeeBps, feeCollector
        );
        vm.startPrank(maker);
        FaucetToken(makerToken).approve(address(exchange), makerAmt);
        id = exchange.makeOffer(taker, makerToken, makerAmt, takerToken, takerAmt, 0, att, feeAtt);
        vm.stopPrank();
    }

    // ── Happy paths ────────────────────────────────────────────────────── //

    function test_Offer_MultipleRounds_MakerCounterCounters() public {
        // Alice offers → Bob counters → Alice counter-counters → Bob accepts → settle.
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);

        uint256 round2Usdc = 800e6;
        uint256 round3Usdc = 900e6;

        // Round 2: Bob counters with 800 USDC.
        AsseteraExchange.KycAttestation memory r2 = _attestReplaceOffer(bob, id, SELL_RWA, round2Usdc);
        vm.startPrank(bob);
        usdc.approve(address(exchange), round2Usdc);
        exchange.replaceOffer(id, SELL_RWA, round2Usdc, 0, r2);
        vm.stopPrank();

        assertEq(exchange.getOffer(id).proposedBy, bob);
        assertEq(exchange.getOffer(id).takerAmount, round2Usdc);

        // Round 3: Alice counter-counters with 900 USDC (returns Bob's 800 USDC).
        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        AsseteraExchange.KycAttestation memory r3 = _attestReplaceOffer(alice, id, SELL_RWA, round3Usdc);
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
        AsseteraExchange.KycAttestation memory acceptAtt = _attestAcceptOffer(bob, id, SELL_RWA, round3Usdc);
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

        AsseteraExchange.KycAttestation memory att = _attestCancelOffer(alice, id, SELL_RWA, WANT_USDC);
        vm.prank(alice);
        exchange.cancelOffer(id, att);

        assertEq(uint8(exchange.getOffer(id).status), uint8(ExchangeTypes.OfferStatus.Cancelled));
        assertEq(rwa.balanceOf(alice), aliceRwaBefore + SELL_RWA);
    }

    function test_Offer_TakerCancelsAfterCounter_TakerGetEscrowBack() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);

        // Bob counters — Bob now holds the escrow.
        AsseteraExchange.KycAttestation memory replaceAtt = _attestReplaceOffer(bob, id, SELL_RWA, 800e6);
        vm.startPrank(bob);
        usdc.approve(address(exchange), 800e6);
        exchange.replaceOffer(id, SELL_RWA, 800e6, 0, replaceAtt);
        vm.stopPrank();

        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        AsseteraExchange.KycAttestation memory cancelAtt = _attestCancelOffer(bob, id, SELL_RWA, 800e6);
        vm.prank(bob);
        exchange.cancelOffer(id, cancelAtt);

        assertEq(uint8(exchange.getOffer(id).status), uint8(ExchangeTypes.OfferStatus.Cancelled));
        assertEq(usdc.balanceOf(bob), bobUsdcBefore + 800e6); // Bob's USDC returned
    }

    // ── Compliance flags ───────────────────────────────────────────────── //

    function test_Offer_ComplianceFlagsSetOnDeploy() public view {
        assertTrue(exchange.complianceRequired(ExchangeTypes.Action.MakeOffer));
        assertTrue(exchange.complianceRequired(ExchangeTypes.Action.ReplaceOffer));
        assertTrue(exchange.complianceRequired(ExchangeTypes.Action.AcceptOffer));
        assertTrue(exchange.complianceRequired(ExchangeTypes.Action.CancelOffer));
        // Action.SettleOffer is unused (AC-246) — acceptOffer settles atomically
        // under AcceptOffer's own gate, so this default is intentionally left unset.
        assertFalse(exchange.complianceRequired(ExchangeTypes.Action.SettleOffer));
    }

    // ── Event shape ───────────────────────────────────────────────────── //

    function test_Offer_EmitsOfferAccepted_WithTerms() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.KycAttestation memory att = _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);

        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectEmit(true, true, false, true);
        emit OfferBook.OfferAccepted(id, bob, SELL_RWA, WANT_USDC);
        exchange.acceptOffer(id, att);
        vm.stopPrank();
    }

    function test_Offer_EmitsOfferSettled_WithFeeTerms() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);
        uint256 id = _makeOfferWithFee(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 100, 50, carol);

        uint256 makerFeeAmt = (WANT_USDC * 100) / 10_000;
        uint256 takerFeeAmt = (SELL_RWA * 50) / 10_000;
        AsseteraExchange.KycAttestation memory att = _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);

        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectEmit(true, true, false, true);
        emit OfferBook.OfferSettled(
            id, bob, WANT_USDC - makerFeeAmt, SELL_RWA - takerFeeAmt, makerFeeAmt, takerFeeAmt, carol
        );
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
        AsseteraExchange.KycAttestation memory counterAtt = _attestReplaceOffer(bob, id, SELL_RWA, counterUsdc);
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

        AsseteraExchange.KycAttestation memory acceptAtt = _attestAcceptOffer(alice, id, SELL_RWA, counterUsdc);
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
            AsseteraExchange.KycAttestation memory att =
                _attestMakeOffer(alice, bob, address(rwa), SELL_RWA, address(evil), 100e18);
            AsseteraExchange.FeeAttestation memory feeAtt =
                _feeMakeOffer(alice, bob, address(rwa), SELL_RWA, address(evil), 100e18);
            vm.startPrank(alice);
            rwa.approve(address(exchange), SELL_RWA);
            id = exchange.makeOffer(bob, address(rwa), SELL_RWA, address(evil), 100e18, 0, att, feeAtt);
            vm.stopPrank();
        }
        // targetOrderId (1) is unreachable — the reentrant fillOrder call reverts
        // at the nonReentrant guard before ever touching order data.
        AsseteraExchange.KycAttestation memory empty;
        evil.arm(address(exchange), abi.encodeCall(OrderBook.fillOrder, (1, 1, empty)));

        AsseteraExchange.KycAttestation memory acceptAtt = _attestAcceptOffer(bob, id, SELL_RWA, 100e18);
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

        AsseteraExchange.KycAttestation memory att =
            _attestPlace(alice, address(evil), 100e18, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feePlace(alice, address(evil), 100e18, address(usdc), WANT_USDC);
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

        AsseteraExchange.KycAttestation memory att =
            _attestPlace(alice, address(evil), 100e18, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feePlace(alice, address(evil), 100e18, address(usdc), WANT_USDC);
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

        AsseteraExchange.KycAttestation memory att =
            _attestPlace(alice, address(evil), 100e18, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feePlace(alice, address(evil), 100e18, address(usdc), WANT_USDC);
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

        AsseteraExchange.KycAttestation memory att =
            _attestPlace(alice, address(evil), 100e18, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feePlace(alice, address(evil), 100e18, address(usdc), WANT_USDC);
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

        AsseteraExchange.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(evil), 100e18, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, bob, address(evil), 100e18, address(usdc), WANT_USDC);
        evil.arm(address(exchange), abi.encodeCall(OrderBook.cancelOrder, (999)));

        vm.startPrank(alice);
        evil.approve(address(exchange), type(uint256).max);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        exchange.makeOffer(bob, address(evil), 100e18, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_ReplaceOffer_ReentrancyGuarded() public {
        ReentrantToken evil = new ReentrantToken();
        evil.mint(alice, 1_000e18);

        AsseteraExchange.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(evil), 100e18, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, bob, address(evil), 100e18, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        evil.approve(address(exchange), type(uint256).max);
        uint256 id = exchange.makeOffer(bob, address(evil), 100e18, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();

        // Bob's counter first returns alice's evil-token escrow — that's the
        // leg we hook. His usdc leg would come after, never reached.
        evil.arm(address(exchange), abi.encodeCall(OrderBook.cancelOrder, (999)));

        AsseteraExchange.KycAttestation memory replaceAtt = _attestReplaceOffer(bob, id, 100e18, WANT_USDC + 1);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC + 1);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        exchange.replaceOffer(id, 100e18, WANT_USDC + 1, 0, replaceAtt);
        vm.stopPrank();
    }

    function test_CancelOffer_ReentrancyGuarded() public {
        ReentrantToken evil = new ReentrantToken();
        evil.mint(alice, 1_000e18);

        AsseteraExchange.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(evil), 100e18, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, bob, address(evil), 100e18, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        evil.approve(address(exchange), type(uint256).max);
        uint256 id = exchange.makeOffer(bob, address(evil), 100e18, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();

        evil.arm(address(exchange), abi.encodeCall(OrderBook.cancelOrder, (999)));

        AsseteraExchange.KycAttestation memory cancelAtt = _attestCancelOffer(alice, id, 100e18, WANT_USDC);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        exchange.cancelOffer(id, cancelAtt);
    }

    function test_SweepExpiredOffers_ReentrancyGuarded() public {
        ReentrantToken evil = new ReentrantToken();
        evil.mint(alice, 1_000e18);

        AsseteraExchange.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(evil), 100e18, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, bob, address(evil), 100e18, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        evil.approve(address(exchange), type(uint256).max);
        uint256 id = exchange.makeOffer(
            bob, address(evil), 100e18, address(usdc), WANT_USDC, uint64(block.timestamp + 1), att, feeAtt
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

        AsseteraExchange.KycAttestation memory att =
            _attestPlace(alice, address(evil), 100e18, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feePlace(alice, address(evil), 100e18, address(usdc), WANT_USDC);
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

        AsseteraExchange.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(evil), 100e18, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, bob, address(evil), 100e18, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        evil.approve(address(exchange), type(uint256).max);
        uint256 id = exchange.makeOffer(bob, address(evil), 100e18, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();

        evil.arm(address(exchange), abi.encodeCall(OrderBook.cancelOrder, (999)));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        exchange.cancelOfferForUser(id, carol, carol);
    }

    function test_Offer_EmitsOfferCancelled_WithTerms() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.KycAttestation memory att = _attestCancelOffer(alice, id, SELL_RWA, WANT_USDC);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit OfferBook.OfferCancelled(id, alice, SELL_RWA, WANT_USDC);
        exchange.cancelOffer(id, att);
    }

    // ── Sad paths ──────────────────────────────────────────────────────── //

    function test_Offer_RevertsOnSelfTarget() public {
        AsseteraExchange.KycAttestation memory att =
            _attestMakeOffer(alice, alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(OfferBook.OfferSelfTarget.selector);
        exchange.makeOffer(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_Offer_ReplaceRevertsForThirdParty() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.KycAttestation memory att = _attestReplaceOffer(carol, id, SELL_RWA, 800e6);
        vm.startPrank(carol);
        usdc.approve(address(exchange), 800e6);
        vm.expectRevert(abi.encodeWithSelector(OfferBook.NotOfferParty.selector, id));
        exchange.replaceOffer(id, SELL_RWA, 800e6, 0, att);
        vm.stopPrank();
    }

    function test_Offer_AcceptRevertsIfProposerTriesToAcceptOwnOffer() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.KycAttestation memory att = _attestAcceptOffer(alice, id, SELL_RWA, WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(abi.encodeWithSelector(OfferBook.AcceptorIsProposer.selector, id));
        exchange.acceptOffer(id, att);
        vm.stopPrank();
    }

    function test_Offer_CancelRevertsAfterAccept() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);

        AsseteraExchange.KycAttestation memory acceptAtt = _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();

        AsseteraExchange.KycAttestation memory cancelAtt = _attest(alice, ExchangeTypes.Action.CancelOffer, id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ExchangeStorage.OfferNotOpen.selector, id));
        exchange.cancelOffer(id, cancelAtt);
    }

    function test_Offer_AcceptRevertsIfExpired() public {
        AsseteraExchange.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        uint64 expireTs = uint64(block.timestamp + 1 hours);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        uint256 id = exchange.makeOffer(bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, expireTs, att, feeAtt);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 hours);

        AsseteraExchange.KycAttestation memory acceptAtt = _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectRevert(abi.encodeWithSelector(OfferBook.OfferIsExpired.selector, id));
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();
    }

    function test_Offer_MakeRevertsOnWrongParamsHash() public {
        // Sign with mismatched takerAmount in paramsHash.
        bytes32 badHash = keccak256(abi.encodePacked(bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC + 1));
        AsseteraExchange.KycAttestation memory att = _signAtt(
            kycSignerPk, alice, ExchangeTypes.Action.MakeOffer, 0, _freshNonce(), block.timestamp + 3 minutes, badHash
        );
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(ExchangeStorage.ParamsHashMismatch.selector);
        exchange.makeOffer(bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_Offer_ReplaceRevertsOnWrongParamsHash() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        // Sign with a different newTakerAmount than what will be passed.
        bytes32 badHash = keccak256(abi.encodePacked(id, SELL_RWA, uint256(800e6 + 1)));
        AsseteraExchange.KycAttestation memory att = _signAtt(
            kycSignerPk, bob, ExchangeTypes.Action.ReplaceOffer, id, _freshNonce(), block.timestamp + 3 minutes, badHash
        );
        vm.startPrank(bob);
        usdc.approve(address(exchange), 800e6);
        vm.expectRevert(ExchangeStorage.ParamsHashMismatch.selector);
        exchange.replaceOffer(id, SELL_RWA, 800e6, 0, att);
        vm.stopPrank();
    }

    function test_Offer_AcceptRevertsOnWrongParamsHash() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        // Attestation signed with mismatched takerAmount.
        bytes32 badHash = keccak256(abi.encodePacked(id, SELL_RWA, WANT_USDC + 1));
        AsseteraExchange.KycAttestation memory att = _signAtt(
            kycSignerPk, bob, ExchangeTypes.Action.AcceptOffer, id, _freshNonce(), block.timestamp + 3 minutes, badHash
        );
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectRevert(ExchangeStorage.ParamsHashMismatch.selector);
        exchange.acceptOffer(id, att);
        vm.stopPrank();
    }

    function test_Offer_CancelRevertsOnWrongParamsHash() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        // Attestation signed with mismatched makerAmount.
        bytes32 badHash = keccak256(abi.encodePacked(id, SELL_RWA + 1, WANT_USDC));
        AsseteraExchange.KycAttestation memory att = _signAtt(
            kycSignerPk,
            alice,
            ExchangeTypes.Action.CancelOffer,
            id,
            _freshNonce(),
            block.timestamp + 3 minutes,
            badHash
        );
        vm.prank(alice);
        vm.expectRevert(ExchangeStorage.ParamsHashMismatch.selector);
        exchange.cancelOffer(id, att);
    }

    function test_Offer_MakeRevertsOnNonceReplay() public {
        AsseteraExchange.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA * 2);
        exchange.makeOffer(bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.expectRevert(IKycGate.KycNonceUsed.selector);
        exchange.makeOffer(bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_Offer_RevertsOnNonExistentOffer() public {
        AsseteraExchange.KycAttestation memory att = _attest(alice, ExchangeTypes.Action.CancelOffer, 999);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ExchangeStorage.OfferNotFound.selector, 999));
        exchange.cancelOffer(999, att);
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
        AsseteraExchange.KycAttestation memory replaceAtt = _attestReplaceOffer(bob, id, SELL_RWA, WANT_USDC * 2);
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
        AsseteraExchange.KycAttestation memory acceptAtt = _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
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
        vm.expectRevert(ExchangeStorage.ZeroAddress.selector);
        exchange.cancelOfferForUser(id, address(0), bob);
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
        AsseteraExchange.KycAttestation memory replaceAtt = _attestReplaceOffer(bob, id, SELL_RWA, WANT_USDC * 2);
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
        AsseteraExchange.KycAttestation memory acceptAtt = _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
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
        AsseteraExchange.KycAttestation memory att =
            _attestPlace(maker, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt = _feePlaceWithFee(
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
        AsseteraExchange.KycAttestation memory att =
            _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
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

        AsseteraExchange.KycAttestation memory att =
            _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
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
        AsseteraExchange.KycAttestation memory att =
            _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feePlaceWithFee(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 50, 0, address(0));
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(ExchangeStorage.ZeroAddress.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_Fee_InvalidFee_Reverts() public {
        // makerFeeBps > 10_000 must revert.
        AsseteraExchange.KycAttestation memory att =
            _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
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
        AsseteraExchange.Order memory o = exchange.getOrder(id);
        assertEq(o.makerFeeBps, 50);
        assertEq(o.takerFeeBps, 30);
        assertEq(o.feeCollector, carol);

        // Revoke carol from allowlist.
        vm.prank(admin);
        exchange.setAllowedCollector(carol, false);

        // Fill should still work using the snapshotted fees/collector.
        uint256 carolUsdc = usdc.balanceOf(carol);
        uint256 carolRwa = rwa.balanceOf(carol);
        AsseteraExchange.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.fillOrder(id, SELL_RWA, att);
        vm.stopPrank();

        // Carol received fees even after allowlist removal.
        assertGt(usdc.balanceOf(carol), carolUsdc); // makerFee in USDC
        assertGt(rwa.balanceOf(carol), carolRwa); // takerFee in RWA
    }

    // --- fill fee deduction ---------------------------------------------- //

    function test_Fee_Fill_MakerAndTakerFeesDeducted() public {
        // makerFeeBps = 50 (0.5%) on buyToken (USDC), takerFeeBps = 30 (0.3%) on sellToken (RWA).
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        uint256 id = _placeRwaForUsdcWithFee(alice, 50, 30, carol);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 bobRwaBefore = rwa.balanceOf(bob);
        uint256 carolUsdcBefore = usdc.balanceOf(carol);
        uint256 carolRwaBefore = rwa.balanceOf(carol);

        AsseteraExchange.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.fillOrder(id, SELL_RWA, att);
        vm.stopPrank();

        // Expected fee amounts.
        uint256 expectedMakerFee = (WANT_USDC * 50) / 10_000; // 0.5% of 1000 USDC = 5 USDC
        uint256 expectedTakerFee = (SELL_RWA * 30) / 10_000; // 0.3% of 10 RWA = 0.03 RWA

        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + WANT_USDC - expectedMakerFee, "maker USDC net");
        assertEq(rwa.balanceOf(bob), bobRwaBefore + SELL_RWA - expectedTakerFee, "taker RWA net");
        assertEq(usdc.balanceOf(carol), carolUsdcBefore + expectedMakerFee, "collector makerFee");
        assertEq(rwa.balanceOf(carol), carolRwaBefore + expectedTakerFee, "collector takerFee");
    }

    function test_Fee_Fill_ZeroFees_NoCollectorTransfer() public {
        uint256 id = _placeRwaForUsdc(alice); // zero fees

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 bobRwaBefore = rwa.balanceOf(bob);

        AsseteraExchange.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
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

        AsseteraExchange.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
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

        AsseteraExchange.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.fillOrder(id, SELL_RWA, att);
        vm.stopPrank();

        uint256 expectedTakerFee = (SELL_RWA * 100) / 10_000;
        assertEq(usdc.balanceOf(carol), carolUsdcBefore, "no makerFee (USDC)");
        assertEq(rwa.balanceOf(carol), carolRwaBefore + expectedTakerFee, "takerFee in RWA");
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

        AsseteraExchange.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), halfUsdc);
        exchange.fillOrder(id, halfRwa, att);
        vm.stopPrank();

        uint256 expectedMakerFee = (halfUsdc * 50) / 10_000;
        uint256 expectedTakerFee = (halfRwa * 30) / 10_000;

        assertEq(usdc.balanceOf(carol), carolUsdcBefore + expectedMakerFee);
        assertEq(rwa.balanceOf(carol), carolRwaBefore + expectedTakerFee);
        // Order stays Open.
        assertEq(uint8(exchange.getOrder(id).status), uint8(ExchangeTypes.OrderStatus.Open));
    }

    function test_Fee_Fill_Rounding_FloorFavorsMakerAndTaker() public {
        // 1 bps on 1 wei = 0.0001 wei → floored to 0; collector receives nothing.
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        AsseteraExchange.KycAttestation memory placeAtt = _attestPlace(alice, address(rwa), 1, address(usdc), 1);
        AsseteraExchange.FeeAttestation memory placeFeeAtt =
            _feePlaceWithFee(alice, address(rwa), 1, address(usdc), 1, 1, 1, carol);
        vm.startPrank(alice);
        rwa.approve(address(exchange), 1);
        uint256 id = exchange.placeOrder(address(rwa), 1, address(usdc), 1, 0, placeAtt, placeFeeAtt);
        vm.stopPrank();

        uint256 carolUsdcBefore = usdc.balanceOf(carol);
        uint256 carolRwaBefore = rwa.balanceOf(carol);

        vm.prank(admin);
        exchange.setComplianceRequired(ExchangeTypes.Action.Fill, false);

        AsseteraExchange.KycAttestation memory empty;
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
        AsseteraExchange.KycAttestation memory att =
            _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
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
        AsseteraExchange.KycAttestation memory att =
            _attestPlace(maker, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
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
        AsseteraExchange.Order memory o = exchange.getOrder(id);
        assertEq(o.makerFeeBps, 50, "makerFeeBps snapshotted");
        assertEq(o.takerFeeBps, 30, "takerFeeBps snapshotted");
        assertEq(o.feeCollector, carol, "feeCollector snapshotted");
    }

    // --- event fields ---------------------------------------------------- //

    function test_Fee_Fill_EmitsOrderFilledWithFeeFields() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);
        uint256 id = _placeRwaForUsdcWithFee(alice, 50, 30, carol);

        uint256 expectedMakerFee = (WANT_USDC * 50) / 10_000;
        uint256 expectedTakerFee = (SELL_RWA * 30) / 10_000;

        AsseteraExchange.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectEmit(true, true, true, true);
        emit OrderBook.OrderFilled(id, alice, bob, SELL_RWA, WANT_USDC, expectedMakerFee, expectedTakerFee, carol);
        exchange.fillOrder(id, SELL_RWA, att);
        vm.stopPrank();
    }

    function test_Fee_PartialFill_EmitsOrderPartiallyFilledWithFeeFields() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);
        uint256 id = _placeRwaForUsdcWithFee(alice, 50, 30, carol);

        uint256 halfRwa = SELL_RWA / 2;
        uint256 halfUsdc = (halfRwa * WANT_USDC + SELL_RWA - 1) / SELL_RWA;
        uint256 expectedMakerFee = (halfUsdc * 50) / 10_000;
        uint256 expectedTakerFee = (halfRwa * 30) / 10_000;
        uint256 expectedRemaining = SELL_RWA - halfRwa;

        AsseteraExchange.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), halfUsdc);
        vm.expectEmit(true, true, true, true);
        emit OrderBook.OrderPartiallyFilled(
            id, alice, bob, halfRwa, expectedRemaining, expectedMakerFee, expectedTakerFee, carol
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
        AsseteraExchange.KycAttestation memory att1 = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC); // covers both fills
        exchange.fillOrder(id, halfRwa, att1);
        vm.stopPrank();

        assertEq(uint8(exchange.getOrder(id).status), uint8(ExchangeTypes.OrderStatus.Open), "still open");

        // Second half (clears the order).
        AsseteraExchange.KycAttestation memory att2 = _attest(bob, ExchangeTypes.Action.Fill, id);
        vm.prank(bob);
        exchange.fillOrder(id, halfRwa, att2);

        assertEq(uint8(exchange.getOrder(id).status), uint8(ExchangeTypes.OrderStatus.Filled), "fully filled");

        uint256 totalMakerFee = (halfUsdc * 50) / 10_000 + (halfUsdc * 50) / 10_000;
        uint256 totalTakerFee = (halfRwa * 30) / 10_000 + (halfRwa * 30) / 10_000;

        assertEq(usdc.balanceOf(carol), carolUsdcBefore + totalMakerFee, "accumulated makerFee USDC");
        assertEq(rwa.balanceOf(carol), carolRwaBefore + totalTakerFee, "accumulated takerFee RWA");
    }

    function test_Fee_TamperedFeeBps_Reverts() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        // Sign with makerFeeBps = 50, then inflate it after signing.
        AsseteraExchange.KycAttestation memory att =
            _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
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

        AsseteraExchange.KycAttestation memory att = _attest(bob, ExchangeTypes.Action.Fill, id);
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
        AsseteraExchange.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feeMakeOfferWithFee(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 100, 50, carol);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(abi.encodeWithSelector(IFeeGate.FeeCollectorNotAllowed.selector, carol));
        exchange.makeOffer(bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_Offer_Fee_InvalidFee_Reverts() public {
        uint16 tooHigh = uint16(AsseteraExchange(address(exchange)).MAX_FEE_BPS()) + 1;
        AsseteraExchange.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feeMakeOfferWithFee(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, tooHigh, 0, carol);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(IFeeGate.InvalidFee.selector);
        exchange.makeOffer(bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att, feeAtt);
        vm.stopPrank();
    }

    function test_Offer_Fee_ZeroFees_NoCollectorRequired() public {
        // Zero fees should succeed without an allowlisted collector (matches order behaviour).
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.Offer memory o = exchange.getOffer(id);
        assertEq(o.makerFeeBps, 0);
        assertEq(o.takerFeeBps, 0);
        assertEq(o.feeCollector, address(0));
    }

    function test_Offer_Fee_StoredInStruct() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);
        uint256 id = _makeOfferWithFee(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 100, 50, carol);
        AsseteraExchange.Offer memory o = exchange.getOffer(id);
        assertEq(o.makerFeeBps, 100, "makerFeeBps stored");
        assertEq(o.takerFeeBps, 50, "takerFeeBps stored");
        assertEq(o.feeCollector, carol, "feeCollector stored");
    }

    // --- fee deduction on accept (settles atomically, AC-246) ------------ //

    function test_Offer_Fee_AcceptSettles_FeesDeducted() public {
        // makerFeeBps=100 (1%) applied to what maker receives (USDC = takerAmount).
        // takerFeeBps=50  (0.5%) applied to what taker receives (RWA = makerAmount).
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

        // Bob accepts — settles atomically, no separate operator step.
        AsseteraExchange.KycAttestation memory acceptAtt = _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();

        uint256 makerFeeAmt = (WANT_USDC * makerFeeBps) / 10_000;
        uint256 takerFeeAmt = (SELL_RWA * takerFeeBps) / 10_000;

        assertEq(uint8(exchange.getOffer(id).status), uint8(ExchangeTypes.OfferStatus.Settled));
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + WANT_USDC - makerFeeAmt, "maker receives USDC minus fee");
        assertEq(rwa.balanceOf(bob), bobRwaBefore + SELL_RWA - takerFeeAmt, "taker receives RWA minus fee");
        assertEq(usdc.balanceOf(carol), carolUsdcBefore + makerFeeAmt, "carol receives maker fee in USDC");
        assertEq(rwa.balanceOf(carol), carolRwaBefore + takerFeeAmt, "carol receives taker fee in RWA");
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

        AsseteraExchange.KycAttestation memory acceptAtt = _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
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

        AsseteraExchange.KycAttestation memory acceptAtt = _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();

        uint256 takerFeeAmt = (SELL_RWA * 150) / 10_000;
        assertEq(rwa.balanceOf(carol) - carolRwaBefore, takerFeeAmt, "carol gets taker fee in RWA");
        assertEq(usdc.balanceOf(carol) - carolUsdcBefore, 0, "carol gets no USDC (no maker fee)");
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + WANT_USDC, "maker receives full USDC");
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
        AsseteraExchange.KycAttestation memory att =
            _attestPlace(alice, address(fot), sellAmt, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feePlace(alice, address(fot), sellAmt, address(usdc), WANT_USDC);
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

        AsseteraExchange.KycAttestation memory aAtt =
            _attestPlace(alice, address(fot), sellAmt, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory aFeeAtt =
            _feePlace(alice, address(fot), sellAmt, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        fot.approve(address(exchange), sellAmt);
        uint256 aliceId = exchange.placeOrder(address(fot), sellAmt, address(usdc), WANT_USDC, 0, aAtt, aFeeAtt);
        vm.stopPrank();

        AsseteraExchange.KycAttestation memory bAtt = _attestPlace(bob, address(fot), sellAmt, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory bFeeAtt = _feePlace(bob, address(fot), sellAmt, address(usdc), WANT_USDC);
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

        AsseteraExchange.KycAttestation memory aAtt =
            _attestPlace(alice, address(rebasing), sellAmt, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory aFeeAtt =
            _feePlace(alice, address(rebasing), sellAmt, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rebasing.approve(address(exchange), sellAmt);
        uint256 aliceId = exchange.placeOrder(address(rebasing), sellAmt, address(usdc), WANT_USDC, 0, aAtt, aFeeAtt);
        vm.stopPrank();

        AsseteraExchange.KycAttestation memory bAtt =
            _attestPlace(bob, address(rebasing), sellAmt, address(usdc), WANT_USDC);
        AsseteraExchange.FeeAttestation memory bFeeAtt =
            _feePlace(bob, address(rebasing), sellAmt, address(usdc), WANT_USDC);
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

        AsseteraExchange.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(fot), makerAmt, address(usdc), takerAmt);
        AsseteraExchange.FeeAttestation memory feeAtt =
            _feeMakeOffer(alice, bob, address(fot), makerAmt, address(usdc), takerAmt);
        vm.startPrank(alice);
        fot.approve(address(exchange), makerAmt);
        uint256 id = exchange.makeOffer(bob, address(fot), makerAmt, address(usdc), takerAmt, 0, att, feeAtt);
        vm.stopPrank();

        // The offer records the nominal makerAmount, but the contract only ever received 99% of it.
        uint256 actualHeld = makerAmt - (makerAmt * 100) / 10_000;
        assertEq(fot.balanceOf(address(exchange)), actualHeld);

        AsseteraExchange.KycAttestation memory acceptAtt = _attestAcceptOffer(bob, id, makerAmt, takerAmt);
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
}
