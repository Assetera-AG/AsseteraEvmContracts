// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAsseteraIssuanceVenue} from "./IAsseteraIssuanceVenue.sol";
import {IMintableERC20} from "./IMintableERC20.sol";

/// @title AsseteraIssuanceVenue — one offering's primary sale, as a venue
/// @notice **One deployment per offering.** The settlement currency and the asset token are
///         fixed at deployment, and the whole contract does one thing: take settlement currency
///         from the router and mint the asset to the buyer at a price a compliance officer set.
///         It is a swap with a price. There is no oracle, no order book, no inventory, no
///         holder list and no currency conversion — anything of that kind happens before the
///         router, off this contract entirely.
///
///         **It is a VENUE to `AsseteraPrimarySales`, in that router's exact sense of the word.**
///         The router cannot tell it from Dinari or Backed and does not try: to the router it is
///         an address in a signed intent that gets approved an exact amount of settlement
///         currency, called with calldata bound by hash and selector, and then judged entirely on
///         the balance deltas the router measured afterwards. Nothing here is privileged there.
///         That is what the name says — "issuance" because we mint rather than execute against
///         somebody else's book, "venue" because that is the role it plays.
///
///         🔴 **Why the issuance path is a separate contract at all, rather than a module holding
///         the minting right inside the router.** The router's settlement intents are signed by
///         one operator key, and every field of an intent is that key's to choose — the delivery
///         floor included. A mint module inside the router would therefore hand a compromised
///         settlement key an unpriced mint: name yourself the buyer, set the floor to one wei,
///         mint. No venue allowlist helps (the attacker names the genuine venue), no value cap
///         helps (it bounds the wrong quantity) and a structurally-fixed recipient does not help
///         (the attacker is the recipient). **This contract helps, because the economics are
///         enforced by code rather than by a signature: it mints only what it has just been
///         paid for, measured, so an intent with a zero quote mints nothing.** The signer cannot
///         mint without paying, whatever they sign.
///
/// @dev    ## The units, stated once and precisely — this is where a decimals bug would live
///
///         `unitPrice` is **the price of ONE WHOLE asset token, denominated in the SETTLEMENT
///         token's smallest unit.** Nothing else. Not a ratio, not a fixed-point number with its
///         own scale, not a price per smallest asset unit.
///
///         Worked through with the pair this is built for — mUSDC at 6 decimals paying for mRWA
///         at 18:
///
///         | quantity | value | meaning |
///         |---|---|---|
///         | `unitPrice` | `12_500_000` | 12.50 mUSDC buys 1.000000000000000000 mRWA |
///         | `settlementIn` | `125_000_000` | the buyer pays 125.00 mUSDC |
///         | `ASSET_UNIT` | `10 ** 18` | one whole mRWA, in mRWA's own units |
///         | `assetOut` | `125e6 * 1e18 / 12.5e6` = `10e18` | the buyer receives 10 mRWA |
///
///         So `assetOut = settlementIn * ASSET_UNIT / unitPrice` and, the other way,
///         `settlementIn = ceil(assetOut * unitPrice / ASSET_UNIT)`. Both run through
///         `Math.mulDiv`, which carries the intermediate product at 512 bits, so the
///         `1e6 * 1e18` in the middle of a realistic quote is exact rather than merely
///         not-yet-overflowing.
///
///         **Why the price is denominated in the settlement token rather than in an abstract
///         scale.** Every alternative encodes the same number with a scaling factor bolted on —
///         "price times 1e18", "rate in basis points of a token" — and every one of them needs
///         the reader to hold two decimal conversions in their head at once. This encoding needs
///         one fact: the price is a settlement-currency amount, so it is written the way every
///         other settlement-currency amount in this system is written. It also makes the bounds
///         legible: with mUSDC, `MIN_UNIT_PRICE = 10_000` reads as one euro-cent and
///         `MAX_UNIT_PRICE = 10_000_000_000` reads as ten thousand mUSDC.
///
///         ⚠️ **The bounds are therefore in settlement-token units too, and they are set at
///         deployment rather than hardcoded**, because "0.01" and "10,000" are decimal numbers a
///         human means, and their raw values depend on a decimals count this contract only learns
///         at deployment. A constant would silently mean a different price on a currency with
///         different decimals, which is the exact class of bug this section exists to prevent.
///
///         **Rounding, and who it favours.** `assetOut` FLOORS, so the buyer never receives more
///         asset than they paid for. The residue is then not kept either: the venue charges the
///         exact ceiling cost of the quantity it is actually about to mint, which is provably at
///         most the payment offered, and simply does not take the difference. The offering is
///         never paid for asset it did not issue, and the buyer is never charged for asset they
///         did not receive.
///
///         ⚠️ **How large that residue can be depends on the two decimal counts, and for the pair
///         this contract is built for it is always ZERO.** Whenever `unitPrice < ASSET_UNIT` — the
///         mUSDC/mRWA case, where a price expressed in six decimals is nowhere near `1e18` — the
///         ceiling cost of the floored quantity lands back exactly on the payment offered, so the
///         charge always equals the offer and the router's refund path never fires for this venue.
///         Reverse the decimals (an 18-decimal currency buying a 6-decimal asset) and the residue
///         becomes real, bounded by one smallest settlement unit, and the router refunds it to the
///         buyer as it would for any venue that rounds a fill down. Both regimes are asserted in
///         `IssuanceVenueDecimalsTest`; the first as a fuzzed property, the second by example.
///
///         ## Decisions taken here, with their reasons
///
///         **The router address is IMMUTABLE, and that is a deliberate departure from "settable
///         by admin".** The router is the one address whose call causes a mint, so a settable
///         router is a single admin transaction away from an arbitrary mint: point it at an EOA,
///         call `purchase`, name any buyer. Immutability removes that lever entirely, which
///         matters precisely because this contract's reason for existing is to bound a
///         compromised key. The cost is real and is accepted: when the router is redeployed —
///         and it will be, the estate rotates proxy addresses by salt version — this venue must
///         be redeployed too. That is one deployment plus one minting-right grant, and it has to
///         happen anyway, because the catalogue entry that names this venue has to be re-pointed
///         and the old venue paused. Redeploying a sale contract is already the accepted way to
///         run a second round; this makes it the way to follow a router as well.
///
///         **Proceeds ACCUMULATE here; they are never forwarded during a purchase.** The
///         alternative — transfer straight to a treasury address at the end of `purchase` — puts
///         an external call to an address an admin controls inside the router's measured-delta
///         window, and gives the settlement path a failure mode with no good answer: a treasury
///         that is a Safe with a reverting fallback, or a contract that runs out of gas, breaks
///         every buyer's purchase and the buyer cannot fix it. Accumulating instead makes the
///         venue's balance the offering's proceeds, withdrawable by an explicit, evented,
///         role-gated call whose destination is chosen per call rather than stored. The
///         "forwarding address" is therefore the `to` argument of `withdraw`, which is strictly
///         more flexible than a stored one and cannot be pre-set by a key that later leaks.
///
///         **Not upgradeable, and not a proxy.** A per-offering contract that can be changed
///         after buyers have paid into it is a governance surface nobody asked for; the terms of
///         an offering should be the terms the offering was sold under. The escape hatch is the
///         one the issuer already has: pause this venue and deploy the next one. That also keeps
///         it out of `script/storage-layout.sh`, which guards the two proxies and should not
///         acquire an entry for a contract with no upgrade path.
///
///         **The purchase cap bounds BUGS, not attackers**, exactly as the router's
///         per-transaction settlement cap does, and it is sized the same way: ten to a hundred
///         times the largest plausible purchase. What it reliably catches is an arithmetic or
///         decimals mistake — the factor of a trillion between a 6-decimal currency and an
///         18-decimal asset — which is the realistic failure for an integration like this one. It
///         is not a loss limit and should not be sized as one. ⚠️ **A zero cap means "this venue
///         cannot sell", not "unlimited"**, mirroring `ISettlementLimits`; a venue deployed with
///         a zero cap is deployed closed.
///
///         **Native currency is never accepted.** No `receive`, no `fallback`, no `payable`
///         function, so a bare value transfer to this contract reverts and there is no balance to
///         sweep and no sweep function to get the access control on. The buyer pays in an ERC-20
///         and in nothing else; any currency conversion happened before the router.
///
///         **No holder whitelist, no KYC, no fee logic, and no attestation of its own.** All four
///         belong to `AsseteraPrimarySales`, which has already verified four signatures, screened
///         the buyer and taken the fee out of the buyer's debit by the time this contract is
///         called. Duplicating any of them here would be a second copy of a rule that drifts from
///         the first. This contract trusts exactly one caller and checks exactly the economics.
///
///         ## Deliberately out of scope for this version
///
///         **A subscription-style offering** — commitments taken during a window, a minimum raise
///         that must be met before anything settles, and an allocation step at a deadline — is
///         not built, and the seam is left clean rather than half-occupied. Such an offering is
///         not a variation on this contract: it separates the buyer's money from the buyer's
///         units in time, which forces an escrow, a refund path for the threshold-not-met case, a
///         privileged allocation action with its own authorisation, and an answer to what happens
///         when a buyer's compliance status changes mid-window. That is a different contract with
///         a different invariant, and it should be written as one. The seam that keeps it cheap
///         is that this venue holds no state a subscription venue would want to inherit: it is an
///         address in a catalogue row and in a signed intent, so a second family is a second
///         contract deployed against the same asset token, not a mode of this one.
///
///         **Round management is not built either, and is not wanted.** Running a second round
///         means deploying a second venue — a new price, a new cap, a new grant of the minting
///         right — and pausing this one. That is a deployment rather than a state machine, it
///         leaves each round's terms permanently readable at its own address, and it means this
///         contract has no notion of "the current round" that could be got wrong.
///
///         **A lifetime issuance cap** (a maximum number of asset units this venue may ever mint)
///         is not built. The per-purchase cap above bounds the bug class this contract is exposed
///         to; an offering size is a property of the offering rather than of one of its sale
///         contracts, and the place to enforce it without arithmetic drift is the asset token's
///         own supply, which the issuer controls. Add it here only with a decision recorded, and
///         note that it would need its own thinking about what happens to a purchase that
///         straddles the cap.
contract AsseteraIssuanceVenue is IAsseteraIssuanceVenue, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --------------------------------------------------------------------- //
    //                                 Roles                                  //
    // --------------------------------------------------------------------- //

    /// @notice May move `unitPrice` within the immutable bounds, and may do nothing else.
    /// @dev Held by the compliance officers who price the offering through our interface. It is
    ///      deliberately NOT the admin role: repricing is a routine business action taken often,
    ///      and it should not need the key that can also change who holds every other role.
    bytes32 public constant RATE_SETTER_ROLE = keccak256("RATE_SETTER_ROLE");

    /// @notice May stop purchases. May NOT restart them.
    /// @dev The asymmetry is the point. Pausing is a safety action whose cost, if it turns out to
    ///      be unnecessary, is a stopped sale; it should be reachable by the fastest key that can
    ///      be trusted with it. Restarting is a claim that the sale is safe again, and it is
    ///      `DEFAULT_ADMIN_ROLE`'s to make. A compromised pauser can therefore stop the offering
    ///      and cannot reopen one that somebody stopped on purpose.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice May withdraw the accumulated proceeds and rescue a stray token.
    /// @dev Held by the issuer. It is separate from `DEFAULT_ADMIN_ROLE` because the party that
    ///      takes the money out of an offering is not usually the party that administers the
    ///      contract, and because a role that only moves value is much easier to review than one
    ///      that also grants roles.
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    /// @notice The most decimals either token may plausibly report. Matches
    ///         `SettlementLimits.MAX_SETTLEMENT_TOKEN_DECIMALS`: well above the 18 of every
    ///         stablecoin and tokenised instrument in use, and far below the point where
    ///         `10 ** decimals` stops fitting sensibly in the arithmetic below.
    uint8 public constant MAX_TOKEN_DECIMALS = 36;

    // --------------------------------------------------------------------- //
    //                              Immutables                                //
    // --------------------------------------------------------------------- //

    /// @notice The ONE address allowed to call `purchase`: `AsseteraPrimarySales`.
    /// @dev Immutable on purpose — see the contract header. Changing it is a redeploy.
    address public immutable ROUTER;

    /// @notice The currency this offering is sold in. Fixed at deployment.
    IERC20 public immutable SETTLEMENT_TOKEN;

    /// @notice The asset this venue mints. Fixed at deployment.
    /// @dev Typed `IERC20` because everything on the money path except one line measures it as an
    ///      ERC-20. The mint assumption is materialised in exactly one place, `_mintAsset`.
    IERC20 public immutable ASSET_TOKEN;

    /// @notice `SETTLEMENT_TOKEN.decimals()`, read once at deployment.
    /// @dev Read once, never on the purchase path. A token that changed its decimals afterwards
    ///      would silently change what a stored cap means, which is why the value is on
    ///      `PurchaseCapSet` as well as here.
    uint8 public immutable SETTLEMENT_DECIMALS;

    /// @notice `ASSET_TOKEN.decimals()`, read once at deployment.
    uint8 public immutable ASSET_DECIMALS;

    /// @notice One whole asset token in the asset token's own units: `10 ** ASSET_DECIMALS`.
    /// @dev The scaling constant of every quote in this contract. Precomputed so no quote ever
    ///      contains an exponentiation, and so the one place decimals enter the arithmetic is
    ///      visible from the getter.
    uint256 public immutable ASSET_UNIT;

    /// @notice Inclusive lower bound on `unitPrice`, in settlement-token units. Never zero.
    uint256 public immutable MIN_UNIT_PRICE;

    /// @notice Inclusive upper bound on `unitPrice`, in settlement-token units.
    uint256 public immutable MAX_UNIT_PRICE;

    // --------------------------------------------------------------------- //
    //                                 State                                  //
    // --------------------------------------------------------------------- //

    /// @notice The price of ONE WHOLE asset token, in the settlement token's smallest unit.
    /// @dev Always within `[MIN_UNIT_PRICE, MAX_UNIT_PRICE]`, and therefore never zero. See the units
    ///      table in the contract header before reading or writing this.
    uint256 public unitPrice;

    /// @notice The per-purchase cap on settlement currency, in raw settlement-token units.
    /// @dev ⚠️ Zero means the venue cannot sell. It is enforced against the amount the caller
    ///      AUTHORISES, not against the slightly smaller amount actually charged, so the number a
    ///      human sizes is the most a buyer can be asked for.
    uint256 public maxSettlementPerPurchase;

    /// @notice The same cap as it was set: whole settlement tokens.
    /// @dev Stored alongside the raw value so the number a human authorised stays readable
    ///      on-chain, the way `ISettlementLimits` keeps both forms.
    uint256 public maxSettlementPerPurchaseWholeUnits;

    // --------------------------------------------------------------------- //
    //                              Construction                              //
    // --------------------------------------------------------------------- //

    /// @notice Deploy one offering's venue.
    ///
    /// @dev    Everything that cannot change afterwards is fixed here: the router, both tokens,
    ///         both sets of decimals and the price bounds. Everything that can — the price, the
    ///         cap, the role holders — starts from this configuration and moves under the roles
    ///         above.
    ///
    ///         ⚠️ **The venue is NOT usable the moment this returns.** Two things still have to
    ///         happen, both on other people's contracts: the ISSUER must grant this address the
    ///         minting right on `ASSET_TOKEN`, and the router's admin must open a settlement cap
    ///         for `SETTLEMENT_TOKEN`. Neither can be done from here, and a purchase attempted
    ///         before them reverts rather than half-settling.
    ///
    ///         `decimals()` is called plainly on both tokens rather than through the guarded
    ///         `staticcall` dance `SettlementLimits._tokenDecimals` uses. The reason that dance
    ///         exists is to turn a non-conforming token into a named error for an operator
    ///         driving an admin transaction on a live contract; here the same failure aborts a
    ///         deployment, in front of the person who typed the address, and a bare revert at
    ///         that moment is a perfectly good outcome.
    ///
    /// @param config The offering's configuration. See `IAsseteraIssuanceVenue.SaleConfig`.
    constructor(SaleConfig memory config) {
        if (
            config.admin == address(0) || config.rateSetter == address(0) || config.pauser == address(0)
                || config.treasurer == address(0) || config.router == address(0) || config.settlementToken == address(0)
                || config.assetToken == address(0)
        ) {
            revert ZeroAddress();
        }
        // A venue that took and minted one token could not state a balance invariant, let alone
        // hold one: the pull and the mint would land in the same accumulator.
        if (config.settlementToken == config.assetToken) revert SameToken();
        // A zero floor would permit a price of zero, and a price of zero divides into any payment
        // an unbounded number of times. The bounds are the only thing standing between a
        // fat-fingered repricing and an offering given away.
        if (config.minUnitPrice == 0 || config.minUnitPrice > config.maxUnitPrice) {
            revert PriceBoundsInvalid(config.minUnitPrice, config.maxUnitPrice);
        }

        ROUTER = config.router;
        SETTLEMENT_TOKEN = IERC20(config.settlementToken);
        ASSET_TOKEN = IERC20(config.assetToken);
        MIN_UNIT_PRICE = config.minUnitPrice;
        MAX_UNIT_PRICE = config.maxUnitPrice;

        SETTLEMENT_DECIMALS = _readDecimals(config.settlementToken);
        ASSET_DECIMALS = _readDecimals(config.assetToken);
        ASSET_UNIT = 10 ** uint256(ASSET_DECIMALS);

        _grantRole(DEFAULT_ADMIN_ROLE, config.admin);
        _grantRole(RATE_SETTER_ROLE, config.rateSetter);
        _grantRole(PAUSER_ROLE, config.pauser);
        _grantRole(TREASURY_ROLE, config.treasurer);

        _setUnitPrice(config.unitPrice);
        _setPurchaseCap(config.maxSettlementPerPurchaseWholeUnits);
    }

    // --------------------------------------------------------------------- //
    //                             The sale path                              //
    // --------------------------------------------------------------------- //

    /// @dev The single whitelisted caller. A modifier rather than a line in the body so that it
    ///      runs BEFORE `whenNotPaused`: a stranger calling a paused venue should be told they
    ///      are not the router, which is the durable fact, rather than that the sale is stopped,
    ///      which is the transient one.
    modifier onlyRouter() {
        if (msg.sender != ROUTER) revert CallerNotRouter(msg.sender);
        _;
    }

    /// @notice Take up to `settlementIn` of the settlement currency from the caller and mint the
    ///         asset it buys to `buyer`. The ONLY way asset is ever created by this contract.
    ///
    ///         The caller must be the router and must already have approved this venue at least
    ///         the amount that will be charged, which is at most `settlementIn`. `buyer` is named
    ///         by the caller: this contract does not know who submitted the transaction and does
    ///         not need to, because the router has already bound the buyer, the asset, the floor
    ///         and this very calldata into four signatures before it gets here.
    ///
    /// @dev    The ordered flow, and why each step is where it is:
    ///           1. the caller is the router, and the sale is not paused — everything else is
    ///              arithmetic on numbers nobody can act on until these two hold;
    ///           2. the per-purchase cap, charged against `settlementIn` (what the caller
    ///              AUTHORISED) rather than against the smaller amount finally taken, because the
    ///              authorised number is the one a human sized the cap against and it is the most
    ///              a buyer can be asked for. Before any external call;
    ///           3. quote: floor the quantity, refuse a quote that rounds to nothing, and hold it
    ///              to the caller's floor;
    ///           4. price it: the exact ceiling cost of the quantity about to be minted, which is
    ///              provably at most `settlementIn`, guarded anyway;
    ///           5. pull it and MEASURE what arrived, refusing anything but the exact amount;
    ///           6. mint and MEASURE what the buyer received, refusing a short delivery;
    ///           7. emit, from the two measurements rather than from the two quotes.
    ///
    ///         **The pull comes before the mint** so that no asset can exist against a payment
    ///         that has not landed. The reverse order would be a mint on credit for the duration
    ///         of one external call, which is exactly the property this contract exists to deny.
    ///
    ///         `nonReentrant` even though the router already holds its own guard for the whole of
    ///         this call: this contract's guarantee should not be a property of its caller's
    ///         implementation. Both token calls are to contracts we may not have written.
    ///
    ///         ⚠️ **Nothing here checks that `buyer` is anyone in particular**, and it must not.
    ///         The router asserts the measured asset delta on the buyer NAMED IN THE SIGNED
    ///         INTENT, so calldata that minted to somebody else fails there. Re-deriving the
    ///         buyer here would mean this contract having an opinion about a router payload it
    ///         cannot see.
    ///
    /// @param buyer        Who receives the asset.
    /// @param settlementIn The most settlement currency this purchase may consume. The venue takes
    ///                     the exact cost of the quantity it mints, which may be marginally less.
    /// @param minAssetOut  The floor the caller requires. Repricing between quote and execution
    ///                     reverts rather than under-filling.
    /// @return assetMinted      The measured quantity the buyer received.
    /// @return settlementCharged The measured amount this venue actually took.
    function purchase(address buyer, uint256 settlementIn, uint256 minAssetOut)
        external
        onlyRouter
        whenNotPaused
        nonReentrant
        returns (uint256 assetMinted, uint256 settlementCharged)
    {
        // ── 1 · the one caller (see `onlyRouter`), and the arguments ──────────────────────
        if (buyer == address(0)) revert ZeroAddress();
        if (settlementIn == 0) revert ZeroAmount();

        // ── 2 · the cap, before anything external ─────────────────────────────────────────
        uint256 cap = maxSettlementPerPurchase;
        // ⚠️ The `cap == 0` test is not redundant with the comparison beside it. Zero means the
        //    venue cannot sell, and a purchase of zero against a zero cap would pass `0 > 0`.
        //    `settlementIn == 0` is already refused above, so this is belt and braces on a
        //    reading that must not depend on that other check staying where it is.
        if (cap == 0 || settlementIn > cap) revert PurchaseCapExceeded(settlementIn, cap);

        // ── 3 · the quote ─────────────────────────────────────────────────────────────────
        uint256 price = unitPrice;
        assetMinted = Math.mulDiv(settlementIn, ASSET_UNIT, price);
        // A payment too small to buy one unit at the current price would otherwise be a pure
        // debit: money taken, nothing minted. That is not a rounding outcome to absorb.
        if (assetMinted == 0) revert NothingToMint(settlementIn, price);
        // The floor the caller signed for. The router asserts the same thing independently, on
        // the buyer's measured balance; this one fails at the venue and names the venue, which is
        // the difference between "the price moved" and "the venue misbehaved" in a trace.
        if (assetMinted < minAssetOut) revert InsufficientAssetOut(assetMinted, minAssetOut);

        // ── 4 · the price of exactly what is about to be minted ───────────────────────────
        // Ceiling, so the offering is never short-paid for a unit it issues. Provably at most
        // `settlementIn`: `assetMinted = floor(settlementIn * ASSET_UNIT / price)` implies
        // `assetMinted * price <= settlementIn * ASSET_UNIT`, so dividing by `ASSET_UNIT` and
        // taking the ceiling of an integer bound cannot exceed `settlementIn`.
        settlementCharged = Math.mulDiv(assetMinted, price, ASSET_UNIT, Math.Rounding.Ceil);
        // Guarded despite the proof: what this would represent is the venue spending more of the
        // router's allowance than the buyer signed for, which is not a class of bug to leave to
        // an argument in a comment.
        if (settlementCharged > settlementIn) revert ChargeExceedsAuthorised(settlementCharged, settlementIn);

        // ── 5 · pull, and MEASURE what arrived ────────────────────────────────────────────
        // 🔴 What `transferFrom` was ASKED to move is not what this contract RECEIVED. A
        //    fee-on-transfer or deflationary settlement currency debits the payer in full and
        //    credits us less; minting the full quantity against that would put the shortfall in
        //    the issuer's proceeds silently, every purchase. Measured, not quoted — the same
        //    discipline the router applies to its own pull.
        uint256 currencyBefore = SETTLEMENT_TOKEN.balanceOf(address(this));
        SETTLEMENT_TOKEN.safeTransferFrom(msg.sender, address(this), settlementCharged);
        uint256 currencyAfter = SETTLEMENT_TOKEN.balanceOf(address(this));
        // Clamped rather than left to a checked subtraction so a balance that went DOWN reports
        // through the named error instead of an arithmetic panic.
        uint256 received = currencyAfter > currencyBefore ? currencyAfter - currencyBefore : 0;
        // Both directions. A short pull is the deflationary currency above; a surplus would mean
        // the venue minting against money it cannot account for. The consequence — such a
        // currency cannot be sold in at all — is a listing decision taken here rather than
        // discovered in a reconciliation.
        if (received != settlementCharged) revert SettlementPullMismatch(settlementCharged, received);

        // ── 6 · mint, and MEASURE what the buyer received ─────────────────────────────────
        // Against the buyer's own pre-call balance rather than against zero: a primary buyer may
        // already hold the asset from an earlier round, and the quantity that matters is what
        // THIS purchase delivered.
        uint256 buyerBefore = ASSET_TOKEN.balanceOf(buyer);
        _mintAsset(buyer, assetMinted);
        uint256 buyerAfter = ASSET_TOKEN.balanceOf(buyer);
        uint256 delivered = buyerAfter > buyerBefore ? buyerAfter - buyerBefore : 0;
        // Catches a `mint` that no-ops, one that returns `false` rather than reverting, an asset
        // token that charges a transfer fee, and a downward rebase inside the call. `<` rather
        // than `!=`: more than quoted reaching the buyer is somebody else's generosity, not this
        // venue's failure, and refusing an otherwise honest purchase over it would be wrong for
        // the same reason the router forwards rather than reverts on over-delivery.
        if (delivered < assetMinted) revert AssetDeliveryShortfall(delivered, assetMinted);

        // ── 7 · report ────────────────────────────────────────────────────────────────────
        // ⚠️ **`assetMinted`, the quantity issued, NOT `delivered`, the measured delta** — and
        //    the difference is worth the sentence. This contract is the ISSUER of what it emits,
        //    so the number that belongs in an issuance record is the number it created. The
        //    measurement's job is to PROVE that creation happened, which it does as the assertion
        //    directly above, and a `delivered` larger than `assetMinted` can only come from
        //    something that is not this sale — an upward rebase of a position the buyer already
        //    held, triggered inside the call. Reporting that as issuance would put another
        //    party's arithmetic into this offering's cap table. The router's own
        //    `PrimarySettled.assetDelivered` is the measured number, so both readings are on
        //    chain in the same transaction, from the party each belongs to.
        //
        //    `settlementCharged` is the quote and `received` is the measurement, and the two are
        //    asserted equal above, so the equality rather than the choice is what carries here.
        emit IssuanceMinted(
            buyer, address(ASSET_TOKEN), assetMinted, address(SETTLEMENT_TOKEN), settlementCharged, price
        );
    }

    /// @dev 🔴 **THE ONE PLACE this contract assumes anything about how an asset token mints.**
    ///      Everything else on the purchase path treats `ASSET_TOKEN` as a plain ERC-20 and judges
    ///      the outcome on a measured balance delta, so supporting a token whose mint is
    ///      `issue(address,uint256)`, or `mintTo`, or one that takes a partition, is a subclass
    ///      that overrides this function and changes nothing else. `IMintableERC20` exists to
    ///      make that statement checkable rather than aspirational.
    ///
    ///      ⚠️ Do not add a return-value check here. The caller measures the delivery, which
    ///      catches strictly more than any return convention would: a `bool` that lies, a mint
    ///      that silently no-ops, and a token that takes a cut on the way out all fail the same
    ///      assertion.
    ///
    /// @param to     The buyer. Never this contract.
    /// @param amount The quantity, in the asset token's own smallest unit.
    function _mintAsset(address to, uint256 amount) internal virtual {
        IMintableERC20(address(ASSET_TOKEN)).mint(to, amount);
    }

    // --------------------------------------------------------------------- //
    //                                 Quotes                                 //
    // --------------------------------------------------------------------- //

    /// @notice What `settlementIn` buys right now, and what it would actually cost.
    ///
    /// @dev    The function whatever builds a settlement intent off-chain should CALL to fill in
    ///         `venueQuoteIn` and `minAssetOut`, rather than reimplementing the arithmetic. Two
    ///         implementations of the same rounding is how an off-by-one-wei disagreement gets
    ///         shipped, and here it would make every purchase whose price does not divide exactly
    ///         revert at the delivery floor.
    ///
    ///         Reverts on the same two conditions `purchase` does — a zero payment and a payment
    ///         too small to mint anything — so a caller that gets an answer can act on it.
    ///
    /// @param settlementIn The payment being considered, in settlement-token units.
    /// @return assetOut          The quantity that payment buys, floored.
    /// @return settlementCharged The exact cost of that quantity, at most `settlementIn`.
    function quoteAssetOut(uint256 settlementIn) external view returns (uint256 assetOut, uint256 settlementCharged) {
        if (settlementIn == 0) revert ZeroAmount();
        uint256 price = unitPrice;
        assetOut = Math.mulDiv(settlementIn, ASSET_UNIT, price);
        if (assetOut == 0) revert NothingToMint(settlementIn, price);
        settlementCharged = Math.mulDiv(assetOut, price, ASSET_UNIT, Math.Rounding.Ceil);
    }

    /// @notice What `assetOut` of the asset costs right now.
    ///
    /// @dev    The inverse of `quoteAssetOut`, for the "I want N units" side of a front end. Note
    ///         that feeding this answer back into `quoteAssetOut` can return slightly MORE than
    ///         `assetOut`, because both directions round in the offering's favour; that is
    ///         correct and is why `purchase` prices the quantity it derived rather than trusting
    ///         a quantity it was handed.
    ///
    /// @param assetOut The quantity being considered, in asset-token units.
    /// @return The cost in settlement-token units, rounded up.
    function quoteSettlementIn(uint256 assetOut) external view returns (uint256) {
        if (assetOut == 0) revert ZeroAmount();
        return Math.mulDiv(assetOut, unitPrice, ASSET_UNIT, Math.Rounding.Ceil);
    }

    // --------------------------------------------------------------------- //
    //                             Admin surface                              //
    // --------------------------------------------------------------------- //

    /// @notice Reprice the offering.
    /// @dev `RATE_SETTER_ROLE` — the compliance officers who price primary offers through our
    ///      interface. Allowed while paused: repricing a stopped offering is how it gets ready to
    ///      restart, and forbidding it would only mean unpausing at the old price first.
    ///
    ///      ⚠️ A repricing is not retroactive and is not coordinated with intents in flight. An
    ///      intent signed at the old price and executed after this reverts at the delivery floor
    ///      if the new price is worse for the buyer, and simply fills better if it is not. That is
    ///      the intended behaviour and it is why the floor is a signed field rather than a
    ///      tolerance.
    /// @param newUnitPrice The new price of one whole asset token, in settlement-token units.
    function setUnitPrice(uint256 newUnitPrice) external onlyRole(RATE_SETTER_ROLE) {
        _setUnitPrice(newUnitPrice);
    }

    /// @notice Set the per-purchase settlement cap.
    /// @dev `DEFAULT_ADMIN_ROLE`, deliberately NOT `RATE_SETTER_ROLE`: the cap is a check on what
    ///      a mis-set price can do, so letting the key that sets the price also raise the ceiling
    ///      would leave no ceiling. Same reasoning, same split, as the router's caps module.
    ///
    ///      Set in WHOLE settlement tokens and stored raw, so the calldata a Safe signer reads is
    ///      the number they meant and the purchase path stays a bare comparison.
    ///      ⚠️ Zero CLOSES the venue.
    /// @param wholeUnits The cap in whole settlement tokens, or zero to close the venue.
    function setMaxSettlementPerPurchase(uint256 wholeUnits) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setPurchaseCap(wholeUnits);
    }

    /// @notice Stop purchases.
    /// @dev `PAUSER_ROLE`. See the role's own documentation for why it cannot unpause.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resume purchases.
    /// @dev `DEFAULT_ADMIN_ROLE` only.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // --------------------------------------------------------------------- //
    //                                Proceeds                                //
    // --------------------------------------------------------------------- //

    /// @notice Move accumulated settlement currency out of the venue.
    ///
    /// @dev    `TREASURY_ROLE` — the issuer. This is the reason the role exists: proceeds land
    ///         here rather than being forwarded during a purchase (the argument is in the
    ///         contract header), so there has to be a way to take them out.
    ///
    ///         **Works while paused, deliberately.** A stopped offering is exactly the situation
    ///         in which an issuer most needs to be able to reach the money, and coupling the two
    ///         would mean reopening a sale somebody stopped in order to settle it.
    ///
    ///         The destination is an argument rather than stored configuration. A stored
    ///         forwarding address is a target that can be pre-set by a key that later leaks and
    ///         then used by a different key; a per-call one is chosen by the same transaction that
    ///         authorises the movement, and it is on the event either way.
    ///
    /// @param to     Where the proceeds go.
    /// @param amount How much to move. The caller reads `SETTLEMENT_TOKEN.balanceOf(venue)` to
    ///               drain it; this function takes an explicit number so a partial withdrawal is
    ///               the ordinary case rather than a special one.
    function withdraw(address to, uint256 amount) external onlyRole(TREASURY_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        SETTLEMENT_TOKEN.safeTransfer(to, amount);
        emit ProceedsWithdrawn(to, amount);
    }

    /// @notice Sweep a token that is not the settlement currency out of the venue.
    ///
    /// @dev    `TREASURY_ROLE`. This contract holds no token but the settlement currency by
    ///         design — it never takes custody of the asset it mints, which goes straight to the
    ///         buyer — so anything else here arrived by accident and would otherwise be stranded.
    ///
    ///         ⚠️ It refuses the settlement currency by name. Proceeds must leave through
    ///         `withdraw`, so that an issuer's accounting can read one event for one meaning
    ///         instead of reconciling two paths that move the same token.
    ///
    /// @param token  The token to sweep. Not the settlement currency.
    /// @param to     Where it goes.
    /// @param amount How much to move.
    function rescue(address token, address to, uint256 amount) external onlyRole(TREASURY_ROLE) nonReentrant {
        if (token == address(SETTLEMENT_TOKEN)) revert RescueOfSettlementToken();
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
    }

    // --------------------------------------------------------------------- //
    //                                Internals                               //
    // --------------------------------------------------------------------- //

    /// @dev Shared by the constructor and the setter so the bounds are enforced in one place and
    ///      an opening price can never bypass the check a repricing is subject to.
    /// @param newUnitPrice The candidate price.
    function _setUnitPrice(uint256 newUnitPrice) private {
        if (newUnitPrice < MIN_UNIT_PRICE || newUnitPrice > MAX_UNIT_PRICE) {
            revert UnitPriceOutOfBounds(newUnitPrice, MIN_UNIT_PRICE, MAX_UNIT_PRICE);
        }
        emit UnitPriceSet(unitPrice, newUnitPrice);
        unitPrice = newUnitPrice;
    }

    /// @dev Shared by the constructor and the setter. The conversion from whole units happens
    ///      here and only here, once per admin action, never on the purchase path.
    /// @param wholeUnits The cap in whole settlement tokens, or zero to close the venue.
    function _setPurchaseCap(uint256 wholeUnits) private {
        // Checked arithmetic: a `wholeUnits` large enough to overflow at this scale panics rather
        // than wrapping, which still fails closed and leaves the venue unable to sell.
        uint256 rawCap = wholeUnits * (10 ** uint256(SETTLEMENT_DECIMALS));

        maxSettlementPerPurchase = rawCap;
        maxSettlementPerPurchaseWholeUnits = wholeUnits;

        emit PurchaseCapSet(wholeUnits, rawCap, SETTLEMENT_DECIMALS);
    }

    /// @dev A token's decimals, bounded to something a real token could report.
    ///
    ///      An address with no code, or one whose `decimals()` returns something that does not
    ///      decode, reverts here and aborts the deployment. That is the whole error handling this
    ///      needs: it happens once, at deployment, in front of the person who supplied the
    ///      address. See the constructor for why it does not copy the router's guarded form.
    ///
    /// @param token The token to interrogate.
    /// @return Its decimals.
    function _readDecimals(address token) private view returns (uint8) {
        uint8 d = IERC20Metadata(token).decimals();
        if (d > MAX_TOKEN_DECIMALS) revert TokenDecimalsImplausible(token, d);
        return d;
    }
}
