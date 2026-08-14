// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev The two non-ERC-20 entry points this venue reaches for on the ASSET token. Declared
///      here rather than imported so the venue can be pointed at any mock that happens to
///      expose them — `FaucetToken` mints, `RebasingToken` mints and rebases — without this
///      file having to know which one it is holding.
interface IHostileTarget {
    function mint(address to, uint256 amount) external;
    function rebase(address account, int256 bps) external;
}

/// @title HostileVenue
/// @notice `DinariLikeVenue` models a venue that behaves. This one models every way a venue
///         can misbehave while still returning success, which is the case `VenueSettler` is
///         built for: the bytes handed to a venue are not ours, nothing on-chain constrains
///         the address, and the settlement is judged on MEASURED balance deltas rather than on
///         anything the venue says or emits.
///
///         One scripted call rather than one function per attack, because the router binds the
///         calldata by hash and by selector: a venue with eight entry points would need eight
///         intents and eight fixtures to say the same thing. The script is executed in the
///         order the fields are declared, and every step is optional.
///
///         What each step is for:
///           * `pullAmount` — consume the approval. Zero (takes nothing), the whole quote
///             (takes exactly the approval), or more than the approval (fails inside the
///             token, which is what makes `forceApprove(venue, venueQuoteIn)` a ceiling).
///           * `rebaseBps` — a rebase of the RECIPIENT's asset balance, triggered from inside
///             the venue call. ⚠️ This is the step that tests the claim in `VenueSettler` that
///             a rebase "cannot occur mid-call": the venue is arbitrary code, so it can call
///             the token.
///           * `deliverAmount` — the honest step. Zero is the venue that lies about filling.
///           * `pushBackAmount` — settlement token pushed back AT the router, which must not be
///             absorbed into the refund or counted as anything.
///           * `reenterTarget` / `reenterCalldata` — a call back into the router (or anywhere
///             else) from inside the venue call.
///
/// @dev    ⚠️ The reentry attempt is RECORDED rather than bubbled, and that is deliberate.
///         `VenueSettler` collapses every venue failure into one `VenueCallFailed`, so a venue
///         that bubbled `ReentrancyGuardReentrantCall` would leave the test asserting on
///         `VenueCallFailed` and unable to say WHICH guard fired. Recording lets the outer
///         settlement complete honestly and the test then assert on the exact selector the
///         reentrant call came back with.
contract HostileVenue {
    /// @param paymentToken   The settlement currency (what the venue pulls and may push back).
    /// @param pullAmount     How much to pull from the caller via `transferFrom`.
    /// @param assetToken     The asset the router measures on the buyer.
    /// @param deliverAmount  How much of it to actually deliver. Zero is the venue that lies.
    /// @param recipient      Who the delivery and the rebase land on. The buyer, normally.
    /// @param pushBackAmount Settlement token to push back at the caller from the venue's own
    ///                       balance. Models a venue that returns funds out of band.
    /// @param rebaseBps      Signed rebase of `recipient`'s asset balance, mid-call.
    /// @param reenterTarget  A contract to call back into. `address(0)` disables the step.
    /// @param reenterData    The calldata for that call.
    struct Script {
        address paymentToken;
        uint256 pullAmount;
        address assetToken;
        uint256 deliverAmount;
        address recipient;
        uint256 pushBackAmount;
        int256 rebaseBps;
        address reenterTarget;
        bytes reenterData;
    }

    /// @notice Whether the scripted reentrant call succeeded. `false` is the assertion a
    ///         reentrancy test actually wants to make.
    bool public reenterAttempted;
    /// @notice Whether that call came back `ok`.
    bool public reenterOk;
    /// @notice Its raw return (or revert) data, so a test can assert on the exact error.
    bytes public reenterReturnData;

    /// @notice Run the script. Always returns success unless a step reverts inside a token.
    /// @param script What to do.
    /// @return ok Always true — a venue that lies returns success, which is the whole point.
    function execute(Script calldata script) external returns (bool ok) {
        if (script.pullAmount != 0) {
            IERC20(script.paymentToken).transferFrom(msg.sender, address(this), script.pullAmount);
        }
        if (script.rebaseBps != 0) {
            IHostileTarget(script.assetToken).rebase(script.recipient, script.rebaseBps);
        }
        if (script.deliverAmount != 0) {
            IHostileTarget(script.assetToken).mint(script.recipient, script.deliverAmount);
        }
        if (script.pushBackAmount != 0) {
            IERC20(script.paymentToken).transfer(msg.sender, script.pushBackAmount);
        }
        if (script.reenterTarget != address(0)) {
            reenterAttempted = true;
            // solhint-disable-next-line avoid-low-level-calls
            (bool called, bytes memory ret) = script.reenterTarget.call(script.reenterData);
            reenterOk = called;
            reenterReturnData = ret;
        }
        return true;
    }

    /// @notice The first four bytes of whatever the reentrant call came back with — the error
    ///         selector when it reverted. Zero when there is nothing to read.
    function reenterErrorSelector() external view returns (bytes4 selector) {
        bytes memory data = reenterReturnData;
        if (data.length < 4) return bytes4(0);
        return bytes4(data[0]) | (bytes4(data[1]) >> 8) | (bytes4(data[2]) >> 16) | (bytes4(data[3]) >> 24);
    }
}
