// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title IssuerAssetToken
/// @notice The asset token as an ISSUER would actually deploy it: role-gated minting, with the
///         sale venue holding `MINTER_ROLE` and nobody else.
///
///         `test/mocks/FaucetToken.sol` has a permissionless `mint`, which is right for a testnet
///         faucet and wrong for the property under test here. The whole reason
///         `AsseteraIssuanceVenue` is a separate contract is that the minting right lives on it
///         and not on the router, and a fixture anyone can mint from cannot show that: a test
///         would pass whether the grant happened or not.
///
/// @dev    18 decimals, matching the tokenised-instrument side of the pair the venue is built
///         for. The `mint(address,uint256)` shape is the OpenZeppelin one `IMintableERC20`
///         assumes; `LegacyMintAssetToken` below is the counter-example.
contract IssuerAssetToken is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    constructor(string memory name_, string memory symbol_, address issuer) ERC20(name_, symbol_) {
        _grantRole(DEFAULT_ADMIN_ROLE, issuer);
    }

    /// @notice Create `amount` for `to`. Minter only.
    /// @param to     The recipient.
    /// @param amount The quantity.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }
}

/// @title ShortMintAssetToken
/// @notice An asset token whose `mint` creates LESS than it was asked for, by a fixed proportion.
///
///         Three real shapes collapse into this one dial, and the venue must refuse all three:
///         a token that takes a cut of every issuance, a token whose `mint` silently no-ops
///         (`shortfallBps = 10_000`), and a token that returns success without doing anything.
///         None of them reverts on its own, so the only thing that catches them is the venue
///         measuring what the buyer actually received.
///
/// @dev    Permissionless `mint`, because the access control is not what is under test here.
contract ShortMintAssetToken is ERC20 {
    /// @notice Basis points of every mint that are silently not created.
    uint16 public immutable SHORTFALL_BPS;

    constructor(string memory name_, string memory symbol_, uint16 shortfallBps_) ERC20(name_, symbol_) {
        SHORTFALL_BPS = shortfallBps_;
    }

    /// @notice Create somewhat less than `amount` for `to`, without complaining about it.
    /// @param to     The recipient.
    /// @param amount The quantity asked for.
    function mint(address to, uint256 amount) external {
        uint256 short = (amount * SHORTFALL_BPS) / 10_000;
        if (amount > short) _mint(to, amount - short);
    }
}

/// @title OverMintAssetToken
/// @notice An asset token whose `mint` creates MORE than it was asked for.
///
///         The mirror of `ShortMintAssetToken`, and it must NOT be refused: the buyer ending up
///         with more than they paid for is somebody else's generosity, not this venue's failure,
///         and reverting an otherwise honest purchase over it would be the wrong trade. What the
///         test built on this mock actually pins is subtler — that the venue reports the quantity
///         it ISSUED rather than the delta it measured, so an unrelated inflation does not enter
///         the offering's issuance record.
///
/// @dev    An upward rebase triggered during the mint has exactly this shape from the venue's
///         point of view, which is why one mock covers both.
contract OverMintAssetToken is ERC20 {
    /// @notice Basis points added on top of every mint.
    uint16 public immutable SURPLUS_BPS;

    constructor(string memory name_, string memory symbol_, uint16 surplusBps_) ERC20(name_, symbol_) {
        SURPLUS_BPS = surplusBps_;
    }

    /// @notice Create rather more than `amount` for `to`.
    /// @param to     The recipient.
    /// @param amount The quantity asked for.
    function mint(address to, uint256 amount) external {
        _mint(to, amount + (amount * SURPLUS_BPS) / 10_000);
    }
}

