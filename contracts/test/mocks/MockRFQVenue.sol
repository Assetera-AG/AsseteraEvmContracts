// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {FaucetToken} from "./FaucetToken.sol";

/// @title MockRFQVenue
/// @notice A testnet-only settlement venue that fills issuer-signed RFQ quotes, so
///         `AsseteraPrimarySales` can exercise BOTH of its settlement legs on a chain where no
///         real RFQ issuer is deployed. It is deliberately issuer-agnostic: the tokens are named
///         by the quote, and nothing here is bound to mUSDC, mRWA or any particular issuer.
///
///         🔴 **NOT for production.** This is a testnet fixture, deployed the same way the
///         `FaucetToken` mocks are. It has no upgradeability, no pause and no allowlist, and its
///         only notion of an eligible counterparty is the quote's `taker`: the address the
///         provider signed the quote for may call `buy` or `sell` with it, and nobody else. It
///         mints through `FaucetToken`'s permissionless `mint`, which means the asset supply is
///         not a scarce thing. Never record an address of this contract in a production
///         deployment record.
///
/// @dev    A quote is an EIP-712 message over the `Quote` struct below, signed by the configured
///         off-chain test RFQ provider (`quoteSigner`). The domain is name `MockRFQVenue`,
///         version `1`, this chain and this contract, so a quote signed for one chain or one
///         venue cannot be replayed against another. Every `quoteId` is single-use, and a quote
///         expires, so a filled or stale quote is refused with a named error rather than filled
///         twice. The signed `taker` binds a quote to the one address that may fill it; on the
///         Assetera route that is the router, which is the caller and the holder of the approval
///         the venue pulls.
///
///         **BUY** — the venue sells the asset to the router's buyer:
///           1. pulls exactly `paymentAmount` of `paymentToken` from `msg.sender` (the router,
///              which has approved exactly this settlement's quote);
///           2. mints `assetAmount` of `assetToken` to `recipient`, which the router's buyer
///              consensus expects to be the buyer. Delivery straight to the buyer is what makes
///              the router's measured asset delta non-zero.
///
///         **SELL** — the venue buys the asset back from the router's seller:
///           1. pulls exactly `assetAmount` of `assetToken` from `msg.sender` (the router, which
///              approved the asset) and KEEPS it: `FaucetToken` has no burn, so the inventory
///              accumulates here rather than being destroyed;
///           2. mints `paymentAmount` of `paymentToken` to `recipient`. ⚠️ On this leg
///              `recipient` must be the ROUTER, not the seller: `VenueRedeemer` measures the
///              proceeds as the router's own currency delta and then forwards the net to the
///              seller. A quote that names the seller here settles with `venueOut == 0` and is
///              refused by the seller's signed floor.
///
///         The two functions exist rather than one with a direction argument because the router
///         hands over opaque calldata bound by selector: a BUY quote cannot be replayed into
///         `sell` (and the reverse) because the signed `side` must match the function called.
contract MockRFQVenue is EIP712, Ownable2Step {
    using SafeERC20 for IERC20;

    /// @notice The side a quote is for. Encoded as `uint8` in the EIP-712 payload.
    uint8 public constant SIDE_BUY = 0;
    /// @notice The other side. See `SIDE_BUY`.
    uint8 public constant SIDE_SELL = 1;

    /// @notice The canonical EIP-712 type of a quote. Kept as a string as well as a hash so an
    ///         off-chain signer can copy it verbatim instead of re-deriving it.
    string public constant QUOTE_TYPE =
        "Quote(uint8 side,address paymentToken,uint256 paymentAmount,address assetToken,uint256 assetAmount,address recipient,address taker,bytes32 quoteId,uint256 expiry)";

    /// @notice `keccak256(QUOTE_TYPE)`, the first word of every quote struct hash.
    bytes32 public constant QUOTE_TYPEHASH = keccak256(bytes(QUOTE_TYPE));

    /// @notice One firm RFQ quote, in the shape the test provider signs it.
    /// @param side          `SIDE_BUY` or `SIDE_SELL`.
    /// @param paymentToken  The settlement currency: what a buyer pays, or what a seller receives.
    /// @param paymentAmount The exact amount of `paymentToken` moved.
    /// @param assetToken    The asset: what a buyer receives, or what a seller gives up.
    /// @param assetAmount   The exact amount of `assetToken` moved.
    /// @param recipient     Who receives the minted side of the trade. The buyer on a BUY quote,
    ///                      the router on a SELL quote (see the contract NatSpec).
    /// @param taker         The only address allowed to fill the quote. On the Assetera route that
    ///                      is always the router, which holds the approval the venue pulls, so a
    ///                      quote signed for one counterparty cannot be filled by another.
    /// @param quoteId       A unique id, usable once ever.
    /// @param expiry        Last timestamp at which the quote is valid, inclusive.
    struct Quote {
        uint8 side;
        address paymentToken;
        uint256 paymentAmount;
        address assetToken;
        uint256 assetAmount;
        address recipient;
        address taker;
        bytes32 quoteId;
        uint256 expiry;
    }

    /// @notice The off-chain test RFQ provider whose signature makes a quote fillable.
    address public quoteSigner;

    /// @notice Whether a quote id has already been filled. A used id can never be used again.
    mapping(bytes32 quoteId => bool used) public quoteUsed;

    /// @notice The quote signer was rotated.
    /// @param previousSigner The signer that could no longer fill quotes.
    /// @param newSigner      The signer that can.
    event QuoteSignerSet(address indexed previousSigner, address indexed newSigner);

    /// @notice One quote was filled.
    /// @param quoteId       The single-use id that was consumed.
    /// @param side          `SIDE_BUY` or `SIDE_SELL`.
    /// @param caller        `msg.sender`, the router in the Assetera route.
    /// @param recipient     Who received the minted side.
    /// @param assetToken    The asset moved.
    /// @param assetAmount   The amount of it moved.
    /// @param paymentToken  The currency moved.
    /// @param paymentAmount The amount of it moved.
    event QuoteFilled(
        bytes32 indexed quoteId,
        uint8 indexed side,
        address indexed caller,
        address recipient,
        address assetToken,
        uint256 assetAmount,
        address paymentToken,
        uint256 paymentAmount
    );

    /// @dev The quote's expiry has passed.
    error QuoteExpired(uint256 expiry);

    /// @dev The quote id has already been filled.
    error QuoteAlreadyUsed(bytes32 quoteId);

    /// @dev The signature does not recover to `quoteSigner`, or is not a valid ECDSA signature.
    error InvalidQuoteSignature();

    /// @dev The quote is for the other side than the function that was called.
    error WrongQuoteSide(uint8 expected, uint8 supplied);

    /// @dev The caller is not the address the quote was signed for.
    /// @param expected The `quote.taker` the provider signed.
    /// @param caller   `msg.sender`.
    error WrongTaker(address expected, address caller);

    /// @dev A configured address is the zero address.
    error ZeroAddress();

    /// @dev The payment pull did not move exactly `paymentAmount`.
    error PaymentPullMismatch(uint256 expected, uint256 received);

    /// @dev The asset pull did not move exactly `assetAmount`.
    error AssetPullMismatch(uint256 expected, uint256 received);

    /// @param quoteSigner_  The off-chain test RFQ provider.
    /// @param initialOwner  The account that may rotate `quoteSigner`.
    ///
    /// @dev    `initialOwner` is a parameter, not `msg.sender`. On a testnet the venue is deployed
    ///         through CreateX CREATE3, where the constructor's `msg.sender` is the CREATE3 proxy,
    ///         so `Ownable(msg.sender)` would hand ownership to an address nobody holds a key for
    ///         and `setQuoteSigner` would be permanently unreachable.
    constructor(address quoteSigner_, address initialOwner) EIP712("MockRFQVenue", "1") Ownable(initialOwner) {
        if (quoteSigner_ == address(0)) revert ZeroAddress();
        quoteSigner = quoteSigner_;
        emit QuoteSignerSet(address(0), quoteSigner_);
    }

    /// @notice Fill a BUY quote: take the payment from the caller, mint the asset to `recipient`.
    /// @param quote     The signed quote.
    /// @param signature The `quoteSigner`'s EIP-712 signature over it.
    /// @return paymentIn The payment pulled, which is exactly `quote.paymentAmount`.
    /// @return assetOut  The asset minted to `quote.recipient`, exactly `quote.assetAmount`.
    function buy(Quote calldata quote, bytes calldata signature)
        external
        returns (uint256 paymentIn, uint256 assetOut)
    {
        _consume(quote, signature, SIDE_BUY);

        IERC20 payment = IERC20(quote.paymentToken);
        uint256 before = payment.balanceOf(address(this));
        payment.safeTransferFrom(msg.sender, address(this), quote.paymentAmount);
        uint256 received = payment.balanceOf(address(this)) - before;
        // Measured rather than assumed: an exact debit request that delivers less is refused here
        // instead of surfacing later as a router balance that does not reconcile.
        if (received != quote.paymentAmount) revert PaymentPullMismatch(quote.paymentAmount, received);

        paymentIn = quote.paymentAmount;
        assetOut = quote.assetAmount;
        // `FaucetToken.mint` is permissionless by design; that is the whole reason this fixture
        // can deliver an asset it does not own. See the contract-level NOT for production note.
        FaucetToken(quote.assetToken).mint(quote.recipient, assetOut);

        emit QuoteFilled(
            quote.quoteId,
            SIDE_BUY,
            msg.sender,
            quote.recipient,
            quote.assetToken,
            assetOut,
            quote.paymentToken,
            paymentIn
        );
    }

    /// @notice Fill a SELL quote: take the asset from the caller, mint the payment to `recipient`.
    /// @param quote     The signed quote.
    /// @param signature The `quoteSigner`'s EIP-712 signature over it.
    /// @return assetIn     The asset pulled, which is exactly `quote.assetAmount`.
    /// @return paymentOut  The payment minted to `quote.recipient`, exactly `quote.paymentAmount`.
    function sell(Quote calldata quote, bytes calldata signature)
        external
        returns (uint256 assetIn, uint256 paymentOut)
    {
        _consume(quote, signature, SIDE_SELL);

        IERC20 asset = IERC20(quote.assetToken);
        uint256 before = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), quote.assetAmount);
        uint256 received = asset.balanceOf(address(this)) - before;
        if (received != quote.assetAmount) revert AssetPullMismatch(quote.assetAmount, received);

        // Kept here: `FaucetToken` has no burn, so the fixture's inventory grows with every sell
        // instead of the asset being destroyed.
        assetIn = quote.assetAmount;
        paymentOut = quote.paymentAmount;
        FaucetToken(quote.paymentToken).mint(quote.recipient, paymentOut);

        emit QuoteFilled(
            quote.quoteId,
            SIDE_SELL,
            msg.sender,
            quote.recipient,
            quote.assetToken,
            assetIn,
            quote.paymentToken,
            paymentOut
        );
    }

    /// @notice The EIP-712 digest `quoteSigner` signs for `quote`.
    /// @dev Exposed so a test provider can sign without re-implementing the domain separator.
    /// @param quote The quote to hash.
    /// @return The digest, ready for `vm.sign` / an off-chain signer.
    function hashQuote(Quote calldata quote) external view returns (bytes32) {
        return _hashTypedDataV4(_structHash(quote));
    }

    /// @notice Replace the off-chain test RFQ provider. The only configurable value.
    /// @param newSigner The new signer. May not be the zero address.
    function setQuoteSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert ZeroAddress();
        address previous = quoteSigner;
        quoteSigner = newSigner;
        emit QuoteSignerSet(previous, newSigner);
    }

    /// @dev Validate a quote against the configured signer and burn its id.
    ///
    ///      The id is burned BEFORE any token is touched, so a token callback (or a second quote
    ///      in the same transaction) cannot fill it twice. Order: taker, side, expiry, replay,
    ///      signature. The caller check comes first because it is the cheapest one and it is an
    ///      authorization question, not a validity question: only the address the quote names may
    ///      fill it, whatever the state of the quote. Each failure has its own error so an operator
    ///      can tell a stale quote from a reused one from a misconfigured signer.
    ///
    /// @param quote     The quote being filled.
    /// @param signature The provider's signature over `hashQuote(quote)`.
    /// @param expected  The side the calling function implements.
    function _consume(Quote calldata quote, bytes calldata signature, uint8 expected) private {
        if (msg.sender != quote.taker) revert WrongTaker(quote.taker, msg.sender);
        if (quote.side != expected) revert WrongQuoteSide(expected, quote.side);
        // Inclusive: a quote is valid while `block.timestamp <= quote.expiry`.
        if (block.timestamp > quote.expiry) revert QuoteExpired(quote.expiry);
        if (quoteUsed[quote.quoteId]) revert QuoteAlreadyUsed(quote.quoteId);

        // `tryRecover` rather than `recover` so a malformed signature reports the same named error
        // as a well-formed signature from the wrong key. Both mean "not signed by the provider".
        (address recovered, ECDSA.RecoverError error,) =
            ECDSA.tryRecover(_hashTypedDataV4(_structHash(quote)), signature);
        if (error != ECDSA.RecoverError.NoError || recovered != quoteSigner) revert InvalidQuoteSignature();

        quoteUsed[quote.quoteId] = true;
    }

    /// @dev The EIP-712 struct hash of a quote. Field order must match `QUOTE_TYPE` exactly.
    function _structHash(Quote calldata quote) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                QUOTE_TYPEHASH,
                quote.side,
                quote.paymentToken,
                quote.paymentAmount,
                quote.assetToken,
                quote.assetAmount,
                quote.recipient,
                quote.taker,
                quote.quoteId,
                quote.expiry
            )
        );
    }
}
