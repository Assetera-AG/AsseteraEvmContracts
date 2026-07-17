// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Malicious ERC20 that attempts to re-enter an arbitrary call during
///         a transfer, used to prove the exchange's shared ReentrancyGuard
///         holds across every state-changing entry point. `arm` takes raw
///         calldata (build it with `abi.encodeCall`) so the same mock can
///         probe any function, not just one hardcoded reentry target.
contract ReentrantToken is ERC20 {
    address public target;
    bytes public callData;
    bool public armed;

    constructor() ERC20("Reentrant", "REENT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @param target_   Contract to reenter (the exchange under test).
    /// @param callData_ Calldata for the reentrant call, e.g.
    ///                  `abi.encodeCall(AsseteraExchange.cancelOrder, (id))`.
    function arm(address target_, bytes calldata callData_) external {
        target = target_;
        callData = callData_;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (armed && target != address(0)) {
            armed = false; // one-shot
            (bool ok, bytes memory ret) = target.call(callData);
            if (!ok) {
                // Bubble the original revert (e.g. ReentrancyGuardReentrantCall) unchanged so
                // vm.expectRevert at the outer call site matches on it.
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
        super._update(from, to, value);
    }
}
