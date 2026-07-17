// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FaucetToken} from "./mocks/FaucetToken.sol";

contract FaucetTokenTest is Test {
    FaucetToken internal usdc; // 6 decimals
    FaucetToken internal rwa; // 18 decimals

    address internal alice = makeAddr("alice");

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function setUp() public {
        usdc = new FaucetToken("Mock USD Coin", "mUSDC", 6);
        rwa = new FaucetToken("Mock RWA Token", "mRWA", 18);
    }

    function test_Metadata() public view {
        assertEq(usdc.name(), "Mock USD Coin");
        assertEq(usdc.symbol(), "mUSDC");
        assertEq(usdc.decimals(), 6);
        assertEq(rwa.decimals(), 18);
    }

    function test_Mint() public {
        usdc.mint(alice, 1_000e6);
        assertEq(usdc.balanceOf(alice), 1_000e6);
        assertEq(usdc.totalSupply(), 1_000e6);
    }

    function test_Drip_MintsToCaller() public {
        vm.prank(alice);
        rwa.drip(5e18);
        assertEq(rwa.balanceOf(alice), 5e18);
    }

    function testFuzz_Mint(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, 1e30);
        usdc.mint(to, amount);
        assertEq(usdc.balanceOf(to), amount);
    }

    function test_Permit_SetsAllowance() public {
        uint256 ownerPk = 0xA11CE;
        address owner = vm.addr(ownerPk);
        address spender = makeAddr("spender");
        uint256 value = 100e6;
        uint256 deadline = block.timestamp + 1 days;

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(usdc, ownerPk, owner, spender, value, deadline);
        usdc.permit(owner, spender, value, deadline, v, r, s);

        assertEq(usdc.allowance(owner, spender), value);
        assertEq(usdc.nonces(owner), 1);
    }

    function test_Permit_RevertsOnExpiredDeadline() public {
        uint256 ownerPk = 0xA11CE;
        address owner = vm.addr(ownerPk);
        address spender = makeAddr("spender");
        uint256 deadline = block.timestamp - 1;

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(usdc, ownerPk, owner, spender, 1e6, deadline);
        vm.expectRevert();
        usdc.permit(owner, spender, 1e6, deadline, v, r, s);
    }

    // --- helper -------------------------------------------------------------

    function _signPermit(
        FaucetToken token,
        uint256 ownerPk,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        uint256 nonce = token.nonces(owner);
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(ownerPk, digest);
    }
}
