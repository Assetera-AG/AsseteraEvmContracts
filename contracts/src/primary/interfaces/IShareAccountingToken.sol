// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IShareAccountingToken
/// @notice The three functions `VenueSettler` calls on a share-accounted asset token under
///         `AssetAccountingMode.RebasingShares`, and nothing else.
///
///         A share-accounted token stores SHARES and derives `balanceOf` as
///         `shares × multiplier` under integer division. Two consequences drive this file:
///         a nominal ERC-20 transfer rounds, so a two-hop path loses raw units and strands a
///         remainder; and `balanceOf` moves with the multiplier even when nothing was
///         transferred, so a balance delta is not a reliable measure of delivery.
///
/// @dev    ⚠️ **Deliberately minimal, and it is not the token's whole interface.** The Backed
///         implementation also exposes `getCurrentMultiplier()` and
///         `getSharesByUnderlyingAmount()`. Those are what the SIGNER needs off chain, to derive
///         the `minAssetOut` floor for the provider's one nominal hop. The router needs neither,
///         and every function named here is a function some future token must implement to be
///         settleable, so the list is kept to what is actually called.
///
///         ⚠️ **Pinned by us, not imported from the issuer.** Backed's Solidity is public but the
///         xStocks integration guidance tells general integrators to use ordinary ERC-20
///         transfers, so `transferShares` is a real function on the deployed proxy rather than a
///         promised-stable integration surface. Verified against Ethereum AAPLx
///         (`0x9d275685dC284C8eB1C79f6ABA7a63Dc75ec890a`) at block `25824064` by read-only
///         simulation. Two operational consequences, both owned by the signer rather than by
///         this contract: the deployed implementation or code hash must be pinned and its
///         `Upgraded` event watched, and this must be re-verified per `(chainId, token)` rather
///         than assumed identical across chains.
interface IShareAccountingToken {
    /// @notice The account's share balance: the quantity that does NOT move when the multiplier
    ///         does, and therefore the only quantity a settlement can be judged on.
    function sharesOf(address account) external view returns (uint256);

    /// @notice Move an exact share count.
    ///
    /// @dev    ⚠️ Returns `bool`, and there is no SafeERC20 equivalent to normalise a token that
    ///         returns nothing instead. `VenueSettler` checks the returned value explicitly and
    ///         reverts `ShareTransferFailed` on a false return, so a token that silently reports
    ///         failure cannot be mistaken for one that moved the shares.
    function transferShares(address recipient, uint256 sharesAmount) external returns (bool);

    /// @notice Convert a share count to the token's visible units at the CURRENT multiplier.
    ///
    /// @dev    Rounds down, which is what makes it safe to compare the result against a signed
    ///         floor: the number it returns can never overstate what the holder can withdraw.
    ///         `VenueSettler` uses it once, on the buyer's measured share delta, so that
    ///         `minAssetOut` stays denominated in the instrument the buyer agreed to buy.
    function getUnderlyingAmountByShares(uint256 sharesAmount) external view returns (uint256);
}
