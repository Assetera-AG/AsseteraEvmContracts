// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MutableDecimalsToken
/// @notice A settlement currency that changes how many decimals it reports, after a cap has
///         already been sized against it.
///
///         `SettlementLimits.setSettlementCap` reads `decimals()` ONCE, in the admin call, and
///         never on the settlement path — deliberately, so the hot path holds no external call
///         and an upgradeable token cannot change the meaning of an approved cap between the
///         moment a human signed it off and the moment it is enforced. The consequence is
///         acknowledged in that file: the stored raw cap then means something else. This mock
///         is what turns that sentence into a test.
///
/// @dev    Not exotic. A settlement currency behind a proxy can do exactly this, and the
///         failure is silent in both directions: fewer decimals makes the cap a factor of
///         `10**delta` too GENEROUS, which is the dangerous one, since the cap exists to catch
///         precisely that class of magnitude error.
contract MutableDecimalsToken is ERC20 {
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Change what the token reports, without touching a single balance.
    /// @param decimals_ The new answer.
    function setDecimals(uint8 decimals_) external {
        _decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title SilentTransferToken
/// @notice A token whose `transfer` returns `true` and moves nothing.
///
///         This is the one non-conformance `SafeERC20` cannot catch: it checks that the call
///         succeeded and that the return value is truthy, and both are satisfied here. What
///         catches it is `VenueSettler`'s step 9 — the router's settlement-token balance must
///         be back at its PRE-CALL value — which is exactly why that assertion is made LAST,
///         after the fee transfer, rather than before it.
///
///         `transferFrom` still works, so the buyer's debit lands and the settlement gets far
///         enough for the refund and the fee to be the things that fail.
///
/// @dev    Six decimals, so it drops into the same USDC-shaped fixtures as `FaucetToken`.
contract SilentTransferToken is ERC20 {
    /// @notice When set, `transfer` is a no-op that reports success.
    bool public silent;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function setSilent(bool silent_) external {
        silent = silent_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (silent) return true;
        return super.transfer(to, value);
    }
}

/// @title RebasingAsset
/// @notice A rebasing 18-decimal asset token: a holder's balance can move without any transfer.
///
///         Tokenised equities rebase on corporate actions, so this is the shape of the real
///         asset leg rather than an exotic one. It exists to test the claim `VenueSettler`
///         makes about its balance-delta assertion, which is that measuring inside ONE
///         transaction is safe.
///
/// @dev    `rebase` is permissionless, which is the honest model: a rebase is triggered by
///         whatever the token's own rules say, and nothing on the settlement path gets to
///         decide when. `test/mocks/RebasingToken.sol` is the exchange's equivalent; this one
///         is separate because the asset leg needs 18 decimals and a `mint` the venue mock can
///         reach through the same interface it uses for `FaucetToken`.
contract RebasingAsset is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Adjust one account's balance in place, in basis points of its current holding.
    /// @param account The holder.
    /// @param bps     Signed: positive grows the balance, negative shrinks it.
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

/// @title FeeOnTransferCurrency
/// @notice A deflationary settlement currency: the sender is debited in full and the recipient
///         receives less. Six decimals, so it drops into the USDC-shaped fixtures.
///
///         `test/mocks/FeeOnTransferToken.sol` is the exchange's equivalent and reports 18
///         decimals, which would hide the whole point here: the interesting cases are the ones
///         where the router is left holding less than the quote it just approved, and those are
///         only legible at the scale the settlement fixtures actually use.
///
/// @dev    The burn applies to `transferFrom` (the buyer's debit), to `transfer` (the refund
///         and the fee) and to the venue's own pull, which is what makes the arithmetic in
///         `VenueSettler` steps 5 to 9 worth asserting rather than assuming.
contract FeeOnTransferCurrency is ERC20 {
    /// @notice Basis points burned on every transfer between two non-zero addresses.
    uint16 public immutable FEE_BPS;

    constructor(string memory name_, string memory symbol_, uint16 feeBps_) ERC20(name_, symbol_) {
        FEE_BPS = feeBps_;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || FEE_BPS == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 burned = (value * FEE_BPS) / 10_000;
        super._update(from, to, value - burned);
        if (burned != 0) super._update(from, address(0), burned);
    }
}
