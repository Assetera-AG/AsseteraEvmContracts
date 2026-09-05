// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PrimaryTypes} from "../../src/primary/types/PrimaryTypes.sol";
import {ISettler} from "../../src/primary/interfaces/ISettler.sol";
import {IShareAccountingToken} from "../../src/primary/interfaces/IShareAccountingToken.sol";
import {XStocksLikeVenue} from "../mocks/XStocksLikeVenue.sol";
import {VenueRedeemerTestBase} from "./VenueRedeemerTestBase.sol";

interface IBackedMintable {
    function mint(address account, uint256 amount) external;
    function minter() external view returns (address);
}

/// @title AaplxSellMainnetForkTest
/// @notice The sell-back leg against the REAL Ethereum AAPLx, forked: run end to end on
///         the deployed token rather than on a mock of it.
///
///         The claim it exists to make is narrow and cannot be made any other way. The router now
///         calls `transferSharesFrom` and `getSharesByUnderlyingAmount`, neither of which the buy
///         leg ever called, and both of which are pinned by US rather than promised by Backed
///         (see `IShareAccountingToken`). A mock proves the arithmetic; only the fork proves the
///         two selectors exist on the deployed implementation and that the allowance the first
///         one spends is denominated the way we assumed.
///
/// @dev    ⚠️ SKIPPED without `MAINNET_RPC_URL`, with `vm.skip` rather than an early `return`:
///         a test that returns without asserting reports PASS, so a machine with no RPC would
///         otherwise show green fork proofs that never ran. Same arrangement as
///         `AaplxMainnetFork.t.sol`, and the same fork-buyer key note applies — the shared
///         fixture's memorable key has real EIP-7702 delegation code against it on mainnet.
contract AaplxSellMainnetForkTest is VenueRedeemerTestBase {
    address internal constant AAPLX = 0x9d275685dC284C8eB1C79f6ABA7a63Dc75ec890a;

    bool internal forked;

    function setUp() public override {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length != 0) {
            vm.createSelectFork(rpc);
            forked = true;
        }

        // See `AaplxMainnetFork.t.sol` for why the shared fixture's buyer key cannot be used on a
        // fork: the address it derives carries EIP-7702 delegation code a real person installed,
        // so consent takes the ERC-1271 branch and the plain ECDSA signature is refused.
        buyerPk = uint256(keccak256("assetera.ao-847.fork-seller"));

        super.setUp();
        if (!forked) {
            vm.skip(true);
            return;
        }

        assertEq(buyer.code.length, 0, "the fork seller must be a plain EOA, or consent takes the ERC-1271 path");

        // The seller's real holding, minted by the token's real minter. `deal` is not usable on a
        // share-accounted token: there is no stored `balanceOf` slot to overwrite, so a cheatcode
        // that wrote one would corrupt exactly the arithmetic under test.
        address minter = IBackedMintable(AAPLX).minter();
        vm.prank(minter);
        IBackedMintable(AAPLX).mint(buyer, 1_000e18);
    }

    /// 🔴 THE HEADLINE. A real AAPLx holding is sold back through the router: the router pulls an
    /// exact share count with `transferSharesFrom`, the venue takes it with an ordinary nominal
    /// `transferFrom`, and the router ends the transaction holding neither a share nor a raw unit.
    function test_ForkSell_Aaplx_PullsExactSharesAndKeepsNothing() public {
        uint256 ceiling = 322_180_642_304_483_388;
        uint256 pulledShares = IShareAccountingToken(AAPLX).getSharesByUnderlyingAmount(ceiling);
        uint256 nominalTaken = IShareAccountingToken(AAPLX).getUnderlyingAmountByShares(pulledShares);

        (bytes memory data, PrimaryTypes.RedemptionIntent memory intent) =
            _forkSellPath(nominalTaken, uint8(PrimaryTypes.AssetAccountingMode.RebasingShares), ceiling);

        uint256 sellerSharesBefore = IShareAccountingToken(AAPLX).sharesOf(buyer);
        uint256 sellerCurrencyBefore = currency.balanceOf(buyer);

        vm.prank(buyer);
        IERC20(AAPLX).approve(address(router), ceiling);
        _submitRedemption(data, intent, TAKER_BPS);

        uint256 venueShares = IShareAccountingToken(AAPLX).sharesOf(address(sellVenue));
        assertGt(venueShares, 0, "the venue took shares");
        assertEq(
            IShareAccountingToken(AAPLX).sharesOf(buyer), sellerSharesBefore - venueShares, "the seller lost only those"
        );
        assertEq(IShareAccountingToken(AAPLX).sharesOf(address(router)), 0, "the router kept no share");
        assertEq(IERC20(AAPLX).balanceOf(address(router)), 0, "not even a visible raw unit");
        assertEq(currency.balanceOf(buyer), sellerCurrencyBefore + NET_OUT, "and was paid the quote, net of the fee");
    }

    /// 🔴 The `transferSharesFrom` allowance is spent in VISIBLE units on the deployed token, not
    /// in shares. Approving exactly the visible ceiling is therefore enough, and this is the
    /// assertion behind the operational advice "approve the number your wallet shows you".
    ///
    /// If Backed ever changed that denomination the pull would revert here rather than silently
    /// under-approving in production.
    function test_ForkSell_Aaplx_ApprovingTheVisibleCeilingIsEnough() public {
        uint256 ceiling = 322_180_642_304_483_388;
        uint256 pulledShares = IShareAccountingToken(AAPLX).getSharesByUnderlyingAmount(ceiling);
        uint256 nominalTaken = IShareAccountingToken(AAPLX).getUnderlyingAmountByShares(pulledShares);

        (bytes memory data, PrimaryTypes.RedemptionIntent memory intent) =
            _forkSellPath(nominalTaken, uint8(PrimaryTypes.AssetAccountingMode.RebasingShares), ceiling);

        vm.prank(buyer);
        IERC20(AAPLX).approve(address(router), ceiling); // not one unit more
        _submitRedemption(data, intent, TAKER_BPS);

        assertLe(IERC20(AAPLX).allowance(buyer, address(router)), ceiling, "the allowance was never overspent");
    }

    /// 🔴 THE CONTROL. The same route under `Erc20Balance` is refused at the pull, because a
    /// nominal `transferFrom` of the ceiling converts to shares once and credits the router less
    /// than it asked for. Without this the test above only shows that SOMETHING settled.
    function test_ForkSell_Aaplx_TheSameRouteUnderErc20ModeIsRefusedAtThePull() public {
        uint256 ceiling = 322_180_642_304_483_388;
        uint256 pulledShares = IShareAccountingToken(AAPLX).getSharesByUnderlyingAmount(ceiling);
        uint256 arrived = IShareAccountingToken(AAPLX).getUnderlyingAmountByShares(pulledShares);
        assertLt(arrived, ceiling, "one nominal hop must lose at least one raw unit");

        (bytes memory data, PrimaryTypes.RedemptionIntent memory intent) =
            _forkSellPath(arrived, uint8(PrimaryTypes.AssetAccountingMode.Erc20Balance), ceiling);

        vm.prank(buyer);
        IERC20(AAPLX).approve(address(router), ceiling);
        vm.expectRevert(abi.encodeWithSelector(ISettler.AssetPullMismatch.selector, ceiling, arrived));
        _submitRedemption(data, intent, TAKER_BPS);
    }

    // -- fixture ---------------------------------------------------------------------------

    function _forkSellPath(uint256 nominalTaken, uint8 mode, uint256 ceiling)
        private
        view
        returns (bytes memory data, PrimaryTypes.RedemptionIntent memory intent)
    {
        data = abi.encodeCall(
            XStocksLikeVenue.executeSell,
            (XStocksLikeVenue.Swap({
                    paymentToken: address(currency),
                    paymentAmount: PROCEEDS,
                    assetToken: AAPLX,
                    assetAmount: nominalTaken,
                    recipient: address(router) // the registered wallet, not the customer
                }))
        );
        intent = PrimaryTypes.RedemptionIntent({
            seller: buyer,
            assetToken: AAPLX,
            accountingMode: mode,
            maxAssetIn: ceiling,
            settlementToken: address(currency),
            venueQuoteOut: PROCEEDS,
            sellerFee: SELL_FEE,
            minSettlementOut: NET_OUT,
            feeCollector: collector,
            venue: address(sellVenue),
            selector: XStocksLikeVenue.executeSell.selector,
            calldataHash: keccak256(data),
            supplierReference: SUPPLIER_REF,
            nonce: INTENT_NONCE,
            deadline: block.timestamp + 3 minutes
        });
    }
}
