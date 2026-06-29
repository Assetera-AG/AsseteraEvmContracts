// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title FaucetToken
/// @notice A minimal ERC20 test token with EIP-2612 permit support and an open
///         faucet `mint`. Used on testnets/local to stand in for real assets:
///         a USDC-like settlement token (6 decimals) and an RWA-like token
///         (18 decimals). NOT for production — `mint` is permissionless by design.
contract FaucetToken is ERC20, ERC20Permit {
    uint8 private immutable _decimals;

    /// @param name_     Token name (e.g. "Mock USD Coin")
    /// @param symbol_   Token symbol (e.g. "mUSDC")
    /// @param decimals_ Decimal precision (6 for USDC-like, 18 for RWA-like)
    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Open faucet: mint `amount` of tokens to `to`.
    /// @dev Permissionless on purpose — this is a testnet fixture.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Convenience faucet: mint `amount` to the caller.
    function drip(uint256 amount) external {
        _mint(msg.sender, amount);
    }
}
