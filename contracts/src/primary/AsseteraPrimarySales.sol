// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {ERC2771ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {VenueSettler} from "./settle/VenueSettler.sol";
import {PrimaryTypes} from "./types/PrimaryTypes.sol";

/// @title AsseteraPrimarySales — the constrained executor for primary market settlement
/// @notice The router a buyer's FIRST acquisition of an asset goes through: we take the
///         buyer's settlement currency, obtain the asset from wherever it comes from, deliver
///         it, refund what was not spent and charge our fee. The exchange
///         (`AsseteraECS`) is the secondary market and is a different contract, on purpose.
///
///         **There is ONE settlement family, and this router holds no minting right on any
///         path.** It is `VenueSettler` — the constrained executor below, an `abstract
///         contract` module inherited into THIS one proxy, the same shape as
///         `OrderBook`/`OfferBook` inside `AsseteraECS`, not a separate deployment and not a
///         `delegatecall` target. It calls somebody else's contract with calldata we did not
///         author and judges the settlement on the balance deltas it measured afterwards.
///
///         **Our own primary issuance is reached through that same path**, with the venue being
///         a per-token sale contract we call exactly as we call Backed or Dinari. That contract
///         is deployed one per token during issuer onboarding; holds the conversion rate and the
///         settlement currency, set by us because pricing a primary offer is a compliance
///         function performed through our interface; is granted the minting right BY THE ISSUER,
///         so no minting right is ever held here; mints only against payment it has actually
///         received from its caller, the way Backed will not mint unless it receives the USDC;
///         refuses every caller but this router, because the KYC and fee gates live here; lets
///         the issuer withdraw the proceeds, with an optional forwarding address; carries an
///         optional issuance cap; and has immutable logic with rotatable role addresses.
///
///         🔴 **The reason is a security one, not a tidiness one: that sale contract is the only
///         control in the whole design that actually bounds a compromised settlement signer.**
///         Every other candidate was tried and failed. A venue allowlist does not help, because
///         the attacker names the genuine venue. A value cap does not help, because it bounds
///         the wrong quantity. A structural recipient on a mint path does not help, because the
///         attacker simply sets themselves as `intent.buyer`. The sale contract DOES help,
///         because the economics are enforced on-chain by a contract we do not have to trust a
///         signature for: craft an intent with a zero quote and the sale contract's own pull
///         from this router fails, so nothing is minted. **The signer cannot mint without
///         paying, whatever they sign.** A `MintSettler` module holding the minting right inside
///         this proxy would have had no such property, which is why it was deleted rather than
///         left waiting to be filled (2026-08-14).
///
///         Building the sale contract is AO-137 and lives OUTSIDE this repo's current scope.
///         Nothing here has to change when it lands: to this router it is an address in a signed
///         intent, like any other venue.
///
///         Why a separate proxy rather than a module inside the exchange: a separate pause
///         lever, a separate audit scope, a separate upgrade cadence and, above all, a
///         separate blast radius — the exchange holds every open order's escrow and a
///         primary-sale bug must not be able to reach it. It also simply does not fit;
///         `AsseteraECS` has under 2 kB of EIP-170 margin left.
///
///         **Four signatures, four signers, three nonce namespaces.** A settlement needs a KYC
///         attestation (compliance backend), a fee attestation (fee service), a settlement
///         intent (settlement operator) and the BUYER's own signature over that same intent.
///         All four are verified before any nonce is burned, so an invalid one cannot spend the
///         others. `SETTLEMENT_OPERATOR_ROLE` is distinct from the other two service roles
///         because it is the only one whose holder can cause a transfer.
///
///         The buyer's signature is the one that is not ours, and it is what keeps
///         `minAssetOut` meaningful: without it a compromised settlement operator sets the
///         delivery floor to one wei and the buyer's own transaction pays for it. Wallet
///         simulation would normally catch that, but ERC-2771 destroys it — the buyer signs a
///         `ForwardRequest` whose `data` is opaque bytes no wallet can render as balance
///         changes — so an EIP-712 payload with named fields is what gives the protection back.
///         Three nonce namespaces rather than four: the buyer signs the intent, so the intent's
///         own single-use nonce is the buyer's replay protection too.
///
///         **A different EIP-712 domain from the exchange's**, so cross-contract attestation
///         replay is impossible by construction rather than by check: an attestation minted
///         for `AsseteraECS` recovers to a different address here and is rejected.
///
///         **No on-chain allowlist of venues, selectors, assets or currencies.** Decided
///         2026-08-13 after three rounds of narrowing; see `IntentGate` for the reasoning and
///         `ISettlementLimits` for what absorbs the loss instead.
///
///         Identity is resolved via `_msgSender()` (ERC-2771) with the same trusted forwarder
///         as the exchange, so a gasless primary sale works the way a gasless order does.
///
/// @dev    Assembled as: `PrimaryTypes` → `PrimaryStorage` (is `FeeGate`) → `IntentGate` →
///         `SettlementLimits` → `VenueSettler` → this file, which adds the three concerns only
///         the final contract needs (`Initializable`, `UUPSUpgradeable`,
///         `ERC2771ContextUpgradeable`) plus the initializer, the admin surface and the frozen
///         entry point.
///
///         ⚠️ **This file owns the inheritance list.** The settlement money path is
///         `VenueSettler`'s and changes there; nothing here should need to change with it.
contract AsseteraPrimarySales is PrimaryTypes, Initializable, UUPSUpgradeable, VenueSettler, ERC2771ContextUpgradeable {
    /// @notice The fee-collector allowlist changed.
    event CollectorAllowed(address indexed collector, bool allowed);
    /// @notice The KYC gate for one primary-sale action was toggled.
    event ComplianceRequiredSet(Action indexed action, bool required);
    /// @notice Native currency was passed through to a venue as part of a whitelist handshake.
    /// @param destination The address the venue nominated.
    /// @param amount      The `msg.value` forwarded, in full, in the same call.
    event WhitelistHandshake(address indexed destination, uint256 amount);

    /// @dev The handshake destination rejected the transfer, or reverted. The whole call goes
    ///      with it: a handshake that half-happened would leave this contract holding native
    ///      currency it has no way to move again.
    error HandshakeTransferFailed(address destination, uint256 amount);

    /// @param trustedForwarder ERC-2771 forwarder (relayer) — the SAME address the exchange
    ///        uses, so the relayer story is unchanged. Immutable in implementation bytecode,
    ///        therefore proxy-safe. `address(0)` disables meta-transactions.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address trustedForwarder) ERC2771ContextUpgradeable(trustedForwarder) {
        _disableInitializers();
    }

    /// @notice Initialise the proxy.
    /// @param admin            DEFAULT_ADMIN_ROLE (upgrade, role management, pause, caps,
    ///                         collector allowlist). Multisig in production.
    /// @param kycSigner        Initial KYC_OPERATOR_ROLE holder (the compliance backend).
    /// @param feeSigner        Initial FEE_OPERATOR_ROLE holder (the fee service).
    /// @param settlementSigner Initial SETTLEMENT_OPERATOR_ROLE holder (the settlement
    ///                         operator). ⚠️ Give it its OWN key. It is the only one of the
    ///                         three that can cause a transfer.
    function initialize(address admin, address kycSigner, address feeSigner, address settlementSigner)
        external
        initializer
    {
        if (admin == address(0) || kycSigner == address(0) || feeSigner == address(0) || settlementSigner == address(0))
        {
            revert ZeroAddress();
        }

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        // ⚠️ DELIBERATELY DIFFERENT from the exchange's "AsseteraExchange". The domain
        //    separator is hashed from this string together with the verifying contract, so a
        //    distinct name makes cross-contract attestation replay impossible by construction
        //    — an exchange attestation recovers to a different address here and is rejected as
        //    `KycBadSigner`, pinned by `test_ExchangeAttestation_CannotBeReplayedHere`.
        //    `AsseteraSignerService` learns this domain through the per-chain allowlist IT
        //    owns; the caller never supplies a verifying contract. Renaming it later would
        //    invalidate every attestation and every intent in flight, and would not even take
        //    effect on a live proxy: OZ v5 keeps `_name` in namespaced storage written only by
        //    this `onlyInitializing` call.
        __EIP712_init("AsseteraPrimarySales", "1");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(KYC_OPERATOR_ROLE, kycSigner);
        _grantRole(FEE_OPERATOR_ROLE, feeSigner);
        _grantRole(SETTLEMENT_OPERATOR_ROLE, settlementSigner);

        // ⚠️ **There is deliberately NO enumeration of `Action` here, and its absence is the
        //    fix.** This initializer used to write `complianceRequired[action] = true` for every
        //    declared action, guarded by a comment and a test. That arrangement gated exactly
        //    the actions somebody remembered: the shared mapping is fail-OPEN, so the day an
        //    ordinal is appended to `PrimaryTypes.Action` without a matching line here, it reads
        //    `false`, `KycGate._verifyKyc` returns on its first line, and the new settlement path
        //    is an UNGATED primary sale. A list that must be kept in step with an enum is the
        //    defect, not the safeguard.
        //
        //    The `complianceRequired` override below inverts the default for this router, so
        //    every ordinal — declared, undeclared, or added years from now — is gated until an
        //    admin explicitly exempts it. Nothing needs to be written at initialization for that
        //    to hold, which is why nothing is.
    }

    // --------------------------------------------------------------------- //
    //                            The entry point                            //
    // --------------------------------------------------------------------- //

    /// @notice Settle one primary purchase against a venue. THE only settlement entry point:
    ///         a third party's contract and the per-token sale contract that fronts our own
    ///         issuance both arrive here, and this function cannot tell them apart because
    ///         there is nothing to tell apart — both are an address in a signed intent.
    ///
    ///         The buyer is debited at most `intent.maxSettlementIn`, the venue is approved
    ///         exactly `intent.venueQuoteIn` and may take less, whatever it does not take is
    ///         refunded in the same transaction, `intent.buyerFee` goes to the allowlisted
    ///         collector, and the buyer must end up holding at least `intent.minAssetOut` of
    ///         `intent.assetToken` or the whole transaction reverts.
    ///
    /// @dev    ⚠️ **This signature is FROZEN.** The signer service builds `intent`, the
    ///         marketplace API assembles the call and the indexer decodes the resulting
    ///         `PrimarySettled`. Neither signature is a field of the struct, because a struct
    ///         cannot contain the signature over itself.
    ///
    ///         ⚠️ **`buyerSignature` changed this SELECTOR and changed no signed payload.**
    ///         `SettlementIntent` is untouched, so `INTENT_TYPEHASH`, every digest, every
    ///         `paramsHash` binding and every attestation in flight are exactly what they were;
    ///         the buyer signs the SAME digest the settlement operator does. The frozen-payload
    ///         warnings on the struct in `PrimaryTypes` are about the struct, not about this
    ///         parameter list. What DOES have to be rebuilt is the caller: the marketplace API
    ///         now collects a second signature and passes one more argument.
    ///
    ///         Order of operations, and why:
    ///           1. all four signatures are verified BEFORE any nonce is burned, so an invalid
    ///              one cannot spend the others;
    ///           2. `orderId` is passed as a literal zero, which is how a non-zero one on the
    ///              KYC attestation is rejected (`KycOrderMismatch`). There is no order book on
    ///              this path, and leaving the field free would create a second, unchecked
    ///              degree of freedom in a signature the compliance signer produces;
    ///           3. the money is the settler family's job, behind an internal seam, so this
    ///              file does not change when a family lands.
    ///
    /// @param venueCalldata   The opaque bytes to hand the venue. Bound by
    ///                        `intent.calldataHash` and `intent.selector`; never what the
    ///                        policy is expressed in.
    /// @param intent          The settlement intent, signed by the settlement operator and by
    ///                        the buyer.
    /// @param intentSignature That operator's EIP-712 signature over `intent`. Accepted only if
    ///                        it recovers to a `SETTLEMENT_OPERATOR_ROLE` holder.
    /// @param buyerSignature  The BUYER's EIP-712 signature over the SAME digest, EOA or
    ///                        ERC-1271. Accepted only if it validates for `intent.buyer`. The
    ///                        two are over one payload and are not interchangeable.
    /// @param kyc             The compliance attestation, `paramsHash`-bound to `intent`.
    /// @param fee             The fee attestation, `paramsHash`-bound to `intent`.
    function settlePrimary(
        bytes calldata venueCalldata,
        SettlementIntent calldata intent,
        bytes calldata intentSignature,
        bytes calldata buyerSignature,
        KycAttestation calldata kyc,
        FeeAttestation calldata fee
    ) external whenNotPaused nonReentrant {
        // Hardcoded, never taken from the caller or from the intent: the action ordinal is what
        // the two attestations are signed against, so letting the request choose it would let a
        // request choose which compliance policy it is screened under. This literal is also the
        // whole reason `Action.SettleMint` is unreachable today — see the enum.
        uint8 action = uint8(Action.SettleVenue);

        bytes32 paramsHash = _verifyIntent(intent, intentSignature, buyerSignature);
        _bindCalldata(venueCalldata, intent);
        // The router does not control the proceeds side of a venue settlement, so an
        // issuer-side fee cannot be charged here. Attesting one must revert rather than
        // silently do nothing.
        //
        // ⚠️ This holds on EVERY path, including our own issuance, and that is a consequence of
        //    the sale-contract design rather than an oversight. When we are the issuer the
        //    proceeds sit in the sale contract and the issuer withdraws them from there; the
        //    conversion rate we set is where the issuer economics are expressed. An earlier
        //    revision of this comment said the mint family "does not carry this restriction",
        //    written when a mint family was going to exist inside this proxy. It does not, so
        //    neither does the exception.
        //
        // ⚠️ BEFORE `_bindAttestations`, and the order is the point rather than an accident.
        //    Behind it, a non-zero maker fee attested against a collector that is not on this
        //    router's allowlist reverted with `FeeCollectorNotAllowed` — a true statement about
        //    a request whose actual defect is that this family cannot charge a maker fee at
        //    all, sending whoever reads the revert to fix the wrong thing. The specific error
        //    wins. Pinned by `test_SettlePrimary_RejectsANonZeroMakerFeeBeforeTheCollectorChecks`,
        //    because this is exactly the kind of line a later tidy-up reorders back.
        if (fee.makerFeeBps != 0) revert MakerFeeNotSupported();
        // The shared preamble: both attestations bound, the per-transaction value cap charged,
        // all three nonces burned. It is shared so that the cap is charged FOR every settlement
        // path rather than BY every settlement path — see `SettlementLimits._authorizeSettlement`.
        _authorizeSettlement(action, intent, paramsHash, kyc, fee);

        // `fee.takerFeeBps` is carried into the settler so it can cross-check `intent.buyerFee`
        // against what the FEE signer attested. Two independent signers must agree on one
        // number; without this the basis points are decorative. Internal signature only.
        SettlementResult memory result = _settleVenue(venueCalldata, intent, fee.takerFeeBps);

        // Every amount below is MEASURED by the family, every identifier is one the settlement
        // operator signed. That split is what lets `AsseteraEvmIndexerService` build an
        // activity-ledger leg with no supplier-specific decoder — nothing here is relayed from
        // whatever the venue chose to emit. ⚠️ `ISettler.PrimarySettled` is FROZEN: `topic0` is
        // derived from its signature, so a field added, reordered or retyped stops matching the
        // deployed filter silently.
        emit PrimarySettled(
            intent.buyer,
            intent.assetToken,
            intent.venue,
            result.assetDelivered,
            intent.settlementToken,
            result.venueIn,
            result.refund,
            result.fee,
            intent.feeCollector,
            intent.supplierReference,
            intent.nonce
        );
    }

    // --------------------------------------------------------------------- //
    //                          Gate action policy                           //
    // --------------------------------------------------------------------- //

    /// @dev This router's answer to `KycGate._paramsHashAllowed`: TRUE for every action it
    ///      declares, because every primary-sale action binds an intent and the attestation's
    ///      `paramsHash` IS that intent's EIP-712 struct hash. The gate's default is the
    ///      restrictive "no action binds parameters", which would reject every settlement, so
    ///      this override is load-bearing rather than cosmetic.
    ///
    ///      `Action.None` is excluded deliberately: ordinal zero is an unset field, never a
    ///      real action, and it must not be able to carry a bound `paramsHash`.
    ///
    ///      `Action.SettleMint` is included even though nothing in `src/` runs under it. It is a
    ///      RESERVED ordinal rather than a dead one (see `PrimaryTypes.Action`), and the answer
    ///      to "does this action bind an intent" is a property of the action, not of whether an
    ///      entry point happens to exist yet. Answering `false` here would be the one that has
    ///      to be remembered later; answering `true` costs nothing, because an ordinal with no
    ///      entry point cannot present an attestation at all.
    function _paramsHashAllowed(uint8 action) internal view virtual override returns (bool) {
        return action == uint8(Action.SettleVenue) || action == uint8(Action.SettleMint);
    }

    /// @notice Whether an action requires a KYC attestation on THIS router.
    ///
    /// @dev    🔴 **The fail-open default of `GateStorage.complianceRequired`, closed — for this
    ///         contract only, and structurally rather than by convention.**
    ///
    ///         The shared getter reads a `mapping(uint8 => bool)` in which an action nobody wrote
    ///         reads `false`, and `KycGate._verifyKyc` returns on its first line when it does. On
    ///         the exchange that is held safe by an initializer that enumerates every action and
    ///         a test that re-enumerates them; on a primary-sales router, where a single ungated
    ///         action is an unscreened first acquisition of a security, "somebody remembered" is
    ///         not a control. Appending an `Action` and forgetting a line is the entire failure
    ///         mode, and it produces no compile error and no failing test.
    ///
    ///         So this router stores the INVERSE — an exemption — in its own ERC-7201 namespace,
    ///         where the zero value means "not exempt". Every `uint8`, declared or not, is
    ///         therefore gated from the moment the proxy is initialised, with nothing written and
    ///         nothing to keep in step. `test_ComplianceGate_IsClosedForEveryOrdinal` fuzzes the
    ///         whole domain; it is the assertion the previous arrangement could not make.
    ///
    ///         ⚠️ **The shared `GateStorage` and `KycGate` are untouched in meaning and in
    ///         storage.** The exchange does not override this getter, so its live
    ///         `complianceRequired` mapping is read exactly as before. The `virtual` keyword on
    ///         the base getter is the whole of the shared change; every gate reaches the policy
    ///         through the function, so the override binds all of them (`_verifyKyc`,
    ///         `_consumeKyc`, `_consumeKycAndFee`, `_bindParamsHash`).
    ///
    ///         ⚠️ Consequence worth knowing: `_gate().complianceRequired` is DEAD storage for
    ///         this proxy. Nothing reads it. A future module that reads the mapping instead of
    ///         calling this function would silently reopen the gate.
    ///
    /// @param  action The action ordinal.
    /// @return Whether a KYC attestation is required for it.
    function complianceRequired(uint8 action) public view override returns (bool) {
        return !_primary().complianceExempt[action];
    }

    // --------------------------------------------------------------------- //
    //                             Admin surface                             //
    // --------------------------------------------------------------------- //

    /// @notice Add or remove an address from this router's fee-collector allowlist.
    /// @dev A separate proxy means separate gate storage, so this allowlist is this
    ///      contract's own and starts EMPTY — the exchange's entries do not carry over. A
    ///      non-zero fee cannot be settled until a collector is listed here.
    /// @param collector The candidate fee recipient.
    /// @param allowed   Whether it is allowed.
    function setAllowedCollector(address collector, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _gate().allowedCollectors[collector] = allowed;
        emit CollectorAllowed(collector, allowed);
    }

    /// @notice Toggle the KYC gate for one primary-sale action.
    /// @dev KYC ONLY. Turning it off does NOT disable fee verification (AC-884), and it does
    ///      NOT disable intent verification either — a settlement always needs a valid intent
    ///      from the settlement operator. Keeps the `Action` enum in its external signature so
    ///      a Safe transaction is readable.
    ///
    ///      ⚠️ Writes the INVERSE flag in this router's own namespace, because that is what
    ///      `complianceRequired` above reads. The signature, the event and the observable
    ///      behaviour of this call are unchanged — `setComplianceRequired(a, false)` still makes
    ///      `complianceRequired(a)` return `false`. What changed is only which way round an
    ///      untouched action reads, and that is the whole point: an admin can still exempt an
    ///      action deliberately, but nobody can exempt one by forgetting about it.
    /// @param action   The action to toggle.
    /// @param required Whether a KYC attestation is required for it.
    function setComplianceRequired(Action action, bool required) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _primary().complianceExempt[uint8(action)] = !required;
        emit ComplianceRequiredSet(action, required);
    }

    /// @notice Pass native currency straight through to `destination`, in one call, as part of a
    ///         third-party venue's funding-wallet whitelist handshake. Admin only.
    ///
    ///         Venues such as Backed onboard a funding wallet by having it nominate an address
    ///         and move a token amount of native currency to it. Nothing else in `src/` is
    ///         `payable` and there is no `receive()`, so without this the router simply cannot
    ///         take part — and the funding wallet has to be the router, because the router is
    ///         what holds the allowances and makes the calls.
    ///
    /// @dev    ⚠️ **Pass-through only. There is deliberately NO `receive()` and NO sweep, and
    ///         that is the whole design rather than an omission.** Holding a balance and
    ///         sweeping it later is the obvious shape and the worse one:
    ///
    ///           * with pass-through only, a stray value transfer to this router still REVERTS,
    ///             so nothing accumulates by accident and there is never dust to strand;
    ///           * nothing is ever held, so there is no sweep function to get the access control
    ///             on, and no window in which a balance exists for anyone to argue about;
    ///           * the zero-standing-balance invariant `VenueSettler` asserts on the settlement
    ///             token stays a FLAT statement about this contract, instead of acquiring a
    ///             native-currency exception every future reader has to hold in their head.
    ///
    ///         If a venue ever needs the router to receive rather than send, that is a new
    ///         decision with a new threat model, not an incremental relaxation of this one.
    ///
    ///         A low-level `call`, not `transfer`: the 2 300-gas stipend fails against a
    ///         contract destination, and a venue's nominated address is as likely to be a Safe
    ///         as an EOA. There is no reentrancy surface to protect — no state is read or
    ///         written here, and the caller is already `DEFAULT_ADMIN_ROLE`.
    ///
    /// @param destination The address the venue nominated. Never `address(0)`.
    function whitelistHandshake(address destination) external payable onlyRole(DEFAULT_ADMIN_ROLE) {
        if (destination == address(0)) revert ZeroAddress();

        // solhint-disable-next-line avoid-low-level-calls
        (bool ok,) = destination.call{value: msg.value}("");
        if (!ok) revert HandshakeTransferFailed(destination, msg.value);

        emit WhitelistHandshake(destination, msg.value);
    }

    /// @notice "Stop primary sales" lever, independent of the exchange's. Admin only.
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Resume primary sales. Admin only.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // --------------------------------------------------------------------- //
    //                       UUPS + ERC-2771 plumbing                        //
    // --------------------------------------------------------------------- //

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /// @dev First release. Nothing on chain reads it; it is the string ops uses to identify a
    ///      deployed implementation. The MAJOR digit is the signal for a storage break.
    function version() external pure virtual returns (string memory) {
        return "1.0.0";
    }

    function _msgSender() internal view override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (address) {
        return ERC2771ContextUpgradeable._msgSender();
    }

    function _msgData() internal view override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (bytes calldata) {
        return ERC2771ContextUpgradeable._msgData();
    }

    function _contextSuffixLength()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (uint256)
    {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }
}
