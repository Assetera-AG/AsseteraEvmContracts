// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ExchangeStorage} from "../storage/ExchangeStorage.sol";

/// @title PermitRelay
/// @notice Lets a caller submit an ERC-2612 `permit` and the venue call it wants to make in one
///         transaction, so nobody has to send a separate `approve` first (AO-298).
///
///         Until now `placeOrderWithPermit` was the only permit-carrying function here, which
///         covered the maker placing an order and nobody else. The taker filling an order, and
///         both parties on `makeOffer` / `replaceOffer` / `acceptOffer`, all had to approve in
///         one transaction and trade in a second.
///
///         The alternative was a `…WithPermit` twin for each of those four functions. We measured
///         both: four twins cost 513 bytes of runtime code, this costs 373, and the venue has
///         about 2.6 kB of EIP-170 headroom, so neither is forced by size. We took this one
///         because it is one selector rather than four, and because it covers any token-pulling
///         function added later — including the parked operator `settle`/`refund` — without
///         another twin each time.
///
/// @dev    The mechanism is a self-`delegatecall`, the same one OpenZeppelin's `Multicall` uses.
///         (We do not inherit `Multicall` itself: it costs 1,012 bytes here, mostly the `bytes[]`
///         decode and the `bytes[]` results array, and we only ever need one inner call.)
///
///         Why a self-`delegatecall` is not a privilege escalation: authorisation everywhere in
///         this contract is `_msgSender()`, and `permitAndCall` re-appends the ERC-2771 sender
///         suffix to the inner calldata before delegating. So the inner function resolves the
///         same actor it would have resolved had the user called it directly, whether the
///         transaction came from the user or from the trusted forwarder. `data` can therefore
///         reach nothing the caller could not already reach — admin functions included, since
///         those check roles against that same `_msgSender()`.
///
///         Two more properties that matter to a reviewer:
///           * `permitAndCall` is deliberately NOT `nonReentrant`. Every function it can delegate
///             into carries its own guard, and taking the guard here would make the inner call
///             revert. The one external call it makes before delegating is `token.permit` on a
///             caller-chosen address; at that point this function holds no state and has moved no
///             funds, so re-entering is equivalent to the caller making the call themselves.
///             `test_PermitAndCall_ReentrantTokenCannotReenterGuardedCall` pins that.
///           * There is no `msg.value` to double-spend across sub-calls (the classic multicall
///             bug) because the venue has no payable functions and this one is not payable.
abstract contract PermitRelay is ExchangeStorage {
    /// @notice Submit an ERC-2612 `permit` for the caller, then make one call on this contract
    ///         with the allowance it granted.
    ///
    ///         The caller is always the permit `owner`. A signature that does not recover to
    ///         `_msgSender()` is rejected by the token, so this cannot be used to redirect
    ///         someone else's permit or to point one at a different spender.
    ///
    /// @dev    Permit failure is swallowed, matching `placeOrderWithPermit`'s long-standing
    ///         behaviour. Three cases need that, and all three must leave the inner call runnable
    ///         rather than reverting the whole transaction:
    ///           1. the token does not implement ERC-2612 at all — the inner call then uses a
    ///              plain allowance set the old way;
    ///           2. the token's EIP-712 domain is not the one the client derived, so the
    ///              signature is well-formed but recovers to the wrong address. Real settlement
    ///              currencies do this: EUROP's domain name is not its `name()`, and USDC has no
    ///              ERC-5267 `eip712Domain()` to read it from. The playground faucet tokens agree
    ///              with `name()`, so playground cannot catch it — `DivergentDomainToken` in the
    ///              test suite does;
    ///           3. the permit already landed, e.g. the transaction is being retried.
    ///         When the allowance really is missing the inner call reverts on the transfer, and
    ///         that revert is bubbled unchanged.
    ///
    ///         One failure is NOT swallowed, here or in `placeOrderWithPermit`: a `token` address
    ///         with no code at all. Solidity's `extcodesize` check happens outside the `try`, so
    ///         the whole call reverts. That is a caller bug rather than a token quirk, and the
    ///         behaviour is unchanged from before AO-298 — see
    ///         `test_PermitAndCall_CodelessTokenAddressReverts`.
    ///
    ///         `permitAccepted` is the diagnostic: simulate this call (`eth_call`) and a `false`
    ///         tells the client its permit did not land, and why the fill is about to fail,
    ///         before the user pays for anything.
    ///
    /// @param token    ERC-20 to permit. Only the caller's own balance is ever at stake.
    /// @param value    Allowance to grant. Must be exactly the value the caller signed.
    /// @param deadline Permit expiry, as signed.
    /// @param v        Permit signature.
    /// @param r        Permit signature.
    /// @param s        Permit signature.
    /// @param data     ABI-encoded call to make on this contract afterwards, e.g.
    ///                 `abi.encodeCall(OrderBook.fillOrder, (id, amount, att))`.
    /// @return permitAccepted Whether the token accepted the permit.
    /// @return result         The inner call's return data.
    function permitAndCall(
        address token,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s,
        bytes calldata data
    ) external returns (bool permitAccepted, bytes memory result) {
        permitAccepted = _tryPermit(token, value, deadline, v, r, s);
        // Carry the ERC-2771 sender suffix into the sub-call when, and only when, this call
        // arrived through the trusted forwarder. `msg.sender != _msgSender()` is exactly that
        // condition; it is how OpenZeppelin's `Multicall` detects the same thing.
        bytes memory context =
            msg.sender == _msgSender() ? bytes("") : msg.data[msg.data.length - _contextSuffixLength():];
        result = Address.functionDelegateCall(address(this), bytes.concat(data, context));
    }

    /// @dev Shared with `OrderBook.placeOrderWithPermit`. Swallows anything the token's `permit`
    ///      reverts with; see `permitAndCall` for why, and for the one case it cannot swallow.
    function _tryPermit(address token, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        internal
        returns (bool ok)
    {
        try IERC20Permit(token).permit(_msgSender(), address(this), value, deadline, v, r, s) {
            ok = true;
        } catch {} // solhint-disable-line no-empty-blocks
    }
}
