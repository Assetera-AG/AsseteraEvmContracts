// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC20 mock simulating a rebasing token's core hazard: an account's
///         balance can change (up or down) without going through `transfer`/
///         `transferFrom`. Real rebasing tokens (e.g. elastic-supply/yield-
///         bearing assets) adjust every holder's balance proportionally on
///         each rebase; this mock simplifies that to a single, directly
///         targeted account (the exchange, in tests) via `rebase`, which is
///         sufficient to reproduce the desync between a contract's *recorded*
///         escrow and its *actual* token balance described in finding M-1.
contract RebasingToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @param account Account whose balance is adjusted in place.
    /// @param bps     Signed adjustment in basis points of `account`'s current
    ///                balance; positive = balance grows, negative = shrinks.
    function rebase(address account, int256 bps) external {
        uint256 balance = balanceOf(account);
        uint256 delta = (balance * uint256(bps < 0 ? -bps : bps)) / 10_000;
        if (delta == 0) return;
        if (bps > 0) {
            _mint(account, delta);
        } else {
            _burn(account, delta);
        }
    }
}
