// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice A fee-on-transfer token that EXEMPTS one address from the fee on both sides, the way
///         OilXCoin exempts the exchange. A transfer where the exempt address is the sender or the
///         recipient moves the full amount; every other transfer burns `feeBps`. Used to prove that
///         routing the buy-side asset leg THROUGH the exchange lets the exemption cover it — a
///         seller-to-buyer transfer is taxed, but seller-to-exchange then exchange-to-buyer is not.
contract ExchangeExemptFeeToken is ERC20 {
    uint16 public immutable feeBps;
    address public immutable exempt;

    constructor(string memory name_, string memory symbol_, uint16 feeBps_, address exempt_) ERC20(name_, symbol_) {
        feeBps = feeBps_;
        exempt = exempt_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || feeBps == 0 || from == exempt || to == exempt) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * feeBps) / 10_000;
        super._update(from, to, value - fee);
        if (fee > 0) super._update(from, address(0), fee);
    }
}
