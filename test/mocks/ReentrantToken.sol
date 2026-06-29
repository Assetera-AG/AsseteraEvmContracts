// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AsseteraExchange} from "../../src/AsseteraExchange.sol";

/// @notice Malicious ERC20 that attempts to re-enter the exchange during a
///         transfer, used to prove the ReentrancyGuard holds. (Used with Fill
///         gating disabled so the empty attestation passes and the reentry
///         reaches the guard.)
contract ReentrantToken is ERC20 {
    address public exchange;
    uint256 public targetOrderId;
    bool public armed;

    constructor() ERC20("Reentrant", "REENT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address exchange_, uint256 orderId) external {
        exchange = exchange_;
        targetOrderId = orderId;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (armed && exchange != address(0)) {
            armed = false; // one-shot
            AsseteraExchange.KycAttestation memory empty;
            AsseteraExchange(exchange).fillOrder(targetOrderId, 1, empty); // 1 = minimal fill to hit guard
        }
        super._update(from, to, value);
    }
}
