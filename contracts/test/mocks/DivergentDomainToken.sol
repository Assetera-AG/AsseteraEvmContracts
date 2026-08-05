// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice An ERC-2612 token whose EIP-712 domain a client CANNOT derive from `name()`.
///         It reproduces two things real settlement currencies do, which the playground
///         faucet tokens do not and therefore cannot catch:
///
///           * **The domain name is not `name()`.** EUROP is the live example: its
///             `name()` and the string it hashed into its domain separator differ, so a
///             permit signed against `name()` recovers to the wrong address and the token
///             rejects it. Constructed here by passing a `domainName_` that differs from
///             `name_`.
///           * **`eip712Domain()` reverts.** USDC predates ERC-5267, so the obvious "just
///             ask the token" fix is not available either. Set `eip712DomainReverts_` to
///             reproduce that; a client is then left with `DOMAIN_SEPARATOR()`, which it
///             can only compare candidate names against, not invert.
///
///         Neither quirk is a contract-side bug, and neither can be fixed contract-side.
///         What the contract owes the client is that a permit which does not land is
///         survivable: it must not brick the trade for a token where the allowance was
///         already set, and it must be visible on simulation. That is what the tests
///         using this mock check.
contract DivergentDomainToken is ERC20, ERC20Permit {
    error Eip712DomainUnsupported();

    bool private immutable _eip712DomainReverts;

    /// @param name_                 The token's `name()`, i.e. what a naive client signs against.
    /// @param symbol_               Token symbol.
    /// @param domainName_           The string actually hashed into the EIP-712 domain separator.
    ///                              Pass something other than `name_` to reproduce EUROP.
    /// @param eip712DomainReverts_  Make ERC-5267 `eip712Domain()` revert, reproducing USDC.
    constructor(string memory name_, string memory symbol_, string memory domainName_, bool eip712DomainReverts_)
        ERC20(name_, symbol_)
        ERC20Permit(domainName_)
    {
        _eip712DomainReverts = eip712DomainReverts_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function eip712Domain()
        public
        view
        override
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        if (_eip712DomainReverts) revert Eip712DomainUnsupported();
        return super.eip712Domain();
    }
}
