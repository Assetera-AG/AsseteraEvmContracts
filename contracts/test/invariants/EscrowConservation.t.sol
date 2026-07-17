// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AsseteraExchange} from "../../src/AsseteraExchange.sol";
import {ExchangeTypes} from "../../src/types/ExchangeTypes.sol";
import {FaucetToken} from "../mocks/FaucetToken.sol";
import {EscrowHandler} from "./EscrowHandler.sol";

/// @notice I-2(b): escrow-conservation invariant/fuzz suite for the security
///         review's funds-custody branch-coverage gap. Proves that for
///         well-behaved (standard, non-fee-on-transfer, non-rebasing) ERC20s,
///         the exchange's actual on-chain token balance always exactly equals
///         the sum of currently-escrowed amounts across every open order and
///         offer — the positive-case counterpart to the M-1/I-2(a) tests in
///         AsseteraExchange.t.sol, which prove that same accounting *breaks*
///         for non-standard tokens by design.
contract EscrowConservationInvariantTest is Test {
    AsseteraExchange internal exchange;
    FaucetToken internal tokenA;
    FaucetToken internal tokenB;
    EscrowHandler internal handler;

    address internal admin = makeAddr("invariant-admin");

    function setUp() public {
        tokenA = new FaucetToken("Token A", "TKA", 18);
        tokenB = new FaucetToken("Token B", "TKB", 6);

        AsseteraExchange impl = new AsseteraExchange(address(0)); // no meta-tx forwarder needed
        bytes memory initData =
            abi.encodeCall(AsseteraExchange.initialize, (admin, makeAddr("invariant-kyc"), makeAddr("invariant-fee")));
        exchange = AsseteraExchange(address(new ERC1967Proxy(address(impl), initData)));

        // Escrow conservation is a pure token-accounting property, independent
        // of KYC/fee attestation gating (which has its own dedicated coverage
        // in AsseteraExchange.t.sol) — disable it so the handler can drive
        // every action freely with empty attestations.
        vm.startPrank(admin);
        exchange.setComplianceRequired(ExchangeTypes.Action.Place, false);
        exchange.setComplianceRequired(ExchangeTypes.Action.Fill, false);
        exchange.setComplianceRequired(ExchangeTypes.Action.MakeOffer, false);
        exchange.setComplianceRequired(ExchangeTypes.Action.ReplaceOffer, false);
        exchange.setComplianceRequired(ExchangeTypes.Action.AcceptOffer, false);
        exchange.setComplianceRequired(ExchangeTypes.Action.CancelOffer, false);
        vm.stopPrank();

        address[3] memory actors = [makeAddr("h-alice"), makeAddr("h-bob"), makeAddr("h-carol")];
        handler = new EscrowHandler(exchange, tokenA, tokenB, actors);

        targetContract(address(handler));
    }

    /// @dev Sum of ground-truth escrowed tokenA (recomputed fresh from every
    ///      order/offer the handler ever created) must equal the exchange's
    ///      actual tokenA balance, after every sequence of fuzzed actions.
    function invariant_EscrowConservation_TokenA() public view {
        assertEq(
            tokenA.balanceOf(address(exchange)), handler.expectedEscrowed(address(tokenA)), "tokenA: escrow != balance"
        );
    }

    function invariant_EscrowConservation_TokenB() public view {
        assertEq(
            tokenB.balanceOf(address(exchange)), handler.expectedEscrowed(address(tokenB)), "tokenB: escrow != balance"
        );
    }
}
