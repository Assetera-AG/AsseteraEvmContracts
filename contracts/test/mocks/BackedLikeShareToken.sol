// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title BackedLikeShareToken
/// @notice A tokenised equity shaped like **Backed/xStocks**, which is the family
///         `AssetAccountingMode.RebasingShares` exists for. It stores SHARES and derives
///         `balanceOf` from them, so a nominal ERC-20 transfer rounds.
///
///         The arithmetic here is not invented. It reproduces the three numbers the 2026-08-24
///         AAPLx mainnet-fork proof measured, at the real multiplier
///         `1003269012539818700` that Ethereum AAPLx
///         (`0x9d275685dC284C8eB1C79f6ABA7a63Dc75ec890a`) reported at block `25824064`:
///
///         | quantity                          | value                |
///         |-----------------------------------|----------------------|
///         | provider's nominal outgoing amount| `322180642304483388` |
///         | shares that actually arrived      | `321130861491345397` |
///         | those shares back in underlying   | `322180642304483387` |
///
///         One raw unit is lost per nominal hop, and forwarding the measured `balanceOf`
///         increase is a second hop, which strands one share at the router. That share is what
///         `RouterBalanceChanged` refused, correctly, before AO-713.
///
/// @dev    Only the surface the router and the tests need. It is NOT a full ERC-20 — no
///         `transferFrom`, no allowances — because `VenueSettler` never pulls the asset. It
///         only ever measures it and pushes it.
///
///         ⚠️ Rounding is DOWN in every direction, matching Backed's integer division. That
///         asymmetry is the whole point of the mock: a version that rounded to nearest, or that
///         stored balances and derived shares, would pass the tests below without proving
///         anything about the token we actually have to settle against.
contract BackedLikeShareToken is IERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    /// @notice The live multiplier, scaled to 1e18. AAPLx reported `1003269012539818700`.
    uint256 public multiplier;

    /// @notice Test-only: makes `transferShares` a silent no-op that reports failure.
    bool public shareTransfersReturnFalse;

    mapping(address => uint256) private _shares;
    uint256 private _totalShares;

    /// @dev The token does not implement allowances; nothing on the settlement path needs them.
    error NotImplemented();
    /// @dev Moving more shares than the sender holds.
    error InsufficientShares();

    constructor(string memory name_, string memory symbol_, uint256 multiplier_) {
        name = name_;
        symbol = symbol_;
        multiplier = multiplier_;
    }

    // ── the share surface the router uses under `RebasingShares` ──────────────────────────

    /// @notice The rebase-invariant quantity. This is what a settlement must be judged on.
    function sharesOf(address account) external view returns (uint256) {
        return _shares[account];
    }

    /// @notice Move an exact share count. Returns `bool`, as Backed's does.
    ///
    /// @dev    ⚠️ When `shareTransfersReturnFalse` is set this moves NOTHING and returns false,
    ///         which Backed's own implementation never does. It is here because there is no
    ///         SafeERC20 equivalent for `transferShares`: nothing in the OpenZeppelin stack
    ///         normalises this return, so `VenueSettler` has to check it by hand, and an
    ///         unchecked return would read a silent no-op as a successful delivery.
    function transferShares(address to, uint256 sharesAmount) external returns (bool) {
        if (shareTransfersReturnFalse) return false;
        _moveShares(msg.sender, to, sharesAmount);
        return true;
    }

    /// @notice Make `transferShares` report failure instead of moving anything.
    /// @param fails Whether the next `transferShares` should return false.
    function setShareTransfersReturnFalse(bool fails) external {
        shareTransfersReturnFalse = fails;
    }

    /// @notice Shares to visible units, rounding down.
    function getUnderlyingAmountByShares(uint256 sharesAmount) public view returns (uint256) {
        return (sharesAmount * multiplier) / 1e18;
    }

    /// @notice Visible units to shares, rounding down. This is the conversion that loses a raw
    ///         unit on every nominal hop, and the one the SIGNER must apply to derive a floor.
    function getSharesByUnderlyingAmount(uint256 amount) public view returns (uint256) {
        return (amount * 1e18) / multiplier;
    }

    // ── the ERC-20 surface, derived ───────────────────────────────────────────────────────

    /// @notice `shares × multiplier`, rounded down. Moves when the multiplier moves, with no
    ///         transfer and no event, which is exactly why a balance delta cannot measure
    ///         delivery of one of these tokens.
    function balanceOf(address account) public view returns (uint256) {
        return getUnderlyingAmountByShares(_shares[account]);
    }

    function totalSupply() external view returns (uint256) {
        return getUnderlyingAmountByShares(_totalShares);
    }

    /// @notice A NOMINAL transfer: the amount is converted to shares with integer division and
    ///         it is the shares that move. The recipient can therefore observe up to one raw
    ///         unit less than `amount`.
    function transfer(address to, uint256 amount) external returns (bool) {
        _moveShares(msg.sender, to, getSharesByUnderlyingAmount(amount));
        return true;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function approve(address, uint256) external pure returns (bool) {
        revert NotImplemented();
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert NotImplemented();
    }

    // ── test controls ─────────────────────────────────────────────────────────────────────

    /// @notice Mint shares directly, so a fixture can seed an inventory or an existing holder
    ///         without going through a nominal amount and its rounding.
    function mintShares(address to, uint256 sharesAmount) external {
        _shares[to] += sharesAmount;
        _totalShares += sharesAmount;
    }

    /// @notice Move the multiplier, as a stock split, a dividend or a fee accrual does.
    ///
    /// @dev    ⚠️ Callable by anyone, including from inside a venue call. That is deliberate:
    ///         the settlement must survive a multiplier change it did not choose and cannot
    ///         predict, and the only honest way to test that is to let the venue do it.
    function setMultiplier(uint256 multiplier_) external {
        multiplier = multiplier_;
    }

    function _moveShares(address from, address to, uint256 sharesAmount) private {
        if (_shares[from] < sharesAmount) revert InsufficientShares();
        unchecked {
            _shares[from] -= sharesAmount;
        }
        _shares[to] += sharesAmount;
        emit Transfer(from, to, getUnderlyingAmountByShares(sharesAmount));
    }
}
