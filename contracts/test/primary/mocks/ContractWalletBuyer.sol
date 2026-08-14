// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @notice The smallest honest ERC-1271 wallet: one owner key, and a signature is valid if it
///         recovers to that owner.
///
///         It stands in for the class of buyer `IntentGate` accepts BECAUSE it uses
///         `SignatureChecker` rather than `ECDSA.recover` — a Safe, or an embedded smart account
///         of the kind the marketplace front end provisions. An EOA-only check would refuse
///         every one of them, which is exactly the client a regulated brokerage cares most
///         about, so this is not an exotic case to cover last.
///
/// @dev    ⚠️ Deliberately NOT a faithful Safe: no threshold, no owner set, no nonce. A test
///         mock that reimplemented Safe would be asserting Safe's behaviour rather than ours.
///         What matters at the seam is the single fact ERC-1271 defines — the magic value comes
///         back, or it does not — and `setRevoked` covers the other half of that, since contract
///         signatures are revocable in a way ECDSA ones are not.
contract ContractWalletBuyer is IERC1271 {
    /// @notice The EOA whose signature this wallet accepts as its own.
    address public immutable OWNER;

    /// @notice When set, every signature is refused regardless of who signed it. Models an
    ///         ERC-1271 wallet that changed its mind, which an EOA cannot do.
    bool public revoked;

    constructor(address owner_) {
        OWNER = owner_;
    }

    function setRevoked(bool revoked_) external {
        revoked = revoked_;
    }

    /// @inheritdoc IERC1271
    /// @dev `tryRecover` rather than `recover`: a malformed or empty signature must come back as
    ///      "not valid" through the ERC-1271 return value, not as a revert from inside this
    ///      wallet. `SignatureChecker` treats a reverting `isValidSignature` as invalid too, so
    ///      both roads reach the same verdict — but only this one lets the caller's own named
    ///      error be the thing the buyer sees.
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        if (revoked) return 0xffffffff;
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        if (err != ECDSA.RecoverError.NoError || recovered != OWNER) return 0xffffffff;
        return IERC1271.isValidSignature.selector;
    }
}
