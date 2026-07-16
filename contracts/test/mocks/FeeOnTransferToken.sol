// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Deflationary ERC20 mock: every transfer between two non-zero
///         addresses burns `feeBps` of the requested amount, so the recipient
///         receives less than the caller asked to send — while the sender is
///         still debited the full amount. This is the standard fee-on-transfer
///         shape (e.g. reflection/deflationary tokens) used to prove the M-1
///         pooled-escrow-solvency finding: a contract that records escrow at
///         the nominal transferred amount ends up holding less than it
///         thinks it does.
contract FeeOnTransferToken is ERC20 {
    uint16 public immutable feeBps;

    constructor(string memory name_, string memory symbol_, uint16 feeBps_) ERC20(name_, symbol_) {
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || feeBps == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * feeBps) / 10_000;
        super._update(from, to, value - fee);
        if (fee > 0) super._update(from, address(0), fee);
    }
}
