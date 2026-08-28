// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAsseteraIssuanceVenue
/// @notice The vocabulary of one per-offering issuance venue: its deployment configuration, the
///         events an indexer decodes, and every error it can revert with. Single-sourced here and
///         inherited (not redeclared) by the implementation, the way `ISettler` single-sources the
///         router's settlement vocabulary.
///
/// @dev    ⚠️ This is an ORDINARY interface, not a frozen one. Unlike the router's, none of these
///         shapes is signed off-chain and none is a `paramsHash` pre-image, so changing one costs
///         a redeploy of a sale contract and an indexer release rather than invalidating payloads
///         in flight. The venue is not upgradeable: an offering that needs a different shape gets
///         a new contract, which is also how a new round is run (see `AsseteraIssuanceVenue`).
interface IAsseteraIssuanceVenue {
    // --------------------------------------------------------------------- //
    //                        Deployment configuration                        //
    // --------------------------------------------------------------------- //

    /// @notice Everything one offering's venue is born with. A struct rather than eleven
    ///         positional constructor arguments because four of them are addresses of the same
    ///         type sitting next to each other, and this contract is deployed once per offering
    ///         by an operations process rather than once per estate by a reviewed runbook. A
    ///         transposed `pauser`/`treasurer` pair is invisible in a positional call and obvious
    ///         in a named one.
    ///
    /// @param admin         `DEFAULT_ADMIN_ROLE`: role administration, the purchase cap, and
    ///                      `unpause`. The Safe multisig in production.
    /// @param rateSetter    `RATE_SETTER_ROLE`: may move `unitPrice` within the immutable bounds
    ///                      below and may do nothing else. Held by the compliance officers who
    ///                      price the offering.
    /// @param pauser        `PAUSER_ROLE`: may stop purchases. Cannot restart them.
    /// @param treasurer     `TREASURY_ROLE`: may withdraw the accumulated proceeds and rescue a
    ///                      stray token. The issuer.
    /// @param router        The ONE address allowed to call `purchase` —
    ///                      `AsseteraPrimarySales`. Immutable; see the contract header for the
    ///                      argument.
    /// @param settlementToken The currency this offering is sold in (e.g. mUSDC, 6 decimals).
    /// @param assetToken    The asset this venue mints (e.g. mRWA, 18 decimals). Must have
    ///                      granted this venue its minting right, which the ISSUER does.
    /// @param unitPrice     The opening price of ONE WHOLE asset token, expressed in the
    ///                      SETTLEMENT token's smallest unit. Read the units section of
    ///                      `AsseteraIssuanceVenue` before setting this; it is the field a
    ///                      decimals mistake lives in.
    /// @param minUnitPrice  Lower bound on `unitPrice`, inclusive. Must be greater than zero.
    /// @param maxUnitPrice  Upper bound on `unitPrice`, inclusive.
    /// @param maxSettlementPerPurchaseWholeUnits The per-purchase cap, in WHOLE settlement
    ///                      tokens. Zero deploys the venue CLOSED.
    struct SaleConfig {
        address admin;
        address rateSetter;
        address pauser;
        address treasurer;
        address router;
        address settlementToken;
        address assetToken;
        uint256 unitPrice;
        uint256 minUnitPrice;
        uint256 maxUnitPrice;
        uint256 maxSettlementPerPurchaseWholeUnits;
    }

    // --------------------------------------------------------------------- //
    //                                 Events                                 //
    // --------------------------------------------------------------------- //

    /// @notice One primary purchase: settlement currency taken from the router, asset minted to
    ///         the buyer.
    ///
    ///         Every amount is what actually happened rather than what was asked for.
    ///         `settlementIn` is the router's MEASURED balance delta on this venue, and
    ///         `assetMinted` is the MEASURED delta on the buyer, so an asset token that charges a
    ///         transfer fee or a mint that under-delivers cannot be reported as a clean fill —
    ///         both revert before this is emitted.
    ///
    /// @dev    Joins to the router's `ISettler.PrimarySettled` on the transaction hash: the two
    ///         are emitted from one call, this one from the venue and that one from the router.
    ///         `PrimarySettled.venueIn` is this event's `settlementIn` seen from the other side,
    ///         and a discrepancy between them is a reconciliation alarm rather than a normal state.
    ///
    ///         The token pair is immutable per deployment and could have been left to a getter.
    ///         It is on the event anyway so an indexer can build the leg from the log alone, which
    ///         is the same discipline that put the measured amounts on `PrimarySettled`.
    ///
    /// @param buyer           Who received the asset. Named by the router, never by this contract.
    /// @param assetToken      The asset minted. Fixed at deployment.
    /// @param assetMinted     Measured `assetToken` delta on `buyer`.
    /// @param settlementToken The currency taken. Fixed at deployment.
    /// @param settlementIn    Measured `settlementToken` delta on this venue: what the buyer's
    ///                        purchase actually cost, which is at most what the router authorised.
    /// @param unitPrice       The price in force when the purchase executed, so the fill can be
    ///                        checked against the rate history without replaying `UnitPriceSet`.
    event IssuanceMinted(
        address indexed buyer,
        address indexed assetToken,
        uint256 assetMinted,
        address settlementToken,
        uint256 settlementIn,
        uint256 unitPrice
    );

    /// @notice The offering was repriced.
    /// @param previousUnitPrice The price that was in force.
    /// @param newUnitPrice      The price now in force, within the immutable bounds.
    event UnitPriceSet(uint256 previousUnitPrice, uint256 newUnitPrice);

