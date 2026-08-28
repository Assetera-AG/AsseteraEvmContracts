// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IMintableERC20
/// @notice The ONE assumption `AsseteraIssuanceVenue` makes about an asset token beyond ERC-20:
///         that it can be told to create `amount` units for `to` through the OpenZeppelin-shaped
///         `mint(address,uint256)`.
///
///         It is a separate file, with one function on it, for a reason worth stating plainly:
///         **the mint signature is the most likely thing about this design to be wrong for a
///         token we did not write.** Issuers turn up with `mint(address,uint256)` (OpenZeppelin's
///         minter preset and every fork of it), with `issue(address,uint256)`, with `mintTo`,
///         with a mint that returns `bool`, and with a mint that takes a partition or a memo.
///         Scattering `assetToken.mint(...)` through a money path would make supporting the
///         second of those a rewrite of that path. Confining it here and to
///         `AsseteraIssuanceVenue._mintAsset` makes it a subclass with one function in it.
///
/// @dev    ⚠️ **The venue never reads the return value and never trusts it.** A mint that
///         returns `false` instead of reverting, a mint that silently no-ops, and an asset token
///         that charges a transfer fee on the way out are all caught the same way: the venue
///         measures `balanceOf(buyer)` across the call and refuses the purchase when the measured
///         delta is short of what was quoted. This interface therefore declares no return value
///         even though some tokens have one — solc encodes the call identically and simply
///         ignores any extra return data.
///
///         ⚠️ **The venue must hold the minting right on the asset token, and the ISSUER grants
///         it.** Nothing here grants it and nothing here checks it, so a deployment whose grant
///         was forgotten fails at the first purchase rather than at deployment. That is
///         deliberate: the grant is a transaction on somebody else's contract, made with somebody
///         else's key, and a constructor-time probe would have to be a zero-amount `mint`, which
///         a good many tokens reject on its own.
interface IMintableERC20 {
    /// @notice Create `amount` units of the token and credit them to `to`.
    /// @param to     The recipient. Always the buyer named in the purchase; never this venue.
    /// @param amount The number of units, in the asset token's own smallest denomination.
    function mint(address to, uint256 amount) external;
}
