// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title HostileWallets
/// @notice The ERC-1271 answers `SignatureChecker` has to survive, one contract each.
///
///         `IntentGate` checks the BUYER's consent with `SignatureChecker.isValidSignatureNow`
///         so that a Safe or an embedded smart account can be a buyer. That hands the verdict
///         to code the buyer controls, and `intent.buyer` is a field the settlement operator
///         fills in — so "a contract that is not a well-behaved wallet" is a case that reaches
///         this line in production rather than an exotic one.
///
///         `ContractWalletBuyer` is the honest wallet, and its `setRevoked` covers the wallet
///         that says a clean "no". These are the wallets that say something else:
///
///           * `RevertingWallet` — reverts instead of answering. Must read as "not valid", not
///             as an undecodable revert out of the staticcall.
///           * `GarbageWallet` — returns a well-formed `bytes4` that is not the magic value.
///           * `TruthyWallet` — returns a non-zero word that is not the magic value either. It
///             is the one a "did the call return something?" check would wave through.
///           * `ShortReturnWallet` — returns fewer than 32 bytes, so `abi.decode` would revert
///             if the length were not checked first.
///           * `PermissiveWallet` — returns the magic value for ANY hash and ANY bytes. Not an
///             attack on us: it is the mutation that proves the ERC-1271 branch is live, and it
///             pins where the trust boundary sits. A wallet that accepts everything harms only
///             itself, and its owner chose the code.
///
/// @dev    All five are `pure`/`view` so that `SignatureChecker`'s staticcall reaches them.

/// @notice A wallet that reverts rather than answering.
contract RevertingWallet {
    error WalletIsUnhappy();

    function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
        revert WalletIsUnhappy();
    }
}

/// @notice A wallet that answers with a well-formed but wrong magic value.
contract GarbageWallet {
    function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
        return 0xdeadbeef;
    }
}

/// @notice A wallet that answers with a non-zero word that is not the magic value.
contract TruthyWallet {
    function isValidSignature(bytes32, bytes memory) external pure returns (bytes32) {
        return bytes32(uint256(1));
    }
}

/// @notice A wallet whose answer is shorter than one word.
contract ShortReturnWallet {
    // solhint-disable-next-line no-complex-fallback
    fallback(bytes calldata) external returns (bytes memory) {
        // Four bytes of the right magic value, and nothing else — an answer that would decode
        // correctly only if the caller ignored the length.
        return hex"1626ba7e";
    }
}

/// @notice A wallet that validates anything at all.
contract PermissiveWallet {
    function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
        return 0x1626ba7e;
    }
}