    /// @notice The per-purchase settlement cap was set.
    /// @dev Both forms are emitted for the same reason `ISettlementLimits.SettlementCapSet`
    ///      carries both: `wholeUnits` is the number a human authorised, `rawCap` is the number
    ///      that is enforced, and `decimals` records what the two were converted against.
    /// @param wholeUnits The cap as set, in whole settlement tokens.
    /// @param rawCap     The cap as enforced: `wholeUnits * 10 ** decimals`.
    /// @param decimals   The settlement token's decimals, fixed at deployment.
    event PurchaseCapSet(uint256 wholeUnits, uint256 rawCap, uint8 decimals);

    /// @notice Accumulated proceeds left the venue.
    /// @param to     Where they went. Chosen per call, never stored.
    /// @param amount How much settlement currency moved.
    event ProceedsWithdrawn(address indexed to, uint256 amount);

    /// @notice A token that is not the settlement currency was swept out.
    /// @param token  The token swept.
    /// @param to     Where it went.
    /// @param amount How much moved.
    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    // --------------------------------------------------------------------- //
    //                                 Errors                                 //
    // --------------------------------------------------------------------- //

    /// @dev Somebody other than the configured router called `purchase`. There is exactly one
    ///      legitimate caller and it is fixed at deployment.
    /// @param caller The address that tried.
    error CallerNotRouter(address caller);

    /// @dev A required address argument was zero.
    error ZeroAddress();

    /// @dev A required amount argument was zero.
    error ZeroAmount();

    /// @dev The settlement token and the asset token are the same address. A venue that took and
    ///      minted one token would have a balance invariant that cannot be stated, let alone held.
    error SameToken();

    /// @dev The price is outside the bounds fixed at deployment.
    /// @param unitPrice    The price that was asked for.
    /// @param minUnitPrice The inclusive lower bound.
    /// @param maxUnitPrice The inclusive upper bound.
    error UnitPriceOutOfBounds(uint256 unitPrice, uint256 minUnitPrice, uint256 maxUnitPrice);

    /// @dev The deployment's price bounds are not a usable range: the floor is zero, or the floor
    ///      is above the ceiling. A zero floor would allow a price of zero, which is an infinite
    ///      quantity of asset for any payment.
    /// @param minUnitPrice The proposed lower bound.
    /// @param maxUnitPrice The proposed upper bound.
    error PriceBoundsInvalid(uint256 minUnitPrice, uint256 maxUnitPrice);

    /// @dev The purchase asks to spend more than the per-purchase cap, or the cap is zero.
    ///      ⚠️ A ZERO cap means "this venue cannot sell", not "unlimited" — the same fail-closed
    ///      reading `ISettlementLimits` gives an unset cap, and for the same reason.
    /// @param settlementIn The amount the purchase authorised.
    /// @param cap          The cap in force, zero if the venue was never opened.
    error PurchaseCapExceeded(uint256 settlementIn, uint256 cap);

    /// @dev The payment is too small to buy a single unit of the asset at the current price, so
    ///      the purchase would take money and mint nothing. A revert, never a silent zero fill.
    /// @param settlementIn The payment offered.
    /// @param unitPrice    The price it was quoted against.
    error NothingToMint(uint256 settlementIn, uint256 unitPrice);

    /// @dev The price moved between the quote being signed and the purchase executing, so the
    ///      buyer would receive less asset than they agreed to. The router asserts the same floor
    ///      independently; this one names the venue as the place it failed.
    /// @param assetOut    What the current price yields.
    /// @param minAssetOut What the caller required.
    error InsufficientAssetOut(uint256 assetOut, uint256 minAssetOut);

    /// @dev The venue computed a charge above the amount the caller authorised. Unreachable by
    ///      construction (the charge is the exact cost of a quantity derived by flooring the same
    ///      payment) and guarded anyway, because the failure it would represent is the venue
    ///      spending more of the router's allowance than the buyer signed for.
    /// @param charged    What the venue was about to take.
    /// @param authorised What the caller offered.
    error ChargeExceedsAuthorised(uint256 charged, uint256 authorised);

    /// @dev The settlement pull did not move exactly what it was asked to move: the venue's
    ///      MEASURED balance delta over `transferFrom` is not the charge.
    ///
    ///      ⚠️ Both directions revert, and the consequence is deliberate: a fee-on-transfer or
    ///      otherwise deflationary settlement currency cannot be sold in at all. Proceeding on
    ///      the quoted number would mint the full quantity against a short payment and leave the
    ///      shortfall in the issuer's proceeds, silently. That is a listing decision, and it is
    ///      taken at the line that moves the money rather than discovered in a reconciliation.
    /// @param requested What the venue asked `transferFrom` to move.
    /// @param received  What its own balance actually grew by.
    error SettlementPullMismatch(uint256 requested, uint256 received);

    /// @dev The mint did not put the quoted quantity in the buyer's hands: a token whose `mint`
    ///      no-ops, returns `false` rather than reverting, charges a transfer fee, or rebased the
    ///      buyer down during the call.
    /// @param delivered The measured delta on the buyer.
    /// @param expected  The quantity quoted and charged for.
    error AssetDeliveryShortfall(uint256 delivered, uint256 expected);

    /// @dev A token reported more decimals than any real token has. Rejected at deployment
    ///      because `10 ** decimals` is an immutable of this contract and a nonsense one would
    ///      make every quote nonsense.
    /// @param token    The token.
    /// @param decimals What it reported.
    error TokenDecimalsImplausible(address token, uint256 decimals);

    /// @dev `rescue` was pointed at the settlement currency. Proceeds leave through `withdraw`,
    ///      which is the evented path an issuer's accounting reads.
    error RescueOfSettlementToken();
}