/// @title LegacyMintAssetToken
/// @notice An asset token whose mint is NOT `mint(address,uint256)`. It is
///         `issue(address,uint256,bytes32)` — a partitioned issuance, which is a shape real
///         security-token frameworks use.
///
///         It exists to make the claim in `IMintableERC20` checkable: supporting a token like
///         this must be a subclass that overrides one internal function and changes nothing on
///         the money path. `AlternateMintIssuanceVenue` is that subclass, and the tests that
///         drive it run the SAME assertions as the ones that drive the standard venue.
contract LegacyMintAssetToken is ERC20 {
    /// @notice The partition of the most recent issuance, so the subclass can be shown to be
    ///         passing the extra argument rather than merely compiling.
    bytes32 public lastPartition;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    /// @notice Create `amount` for `to` within `partition`.
    /// @param to        The recipient.
    /// @param amount    The quantity.
    /// @param partition The issuance partition.
    function issue(address to, uint256 amount, bytes32 partition) external {
        lastPartition = partition;
        _mint(to, amount);
    }
}

/// @title ForwardingRouter
/// @notice A stand-in for `AsseteraPrimarySales` that does nothing but forward a purchase, and
///         that has NO reentrancy guard of its own.
///
///         It exists to reach the venue's own guard. A hostile settlement currency calling
///         `purchase` directly is refused by the caller allowlist long before the guard, which is
///         the right outcome and also means the guard is never exercised by that test. Routing
///         the reentrant call back through the address the venue trusts is the only way to ask
///         "and if the trusted caller itself re-enters?" — and the answer must not depend on the
///         real router happening to hold a guard of its own.
///
/// @dev    Deliberately guardless. A mock that replicated the router's `nonReentrant` would stop
///         the reentrant call in the mock and prove nothing about the venue.
contract ForwardingRouter {
    /// @notice Forward one purchase to `venue`.
    /// @param venue        The issuance venue.
    /// @param buyer        The buyer.
    /// @param settlementIn The payment.
    /// @param minAssetOut  The delivery floor.
    /// @return The venue's own return data, unexamined.
    function forward(address venue, address buyer, uint256 settlementIn, uint256 minAssetOut)
        external
        returns (bytes memory)
    {
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory ret) =
            venue.call(abi.encodeWithSignature("purchase(address,uint256,uint256)", buyer, settlementIn, minAssetOut));
        if (!ok) {
            // Bubble the venue's revert verbatim so a caller can read WHICH check refused it.
            // solhint-disable-next-line no-inline-assembly
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    /// @notice Approve `spender` to spend `token` on this router's behalf, as the real router
    ///         does per settlement.
    /// @param token   The settlement currency.
    /// @param spender The venue.
    /// @param amount  The exact amount for one purchase.
    function approve(address token, address spender, uint256 amount) external {
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        require(ok, "approve failed");
    }
}

/// @title ReentrantCurrency
/// @notice A six-decimal settlement currency that calls back into a nominated target in the
///         middle of `transferFrom`, before the venue has minted anything.
///
///         This is the hostile-token shape that matters to a sale venue: the venue pulls the
///         payment and then mints, so a currency that re-enters between the two is trying to get
///         a second mint out of one payment. The result must be that the second call fails and
///         the first completes exactly once.
///
/// @dev    The reentrant call's failure is SWALLOWED and recorded rather than bubbled, on
///         purpose. Bubbling would make the outer purchase revert, and a test asserting that
///         cannot tell "the guard held" from "the guard held and also nothing else worked". With
///         the failure swallowed, the assertion is the one that matters: the outer purchase
///         succeeded, `reentrySucceeded` is false, and the buyer holds exactly one purchase.
contract ReentrantCurrency is ERC20 {
    /// @notice What to call back into, and with what. Zero target disables the callback.
    address public target;
    bytes public payload;

    /// @notice Whether the most recent callback returned successfully.
    bool public reentrySucceeded;
    /// @notice How many callbacks have been attempted.
    uint256 public reentryAttempts;
    /// @notice The revert data of the most recent failed callback, so a test can assert WHICH
    ///         check refused it rather than only that something did.
    bytes public lastReentryError;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Arm the callback.
    /// @param target_  The contract to re-enter.
    /// @param payload_ The calldata to re-enter it with.
    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _attemptReentry();
        return super.transferFrom(from, to, value);
    }

    function _attemptReentry() private {
        address t = target;
        if (t == address(0)) return;
        reentryAttempts += 1;
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory returndata) = t.call(payload);
        reentrySucceeded = ok;
        lastReentryError = ok ? bytes("") : returndata;
    }
}
