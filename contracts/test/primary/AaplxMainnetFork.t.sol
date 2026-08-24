// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PrimaryTypes} from "../../src/primary/types/PrimaryTypes.sol";
import {ISettler} from "../../src/primary/interfaces/ISettler.sol";
import {IShareAccountingToken} from "../../src/primary/interfaces/IShareAccountingToken.sol";
import {XStocksLikeVenue} from "../mocks/XStocksLikeVenue.sol";
import {VenueSettlerTestBase} from "./VenueSettlerTestBase.sol";

interface IBackedShares {
    function getSharesByUnderlyingAmount(uint256 amount) external view returns (uint256);
}

interface IBackedMintable {
    function mint(address account, uint256 amount) external;
    function minter() external view returns (address);
}

/// @title AaplxMainnetForkTest
/// @notice AO-713 against the REAL token, on a fork of Ethereum mainnet.
///
///         `VenueSettlerShares.t.sol` proves the settler against a mock whose arithmetic
///         reproduces the three quantities the 2026-08-24 proof measured. This file removes the
///         mock from the one place it actually mattered: the asset is the deployed AAPLx proxy,
///         with Backed's own bytecode, its own rounding and whatever multiplier is live at the
///         forked block.
///
/// @dev    ⚠️ **What this deliberately does NOT prove, so a green run is not over-read.** The
///         venue is still `XStocksLikeVenue`, not the real `AtomicSwap`, because `executeSwap`
///         requires a provider signature over a firm quote that only xStocks can produce. That
///         leg was already proven live on 2026-08-24: the provider accepted our registered
///         contract, returned a valid hard quote, and let it call `executeSwap` with a
///         pre-approved allowance. What failed was ours, and what is under test here is ours.
///         The settlement currency is likewise a mock, because the currency leg is unchanged by
///         this work.
///
///         Skipped unless `MAINNET_RPC_URL` is set, so a machine with no archive access runs the
///         rest of the suite normally rather than failing.
contract AaplxMainnetForkTest is VenueSettlerTestBase {
    /// Ethereum mainnet AAPLx. Its `sharesOf` / `transferShares` / `getUnderlyingAmountByShares`
    /// surface was confirmed by read-only simulation at block `25824064`.
    address internal constant AAPLX = 0x9d275685dC284C8eB1C79f6ABA7a63Dc75ec890a;

    XStocksLikeVenue internal xstocks;
    bool internal forked;

    function setUp() public override {
        // ⚠️ The fork is selected BEFORE `super.setUp()`, so the shared fixture deploys its
        // router, currency and signers onto forked state. Selecting it afterwards would discard
        // every one of them and leave the money path pointing at empty addresses.
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length != 0) {
            vm.createSelectFork(rpc);
            forked = true;
        }

        // 🔴 The shared fixture's buyer key is `0xB0B`, and on MAINNET the address it derives
        //    (`0x0376AAc07Ad725E01357B1725B5ceC61aE10473c`) carries EIP-7702 delegation code
        //    (`0xef0100…`) that a real person installed. `IntentGate` correctly sees a buyer
        //    WITH code and takes the ERC-1271 branch, so the plain ECDSA consent signature this
        //    fixture produces is refused with `BuyerConsentBadSignature`.
        //
        //    That is the router behaving exactly as designed. It is the FIXTURE that is wrong on
        //    a fork, and the failure names neither the cause nor the file. Any fork test in this
        //    repo that reuses a memorable private key will hit the same thing, because memorable
        //    keys are exactly the ones with real activity against them.
        //
        //    Overridden before `super.setUp()` so the buyer address is derived from the new key.
        buyerPk = uint256(keccak256("assetera.ao-713.fork-buyer"));

        super.setUp();
        // ⚠️ `vm.skip`, not an early `return`. A test that returns without asserting reports
        //    PASS, so a machine with no RPC would show three green fork proofs that never ran.
        if (!forked) {
            vm.skip(true);
            return;
        }

        assertEq(buyer.code.length, 0, "the fork buyer must be a plain EOA, or consent takes the ERC-1271 path");

        xstocks = new XStocksLikeVenue();

        // Real inventory, minted by the token's real minter. `deal` is not usable here: a
        // share-accounted token has no stored `balanceOf` slot to overwrite, so a cheatcode that
        // writes one would corrupt exactly the arithmetic under test.
        address minter = IBackedMintable(AAPLX).minter();
        vm.prank(minter);
        IBackedMintable(AAPLX).mint(address(xstocks), 10_000e18);
    }

    /// 🔴 THE PROOF. Real AAPLx, real multiplier, the router as the xStocks receiving wallet:
    /// the provider transfers a nominal amount in, the router forwards the exact share delta
    /// out, and its own share count returns to zero. No stranded share, no `RouterBalanceChanged`.
    function test_Fork_Aaplx_RouterForwardsTheExactShareDeltaAndKeepsNothing() public {
        uint256 nominalOut = 322_180_642_304_483_388; // the observed quote's outgoing amount
        uint256 expectedShares = IShareAccountingToken(AAPLX).sharesOf(address(xstocks));

        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) =
            _forkPath(nominalOut, uint8(PrimaryTypes.AssetAccountingMode.RebasingShares), 1);

        _settleVenueWith(data, intent, TAKER_BPS);

        uint256 venueSharesAfter = IShareAccountingToken(AAPLX).sharesOf(address(xstocks));
        uint256 sharesMoved = expectedShares - venueSharesAfter;

        assertGt(sharesMoved, 0, "the provider moved shares");
        assertEq(IShareAccountingToken(AAPLX).sharesOf(buyer), sharesMoved, "the buyer got every one of them");
        assertEq(IShareAccountingToken(AAPLX).sharesOf(address(router)), 0, "and the router kept none");
        assertEq(IERC20(AAPLX).balanceOf(address(router)), 0, "not even a visible raw unit");
    }

    /// The control, and the reason the test above is evidence rather than a coincidence: the
    /// SAME route, the same real token, the same nominal amount, under `Erc20Balance` still
    /// reverts exactly as the deployed router did on 2026-08-24.
    function test_Fork_Aaplx_TheSameRouteUnderErc20ModeStillStrandsAShare() public {
        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) =
            _forkPath(322_180_642_304_483_388, uint8(PrimaryTypes.AssetAccountingMode.Erc20Balance), 1);

        _approveExact(intent);
        vm.expectRevert(ISettler.RouterBalanceChanged.selector);
        _submit(data, intent, TAKER_BPS);
    }

    /// ⚠️ The floor a signer may sign for this route, computed from the live multiplier rather
    /// than hardcoded: one nominal hop cannot deliver the provider's raw amount, so signing it
    /// reverts. This is the number `AsseteraSignerService` has to derive (AO-714).
    function test_Fork_Aaplx_SigningTheProvidersRawNominalAmountReverts() public {
        uint256 nominalOut = 322_180_642_304_483_388;
        // The formula the signer must use, evaluated against the LIVE token rather than pinned:
        // convert the provider's nominal amount to shares and back, both rounding down.
        uint256 oneHopFloor = IShareAccountingToken(AAPLX)
            .getUnderlyingAmountByShares(IBackedShares(AAPLX).getSharesByUnderlyingAmount(nominalOut));
        assertLt(oneHopFloor, nominalOut, "one nominal hop must lose at least one raw unit");

        (bytes memory data, PrimaryTypes.SettlementIntent memory intent) =
            _forkPath(nominalOut, uint8(PrimaryTypes.AssetAccountingMode.RebasingShares), nominalOut);

        _approveExact(intent);
        // ⚠️ Named, not a bare `expectRevert()`. A bare one passed this test while the fixture's
        //    buyer signature was being refused for an unrelated reason, which is precisely how a
        //    fork test comes out green while proving nothing.
        vm.expectRevert(abi.encodeWithSelector(ISettler.InsufficientAssetDelivered.selector, oneHopFloor, nominalOut));
        _submit(data, intent, TAKER_BPS);
    }

    // ── fixture ───────────────────────────────────────────────────────────────────────────

    function _forkPath(uint256 nominalOut, uint8 mode, uint256 minOut)
        private
        view
        returns (bytes memory data, PrimaryTypes.SettlementIntent memory intent)
    {
        data = abi.encodeCall(
            XStocksLikeVenue.executeSwap,
            (XStocksLikeVenue.Swap({
                    paymentToken: address(currency),
                    paymentAmount: QUOTE,
                    assetToken: AAPLX,
                    assetAmount: nominalOut,
                    recipient: address(router) // the registered wallet, not the customer
                }))
        );
        intent = PrimaryTypes.SettlementIntent({
            buyer: buyer,
            assetToken: AAPLX,
            accountingMode: mode,
            minAssetOut: minOut,
            settlementToken: address(currency),
            venueQuoteIn: QUOTE,
            buyerFee: FEE,
            maxSettlementIn: QUOTE + FEE,
            feeCollector: collector,
            venue: address(xstocks),
            selector: XStocksLikeVenue.executeSwap.selector,
            calldataHash: keccak256(data),
            supplierReference: SUPPLIER_REF,
            nonce: INTENT_NONCE,
            deadline: block.timestamp + 3 minutes
        });
    }
}
