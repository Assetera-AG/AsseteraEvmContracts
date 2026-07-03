// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {AsseteraExchange} from "../src/AsseteraExchange.sol";
import {FaucetToken} from "../src/FaucetToken.sol";
import {AsseteraExchangeV2} from "./mocks/AsseteraExchangeV2.sol";
import {ReentrantToken} from "./mocks/ReentrantToken.sol";

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

    bytes32 internal OPERATOR_ROLE;
    bytes32 internal KYC_OPERATOR_ROLE;
    bytes32 internal ADMIN_ROLE;

    uint256 internal constant SELL_RWA = 10e18;
    uint256 internal constant WANT_USDC = 1_000e6;

    uint256 internal _nonceCtr;

    bytes32 internal constant KYC_TYPEHASH =
        keccak256("KycAttestation(address account,uint8 action,uint256 orderId,uint256 nonce,uint256 deadline,bytes32 paramsHash,uint16 makerFeeBps,uint16 takerFeeBps,address feeCollector)");

    event OrderPlaced(
        uint256 indexed id, address indexed maker, address sellToken, uint256 sellAmount, address buyToken, uint256 buyAmount, uint64 expireTs
    );
    event OrderForceCancelled(uint256 indexed id, address indexed maker, address recipient, address indexed admin);

    function setUp() public {
        kycSigner = vm.addr(kycSignerPk);

        usdc = new FaucetToken("Mock USD Coin", "mUSDC", 6);
        rwa = new FaucetToken("Mock RWA Token", "mRWA", 18);
        forwarder = new ERC2771Forwarder("AsseteraForwarder");

        AsseteraExchange impl = new AsseteraExchange(address(forwarder));
        bytes memory initData = abi.encodeCall(AsseteraExchange.initialize, (admin, operator, kycSigner));
        exchange = AsseteraExchange(address(new ERC1967Proxy(address(impl), initData)));

        OPERATOR_ROLE = exchange.OPERATOR_ROLE();
        KYC_OPERATOR_ROLE = exchange.KYC_OPERATOR_ROLE();
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
        bytes32 paramsHash,
        uint16 makerFeeBps,
        uint16 takerFeeBps,
        address feeCollector
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
        bytes32 structHash = keccak256(abi.encode(KYC_TYPEHASH, account, uint8(action), orderId, nonce, deadline, paramsHash, makerFeeBps, takerFeeBps, feeCollector));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        att = AsseteraExchange.KycAttestation({
            account: account,
            action: action,
            orderId: orderId,
            nonce: nonce,
            deadline: deadline,
            paramsHash: paramsHash,
            makerFeeBps: makerFeeBps,
            takerFeeBps: takerFeeBps,
            feeCollector: feeCollector,
            signature: abi.encodePacked(r, s, v)
        });
    }

    /// A valid, fresh attestation for non-Place actions (paramsHash = 0, no fees).
    function _attest(address account, AsseteraExchange.Action action, uint256 orderId)
        internal
        returns (AsseteraExchange.KycAttestation memory)
    {
        return _signAtt(kycSignerPk, account, action, orderId, _freshNonce(), block.timestamp + 3 minutes, bytes32(0), 0, 0, address(0));
    }

    /// A valid, fresh attestation for Place actions (paramsHash bound to order params, zero fees).
    function _attestPlace(address account, address sellToken, uint256 sellAmount, address buyToken, uint256 buyAmount)
        internal
        returns (AsseteraExchange.KycAttestation memory)
    {
        bytes32 ph = keccak256(abi.encode(sellToken, sellAmount, buyToken, buyAmount));
        return _signAtt(kycSignerPk, account, AsseteraExchange.Action.Place, 0, _freshNonce(), block.timestamp + 3 minutes, ph, 0, 0, address(0));
    }

    /// A valid, fresh Place attestation with per-pair fee parameters.
    function _attestPlaceWithFee(
        address account,
        address sellToken, uint256 sellAmount,
        address buyToken,  uint256 buyAmount,
        uint16 makerFeeBps, uint16 takerFeeBps,
        address feeCollector
    ) internal returns (AsseteraExchange.KycAttestation memory) {
        bytes32 ph = keccak256(abi.encode(sellToken, sellAmount, buyToken, buyAmount));
        return _signAtt(kycSignerPk, account, AsseteraExchange.Action.Place, 0, _freshNonce(), block.timestamp + 3 minutes, ph, makerFeeBps, takerFeeBps, feeCollector);
    }

    function _placeRwaForUsdc(address maker) internal returns (uint256 id) {
        AsseteraExchange.KycAttestation memory att = _attestPlace(maker, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(maker);
        rwa.approve(address(exchange), SELL_RWA);
        id = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att);
        vm.stopPrank();
    }

    function _placeUsdcForRwa(address maker, uint256 usdcAmt, uint256 rwaWant) internal returns (uint256 id) {
        AsseteraExchange.KycAttestation memory att = _attestPlace(maker, address(usdc), usdcAmt, address(rwa), rwaWant);
        vm.startPrank(maker);
        usdc.approve(address(exchange), usdcAmt);
        id = exchange.placeOrder(address(usdc), usdcAmt, address(rwa), rwaWant, 0, att);
        vm.stopPrank();
    }

    // ===================================================================== //
    //                              initialize                               //
    // ===================================================================== //

    function test_Initialize_GrantsRolesAndDefaults() public view {
        assertTrue(exchange.hasRole(ADMIN_ROLE, admin));
        assertTrue(exchange.hasRole(OPERATOR_ROLE, operator));
        assertTrue(exchange.hasRole(KYC_OPERATOR_ROLE, kycSigner));
        assertEq(exchange.version(), "3.1.0");
        assertTrue(exchange.complianceRequired(AsseteraExchange.Action.Place));
        assertTrue(exchange.complianceRequired(AsseteraExchange.Action.Fill));
        assertTrue(exchange.complianceRequired(AsseteraExchange.Action.Settle));
        assertTrue(exchange.complianceRequired(AsseteraExchange.Action.Cancel));
        assertEq(exchange.trustedForwarder(), address(forwarder));
    }

    function test_Initialize_RevertsOnZeroKycSigner() public {
        AsseteraExchange impl = new AsseteraExchange(address(forwarder));
        bytes memory initData = abi.encodeCall(AsseteraExchange.initialize, (admin, operator, address(0)));
        vm.expectRevert(AsseteraExchange.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_CannotReinitialize() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        exchange.initialize(alice, bob, carol);
    }

    // ===================================================================== //
    //                              placeOrder                               //
    // ===================================================================== //

    function test_PlaceOrder_HappyPath() public {
        AsseteraExchange.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectEmit(true, true, false, true, address(exchange));
        emit OrderPlaced(1, alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0);
        uint256 id = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att);
        vm.stopPrank();

        assertEq(id, 1);
        assertEq(rwa.balanceOf(address(exchange)), SELL_RWA);
        assertEq(uint8(exchange.getOrder(1).status), uint8(AsseteraExchange.OrderStatus.Open));
        assertEq(exchange.getOrder(1).remainingQuantity, SELL_RWA);
        assertEq(exchange.getOrder(1).expireTs, 0);
    }

    function test_PlaceOrder_WithExpiry() public {
        uint64 expireTs = uint64(block.timestamp + 1 hours);
        AsseteraExchange.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        uint256 id = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, expireTs, att);
        vm.stopPrank();

        assertEq(exchange.getOrder(id).expireTs, expireTs);
    }

    function test_PlaceOrder_RevertsOnInvalidExpiry() public {
        // Forge default block.timestamp is 1; warp forward so block.timestamp - 1 != 0
        // (0 is the "no expiry" sentinel and would not trigger InvalidExpiry).
        vm.warp(1 hours);
        AsseteraExchange.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(AsseteraExchange.InvalidExpiry.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, uint64(block.timestamp - 1), att);
        vm.stopPrank();
    }

    function test_PlaceOrder_RevertsWithoutAttestation_BadSigner() public {
        // Signed by a key that does NOT hold KYC_OPERATOR_ROLE.
        bytes32 ph = keccak256(abi.encode(address(rwa), SELL_RWA, address(usdc), WANT_USDC));
        AsseteraExchange.KycAttestation memory att =
            _signAtt(0xBAD, alice, AsseteraExchange.Action.Place, 0, _freshNonce(), block.timestamp + 3 minutes, ph, 0, 0, address(0));
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(AsseteraExchange.KycBadSigner.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att);
        vm.stopPrank();
    }

    function test_PlaceOrder_RevertsOnExpiredAttestation() public {
        bytes32 ph = keccak256(abi.encode(address(rwa), SELL_RWA, address(usdc), WANT_USDC));
        AsseteraExchange.KycAttestation memory att =
            _signAtt(kycSignerPk, alice, AsseteraExchange.Action.Place, 0, _freshNonce(), block.timestamp + 100, ph, 0, 0, address(0));
        vm.warp(block.timestamp + 101);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(AsseteraExchange.KycExpired.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att);
        vm.stopPrank();
    }

    function test_PlaceOrder_RevertsOnTtlTooLong() public {
        bytes32 ph = keccak256(abi.encode(address(rwa), SELL_RWA, address(usdc), WANT_USDC));
        AsseteraExchange.KycAttestation memory att =
            _signAtt(kycSignerPk, alice, AsseteraExchange.Action.Place, 0, _freshNonce(), block.timestamp + 16 minutes, ph, 0, 0, address(0));
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(AsseteraExchange.KycTtlTooLong.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att);
        vm.stopPrank();
    }

    function test_PlaceOrder_RevertsOnAccountMismatch() public {
        // Attestation is for bob, but alice is acting.
        AsseteraExchange.KycAttestation memory att = _attestPlace(bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(AsseteraExchange.KycAccountMismatch.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att);
        vm.stopPrank();
    }

    function test_PlaceOrder_RevertsOnActionMismatch() public {
        // Attestation carries the correct paramsHash but wrong action (Fill vs Place).
        // paramsHash check passes; KycActionMismatch fires inside _consumeKyc.
        bytes32 ph = keccak256(abi.encode(address(rwa), SELL_RWA, address(usdc), WANT_USDC));
        AsseteraExchange.KycAttestation memory att =
            _signAtt(kycSignerPk, alice, AsseteraExchange.Action.Fill, 0, _freshNonce(), block.timestamp + 3 minutes, ph, 0, 0, address(0));
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(AsseteraExchange.KycActionMismatch.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att);
        vm.stopPrank();
    }

    function test_PlaceOrder_RevertsOnNonceReuse() public {
        AsseteraExchange.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA * 2);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att);
        // Same attestation (same nonce) again -> consumed.
        vm.expectRevert(AsseteraExchange.KycNonceUsed.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att);
        vm.stopPrank();
    }

    function test_PlaceOrder_RevertsWhenPaused() public {
        vm.prank(operator);
        exchange.pause();
        AsseteraExchange.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att);
        vm.stopPrank();
    }

    function test_PlaceOrder_GatingOff_NoAttestationNeeded() public {
        vm.prank(admin);
        exchange.setComplianceRequired(AsseteraExchange.Action.Place, false);
        AsseteraExchange.KycAttestation memory empty; // garbage / empty
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        uint256 id = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, empty);
        vm.stopPrank();
        assertEq(id, 1);
    }

    function test_PlaceOrder_RevertsOnZeroAmount() public {
        AsseteraExchange.KycAttestation memory att = _attestPlace(alice, address(rwa), 0, address(usdc), WANT_USDC);
        vm.prank(alice);
        vm.expectRevert(AsseteraExchange.ZeroAmount.selector);
        exchange.placeOrder(address(rwa), 0, address(usdc), WANT_USDC, 0, att);
    }

    // ===================================================================== //
    //                              cancelOrder                              //
    // ===================================================================== //

    function test_CancelOrder_HappyPath() public {
        uint256 id = _placeRwaForUsdc(alice);
        uint256 bal = rwa.balanceOf(alice);
        AsseteraExchange.KycAttestation memory att = _attest(alice, AsseteraExchange.Action.Cancel, id);
        vm.prank(alice);
        exchange.cancelOrder(id, att);
        assertEq(uint8(exchange.getOrder(id).status), uint8(AsseteraExchange.OrderStatus.Cancelled));
        assertEq(rwa.balanceOf(alice), bal + SELL_RWA);
    }

    function test_CancelOrder_FrozenUserCannotCancel() public {
        // "Frozen" = backend won't sign. Simulate with a non-KYC signer.
        uint256 id = _placeRwaForUsdc(alice);
        AsseteraExchange.KycAttestation memory att =
            _signAtt(0xBAD, alice, AsseteraExchange.Action.Cancel, id, _freshNonce(), block.timestamp + 3 minutes, bytes32(0), 0, 0, address(0));
        vm.prank(alice);
        vm.expectRevert(AsseteraExchange.KycBadSigner.selector);
        exchange.cancelOrder(id, att);
    }

    function test_CancelOrder_RevertsIfNotMaker() public {
        uint256 id = _placeRwaForUsdc(alice);
        AsseteraExchange.KycAttestation memory att = _attest(bob, AsseteraExchange.Action.Cancel, id);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.NotMaker.selector, id));
        exchange.cancelOrder(id, att);
    }

    // ===================================================================== //
    //               cancelOrderSelf — maker self-cancel                     //
    // ===================================================================== //

    function test_CancelOrderSelf_HappyPath() public {
        uint256 id = _placeRwaForUsdc(alice);
        uint256 bal = rwa.balanceOf(alice);

        vm.prank(alice);
        exchange.cancelOrderSelf(id);

        assertEq(uint8(exchange.getOrder(id).status), uint8(AsseteraExchange.OrderStatus.Cancelled));
        assertEq(rwa.balanceOf(alice), bal + SELL_RWA);
    }

    function test_CancelOrderSelf_ReturnsRemainingAfterPartialFill() public {
        uint256 id = _placeRwaForUsdc(alice);

        // Bob partially fills half
        uint256 halfRwa = SELL_RWA / 2;
        uint256 halfUsdc = (halfRwa * WANT_USDC + SELL_RWA - 1) / SELL_RWA; // ceiling
        vm.prank(admin);
        exchange.setComplianceRequired(AsseteraExchange.Action.Fill, false);
        vm.startPrank(bob);
        usdc.approve(address(exchange), halfUsdc);
        exchange.fillOrder(id, halfRwa, AsseteraExchange.KycAttestation({
            account: address(0), action: AsseteraExchange.Action.None,
            orderId: 0, nonce: 0, deadline: 0, paramsHash: bytes32(0),
            makerFeeBps: 0, takerFeeBps: 0, feeCollector: address(0), signature: ""
        }));
        vm.stopPrank();

        // Alice cancels with remaining half
        uint256 aliceRwa = rwa.balanceOf(alice);
        vm.prank(alice);
        exchange.cancelOrderSelf(id);

        assertEq(rwa.balanceOf(alice), aliceRwa + halfRwa);
    }

    function test_CancelOrderSelf_RevertsIfNotMaker() public {
        uint256 id = _placeRwaForUsdc(alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.NotMaker.selector, id));
        exchange.cancelOrderSelf(id);
    }

    function test_CancelOrderSelf_RevertsIfNotOpen() public {
        uint256 id = _placeRwaForUsdc(alice);
        vm.prank(alice);
        exchange.cancelOrderSelf(id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.OrderNotOpen.selector, id));
        exchange.cancelOrderSelf(id);
    }

    // ===================================================================== //
    //               fillOrder — self-trade prevention, partial fills        //
    // ===================================================================== //

    function test_FillOrder_HappyPath() public {
        uint256 id = _placeRwaForUsdc(alice);
        uint256 aliceUsdc = usdc.balanceOf(alice);
        uint256 bobRwa = rwa.balanceOf(bob);
        AsseteraExchange.KycAttestation memory att = _attest(bob, AsseteraExchange.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.fillOrder(id, SELL_RWA, att);
        vm.stopPrank();

        assertEq(uint8(exchange.getOrder(id).status), uint8(AsseteraExchange.OrderStatus.Filled));
        assertEq(exchange.getOrder(id).remainingQuantity, 0);
        assertEq(usdc.balanceOf(alice), aliceUsdc + WANT_USDC);
        assertEq(rwa.balanceOf(bob), bobRwa + SELL_RWA);
    }

    function test_FillOrder_PartialFill_HappyPath() public {
        uint256 id = _placeRwaForUsdc(alice);
        uint256 halfRwa = SELL_RWA / 2;
        uint256 halfUsdc = (halfRwa * WANT_USDC + SELL_RWA - 1) / SELL_RWA; // ceiling

        AsseteraExchange.KycAttestation memory att = _attest(bob, AsseteraExchange.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), halfUsdc);
        exchange.fillOrder(id, halfRwa, att);
        vm.stopPrank();

        // Order stays Open with half remaining
        assertEq(uint8(exchange.getOrder(id).status), uint8(AsseteraExchange.OrderStatus.Open));
        assertEq(exchange.getOrder(id).remainingQuantity, SELL_RWA - halfRwa);
    }

    function test_FillOrder_PartialFill_ThenFullFill() public {
        uint256 id = _placeRwaForUsdc(alice);
        uint256 halfRwa = SELL_RWA / 2;

        vm.prank(admin);
        exchange.setComplianceRequired(AsseteraExchange.Action.Fill, false);

        AsseteraExchange.KycAttestation memory empty;
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.fillOrder(id, halfRwa, empty);
        assertEq(uint8(exchange.getOrder(id).status), uint8(AsseteraExchange.OrderStatus.Open));
        // Fill remaining half
        exchange.fillOrder(id, SELL_RWA - halfRwa, empty);
        vm.stopPrank();

        assertEq(uint8(exchange.getOrder(id).status), uint8(AsseteraExchange.OrderStatus.Filled));
        assertEq(exchange.getOrder(id).remainingQuantity, 0);
    }

    function test_FillOrder_SelfTradePrevention() public {
        // Maker cannot fill their own order (self-trade prevention).
        uint256 id = _placeRwaForUsdc(alice);
        vm.prank(admin);
        exchange.setComplianceRequired(AsseteraExchange.Action.Fill, false);

        AsseteraExchange.KycAttestation memory empty;
        vm.startPrank(alice);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.SelfTrade.selector, id));
        exchange.fillOrder(id, SELL_RWA, empty);
        vm.stopPrank();
    }

    function test_FillOrder_RevertsOnExpiredOrder() public {
        // Filling an expired order must revert.
        uint64 expireTs = uint64(block.timestamp + 1 hours);
        AsseteraExchange.KycAttestation memory placeAtt = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        uint256 id = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, expireTs, placeAtt);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 hours);
        vm.prank(admin);
        exchange.setComplianceRequired(AsseteraExchange.Action.Fill, false);

        AsseteraExchange.KycAttestation memory empty;
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.OrderIsExpired.selector, id));
        exchange.fillOrder(id, SELL_RWA, empty);
        vm.stopPrank();
    }

    function test_FillOrder_RevertsOnFillAmountZero() public {
        uint256 id = _placeRwaForUsdc(alice);
        AsseteraExchange.KycAttestation memory att = _attest(bob, AsseteraExchange.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectRevert(AsseteraExchange.FillAmountZero.selector);
        exchange.fillOrder(id, 0, att);
        vm.stopPrank();
    }

    function test_FillOrder_RevertsOnFillExceedsRemaining() public {
        uint256 id = _placeRwaForUsdc(alice);
        AsseteraExchange.KycAttestation memory att = _attest(bob, AsseteraExchange.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC * 2);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.FillExceedsRemaining.selector, id, SELL_RWA));
        exchange.fillOrder(id, SELL_RWA + 1, att);
        vm.stopPrank();
    }

    function test_FillOrder_RevertsWithoutValidAttestation() public {
        uint256 id = _placeRwaForUsdc(alice);
        AsseteraExchange.KycAttestation memory att =
            _signAtt(0xBAD, bob, AsseteraExchange.Action.Fill, id, _freshNonce(), block.timestamp + 3 minutes, bytes32(0), 0, 0, address(0));
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectRevert(AsseteraExchange.KycBadSigner.selector);
        exchange.fillOrder(id, SELL_RWA, att);
        vm.stopPrank();
    }

    function test_FillOrder_RevertsOnWrongOrderIdBinding() public {
        uint256 id = _placeRwaForUsdc(alice);
        // Attestation bound to a different order id.
        AsseteraExchange.KycAttestation memory att = _attest(bob, AsseteraExchange.Action.Fill, id + 99);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectRevert(AsseteraExchange.KycOrderMismatch.selector);
        exchange.fillOrder(id, SELL_RWA, att);
        vm.stopPrank();
    }

    // ===================================================================== //
    //              settle — self-trade, expiry, partial settlement          //
    // ===================================================================== //

    function test_Settle_HappyPath_TwoAttestations() public {
        uint256 a = _placeRwaForUsdc(alice);
        uint256 b = _placeUsdcForRwa(bob, WANT_USDC, SELL_RWA);
        uint256 aliceUsdc = usdc.balanceOf(alice);
        uint256 bobRwa = rwa.balanceOf(bob);

        AsseteraExchange.KycAttestation memory attA = _attest(alice, AsseteraExchange.Action.Settle, a);
        AsseteraExchange.KycAttestation memory attB = _attest(bob, AsseteraExchange.Action.Settle, b);
        vm.prank(operator);
        exchange.settle(a, b, attA, attB);

        assertEq(uint8(exchange.getOrder(a).status), uint8(AsseteraExchange.OrderStatus.Settled));
        assertEq(usdc.balanceOf(alice), aliceUsdc + WANT_USDC);
        assertEq(rwa.balanceOf(bob), bobRwa + SELL_RWA);
    }

    function test_Settle_SelfTradePrevention() public {
        // Same maker on both sides must revert (self-trade prevention).
        uint256 a = _placeRwaForUsdc(alice);
        uint256 b = _placeUsdcForRwa(alice, WANT_USDC, SELL_RWA);

        AsseteraExchange.KycAttestation memory attA = _attest(alice, AsseteraExchange.Action.Settle, a);
        AsseteraExchange.KycAttestation memory attB = _attest(alice, AsseteraExchange.Action.Settle, b);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.SelfTrade.selector, a));
        exchange.settle(a, b, attA, attB);
    }

    function test_Settle_RevertsOnExpiredOrder() public {
        // Settling when one order is expired must revert.
        uint64 expireTs = uint64(block.timestamp + 1 hours);
        AsseteraExchange.KycAttestation memory placeAtt = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        uint256 a = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, expireTs, placeAtt);
        vm.stopPrank();

        uint256 b = _placeUsdcForRwa(bob, WANT_USDC, SELL_RWA);
        vm.warp(block.timestamp + 2 hours);

        AsseteraExchange.KycAttestation memory attA = _attest(alice, AsseteraExchange.Action.Settle, a);
        AsseteraExchange.KycAttestation memory attB = _attest(bob, AsseteraExchange.Action.Settle, b);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.OrderIsExpired.selector, a));
        exchange.settle(a, b, attA, attB);
    }

    function test_Settle_RevertsOnExpiredSellOrder() public {
        // Settling when the sell-side order is expired must revert.
        uint256 a = _placeUsdcForRwa(alice, WANT_USDC, SELL_RWA);

        uint64 expireTs = uint64(block.timestamp + 1 hours);
        AsseteraExchange.KycAttestation memory placeAtt = _attestPlace(bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(bob);
        rwa.approve(address(exchange), SELL_RWA);
        uint256 b = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, expireTs, placeAtt);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 hours);

        AsseteraExchange.KycAttestation memory attA = _attest(alice, AsseteraExchange.Action.Settle, a);
        AsseteraExchange.KycAttestation memory attB = _attest(bob, AsseteraExchange.Action.Settle, b);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.OrderIsExpired.selector, b));
        exchange.settle(a, b, attA, attB);
    }

    function test_Settle_PartialFill_BothOrdersHalfFilled() public {
        // Both orders half-filled before settle — remaining quantities are price-compatible.
        uint256 a = _placeRwaForUsdc(alice); // sell 10 RWA for 1000 USDC
        uint256 b = _placeUsdcForRwa(bob, WANT_USDC, SELL_RWA); // sell 1000 USDC for 10 RWA

        vm.prank(admin);
        exchange.setComplianceRequired(AsseteraExchange.Action.Fill, false);

        AsseteraExchange.KycAttestation memory emptyAtt = AsseteraExchange.KycAttestation({
            account: address(0), action: AsseteraExchange.Action.None,
            orderId: 0, nonce: 0, deadline: 0, paramsHash: bytes32(0),
            makerFeeBps: 0, takerFeeBps: 0, feeCollector: address(0), signature: ""
        });

        uint256 halfRwa  = SELL_RWA / 2;                                      // 5 RWA
        uint256 halfUsdc = (halfRwa * WANT_USDC + SELL_RWA - 1) / SELL_RWA;  // 500 USDC (ceiling)

        // carol half-fills alice's order: takes 5 RWA, pays 500 USDC
        vm.startPrank(carol);
        usdc.approve(address(exchange), halfUsdc);
        exchange.fillOrder(a, halfRwa, emptyAtt);

        // carol half-fills bob's order: takes 500 USDC, pays 5 RWA
        rwa.approve(address(exchange), halfRwa);
        exchange.fillOrder(b, halfUsdc, emptyAtt);
        vm.stopPrank();

        // alice.remaining = 5 RWA, bob.remaining = 500 USDC — still price-compatible.
        uint256 aliceUsdc = usdc.balanceOf(alice);
        uint256 bobRwa    = rwa.balanceOf(bob);

        AsseteraExchange.KycAttestation memory attA = _attest(alice, AsseteraExchange.Action.Settle, a);
        AsseteraExchange.KycAttestation memory attB = _attest(bob,   AsseteraExchange.Action.Settle, b);
        vm.prank(operator);
        exchange.settle(a, b, attA, attB);

        assertEq(usdc.balanceOf(alice), aliceUsdc + halfUsdc); // 500 USDC from bob's remaining
        assertEq(rwa.balanceOf(bob),    bobRwa    + halfRwa);  // 5 RWA from alice's remaining
        assertEq(uint8(exchange.getOrder(a).status), uint8(AsseteraExchange.OrderStatus.Settled));
        assertEq(uint8(exchange.getOrder(b).status), uint8(AsseteraExchange.OrderStatus.Settled));
    }

    function test_Settle_RevertsOnUnfairPartialSettlement() public {
        // Only alice's order is half-filled; settling would give bob 5 RWA for 1000 USDC
        // — below bob's limit of 10 RWA for 1000 USDC.
        uint256 a = _placeRwaForUsdc(alice);
        uint256 b = _placeUsdcForRwa(bob, WANT_USDC, SELL_RWA);

        vm.prank(admin);
        exchange.setComplianceRequired(AsseteraExchange.Action.Fill, false);

        uint256 halfRwa  = SELL_RWA / 2;
        uint256 halfUsdc = (halfRwa * WANT_USDC + SELL_RWA - 1) / SELL_RWA;

        vm.startPrank(carol);
        usdc.approve(address(exchange), halfUsdc);
        exchange.fillOrder(a, halfRwa, AsseteraExchange.KycAttestation({
            account: address(0), action: AsseteraExchange.Action.None,
            orderId: 0, nonce: 0, deadline: 0, paramsHash: bytes32(0),
            makerFeeBps: 0, takerFeeBps: 0, feeCollector: address(0), signature: ""
        }));
        vm.stopPrank();

        AsseteraExchange.KycAttestation memory attA = _attest(alice, AsseteraExchange.Action.Settle, a);
        AsseteraExchange.KycAttestation memory attB = _attest(bob,   AsseteraExchange.Action.Settle, b);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.PriceNotCrossed.selector, a, b));
        exchange.settle(a, b, attA, attB);
    }

    function test_Settle_RevertsIfMakerNotAttested() public {
        uint256 a = _placeRwaForUsdc(alice);
        uint256 b = _placeUsdcForRwa(bob, WANT_USDC, SELL_RWA);
        AsseteraExchange.KycAttestation memory attA = _attest(alice, AsseteraExchange.Action.Settle, a);
        // Bob's attestation signed by a non-KYC key.
        AsseteraExchange.KycAttestation memory attB =
            _signAtt(0xBAD, bob, AsseteraExchange.Action.Settle, b, _freshNonce(), block.timestamp + 3 minutes, bytes32(0), 0, 0, address(0));
        vm.prank(operator);
        vm.expectRevert(AsseteraExchange.KycBadSigner.selector);
        exchange.settle(a, b, attA, attB);
    }

    function test_Settle_RevertsIfNotOperator() public {
        uint256 a = _placeRwaForUsdc(alice);
        uint256 b = _placeUsdcForRwa(bob, WANT_USDC, SELL_RWA);
        AsseteraExchange.KycAttestation memory attA = _attest(alice, AsseteraExchange.Action.Settle, a);
        AsseteraExchange.KycAttestation memory attB = _attest(bob, AsseteraExchange.Action.Settle, b);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", carol, OPERATOR_ROLE)
        );
        exchange.settle(a, b, attA, attB);
    }

    function test_Settle_RevertsIfNotComplementary() public {
        uint256 a = _placeRwaForUsdc(alice);
        uint256 b = _placeRwaForUsdc(bob); // same direction
        AsseteraExchange.KycAttestation memory attA = _attest(alice, AsseteraExchange.Action.Settle, a);
        AsseteraExchange.KycAttestation memory attB = _attest(bob, AsseteraExchange.Action.Settle, b);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.NotComplementary.selector, a, b));
        exchange.settle(a, b, attA, attB);
    }

    // ===================================================================== //
    //                   sweepExpired — order expiry sweep                   //
    // ===================================================================== //

    function test_SweepExpired_RefundsEscrow() public {
        uint64 expireTs = uint64(block.timestamp + 1 hours);
        AsseteraExchange.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        uint256 id = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, expireTs, att);
        vm.stopPrank();

        uint256 aliceRwa = rwa.balanceOf(alice);
        vm.warp(block.timestamp + 2 hours);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        exchange.sweepExpired(ids);

        assertEq(uint8(exchange.getOrder(id).status), uint8(AsseteraExchange.OrderStatus.Expired));
        assertEq(rwa.balanceOf(alice), aliceRwa + SELL_RWA);
    }

    function test_SweepExpired_SkipsNonExpiredAndNonOpen() public {
        // Order 1: no expiry (skipped)
        uint256 id1 = _placeRwaForUsdc(alice);
        // Order 2: expiry in future (skipped)
        uint64 future = uint64(block.timestamp + 2 hours);
        AsseteraExchange.KycAttestation memory att2 = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        uint256 id2 = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, future, att2);
        vm.stopPrank();
        // Order 3: expiry in past (swept)
        uint64 past = uint64(block.timestamp + 1 hours);
        AsseteraExchange.KycAttestation memory att3 = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        uint256 id3 = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, past, att3);
        vm.stopPrank();

        vm.warp(block.timestamp + 90 minutes); // id3 expired, id2 not yet

        uint256[] memory ids = new uint256[](3);
        ids[0] = id1; ids[1] = id2; ids[2] = id3;
        exchange.sweepExpired(ids);

        assertEq(uint8(exchange.getOrder(id1).status), uint8(AsseteraExchange.OrderStatus.Open));
        assertEq(uint8(exchange.getOrder(id2).status), uint8(AsseteraExchange.OrderStatus.Open));
        assertEq(uint8(exchange.getOrder(id3).status), uint8(AsseteraExchange.OrderStatus.Expired));
    }

    function test_SweepExpired_CannotSweepTwice() public {
        uint64 expireTs = uint64(block.timestamp + 1 hours);
        AsseteraExchange.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        uint256 id = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, expireTs, att);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 hours);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        exchange.sweepExpired(ids); // first sweep
        uint256 bal = rwa.balanceOf(alice);
        exchange.sweepExpired(ids); // second sweep — silently skipped (status != Open)
        assertEq(rwa.balanceOf(alice), bal); // no double-refund
    }

    function test_SweepExpired_SkipsBlacklistedMaker() public {
        // Alice places an order with expiry, then gets blacklisted.
        uint64 expireTs = uint64(block.timestamp + 1 hours);
        AsseteraExchange.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        uint256 id = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, expireTs, att);
        vm.stopPrank();

        bytes32 h = keccak256(abi.encodePacked(alice));
        vm.prank(admin);
        exchange.setBlacklisted(h, true);

        vm.warp(block.timestamp + 2 hours); // order has expired

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        exchange.sweepExpired(ids); // should silently skip — alice is blacklisted

        // Order remains Open so admin can route funds via cancelOrderForUser.
        assertEq(uint8(exchange.getOrder(id).status), uint8(AsseteraExchange.OrderStatus.Open));
        assertEq(rwa.balanceOf(alice), 1_000e18 - SELL_RWA); // escrow not returned

        // Admin releases funds to compliance recipient.
        uint256 carolBal = rwa.balanceOf(carol);
        vm.prank(admin);
        exchange.cancelOrderForUser(id, carol);
        assertEq(rwa.balanceOf(carol), carolBal + SELL_RWA);
    }

    // ===================================================================== //
    //                       refund / cancelOrderForUser                     //
    // ===================================================================== //

    function test_Refund_HappyPath() public {
        uint256 id = _placeRwaForUsdc(alice);
        uint256 bal = rwa.balanceOf(alice);
        vm.prank(operator);
        exchange.refund(id, "kyc lapsed");
        assertEq(uint8(exchange.getOrder(id).status), uint8(AsseteraExchange.OrderStatus.Refunded));
        assertEq(rwa.balanceOf(alice), bal + SELL_RWA);
    }

    function test_CancelOrderForUser_RoutesToRecipient() public {
        uint256 id = _placeRwaForUsdc(alice);
        uint256 carolBal = rwa.balanceOf(carol);

        vm.expectEmit(true, true, false, true, address(exchange));
        emit OrderForceCancelled(id, alice, carol, admin);
        vm.prank(admin);
        exchange.cancelOrderForUser(id, carol); // route to a compliance-chosen address

        assertEq(uint8(exchange.getOrder(id).status), uint8(AsseteraExchange.OrderStatus.ForceCancelled));
        assertEq(rwa.balanceOf(carol), carolBal + SELL_RWA);
    }

    function test_CancelOrderForUser_FrozenUserFlow() public {
        // Frozen user can't self-cancel (bad signer), admin releases funds to them.
        uint256 id = _placeRwaForUsdc(alice);
        AsseteraExchange.KycAttestation memory bad =
            _signAtt(0xBAD, alice, AsseteraExchange.Action.Cancel, id, _freshNonce(), block.timestamp + 3 minutes, bytes32(0), 0, 0, address(0));
        vm.prank(alice);
        vm.expectRevert(AsseteraExchange.KycBadSigner.selector);
        exchange.cancelOrder(id, bad);

        uint256 bal = rwa.balanceOf(alice);
        vm.prank(admin);
        exchange.cancelOrderForUser(id, alice);
        assertEq(rwa.balanceOf(alice), bal + SELL_RWA);
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
        vm.expectRevert(AsseteraExchange.ZeroAddress.selector);
        exchange.cancelOrderForUser(id, address(0));
    }

    // ===================================================================== //
    //                        setComplianceRequired                          //
    // ===================================================================== //

    function test_SetComplianceRequired_OnlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, ADMIN_ROLE)
        );
        exchange.setComplianceRequired(AsseteraExchange.Action.Fill, false);
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
        // KYC attestation for the user
        AsseteraExchange.KycAttestation memory att = _attestPlace(user, address(rwa), SELL_RWA, address(usdc), WANT_USDC);

        bytes memory callData = abi.encodeCall(
            AsseteraExchange.placeOrderWithPermit,
            (address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, permitDeadline, pv, pr, ps, att)
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
                keccak256("ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)"),
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
    //                                views                                  //
    // ===================================================================== //

    function test_GetOpenOrders_FiltersClosed() public {
        uint256 id1 = _placeRwaForUsdc(alice);
        _placeRwaForUsdc(alice); // id2 open
        AsseteraExchange.KycAttestation memory att = _attest(alice, AsseteraExchange.Action.Cancel, id1);
        vm.prank(alice);
        exchange.cancelOrder(id1, att);
        AsseteraExchange.Order[] memory open = exchange.getOpenOrders();
        assertEq(open.length, 1);
        assertEq(open[0].id, 2);
    }

    // ===================================================================== //
    //                              reentrancy                               //
    // ===================================================================== //

    function test_FillOrder_ReentrancyGuarded() public {
        // Disable Fill gating so the empty attestation in the reentrant call
        // reaches the guard rather than failing KYC first.
        vm.prank(admin);
        exchange.setComplianceRequired(AsseteraExchange.Action.Fill, false);

        ReentrantToken evil = new ReentrantToken();
        evil.mint(bob, 1_000e18);

        uint256 id;
        {
            AsseteraExchange.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(evil), 100e18);
            vm.startPrank(alice);
            rwa.approve(address(exchange), SELL_RWA);
            id = exchange.placeOrder(address(rwa), SELL_RWA, address(evil), 100e18, 0, att);
            vm.stopPrank();
        }
        evil.arm(address(exchange), id);

        AsseteraExchange.KycAttestation memory empty;
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
        vm.startPrank(alice);
        rwa.approve(address(exchange), sellAmt);
        uint256 id = exchange.placeOrder(address(rwa), sellAmt, address(usdc), buyAmt, 0, pAtt);
        vm.stopPrank();

        AsseteraExchange.KycAttestation memory fAtt = _attest(bob, AsseteraExchange.Action.Fill, id);
        uint256 aliceUsdc = usdc.balanceOf(alice);
        vm.startPrank(bob);
        usdc.approve(address(exchange), buyAmt);
        exchange.fillOrder(id, sellAmt, fAtt);
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), aliceUsdc + buyAmt);
    }

    // ===================================================================== //
    //                       additional coverage                             //
    // ===================================================================== //

    function test_Initialize_RevertsOnZeroAdmin() public {
        AsseteraExchange impl = new AsseteraExchange(address(forwarder));
        bytes memory initData = abi.encodeCall(AsseteraExchange.initialize, (address(0), operator, kycSigner));
        vm.expectRevert(AsseteraExchange.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertsOnZeroOperator() public {
        AsseteraExchange impl = new AsseteraExchange(address(forwarder));
        bytes memory initData = abi.encodeCall(AsseteraExchange.initialize, (admin, address(0), kycSigner));
        vm.expectRevert(AsseteraExchange.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_PlaceOrderWithPermit_Direct() public {
        uint256 pk = 0xBEEF;
        address maker = vm.addr(pk);
        rwa.mint(maker, SELL_RWA);
        uint256 dl = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(rwa, pk, maker, address(exchange), SELL_RWA, dl);
        AsseteraExchange.KycAttestation memory att = _attestPlace(maker, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.prank(maker);
        uint256 id =
            exchange.placeOrderWithPermit(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, dl, v, r, s, att);
        assertEq(id, 1);
        assertEq(rwa.balanceOf(address(exchange)), SELL_RWA);
    }

    function test_PlaceOrder_RevertsOnZeroSellToken() public {
        AsseteraExchange.KycAttestation memory att = _attestPlace(alice, address(0), SELL_RWA, address(usdc), WANT_USDC);
        vm.prank(alice);
        vm.expectRevert(AsseteraExchange.ZeroAddress.selector);
        exchange.placeOrder(address(0), SELL_RWA, address(usdc), WANT_USDC, 0, att);
    }

    function test_PlaceOrder_RevertsOnSameToken() public {
        AsseteraExchange.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(rwa), WANT_USDC);
        vm.prank(alice);
        vm.expectRevert(AsseteraExchange.SameToken.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(rwa), WANT_USDC, 0, att);
    }

    function test_PlaceOrder_RevertsOnOrderIdMismatch() public {
        // Attestation carries the correct paramsHash but wrong orderId (7 vs required 0 for Place).
        // paramsHash check passes; KycOrderMismatch fires inside _consumeKyc.
        bytes32 ph = keccak256(abi.encode(address(rwa), SELL_RWA, address(usdc), WANT_USDC));
        AsseteraExchange.KycAttestation memory att =
            _signAtt(kycSignerPk, alice, AsseteraExchange.Action.Place, 7, _freshNonce(), block.timestamp + 3 minutes, ph, 0, 0, address(0));
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(AsseteraExchange.KycOrderMismatch.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att);
        vm.stopPrank();
    }

    function test_CancelOrder_RevertsIfNotOpen() public {
        uint256 id = _placeRwaForUsdc(alice);
        AsseteraExchange.KycAttestation memory a1 = _attest(alice, AsseteraExchange.Action.Cancel, id);
        vm.prank(alice);
        exchange.cancelOrder(id, a1);
        AsseteraExchange.KycAttestation memory a2 = _attest(alice, AsseteraExchange.Action.Cancel, id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.OrderNotOpen.selector, id));
        exchange.cancelOrder(id, a2);
    }

    function test_FillOrder_RevertsIfNotOpen() public {
        uint256 id = _placeRwaForUsdc(alice);
        AsseteraExchange.KycAttestation memory c = _attest(alice, AsseteraExchange.Action.Cancel, id);
        vm.prank(alice);
        exchange.cancelOrder(id, c);
        AsseteraExchange.KycAttestation memory f = _attest(bob, AsseteraExchange.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.OrderNotOpen.selector, id));
        exchange.fillOrder(id, SELL_RWA, f);
        vm.stopPrank();
    }

    function test_FillOrder_RevertsWhenPaused() public {
        uint256 id = _placeRwaForUsdc(alice);
        vm.prank(operator);
        exchange.pause();
        AsseteraExchange.KycAttestation memory f = _attest(bob, AsseteraExchange.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        exchange.fillOrder(id, SELL_RWA, f);
        vm.stopPrank();
    }

    function test_Pause_Unpause_Cycle() public {
        vm.prank(operator);
        exchange.pause();
        assertTrue(exchange.paused());
        vm.prank(operator);
        exchange.unpause();
        assertFalse(exchange.paused());
        _placeRwaForUsdc(alice); // works again
    }

    function test_Pause_RevertsIfNotOperator() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, OPERATOR_ROLE)
        );
        exchange.pause();
    }

    function test_Refund_RevertsIfNotOperator() public {
        uint256 id = _placeRwaForUsdc(alice);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, OPERATOR_ROLE)
        );
        exchange.refund(id, "x");
    }

    function test_Refund_RevertsIfNotOpen() public {
        uint256 id = _placeRwaForUsdc(alice);
        vm.prank(operator);
        exchange.refund(id, "x");
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.OrderNotOpen.selector, id));
        exchange.refund(id, "again");
    }

    function test_Settle_RevertsIfPriceNotCrossed() public {
        uint256 a = _placeRwaForUsdc(alice); // wants 1000 USDC
        uint256 b = _placeUsdcForRwa(bob, 900e6, SELL_RWA); // only 900 escrowed
        AsseteraExchange.KycAttestation memory attA = _attest(alice, AsseteraExchange.Action.Settle, a);
        AsseteraExchange.KycAttestation memory attB = _attest(bob, AsseteraExchange.Action.Settle, b);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.PriceNotCrossed.selector, a, b));
        exchange.settle(a, b, attA, attB);
    }

    function test_Settle_RevertsIfFirstNotOpen() public {
        uint256 a = _placeRwaForUsdc(alice);
        uint256 b = _placeUsdcForRwa(bob, WANT_USDC, SELL_RWA);
        AsseteraExchange.KycAttestation memory c = _attest(alice, AsseteraExchange.Action.Cancel, a);
        vm.prank(alice);
        exchange.cancelOrder(a, c);
        AsseteraExchange.KycAttestation memory attA = _attest(alice, AsseteraExchange.Action.Settle, a);
        AsseteraExchange.KycAttestation memory attB = _attest(bob, AsseteraExchange.Action.Settle, b);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.OrderNotOpen.selector, a));
        exchange.settle(a, b, attA, attB);
    }

    function test_Settle_RevertsIfSecondNotOpen() public {
        uint256 a = _placeRwaForUsdc(alice);
        uint256 b = _placeUsdcForRwa(bob, WANT_USDC, SELL_RWA);
        AsseteraExchange.KycAttestation memory c = _attest(bob, AsseteraExchange.Action.Cancel, b);
        vm.prank(bob);
        exchange.cancelOrder(b, c);
        AsseteraExchange.KycAttestation memory attA = _attest(alice, AsseteraExchange.Action.Settle, a);
        AsseteraExchange.KycAttestation memory attB = _attest(bob, AsseteraExchange.Action.Settle, b);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.OrderNotOpen.selector, b));
        exchange.settle(a, b, attA, attB);
    }

    function test_Settle_PriceImprovementToMakers() public {
        uint256 a = _placeRwaForUsdc(alice); // wants 1000 USDC
        uint256 b = _placeUsdcForRwa(bob, 1_200e6, SELL_RWA); // escrows 1200
        uint256 aliceUsdc = usdc.balanceOf(alice);
        AsseteraExchange.KycAttestation memory attA = _attest(alice, AsseteraExchange.Action.Settle, a);
        AsseteraExchange.KycAttestation memory attB = _attest(bob, AsseteraExchange.Action.Settle, b);
        vm.prank(operator);
        exchange.settle(a, b, attA, attB);
        assertEq(usdc.balanceOf(alice), aliceUsdc + 1_200e6); // improvement: alice gets all of bob's 1200
    }

    function test_CancelOrderForUser_RevertsIfNotOpen() public {
        uint256 id = _placeRwaForUsdc(alice);
        vm.prank(admin);
        exchange.cancelOrderForUser(id, alice);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.OrderNotOpen.selector, id));
        exchange.cancelOrderForUser(id, alice);
    }

    function test_SetComplianceRequired_TogglesGating() public {
        vm.prank(admin);
        exchange.setComplianceRequired(AsseteraExchange.Action.Fill, false);
        assertFalse(exchange.complianceRequired(AsseteraExchange.Action.Fill));
        // fill now works with an empty attestation
        uint256 id = _placeRwaForUsdc(alice);
        AsseteraExchange.KycAttestation memory empty;
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.fillOrder(id, SELL_RWA, empty);
        vm.stopPrank();
        assertEq(uint8(exchange.getOrder(id).status), uint8(AsseteraExchange.OrderStatus.Filled));
    }

    function test_GetOrders_Pagination() public {
        _placeRwaForUsdc(alice);
        _placeRwaForUsdc(alice);
        _placeRwaForUsdc(alice);
        AsseteraExchange.Order[] memory page = exchange.getOrders(1, 2);
        assertEq(page.length, 2);
        assertEq(page[0].id, 1);
        AsseteraExchange.Order[] memory tail = exchange.getOrders(2, 100);
        assertEq(tail.length, 2);
        assertEq(tail[0].id, 2);
        AsseteraExchange.Order[] memory z = exchange.getOrders(0, 1);
        assertEq(z[0].id, 1);
    }

    // ===================================================================== //
    //              blacklist  &  paramsHash binding                         //
    // ===================================================================== //

    function test_Blacklist_BlocksAllKycActions() public {
        bytes32 h = keccak256(abi.encodePacked(alice));
        vm.prank(admin);
        exchange.setBlacklisted(h, true);

        AsseteraExchange.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(AsseteraExchange.AccountBlacklisted.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att);
        vm.stopPrank();
    }

    function test_Blacklist_BlocksCancelOrderSelf() public {
        uint256 id = _placeRwaForUsdc(alice);

        bytes32 h = keccak256(abi.encodePacked(alice));
        vm.prank(admin);
        exchange.setBlacklisted(h, true);

        vm.prank(alice);
        vm.expectRevert(AsseteraExchange.AccountBlacklisted.selector);
        exchange.cancelOrderSelf(id);
    }

    function test_Blacklist_CancelOrderForUser_ReleasesBlacklistedFunds() public {
        uint256 id = _placeRwaForUsdc(alice);

        bytes32 h = keccak256(abi.encodePacked(alice));
        vm.prank(admin);
        exchange.setBlacklisted(h, true);

        // alice cannot self-cancel; admin releases funds to a compliance recipient
        uint256 bal = rwa.balanceOf(carol);
        vm.prank(admin);
        exchange.cancelOrderForUser(id, carol);
        assertEq(rwa.balanceOf(carol), bal + SELL_RWA);
    }

    function test_Blacklist_OnlyAdminCanSet() public {
        bytes32 h = keccak256(abi.encodePacked(alice));
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", operator, ADMIN_ROLE)
        );
        exchange.setBlacklisted(h, true);
    }

    function test_PlaceOrder_RevertsOnParamsHashMismatch() public {
        // Sign attestation for (rwa, SELL_RWA, usdc, WANT_USDC) but call with different buyAmount.
        AsseteraExchange.KycAttestation memory att = _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(AsseteraExchange.ParamsHashMismatch.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC + 1, 0, att);
        vm.stopPrank();
    }

    // ===================================================================== //
    //                       missing-coverage additions                       //
    // ===================================================================== //

    // --- M-1 invariant: nonce NOT burned when param validation fails ----- //

    function test_PlaceOrder_NonceSurvivedAfterParamValidationFailure() public {
        AsseteraExchange.KycAttestation memory att =
            _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);

        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);

        // InvalidExpiry fires before _consumeKyc — nonce must NOT be burned.
        // expireTs <= block.timestamp triggers InvalidExpiry (zero means "no expiry").
        uint64 past = uint64(block.timestamp);
        vm.expectRevert(AsseteraExchange.InvalidExpiry.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, past, att);

        // Same attestation (same nonce) succeeds on retry with a valid expiry.
        uint256 id = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att);
        vm.stopPrank();

        assertEq(exchange.getOrder(id).maker, alice);
    }

    // --- blacklist: taker and settle legs -------------------------------- //

    function test_Blacklist_BlocksFillOrder() public {
        uint256 id = _placeRwaForUsdc(alice);

        bytes32 h = keccak256(abi.encodePacked(bob));
        vm.prank(admin);
        exchange.setBlacklisted(h, true);

        AsseteraExchange.KycAttestation memory att = _attest(bob, AsseteraExchange.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectRevert(AsseteraExchange.AccountBlacklisted.selector);
        exchange.fillOrder(id, SELL_RWA, att);
        vm.stopPrank();
    }

    function test_Blacklist_BlocksSettle_WhenMakerBlacklisted() public {
        uint256 a = _placeRwaForUsdc(alice);
        uint256 b = _placeUsdcForRwa(bob, WANT_USDC, SELL_RWA);

        bytes32 h = keccak256(abi.encodePacked(alice));
        vm.prank(admin);
        exchange.setBlacklisted(h, true);

        AsseteraExchange.KycAttestation memory attA = _attest(alice, AsseteraExchange.Action.Settle, a);
        AsseteraExchange.KycAttestation memory attB = _attest(bob, AsseteraExchange.Action.Settle, b);
        vm.prank(operator);
        vm.expectRevert(AsseteraExchange.AccountBlacklisted.selector);
        exchange.settle(a, b, attA, attB);
    }

    // --- unblacklist restores access ------------------------------------- //

    function test_Blacklist_Unblacklist_RestoresAccess() public {
        bytes32 h = keccak256(abi.encodePacked(alice));
        vm.prank(admin);
        exchange.setBlacklisted(h, true);

        // Blocked before unblacklisting.
        AsseteraExchange.KycAttestation memory att1 =
            _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA * 2);
        vm.expectRevert(AsseteraExchange.AccountBlacklisted.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att1);
        vm.stopPrank();

        vm.prank(admin);
        exchange.setBlacklisted(h, false);

        // Access restored after unblacklisting.
        AsseteraExchange.KycAttestation memory att2 =
            _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        uint256 id = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att2);
        vm.stopPrank();

        assertEq(exchange.getOrder(id).maker, alice);
    }

    // --- cancelOrderSelf has no whenNotPaused modifier ------------------- //

    function test_CancelOrderSelf_WorksWhenPaused() public {
        uint256 id = _placeRwaForUsdc(alice);
        uint256 bal = rwa.balanceOf(alice);

        vm.prank(operator);
        exchange.pause();
        assertTrue(exchange.paused());

        vm.prank(alice);
        exchange.cancelOrderSelf(id);

        assertEq(uint8(exchange.getOrder(id).status), uint8(AsseteraExchange.OrderStatus.Cancelled));
        assertEq(rwa.balanceOf(alice), bal + SELL_RWA);
    }

    // --- zero buyAmount and zero buyToken -------------------------------- //

    function test_PlaceOrder_RevertsOnZeroBuyAmount() public {
        AsseteraExchange.KycAttestation memory att =
            _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), 0);
        vm.prank(alice);
        vm.expectRevert(AsseteraExchange.ZeroAmount.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), 0, 0, att);
    }

    function test_PlaceOrder_RevertsOnZeroBuyToken() public {
        AsseteraExchange.KycAttestation memory att =
            _attestPlace(alice, address(rwa), SELL_RWA, address(0), WANT_USDC);
        vm.prank(alice);
        vm.expectRevert(AsseteraExchange.ZeroAddress.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(0), WANT_USDC, 0, att);
    }

    // --- sweepExpired returns only remainingQuantity for partial fills --- //

    function test_SweepExpired_PartiallyFilledOrder() public {
        uint64 expireTs = uint64(block.timestamp + 1 hours);
        AsseteraExchange.KycAttestation memory placeAtt =
            _attestPlace(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        uint256 id = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, expireTs, placeAtt);
        vm.stopPrank();

        vm.prank(admin);
        exchange.setComplianceRequired(AsseteraExchange.Action.Fill, false);

        uint256 halfRwa  = SELL_RWA / 2;
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

        assertEq(uint8(exchange.getOrder(id).status), uint8(AsseteraExchange.OrderStatus.Expired));
        assertEq(rwa.balanceOf(alice), aliceRwaBefore + (SELL_RWA - halfRwa));
    }

    // --- L-1 fix: settle verifies both before consuming either nonce ----- //

    function test_Settle_SecondMakerKycFailDoesNotBurnFirstNonce() public {
        uint256 a = _placeRwaForUsdc(alice);
        uint256 b = _placeUsdcForRwa(bob, WANT_USDC, SELL_RWA);

        AsseteraExchange.KycAttestation memory attA = _attest(alice, AsseteraExchange.Action.Settle, a);
        // Bob's attestation has a bad signer — the call should revert.
        AsseteraExchange.KycAttestation memory badAttB =
            _signAtt(0xBAD, bob, AsseteraExchange.Action.Settle, b, _freshNonce(), block.timestamp + 3 minutes, bytes32(0), 0, 0, address(0));

        vm.prank(operator);
        vm.expectRevert(AsseteraExchange.KycBadSigner.selector);
        exchange.settle(a, b, attA, badAttB);

        // Alice's nonce was NOT burned — same attestation must succeed on retry.
        AsseteraExchange.KycAttestation memory goodAttB = _attest(bob, AsseteraExchange.Action.Settle, b);
        vm.prank(operator);
        exchange.settle(a, b, attA, goodAttB);

        assertEq(uint8(exchange.getOrder(a).status), uint8(AsseteraExchange.OrderStatus.Settled));
    }

    // --- I-2 fix: non-Place attestation with non-zero paramsHash rejected  //

    function test_FillOrder_RevertsOnNonZeroParamsHash() public {
        uint256 id = _placeRwaForUsdc(alice);
        // A Fill attestation signed with a non-zero paramsHash must be rejected.
        AsseteraExchange.KycAttestation memory att =
            _signAtt(kycSignerPk, bob, AsseteraExchange.Action.Fill, id, _freshNonce(), block.timestamp + 3 minutes, keccak256("nonzero"), 0, 0, address(0));
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectRevert(AsseteraExchange.ParamsHashMismatch.selector);
        exchange.fillOrder(id, SELL_RWA, att);
        vm.stopPrank();
    }

    // --- settle rejects swapped attestations ----------------------------- //

    function test_Settle_RevertsOnSwappedAttestations() public {
        uint256 a = _placeRwaForUsdc(alice);
        uint256 b = _placeUsdcForRwa(bob, WANT_USDC, SELL_RWA);

        AsseteraExchange.KycAttestation memory attA = _attest(alice, AsseteraExchange.Action.Settle, a);
        AsseteraExchange.KycAttestation memory attB = _attest(bob,   AsseteraExchange.Action.Settle, b);

        // attB is bound to bob/orderId=b; passing it as attBuy for buyId=a (maker=alice)
        // fires KycAccountMismatch on the first _consumeKyc call.
        vm.prank(operator);
        vm.expectRevert(AsseteraExchange.KycAccountMismatch.selector);
        exchange.settle(a, b, attB, attA);
    }

    // ===================================================================== //
    //                     offer / counter-offer                             //
    // ===================================================================== //

    // ── Offer attestation helpers ──────────────────────────────────────── //

    function _attestMakeOffer(
        address maker,
        address taker,
        address makerToken,
        uint256 makerAmt,
        address takerToken,
        uint256 takerAmt
    ) internal returns (AsseteraExchange.KycAttestation memory) {
        bytes32 ph = keccak256(abi.encodePacked(taker, makerToken, makerAmt, takerToken, takerAmt));
        return _signAtt(kycSignerPk, maker, AsseteraExchange.Action.MakeOffer, 0, _freshNonce(), block.timestamp + 3 minutes, ph, 0, 0, address(0));
    }

    function _attestReplaceOffer(
        address caller,
        uint256 offerId,
        uint256 newMakerAmt,
        uint256 newTakerAmt
    ) internal returns (AsseteraExchange.KycAttestation memory) {
        bytes32 ph = keccak256(abi.encodePacked(offerId, newMakerAmt, newTakerAmt));
        return _signAtt(kycSignerPk, caller, AsseteraExchange.Action.ReplaceOffer, offerId, _freshNonce(), block.timestamp + 3 minutes, ph, 0, 0, address(0));
    }

    function _attestAcceptOffer(
        address caller,
        uint256 offerId,
        uint256 makerAmt,
        uint256 takerAmt
    ) internal returns (AsseteraExchange.KycAttestation memory) {
        bytes32 ph = keccak256(abi.encodePacked(offerId, makerAmt, takerAmt));
        return _signAtt(kycSignerPk, caller, AsseteraExchange.Action.AcceptOffer, offerId, _freshNonce(), block.timestamp + 3 minutes, ph, 0, 0, address(0));
    }

    function _attestCancelOffer(
        address caller,
        uint256 offerId,
        uint256 makerAmt,
        uint256 takerAmt
    ) internal returns (AsseteraExchange.KycAttestation memory) {
        bytes32 ph = keccak256(abi.encodePacked(offerId, makerAmt, takerAmt));
        return _signAtt(kycSignerPk, caller, AsseteraExchange.Action.CancelOffer, offerId, _freshNonce(), block.timestamp + 3 minutes, ph, 0, 0, address(0));
    }

    function _attestSettleOffer(
        address caller,
        uint256 offerId,
        uint256 makerAmt,
        uint256 takerAmt
    ) internal returns (AsseteraExchange.KycAttestation memory) {
        bytes32 ph = keccak256(abi.encodePacked(offerId, makerAmt, takerAmt));
        return _signAtt(kycSignerPk, caller, AsseteraExchange.Action.SettleOffer, offerId, _freshNonce(), block.timestamp + 3 minutes, ph, 0, 0, address(0));
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
        vm.startPrank(maker);
        FaucetToken(makerToken).approve(address(exchange), makerAmt);
        id = exchange.makeOffer(taker, makerToken, makerAmt, takerToken, takerAmt, expireTs, att);
        vm.stopPrank();
    }

    function _attestMakeOfferWithFee(
        address maker,
        address taker,
        address makerToken, uint256 makerAmt,
        address takerToken, uint256 takerAmt,
        uint16 makerFeeBps, uint16 takerFeeBps,
        address feeCollector
    ) internal returns (AsseteraExchange.KycAttestation memory) {
        bytes32 ph = keccak256(abi.encodePacked(taker, makerToken, makerAmt, takerToken, takerAmt));
        return _signAtt(kycSignerPk, maker, AsseteraExchange.Action.MakeOffer, 0, _freshNonce(), block.timestamp + 3 minutes, ph, makerFeeBps, takerFeeBps, feeCollector);
    }

    function _makeOfferWithFee(
        address maker,
        address taker,
        address makerToken, uint256 makerAmt,
        address takerToken, uint256 takerAmt,
        uint16 makerFeeBps, uint16 takerFeeBps,
        address feeCollector
    ) internal returns (uint256 id) {
        AsseteraExchange.KycAttestation memory att =
            _attestMakeOfferWithFee(maker, taker, makerToken, makerAmt, takerToken, takerAmt, makerFeeBps, takerFeeBps, feeCollector);
        vm.startPrank(maker);
        FaucetToken(makerToken).approve(address(exchange), makerAmt);
        id = exchange.makeOffer(taker, makerToken, makerAmt, takerToken, takerAmt, 0, att);
        vm.stopPrank();
    }

    // ── Happy paths ────────────────────────────────────────────────────── //

    function test_Offer_MakeAcceptSettle_DirectAccept() public {
        // Alice offers 10 RWA for 1000 USDC; Bob accepts immediately without countering.
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        assertEq(rwa.balanceOf(address(exchange)), SELL_RWA);
        assertEq(uint8(exchange.getOffer(id).status), uint8(AsseteraExchange.OfferStatus.Open));
        assertEq(exchange.getOffer(id).proposedBy, alice);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 bobRwaBefore    = rwa.balanceOf(bob);

        // Bob accepts: escrows takerAmount (USDC).
        AsseteraExchange.KycAttestation memory acceptAtt =
            _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();

        assertEq(uint8(exchange.getOffer(id).status), uint8(AsseteraExchange.OfferStatus.Accepted));
        assertEq(usdc.balanceOf(address(exchange)), WANT_USDC);

        // Operator settles.
        AsseteraExchange.KycAttestation memory makerAtt = _attestSettleOffer(alice, id, SELL_RWA, WANT_USDC);
        AsseteraExchange.KycAttestation memory takerAtt = _attestSettleOffer(bob,   id, SELL_RWA, WANT_USDC);
        vm.prank(operator);
        exchange.settleOffer(id, makerAtt, takerAtt);

        assertEq(uint8(exchange.getOffer(id).status), uint8(AsseteraExchange.OfferStatus.Settled));
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + WANT_USDC); // alice receives USDC
        assertEq(rwa.balanceOf(bob),   bobRwaBefore    + SELL_RWA);  // bob receives RWA
        assertEq(rwa.balanceOf(address(exchange)),  0);
        assertEq(usdc.balanceOf(address(exchange)), 0);
    }

    function test_Offer_MakeReplaceAcceptSettle_TakerCounters() public {
        // Alice offers 10 RWA for 1000 USDC; Bob counters with 800 USDC; Alice accepts.
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);

        uint256 counterUsdc = 800e6;

        // Bob counters: returns Alice's RWA escrow, Bob escrows takerAmount (USDC).
        uint256 aliceRwaBefore = rwa.balanceOf(alice);
        AsseteraExchange.KycAttestation memory replaceAtt =
            _attestReplaceOffer(bob, id, SELL_RWA, counterUsdc);
        vm.startPrank(bob);
        usdc.approve(address(exchange), counterUsdc);
        exchange.replaceOffer(id, SELL_RWA, counterUsdc, 0, replaceAtt);
        vm.stopPrank();

        assertEq(uint8(exchange.getOffer(id).status), uint8(AsseteraExchange.OfferStatus.Countered));
        assertEq(exchange.getOffer(id).proposedBy, bob);
        assertEq(rwa.balanceOf(alice), aliceRwaBefore + SELL_RWA);   // Alice's RWA returned
        assertEq(usdc.balanceOf(address(exchange)), counterUsdc);     // Bob's USDC escrowed

        // Alice accepts Bob's counter: escrows makerAmount (RWA).
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 bobRwaBefore    = rwa.balanceOf(bob);
        AsseteraExchange.KycAttestation memory acceptAtt =
            _attestAcceptOffer(alice, id, SELL_RWA, counterUsdc);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();

        assertEq(uint8(exchange.getOffer(id).status), uint8(AsseteraExchange.OfferStatus.Accepted));

        // Operator settles.
        AsseteraExchange.KycAttestation memory makerAtt = _attestSettleOffer(alice, id, SELL_RWA, counterUsdc);
        AsseteraExchange.KycAttestation memory takerAtt = _attestSettleOffer(bob,   id, SELL_RWA, counterUsdc);
        vm.prank(operator);
        exchange.settleOffer(id, makerAtt, takerAtt);

        assertEq(uint8(exchange.getOffer(id).status), uint8(AsseteraExchange.OfferStatus.Settled));
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + counterUsdc);
        assertEq(rwa.balanceOf(bob),   bobRwaBefore    + SELL_RWA);
    }

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

        // Bob accepts Alice's 900 USDC counter.
        AsseteraExchange.KycAttestation memory acceptAtt =
            _attestAcceptOffer(bob, id, SELL_RWA, round3Usdc);
        vm.startPrank(bob);
        usdc.approve(address(exchange), round3Usdc);
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();

        // Settle.
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 bobRwaBefore    = rwa.balanceOf(bob);
        AsseteraExchange.KycAttestation memory makerAtt = _attestSettleOffer(alice, id, SELL_RWA, round3Usdc);
        AsseteraExchange.KycAttestation memory takerAtt = _attestSettleOffer(bob,   id, SELL_RWA, round3Usdc);
        vm.prank(operator);
        exchange.settleOffer(id, makerAtt, takerAtt);

        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + round3Usdc);
        assertEq(rwa.balanceOf(bob),   bobRwaBefore    + SELL_RWA);
    }

    function test_Offer_CancelOpenOffer_MakerGetEscrowBack() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        uint256 aliceRwaBefore = rwa.balanceOf(alice);

        AsseteraExchange.KycAttestation memory att = _attestCancelOffer(alice, id, SELL_RWA, WANT_USDC);
        vm.prank(alice);
        exchange.cancelOffer(id, att);

        assertEq(uint8(exchange.getOffer(id).status), uint8(AsseteraExchange.OfferStatus.Cancelled));
        assertEq(rwa.balanceOf(alice), aliceRwaBefore + SELL_RWA);
    }

    function test_Offer_TakerCancelsAfterCounter_TakerGetEscrowBack() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);

        // Bob counters — Bob now holds the escrow.
        AsseteraExchange.KycAttestation memory replaceAtt =
            _attestReplaceOffer(bob, id, SELL_RWA, 800e6);
        vm.startPrank(bob);
        usdc.approve(address(exchange), 800e6);
        exchange.replaceOffer(id, SELL_RWA, 800e6, 0, replaceAtt);
        vm.stopPrank();

        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        AsseteraExchange.KycAttestation memory cancelAtt = _attestCancelOffer(bob, id, SELL_RWA, 800e6);
        vm.prank(bob);
        exchange.cancelOffer(id, cancelAtt);

        assertEq(uint8(exchange.getOffer(id).status), uint8(AsseteraExchange.OfferStatus.Cancelled));
        assertEq(usdc.balanceOf(bob), bobUsdcBefore + 800e6); // Bob's USDC returned
    }

    // ── Compliance flags ───────────────────────────────────────────────── //

    function test_Offer_ComplianceFlagsSetOnDeploy() public view {
        assertTrue(exchange.complianceRequired(AsseteraExchange.Action.MakeOffer));
        assertTrue(exchange.complianceRequired(AsseteraExchange.Action.ReplaceOffer));
        assertTrue(exchange.complianceRequired(AsseteraExchange.Action.AcceptOffer));
        assertTrue(exchange.complianceRequired(AsseteraExchange.Action.CancelOffer));
        assertTrue(exchange.complianceRequired(AsseteraExchange.Action.SettleOffer));
    }

    // ── Event shape ───────────────────────────────────────────────────── //

    function test_Offer_EmitsOfferAccepted_WithTerms() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.KycAttestation memory att = _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);

        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectEmit(true, true, false, true);
        emit AsseteraExchange.OfferAccepted(id, bob, SELL_RWA, WANT_USDC);
        exchange.acceptOffer(id, att);
        vm.stopPrank();
    }

    function test_Offer_EmitsOfferCancelled_WithTerms() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.KycAttestation memory att = _attestCancelOffer(alice, id, SELL_RWA, WANT_USDC);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit AsseteraExchange.OfferCancelled(id, alice, SELL_RWA, WANT_USDC);
        exchange.cancelOffer(id, att);
    }

    // ── Sad paths ──────────────────────────────────────────────────────── //

    function test_Offer_RevertsOnSelfTarget() public {
        AsseteraExchange.KycAttestation memory att =
            _attestMakeOffer(alice, alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(AsseteraExchange.OfferSelfTarget.selector);
        exchange.makeOffer(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att);
        vm.stopPrank();
    }

    function test_Offer_ReplaceRevertsForThirdParty() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.KycAttestation memory att = _attestReplaceOffer(carol, id, SELL_RWA, 800e6);
        vm.startPrank(carol);
        usdc.approve(address(exchange), 800e6);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.NotOfferParty.selector, id));
        exchange.replaceOffer(id, SELL_RWA, 800e6, 0, att);
        vm.stopPrank();
    }

    function test_Offer_AcceptRevertsIfProposerTriesToAcceptOwnOffer() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.KycAttestation memory att =
            _attestAcceptOffer(alice, id, SELL_RWA, WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.AcceptorIsProposer.selector, id));
        exchange.acceptOffer(id, att);
        vm.stopPrank();
    }

    function test_Offer_SettleRevertsBeforeAccept() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.KycAttestation memory makerAtt = _attest(alice, AsseteraExchange.Action.Settle, id);
        AsseteraExchange.KycAttestation memory takerAtt = _attest(bob,   AsseteraExchange.Action.Settle, id);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.OfferNotAccepted.selector, id));
        exchange.settleOffer(id, makerAtt, takerAtt);
    }

    function test_Offer_CancelRevertsAfterAccept() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);

        AsseteraExchange.KycAttestation memory acceptAtt =
            _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();

        AsseteraExchange.KycAttestation memory cancelAtt = _attest(alice, AsseteraExchange.Action.Cancel, id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.OfferNotOpen.selector, id));
        exchange.cancelOffer(id, cancelAtt);
    }

    function test_Offer_AcceptRevertsIfExpired() public {
        AsseteraExchange.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        uint64 expireTs = uint64(block.timestamp + 1 hours);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        uint256 id = exchange.makeOffer(bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, expireTs, att);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 hours);

        AsseteraExchange.KycAttestation memory acceptAtt =
            _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.OfferIsExpired.selector, id));
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();
    }

    function test_Offer_SettleRevertsIfMakerBlacklisted() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);

        AsseteraExchange.KycAttestation memory acceptAtt =
            _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();

        vm.prank(admin);
        exchange.setBlacklisted(keccak256(abi.encodePacked(alice)), true);

        AsseteraExchange.KycAttestation memory makerAtt = _attest(alice, AsseteraExchange.Action.Settle, id);
        AsseteraExchange.KycAttestation memory takerAtt = _attest(bob,   AsseteraExchange.Action.Settle, id);
        vm.prank(operator);
        vm.expectRevert(AsseteraExchange.AccountBlacklisted.selector);
        exchange.settleOffer(id, makerAtt, takerAtt);
    }

    function test_Offer_MakeRevertsOnWrongParamsHash() public {
        // Sign with mismatched takerAmount in paramsHash.
        bytes32 badHash = keccak256(abi.encodePacked(bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC + 1));
        AsseteraExchange.KycAttestation memory att =
            _signAtt(kycSignerPk, alice, AsseteraExchange.Action.MakeOffer, 0, _freshNonce(), block.timestamp + 3 minutes, badHash, 0, 0, address(0));
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(AsseteraExchange.ParamsHashMismatch.selector);
        exchange.makeOffer(bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att);
        vm.stopPrank();
    }

    function test_Offer_ReplaceRevertsOnWrongParamsHash() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        // Sign with a different newTakerAmount than what will be passed.
        bytes32 badHash = keccak256(abi.encodePacked(id, SELL_RWA, uint256(800e6 + 1)));
        AsseteraExchange.KycAttestation memory att =
            _signAtt(kycSignerPk, bob, AsseteraExchange.Action.ReplaceOffer, id, _freshNonce(), block.timestamp + 3 minutes, badHash, 0, 0, address(0));
        vm.startPrank(bob);
        usdc.approve(address(exchange), 800e6);
        vm.expectRevert(AsseteraExchange.ParamsHashMismatch.selector);
        exchange.replaceOffer(id, SELL_RWA, 800e6, 0, att);
        vm.stopPrank();
    }

    function test_Offer_AcceptRevertsOnWrongParamsHash() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        // Attestation signed with mismatched takerAmount.
        bytes32 badHash = keccak256(abi.encodePacked(id, SELL_RWA, WANT_USDC + 1));
        AsseteraExchange.KycAttestation memory att =
            _signAtt(kycSignerPk, bob, AsseteraExchange.Action.AcceptOffer, id, _freshNonce(), block.timestamp + 3 minutes, badHash, 0, 0, address(0));
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectRevert(AsseteraExchange.ParamsHashMismatch.selector);
        exchange.acceptOffer(id, att);
        vm.stopPrank();
    }

    function test_Offer_CancelRevertsOnWrongParamsHash() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        // Attestation signed with mismatched makerAmount.
        bytes32 badHash = keccak256(abi.encodePacked(id, SELL_RWA + 1, WANT_USDC));
        AsseteraExchange.KycAttestation memory att =
            _signAtt(kycSignerPk, alice, AsseteraExchange.Action.CancelOffer, id, _freshNonce(), block.timestamp + 3 minutes, badHash, 0, 0, address(0));
        vm.prank(alice);
        vm.expectRevert(AsseteraExchange.ParamsHashMismatch.selector);
        exchange.cancelOffer(id, att);
    }

    function test_Offer_SettleRevertsOnWrongParamsHash() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);

        AsseteraExchange.KycAttestation memory acceptAtt =
            _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();

        // Maker attestation signed with wrong takerAmount.
        bytes32 badHash = keccak256(abi.encodePacked(id, SELL_RWA, WANT_USDC + 1));
        AsseteraExchange.KycAttestation memory badMakerAtt =
            _signAtt(kycSignerPk, alice, AsseteraExchange.Action.SettleOffer, id, _freshNonce(), block.timestamp + 3 minutes, badHash, 0, 0, address(0));
        AsseteraExchange.KycAttestation memory takerAtt = _attestSettleOffer(bob, id, SELL_RWA, WANT_USDC);

        vm.prank(operator);
        vm.expectRevert(AsseteraExchange.ParamsHashMismatch.selector);
        exchange.settleOffer(id, badMakerAtt, takerAtt);
    }

    function test_Offer_CancelOffer_RejectsOrderCancelAttestation() public {
        // Cross-function replay guard: an Action.Cancel (order-level) attestation must not
        // authenticate cancelOffer even when offerId == orderId numerically.
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        // Sign with Action.Cancel (4) instead of Action.CancelOffer (8).
        AsseteraExchange.KycAttestation memory orderCancelAtt =
            _signAtt(kycSignerPk, alice, AsseteraExchange.Action.Cancel, id, _freshNonce(), block.timestamp + 3 minutes, bytes32(0), 0, 0, address(0));
        vm.prank(alice);
        // paramsHash content check fires first (hash=0 != expected); still proves isolation.
        vm.expectRevert(AsseteraExchange.ParamsHashMismatch.selector);
        exchange.cancelOffer(id, orderCancelAtt);
    }

    function test_Offer_SettleOffer_RejectsOrderSettleAttestation() public {
        // Cross-function replay guard: Action.Settle (order-level) attestations must not
        // authenticate settleOffer even when offerId == orderId numerically.
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.KycAttestation memory acceptAtt = _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();

        // Sign with Action.Settle (3) instead of Action.SettleOffer (9).
        AsseteraExchange.KycAttestation memory orderSettleAtt =
            _signAtt(kycSignerPk, alice, AsseteraExchange.Action.Settle, id, _freshNonce(), block.timestamp + 3 minutes, bytes32(0), 0, 0, address(0));
        AsseteraExchange.KycAttestation memory goodTakerAtt = _attestSettleOffer(bob, id, SELL_RWA, WANT_USDC);

        vm.prank(operator);
        vm.expectRevert(AsseteraExchange.KycActionMismatch.selector);
        exchange.settleOffer(id, orderSettleAtt, goodTakerAtt);
    }

    function test_Offer_MakeRevertsOnNonceReplay() public {
        AsseteraExchange.KycAttestation memory att =
            _attestMakeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA * 2);
        exchange.makeOffer(bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att);
        vm.expectRevert(AsseteraExchange.KycNonceUsed.selector);
        exchange.makeOffer(bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att);
        vm.stopPrank();
    }

    function test_Offer_SettleSecondKycFailDoesNotBurnFirstNonce() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);

        AsseteraExchange.KycAttestation memory acceptAtt =
            _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();

        AsseteraExchange.KycAttestation memory makerAtt = _attestSettleOffer(alice, id, SELL_RWA, WANT_USDC);
        AsseteraExchange.KycAttestation memory badTakerAtt =
            _signAtt(0xBAD, bob, AsseteraExchange.Action.SettleOffer, id, _freshNonce(), block.timestamp + 3 minutes, bytes32(0), 0, 0, address(0));

        vm.prank(operator);
        vm.expectRevert(AsseteraExchange.KycBadSigner.selector);
        exchange.settleOffer(id, makerAtt, badTakerAtt);

        // Alice's nonce must still be valid — retry with good taker attestation.
        AsseteraExchange.KycAttestation memory goodTakerAtt = _attestSettleOffer(bob, id, SELL_RWA, WANT_USDC);
        vm.prank(operator);
        exchange.settleOffer(id, makerAtt, goodTakerAtt);

        assertEq(uint8(exchange.getOffer(id).status), uint8(AsseteraExchange.OfferStatus.Settled));
    }

    function test_Offer_RevertsOnNonExistentOffer() public {
        AsseteraExchange.KycAttestation memory att = _attest(alice, AsseteraExchange.Action.Cancel, 999);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.OfferNotFound.selector, 999));
        exchange.cancelOffer(999, att);
    }

    // --- cancelOfferForUser ---

    function test_CancelOfferForUser_OpenOffer_ReturnsMakerEscrow() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);

        uint256 aliceBefore = rwa.balanceOf(alice);
        vm.prank(admin);
        exchange.cancelOfferForUser(id, alice, bob);

        assertEq(rwa.balanceOf(alice), aliceBefore + SELL_RWA);
        assertEq(uint8(exchange.getOffer(id).status), uint8(AsseteraExchange.OfferStatus.ForceCancelled));
    }

    function test_CancelOfferForUser_CounteredOffer_ReturnsTakerEscrow() public {
        // Bob counters: Bob's takerToken is now escrowed (proposedBy = bob).
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.KycAttestation memory replaceAtt =
            _attestReplaceOffer(bob, id, SELL_RWA, WANT_USDC * 2);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC * 2);
        exchange.replaceOffer(id, SELL_RWA, WANT_USDC * 2, 0, replaceAtt);
        vm.stopPrank();

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(admin);
        exchange.cancelOfferForUser(id, alice, bob);

        assertEq(usdc.balanceOf(bob), bobBefore + WANT_USDC * 2);
    }

    function test_CancelOfferForUser_AcceptedOffer_ReturnsBothEscrows() public {
        // The core scenario: both sides escrowed, maker is blacklisted post-accept,
        // settleOffer is blocked, and the only exit is cancelOfferForUser.
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.KycAttestation memory acceptAtt =
            _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();

        // Blacklist alice — settleOffer would now revert.
        vm.prank(admin);
        exchange.setBlacklisted(keccak256(abi.encodePacked(alice)), true);
        AsseteraExchange.KycAttestation memory makerAtt = _attestSettleOffer(alice, id, SELL_RWA, WANT_USDC);
        AsseteraExchange.KycAttestation memory takerAtt  = _attestSettleOffer(bob,   id, SELL_RWA, WANT_USDC);
        vm.prank(operator);
        vm.expectRevert(AsseteraExchange.AccountBlacklisted.selector);
        exchange.settleOffer(id, makerAtt, takerAtt);

        // Admin rescues both escrows to compliance-chosen addresses.
        uint256 aliceBefore = rwa.balanceOf(alice);
        uint256 bobBefore   = usdc.balanceOf(bob);
        vm.prank(admin);
        exchange.cancelOfferForUser(id, alice, bob);

        assertEq(rwa.balanceOf(alice),  aliceBefore + SELL_RWA);
        assertEq(usdc.balanceOf(bob),   bobBefore   + WANT_USDC);
        assertEq(uint8(exchange.getOffer(id).status), uint8(AsseteraExchange.OfferStatus.ForceCancelled));
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
        assertEq(uint8(exchange.getOffer(id).status), uint8(AsseteraExchange.OfferStatus.Expired));

        // Admin calling cancelOfferForUser on an Expired offer must revert.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.OfferNotOpen.selector, id));
        exchange.cancelOfferForUser(id, alice, bob);
    }

    function test_CancelOfferForUser_RevertsOnSettledOffer() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.KycAttestation memory acceptAtt =
            _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();

        AsseteraExchange.KycAttestation memory makerAtt = _attestSettleOffer(alice, id, SELL_RWA, WANT_USDC);
        AsseteraExchange.KycAttestation memory takerAtt  = _attestSettleOffer(bob,   id, SELL_RWA, WANT_USDC);
        vm.prank(operator);
        exchange.settleOffer(id, makerAtt, takerAtt);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.OfferNotOpen.selector, id));
        exchange.cancelOfferForUser(id, alice, bob);
    }

    function test_CancelOfferForUser_RevertsOnZeroRecipient() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.prank(admin);
        vm.expectRevert(AsseteraExchange.ZeroAddress.selector);
        exchange.cancelOfferForUser(id, address(0), bob);
    }

    function test_CancelOfferForUser_EmitsOfferForceCancelled() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        vm.prank(admin);
        vm.expectEmit(true, true, false, true);
        emit AsseteraExchange.OfferForceCancelled(id, alice, alice, bob, admin);
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
        assertEq(uint8(exchange.getOffer(id).status), uint8(AsseteraExchange.OfferStatus.Expired));
    }

    function test_SweepExpiredOffers_CounteredOffer_ReturnsTakerEscrow() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);
        uint256 id = _makeOfferWithExpiry(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, expiry);

        // Bob counters — Bob's takerToken is now escrowed, new expiry set by Bob.
        uint64 newExpiry = uint64(block.timestamp + 2 hours);
        AsseteraExchange.KycAttestation memory replaceAtt =
            _attestReplaceOffer(bob, id, SELL_RWA, WANT_USDC * 2);
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
        assertEq(uint8(exchange.getOffer(id).status), uint8(AsseteraExchange.OfferStatus.Expired));
    }

    function test_SweepExpiredOffers_SkipsNonExpired() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);
        uint256 id = _makeOfferWithExpiry(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, expiry);

        // Not yet expired — should be a no-op.
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        exchange.sweepExpiredOffers(ids);

        assertEq(uint8(exchange.getOffer(id).status), uint8(AsseteraExchange.OfferStatus.Open));
    }

    function test_SweepExpiredOffers_SkipsNoExpiry() public {
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC); // expireTs=0

        vm.warp(block.timestamp + 365 days);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        exchange.sweepExpiredOffers(ids);

        assertEq(uint8(exchange.getOffer(id).status), uint8(AsseteraExchange.OfferStatus.Open));
    }

    function test_SweepExpiredOffers_SkipsBlacklistedProposer() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);
        uint256 id = _makeOfferWithExpiry(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, expiry);

        vm.prank(admin);
        exchange.setBlacklisted(keccak256(abi.encodePacked(alice)), true);

        vm.warp(block.timestamp + 1 hours + 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        exchange.sweepExpiredOffers(ids); // silent skip

        // Tokens still in contract — admin must use cancelOfferForUser.
        assertEq(uint8(exchange.getOffer(id).status), uint8(AsseteraExchange.OfferStatus.Open));
    }

    function test_SweepExpiredOffers_SkipsAcceptedOffer() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);
        uint256 id = _makeOfferWithExpiry(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, expiry);

        // Bob accepts before expiry.
        AsseteraExchange.KycAttestation memory acceptAtt =
            _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours + 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        exchange.sweepExpiredOffers(ids); // silent skip — Accepted is not Open/Countered

        assertEq(uint8(exchange.getOffer(id).status), uint8(AsseteraExchange.OfferStatus.Accepted));
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
        emit AsseteraExchange.OfferExpired(id, alice, SELL_RWA);
        exchange.sweepExpiredOffers(ids);
    }

    // ===================================================================== //
    //     fee snapshotting, allowlist, deduction, rounding                   //
    // ===================================================================== //

    // Helper: place RWA-for-USDC with explicit fee params; assumes collector already allowlisted.
    function _placeRwaForUsdcWithFee(
        address maker,
        uint16 makerFeeBps,
        uint16 takerFeeBps,
        address feeCollector
    ) internal returns (uint256 id) {
        AsseteraExchange.KycAttestation memory att =
            _attestPlaceWithFee(maker, address(rwa), SELL_RWA, address(usdc), WANT_USDC, makerFeeBps, takerFeeBps, feeCollector);
        vm.startPrank(maker);
        rwa.approve(address(exchange), SELL_RWA);
        id = exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att);
        vm.stopPrank();
    }

    // --- collector allowlist --------------------------------------------- //

    function test_Fee_CollectorNotAllowlisted_Reverts() public {
        // carol is not in the allowlist — placing an order with her as collector must revert.
        AsseteraExchange.KycAttestation memory att =
            _attestPlaceWithFee(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 50, 30, carol);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.FeeCollectorNotAllowed.selector, carol));
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att);
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
            _attestPlaceWithFee(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 50, 30, carol);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.FeeCollectorNotAllowed.selector, carol));
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att);
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
        _placeRwaForUsdc(alice); // uses _attestPlace which sends 0 fees and address(0) collector
    }

    function test_Fee_NonZeroFeeWithZeroCollectorReverts() public {
        AsseteraExchange.KycAttestation memory att =
            _attestPlaceWithFee(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 50, 0, address(0));
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(AsseteraExchange.ZeroAddress.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att);
        vm.stopPrank();
    }

    function test_Fee_InvalidFee_Reverts() public {
        // makerFeeBps > 10_000 must revert.
        AsseteraExchange.KycAttestation memory att =
            _attestPlaceWithFee(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 10_001, 0, carol);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(AsseteraExchange.InvalidFee.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att);
        vm.stopPrank();
    }

    function test_Fee_EmitsCollectorAllowed() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit AsseteraExchange.CollectorAllowed(carol, true);
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
        assertEq(o.makerFeeBps,  50);
        assertEq(o.takerFeeBps,  30);
        assertEq(o.feeCollector, carol);

        // Revoke carol from allowlist.
        vm.prank(admin);
        exchange.setAllowedCollector(carol, false);

        // Fill should still work using the snapshotted fees/collector.
        uint256 carolUsdc = usdc.balanceOf(carol);
        uint256 carolRwa  = rwa.balanceOf(carol);
        AsseteraExchange.KycAttestation memory att = _attest(bob, AsseteraExchange.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.fillOrder(id, SELL_RWA, att);
        vm.stopPrank();

        // Carol received fees even after allowlist removal.
        assertGt(usdc.balanceOf(carol), carolUsdc); // makerFee in USDC
        assertGt(rwa.balanceOf(carol),  carolRwa);  // takerFee in RWA
    }

    // --- fill fee deduction ---------------------------------------------- //

    function test_Fee_Fill_MakerAndTakerFeesDeducted() public {
        // makerFeeBps = 50 (0.5%) on buyToken (USDC), takerFeeBps = 30 (0.3%) on sellToken (RWA).
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        uint256 id = _placeRwaForUsdcWithFee(alice, 50, 30, carol);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 bobRwaBefore    = rwa.balanceOf(bob);
        uint256 carolUsdcBefore = usdc.balanceOf(carol);
        uint256 carolRwaBefore  = rwa.balanceOf(carol);

        AsseteraExchange.KycAttestation memory att = _attest(bob, AsseteraExchange.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.fillOrder(id, SELL_RWA, att);
        vm.stopPrank();

        // Expected fee amounts.
        uint256 expectedMakerFee = (WANT_USDC * 50) / 10_000; // 0.5% of 1000 USDC = 5 USDC
        uint256 expectedTakerFee = (SELL_RWA * 30) / 10_000;  // 0.3% of 10 RWA = 0.03 RWA

        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + WANT_USDC - expectedMakerFee, "maker USDC net");
        assertEq(rwa.balanceOf(bob),    bobRwaBefore    + SELL_RWA  - expectedTakerFee,  "taker RWA net");
        assertEq(usdc.balanceOf(carol), carolUsdcBefore + expectedMakerFee,               "collector makerFee");
        assertEq(rwa.balanceOf(carol),  carolRwaBefore  + expectedTakerFee,               "collector takerFee");
    }

    function test_Fee_Fill_ZeroFees_NoCollectorTransfer() public {
        uint256 id = _placeRwaForUsdc(alice); // zero fees

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 bobRwaBefore    = rwa.balanceOf(bob);

        AsseteraExchange.KycAttestation memory att = _attest(bob, AsseteraExchange.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.fillOrder(id, SELL_RWA, att);
        vm.stopPrank();

        // Full amounts reach maker and taker — no deduction.
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + WANT_USDC);
        assertEq(rwa.balanceOf(bob),    bobRwaBefore    + SELL_RWA);
    }

    function test_Fee_Fill_OnlyMakerFee() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        uint256 id = _placeRwaForUsdcWithFee(alice, 100, 0, carol); // 1% maker, 0 taker

        uint256 carolUsdcBefore = usdc.balanceOf(carol);
        uint256 carolRwaBefore  = rwa.balanceOf(carol);

        AsseteraExchange.KycAttestation memory att = _attest(bob, AsseteraExchange.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.fillOrder(id, SELL_RWA, att);
        vm.stopPrank();

        uint256 expectedMakerFee = (WANT_USDC * 100) / 10_000;
        assertEq(usdc.balanceOf(carol), carolUsdcBefore + expectedMakerFee, "makerFee in USDC");
        assertEq(rwa.balanceOf(carol),  carolRwaBefore,                     "no takerFee (RWA)");
    }

    function test_Fee_Fill_OnlyTakerFee() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        uint256 id = _placeRwaForUsdcWithFee(alice, 0, 100, carol); // 0 maker, 1% taker

        uint256 carolUsdcBefore = usdc.balanceOf(carol);
        uint256 carolRwaBefore  = rwa.balanceOf(carol);

        AsseteraExchange.KycAttestation memory att = _attest(bob, AsseteraExchange.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.fillOrder(id, SELL_RWA, att);
        vm.stopPrank();

        uint256 expectedTakerFee = (SELL_RWA * 100) / 10_000;
        assertEq(usdc.balanceOf(carol), carolUsdcBefore,                    "no makerFee (USDC)");
        assertEq(rwa.balanceOf(carol),  carolRwaBefore + expectedTakerFee,  "takerFee in RWA");
    }

    function test_Fee_PartialFill_FeesProportional() public {
        // Fill half the order — fees apply proportionally to the filled portion only.
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        uint256 id = _placeRwaForUsdcWithFee(alice, 50, 30, carol);

        uint256 halfRwa  = SELL_RWA / 2;
        uint256 halfUsdc = (halfRwa * WANT_USDC + SELL_RWA - 1) / SELL_RWA; // ceiling

        uint256 carolUsdcBefore = usdc.balanceOf(carol);
        uint256 carolRwaBefore  = rwa.balanceOf(carol);

        AsseteraExchange.KycAttestation memory att = _attest(bob, AsseteraExchange.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), halfUsdc);
        exchange.fillOrder(id, halfRwa, att);
        vm.stopPrank();

        uint256 expectedMakerFee = (halfUsdc * 50) / 10_000;
        uint256 expectedTakerFee = (halfRwa  * 30) / 10_000;

        assertEq(usdc.balanceOf(carol), carolUsdcBefore + expectedMakerFee);
        assertEq(rwa.balanceOf(carol),  carolRwaBefore  + expectedTakerFee);
        // Order stays Open.
        assertEq(uint8(exchange.getOrder(id).status), uint8(AsseteraExchange.OrderStatus.Open));
    }

    function test_Fee_Fill_Rounding_FloorFavorsMakerAndTaker() public {
        // 1 bps on 1 wei = 0.0001 wei → floored to 0; collector receives nothing.
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        AsseteraExchange.KycAttestation memory placeAtt =
            _attestPlaceWithFee(alice, address(rwa), 1, address(usdc), 1, 1, 1, carol);
        vm.startPrank(alice);
        rwa.approve(address(exchange), 1);
        uint256 id = exchange.placeOrder(address(rwa), 1, address(usdc), 1, 0, placeAtt);
        vm.stopPrank();

        uint256 carolUsdcBefore = usdc.balanceOf(carol);
        uint256 carolRwaBefore  = rwa.balanceOf(carol);

        vm.prank(admin);
        exchange.setComplianceRequired(AsseteraExchange.Action.Fill, false);

        AsseteraExchange.KycAttestation memory empty;
        vm.startPrank(bob);
        usdc.approve(address(exchange), 1);
        exchange.fillOrder(id, 1, empty);
        vm.stopPrank();

        // (1 * 1) / 10_000 = 0 — floor division, collector receives nothing.
        assertEq(usdc.balanceOf(carol), carolUsdcBefore, "no USDC fee (floored to 0)");
        assertEq(rwa.balanceOf(carol),  carolRwaBefore,  "no RWA fee (floored to 0)");
    }

    // --- settle fee deduction -------------------------------------------- //

    function test_Fee_Settle_BothOrdersHaveFees() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        // Alice sells RWA for USDC with 50 bps maker fee.
        uint256 a = _placeRwaForUsdcWithFee(alice, 50, 0, carol); // a.makerFeeBps=50
        // Bob sells USDC for RWA with 30 bps maker fee.
        AsseteraExchange.KycAttestation memory bAtt =
            _attestPlaceWithFee(bob, address(usdc), WANT_USDC, address(rwa), SELL_RWA, 30, 0, carol);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        uint256 b = exchange.placeOrder(address(usdc), WANT_USDC, address(rwa), SELL_RWA, 0, bAtt);
        vm.stopPrank();

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 bobRwaBefore    = rwa.balanceOf(bob);
        uint256 carolUsdcBefore = usdc.balanceOf(carol);
        uint256 carolRwaBefore  = rwa.balanceOf(carol);

        AsseteraExchange.KycAttestation memory attA = _attest(alice, AsseteraExchange.Action.Settle, a);
        AsseteraExchange.KycAttestation memory attB = _attest(bob,   AsseteraExchange.Action.Settle, b);
        vm.prank(operator);
        exchange.settle(a, b, attA, attB);

        // a.makerFeeBps=50 on what alice receives (WANT_USDC of b.sellToken = USDC).
        uint256 aliceFee = (WANT_USDC * 50) / 10_000;
        // b.makerFeeBps=30 on what bob receives (SELL_RWA of a.sellToken = RWA).
        uint256 bobFee   = (SELL_RWA  * 30) / 10_000;

        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + WANT_USDC - aliceFee, "alice USDC net");
        assertEq(rwa.balanceOf(bob),    bobRwaBefore    + SELL_RWA  - bobFee,   "bob RWA net");
        assertEq(usdc.balanceOf(carol), carolUsdcBefore + aliceFee,             "carol USDC fee");
        assertEq(rwa.balanceOf(carol),  carolRwaBefore  + bobFee,               "carol RWA fee");
    }

    function test_Fee_Settle_ZeroFees_NoCollectorTransfer() public {
        uint256 a = _placeRwaForUsdc(alice);
        uint256 b = _placeUsdcForRwa(bob, WANT_USDC, SELL_RWA);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 bobRwaBefore    = rwa.balanceOf(bob);

        AsseteraExchange.KycAttestation memory attA = _attest(alice, AsseteraExchange.Action.Settle, a);
        AsseteraExchange.KycAttestation memory attB = _attest(bob,   AsseteraExchange.Action.Settle, b);
        vm.prank(operator);
        exchange.settle(a, b, attA, attB);

        // Zero fees — full amounts reach both makers.
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + WANT_USDC);
        assertEq(rwa.balanceOf(bob),    bobRwaBefore    + SELL_RWA);
    }

    function test_Fee_Settle_DifferentCollectors() public {
        // alice's order → collector carol; bob's order → collector alice (edge case).
        vm.startPrank(admin);
        exchange.setAllowedCollector(carol, true);
        exchange.setAllowedCollector(alice, true);
        vm.stopPrank();

        uint256 a = _placeRwaForUsdcWithFee(alice, 100, 0, carol);
        AsseteraExchange.KycAttestation memory bAtt =
            _attestPlaceWithFee(bob, address(usdc), WANT_USDC, address(rwa), SELL_RWA, 100, 0, alice);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        uint256 b = exchange.placeOrder(address(usdc), WANT_USDC, address(rwa), SELL_RWA, 0, bAtt);
        vm.stopPrank();

        uint256 carolUsdcBefore = usdc.balanceOf(carol); // gets alice's fee (buyToken = USDC)
        uint256 aliceRwaBefore  = rwa.balanceOf(alice);  // gets bob's fee (sellToken = RWA) + is maker

        AsseteraExchange.KycAttestation memory attA = _attest(alice, AsseteraExchange.Action.Settle, a);
        AsseteraExchange.KycAttestation memory attB = _attest(bob,   AsseteraExchange.Action.Settle, b);
        vm.prank(operator);
        exchange.settle(a, b, attA, attB);

        // a.makerFeeBps=100 on what alice RECEIVES = settleB (WANT_USDC of b.sellToken=USDC) → to carol
        // b.makerFeeBps=100 on what bob   RECEIVES = settleA (SELL_RWA  of a.sellToken=RWA)  → to alice (b.feeCollector)
        uint256 aliceFee = (WANT_USDC * 100) / 10_000;
        uint256 bobFee   = (SELL_RWA  * 100) / 10_000;

        assertEq(usdc.balanceOf(carol), carolUsdcBefore + aliceFee, "carol receives USDC makerFee from alice's order");
        assertEq(rwa.balanceOf(alice),  aliceRwaBefore  + bobFee,   "alice receives RWA makerFee as bob's collector");
        assertEq(uint8(exchange.getOrder(a).status), uint8(AsseteraExchange.OrderStatus.Settled));
        assertEq(uint8(exchange.getOrder(b).status), uint8(AsseteraExchange.OrderStatus.Settled));
    }

    // --- validation: takerFeeBps > MAX ----------------------------------- //

    function test_Fee_InvalidFee_TakerBpsExceedsMax_Reverts() public {
        // takerFeeBps > 10_000 must also revert (right branch of the || condition).
        AsseteraExchange.KycAttestation memory att =
            _attestPlaceWithFee(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, 10_001, carol);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(AsseteraExchange.InvalidFee.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att);
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
            _attestPlaceWithFee(maker, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 50, 30, carol);
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(rwa, pk, maker, address(exchange), SELL_RWA, dl);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.FeeCollectorNotAllowed.selector, carol));
        exchange.placeOrderWithPermit(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, dl, v, r, s, att);

        // Happy: allowlist carol, then permit + fees succeed.
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);
        // Fresh attestation (new nonce) and fresh permit sig (ERC-2612 nonce still 0 since first call reverted).
        att = _attestPlaceWithFee(maker, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 50, 30, carol);
        (v, r, s) = _signPermit(rwa, pk, maker, address(exchange), SELL_RWA, dl);
        vm.prank(maker);
        uint256 id = exchange.placeOrderWithPermit(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, dl, v, r, s, att);
        AsseteraExchange.Order memory o = exchange.getOrder(id);
        assertEq(o.makerFeeBps,  50,   "makerFeeBps snapshotted");
        assertEq(o.takerFeeBps,  30,   "takerFeeBps snapshotted");
        assertEq(o.feeCollector, carol, "feeCollector snapshotted");
    }

    // --- event fields ---------------------------------------------------- //

    function test_Fee_Fill_EmitsOrderFilledWithFeeFields() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);
        uint256 id = _placeRwaForUsdcWithFee(alice, 50, 30, carol);

        uint256 expectedMakerFee = (WANT_USDC * 50) / 10_000;
        uint256 expectedTakerFee = (SELL_RWA  * 30) / 10_000;

        AsseteraExchange.KycAttestation memory att = _attest(bob, AsseteraExchange.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        vm.expectEmit(true, true, true, true);
        emit AsseteraExchange.OrderFilled(id, alice, bob, SELL_RWA, WANT_USDC, expectedMakerFee, expectedTakerFee, carol);
        exchange.fillOrder(id, SELL_RWA, att);
        vm.stopPrank();
    }

    function test_Fee_PartialFill_EmitsOrderPartiallyFilledWithFeeFields() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);
        uint256 id = _placeRwaForUsdcWithFee(alice, 50, 30, carol);

        uint256 halfRwa       = SELL_RWA / 2;
        uint256 halfUsdc      = (halfRwa * WANT_USDC + SELL_RWA - 1) / SELL_RWA;
        uint256 expectedMakerFee  = (halfUsdc * 50) / 10_000;
        uint256 expectedTakerFee  = (halfRwa  * 30) / 10_000;
        uint256 expectedRemaining = SELL_RWA - halfRwa;

        AsseteraExchange.KycAttestation memory att = _attest(bob, AsseteraExchange.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), halfUsdc);
        vm.expectEmit(true, true, true, true);
        emit AsseteraExchange.OrderPartiallyFilled(id, alice, bob, halfRwa, expectedRemaining, expectedMakerFee, expectedTakerFee, carol);
        exchange.fillOrder(id, halfRwa, att);
        vm.stopPrank();
    }

    function test_Fee_Settle_EmitsOrderSettledWithFeeFields() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        uint256 a = _placeRwaForUsdcWithFee(alice, 50, 0, carol);
        AsseteraExchange.KycAttestation memory bAtt =
            _attestPlaceWithFee(bob, address(usdc), WANT_USDC, address(rwa), SELL_RWA, 30, 0, carol);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        uint256 b = exchange.placeOrder(address(usdc), WANT_USDC, address(rwa), SELL_RWA, 0, bAtt);
        vm.stopPrank();

        // buyMakerFeeAmount: a.makerFeeBps on what alice receives (settleB = WANT_USDC of b.sellToken).
        uint256 buyMakerFee  = (WANT_USDC * 50) / 10_000;
        // sellMakerFeeAmount: b.makerFeeBps on what bob receives (settleA = SELL_RWA of a.sellToken).
        uint256 sellMakerFee = (SELL_RWA  * 30) / 10_000;

        AsseteraExchange.KycAttestation memory attA = _attest(alice, AsseteraExchange.Action.Settle, a);
        AsseteraExchange.KycAttestation memory attB = _attest(bob,   AsseteraExchange.Action.Settle, b);
        vm.prank(operator);
        vm.expectEmit(true, true, true, true);
        emit AsseteraExchange.OrderSettled(a, b, operator, SELL_RWA, WANT_USDC, buyMakerFee, sellMakerFee, carol, carol);
        exchange.settle(a, b, attA, attB);
    }

    // --- sequential partial fills ---------------------------------------- //

    function test_Fee_TwoSequentialPartialFills_FeesAccumulate() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);
        uint256 id = _placeRwaForUsdcWithFee(alice, 50, 30, carol);

        uint256 halfRwa  = SELL_RWA / 2;
        uint256 halfUsdc = (halfRwa * WANT_USDC + SELL_RWA - 1) / SELL_RWA;

        uint256 carolUsdcBefore = usdc.balanceOf(carol);
        uint256 carolRwaBefore  = rwa.balanceOf(carol);

        // First half.
        AsseteraExchange.KycAttestation memory att1 = _attest(bob, AsseteraExchange.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC); // covers both fills
        exchange.fillOrder(id, halfRwa, att1);
        vm.stopPrank();

        assertEq(uint8(exchange.getOrder(id).status), uint8(AsseteraExchange.OrderStatus.Open), "still open");

        // Second half (clears the order).
        AsseteraExchange.KycAttestation memory att2 = _attest(bob, AsseteraExchange.Action.Fill, id);
        vm.prank(bob);
        exchange.fillOrder(id, halfRwa, att2);

        assertEq(uint8(exchange.getOrder(id).status), uint8(AsseteraExchange.OrderStatus.Filled), "fully filled");

        uint256 totalMakerFee = (halfUsdc * 50) / 10_000 + (halfUsdc * 50) / 10_000;
        uint256 totalTakerFee = (halfRwa  * 30) / 10_000 + (halfRwa  * 30) / 10_000;

        assertEq(usdc.balanceOf(carol), carolUsdcBefore + totalMakerFee, "accumulated makerFee USDC");
        assertEq(rwa.balanceOf(carol),  carolRwaBefore  + totalTakerFee, "accumulated takerFee RWA");
    }

    // --- settle: one order with fee, one without ------------------------- //

    function test_Fee_Settle_OnlyOneOrderHasFee() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        uint256 a = _placeRwaForUsdcWithFee(alice, 50, 0, carol);
        uint256 b = _placeUsdcForRwa(bob, WANT_USDC, SELL_RWA); // zero fees

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 bobRwaBefore    = rwa.balanceOf(bob);
        uint256 carolUsdcBefore = usdc.balanceOf(carol);
        uint256 carolRwaBefore  = rwa.balanceOf(carol);

        AsseteraExchange.KycAttestation memory attA = _attest(alice, AsseteraExchange.Action.Settle, a);
        AsseteraExchange.KycAttestation memory attB = _attest(bob,   AsseteraExchange.Action.Settle, b);
        vm.prank(operator);
        exchange.settle(a, b, attA, attB);

        uint256 aliceFee = (WANT_USDC * 50) / 10_000;

        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + WANT_USDC - aliceFee, "alice net USDC");
        assertEq(rwa.balanceOf(bob),    bobRwaBefore    + SELL_RWA,              "bob full RWA (no fee)");
        assertEq(usdc.balanceOf(carol), carolUsdcBefore + aliceFee,              "carol receives alice's fee");
        assertEq(rwa.balanceOf(carol),  carolRwaBefore,                          "carol RWA unchanged (no bob fee)");
    }

    // --- settle: takerFeeBps is NOT applied in the settle path ----------- //

    function test_Fee_Settle_TakerBpsIgnored() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        // Both orders carry a non-zero takerFeeBps; settle must not deduct it.
        uint256 a = _placeRwaForUsdcWithFee(alice, 50, 200, carol);
        AsseteraExchange.KycAttestation memory bAtt =
            _attestPlaceWithFee(bob, address(usdc), WANT_USDC, address(rwa), SELL_RWA, 30, 200, carol);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        uint256 b = exchange.placeOrder(address(usdc), WANT_USDC, address(rwa), SELL_RWA, 0, bAtt);
        vm.stopPrank();

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 bobRwaBefore    = rwa.balanceOf(bob);

        AsseteraExchange.KycAttestation memory attA = _attest(alice, AsseteraExchange.Action.Settle, a);
        AsseteraExchange.KycAttestation memory attB = _attest(bob,   AsseteraExchange.Action.Settle, b);
        vm.prank(operator);
        exchange.settle(a, b, attA, attB);

        // Only makerFeeBps deducted — takerFeeBps (200) must be ignored in the settle path.
        uint256 aliceFee = (WANT_USDC * 50) / 10_000;
        uint256 bobFee   = (SELL_RWA  * 30) / 10_000;

        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + WANT_USDC - aliceFee, "alice: only makerFee deducted");
        assertEq(rwa.balanceOf(bob),    bobRwaBefore    + SELL_RWA  - bobFee,   "bob: only makerFee deducted");
    }

    // --- fee field tamper → signature verification fails ---------------- //

    function test_Fee_TamperedFeeBps_Reverts() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        // Sign with makerFeeBps = 50, then inflate it after signing.
        AsseteraExchange.KycAttestation memory att =
            _attestPlaceWithFee(alice, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 50, 30, carol);
        att.makerFeeBps = 5_000; // tamper — sig now covers a different struct hash

        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(AsseteraExchange.KycBadSigner.selector);
        exchange.placeOrder(address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att);
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
        uint256 bobRwaBefore    = rwa.balanceOf(bob);

        AsseteraExchange.KycAttestation memory att = _attest(bob, AsseteraExchange.Action.Fill, id);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.fillOrder(id, SELL_RWA, att);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), aliceUsdcBefore,             "maker receives 0 (100% fee)");
        assertEq(usdc.balanceOf(carol), carolUsdcBefore + WANT_USDC, "collector receives 100% of buyToken");
        assertEq(rwa.balanceOf(bob),    bobRwaBefore    + SELL_RWA,  "taker receives full sellToken (zero taker fee)");
    }

    // --- offer fee deduction (v3.1.0) ------------------------------------ //

    function test_Offer_Fee_CollectorNotAllowlisted_Reverts() public {
        AsseteraExchange.KycAttestation memory att =
            _attestMakeOfferWithFee(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 100, 50, carol);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(abi.encodeWithSelector(AsseteraExchange.FeeCollectorNotAllowed.selector, carol));
        exchange.makeOffer(bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att);
        vm.stopPrank();
    }

    function test_Offer_Fee_InvalidFee_Reverts() public {
        uint16 tooHigh = uint16(AsseteraExchange(address(exchange)).MAX_FEE_BPS()) + 1;
        AsseteraExchange.KycAttestation memory att =
            _attestMakeOfferWithFee(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, tooHigh, 0, carol);
        vm.startPrank(alice);
        rwa.approve(address(exchange), SELL_RWA);
        vm.expectRevert(AsseteraExchange.InvalidFee.selector);
        exchange.makeOffer(bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, att);
        vm.stopPrank();
    }

    function test_Offer_Fee_ZeroFees_NoCollectorRequired() public {
        // Zero fees should succeed without an allowlisted collector (matches order behaviour).
        uint256 id = _makeOffer(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC);
        AsseteraExchange.Offer memory o = exchange.getOffer(id);
        assertEq(o.makerFeeBps,  0);
        assertEq(o.takerFeeBps,  0);
        assertEq(o.feeCollector, address(0));
    }

    function test_Offer_Fee_StoredInStruct() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);
        uint256 id = _makeOfferWithFee(alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 100, 50, carol);
        AsseteraExchange.Offer memory o = exchange.getOffer(id);
        assertEq(o.makerFeeBps,  100,  "makerFeeBps stored");
        assertEq(o.takerFeeBps,  50,   "takerFeeBps stored");
        assertEq(o.feeCollector, carol, "feeCollector stored");
    }

    function test_Offer_Fee_MakeAcceptSettle_FeesDeducted() public {
        // makerFeeBps=100 (1%) applied to what maker receives (USDC = takerAmount).
        // takerFeeBps=50  (0.5%) applied to what taker receives (RWA = makerAmount).
        uint16 makerFeeBps = 100;
        uint16 takerFeeBps = 50;

        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        uint256 id = _makeOfferWithFee(
            alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC,
            makerFeeBps, takerFeeBps, carol
        );

        // Bob accepts: escrows USDC.
        AsseteraExchange.KycAttestation memory acceptAtt =
            _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 bobRwaBefore    = rwa.balanceOf(bob);
        uint256 carolUsdcBefore = usdc.balanceOf(carol);
        uint256 carolRwaBefore  = rwa.balanceOf(carol);

        // Operator settles.
        AsseteraExchange.KycAttestation memory makerAtt = _attestSettleOffer(alice, id, SELL_RWA, WANT_USDC);
        AsseteraExchange.KycAttestation memory takerAtt = _attestSettleOffer(bob,   id, SELL_RWA, WANT_USDC);
        vm.prank(operator);
        exchange.settleOffer(id, makerAtt, takerAtt);

        uint256 makerFeeAmt = (WANT_USDC * makerFeeBps) / 10_000;
        uint256 takerFeeAmt = (SELL_RWA  * takerFeeBps) / 10_000;

        assertEq(uint8(exchange.getOffer(id).status), uint8(AsseteraExchange.OfferStatus.Settled));
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + WANT_USDC - makerFeeAmt, "maker receives USDC minus fee");
        assertEq(rwa.balanceOf(bob),    bobRwaBefore    + SELL_RWA  - takerFeeAmt, "taker receives RWA minus fee");
        assertEq(usdc.balanceOf(carol), carolUsdcBefore + makerFeeAmt,             "carol receives maker fee in USDC");
        assertEq(rwa.balanceOf(carol),  carolRwaBefore  + takerFeeAmt,             "carol receives taker fee in RWA");
        assertEq(rwa.balanceOf(address(exchange)),  0, "exchange holds no RWA");
        assertEq(usdc.balanceOf(address(exchange)), 0, "exchange holds no USDC");
    }

    function test_Offer_Fee_OnlyMakerFee() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        uint256 id = _makeOfferWithFee(
            alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 200, 0, carol
        );
        AsseteraExchange.KycAttestation memory acceptAtt =
            _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();

        uint256 bobRwaBefore   = rwa.balanceOf(bob);
        uint256 carolUsdcBefore = usdc.balanceOf(carol);
        uint256 carolRwaBefore  = rwa.balanceOf(carol);

        AsseteraExchange.KycAttestation memory makerAtt = _attestSettleOffer(alice, id, SELL_RWA, WANT_USDC);
        AsseteraExchange.KycAttestation memory takerAtt = _attestSettleOffer(bob,   id, SELL_RWA, WANT_USDC);
        vm.prank(operator);
        exchange.settleOffer(id, makerAtt, takerAtt);

        uint256 makerFeeAmt = (WANT_USDC * 200) / 10_000;
        assertEq(usdc.balanceOf(carol) - carolUsdcBefore, makerFeeAmt, "carol gets maker fee in USDC");
        assertEq(rwa.balanceOf(carol)  - carolRwaBefore,  0,           "carol gets no RWA (no taker fee)");
        assertEq(rwa.balanceOf(bob),    bobRwaBefore + SELL_RWA,       "taker receives full RWA");
    }

    function test_Offer_Fee_OnlyTakerFee() public {
        vm.prank(admin);
        exchange.setAllowedCollector(carol, true);

        uint256 id = _makeOfferWithFee(
            alice, bob, address(rwa), SELL_RWA, address(usdc), WANT_USDC, 0, 150, carol
        );
        AsseteraExchange.KycAttestation memory acceptAtt =
            _attestAcceptOffer(bob, id, SELL_RWA, WANT_USDC);
        vm.startPrank(bob);
        usdc.approve(address(exchange), WANT_USDC);
        exchange.acceptOffer(id, acceptAtt);
        vm.stopPrank();

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 carolRwaBefore  = rwa.balanceOf(carol);
        uint256 carolUsdcBefore = usdc.balanceOf(carol);

        AsseteraExchange.KycAttestation memory makerAtt = _attestSettleOffer(alice, id, SELL_RWA, WANT_USDC);
        AsseteraExchange.KycAttestation memory takerAtt = _attestSettleOffer(bob,   id, SELL_RWA, WANT_USDC);
        vm.prank(operator);
        exchange.settleOffer(id, makerAtt, takerAtt);

        uint256 takerFeeAmt = (SELL_RWA * 150) / 10_000;
        assertEq(rwa.balanceOf(carol)  - carolRwaBefore,  takerFeeAmt, "carol gets taker fee in RWA");
        assertEq(usdc.balanceOf(carol) - carolUsdcBefore, 0,           "carol gets no USDC (no maker fee)");
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + WANT_USDC,   "maker receives full USDC");
    }

    // --- permit helper ---
    function _signPermit(
        FaucetToken token,
        uint256 ownerPk,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 PERMIT_TYPEHASH =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        uint256 nonce = token.nonces(owner);
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(ownerPk, digest);
    }
}
