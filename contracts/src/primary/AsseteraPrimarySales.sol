// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {ERC2771ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {VenueSettler} from "./settle/VenueSettler.sol";
import {MintSettler} from "./settle/MintSettler.sol";
import {PrimaryTypes} from "./types/PrimaryTypes.sol";

/// @title AsseteraPrimarySales — the constrained executor for primary market settlement
/// @notice The router a buyer's FIRST acquisition of an asset goes through: we take the
///         buyer's settlement currency, obtain the asset from wherever it comes from, deliver
///         it, refund what was not spent and charge our fee. The exchange
///         (`AsseteraECS`) is the secondary market and is a different contract, on purpose.
///
///         There are two settlement families, and they are `abstract contract` modules
///         inherited into THIS one proxy — the same shape as `OrderBook`/`OfferBook` inside
///         `AsseteraECS`, not separate deployments and not `delegatecall` targets:
///
///           * **S2 · third-party venue** (`VenueSettler`) — the constrained executor below.
///             We hold no minting right, so we call somebody else's contract with calldata we
///             did not author.
///           * **S1 · mint** (`MintSettler`) — we hold the minting right, so there is no venue
///             and no arbitrary calldata at all.
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
///         `SettlementLimits` → {`VenueSettler`, `MintSettler`} → this file, which adds the
///         three concerns only the final contract needs (`Initializable`, `UUPSUpgradeable`,
///         `ERC2771ContextUpgradeable`) plus the initializer, the admin surface and the frozen
///         entry point.
///
///         ⚠️ **This file owns the inheritance list and the module stubs.** The family packets
///         add to their own module file only. Nothing here should need to change when a family
///         is implemented.
contract AsseteraPrimarySales is
    PrimaryTypes,
    Initializable,
    UUPSUpgradeable,
    VenueSettler,
    MintSettler,
    ERC2771ContextUpgradeable
{
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

        // ⚠️ EVERY action declared in `PrimaryTypes.Action` MUST appear below.
        //    `complianceRequired` is a `mapping(uint8 => bool)` and is fail-OPEN: an action
        //    nobody enables reads `false` and `KycGate._verifyKyc` returns on its first line,
        //    so a forgotten action is an UNGATED primary sale rather than a gated one. A
        //    comment is not enough to prevent that, which is why
        //    `test_Initialize_GatesEveryDeclaredAction` asserts it action by action.
        //
        //    `Action.SettleMint` is enabled here even though the mint family has no entry
        //    point yet. Enabling the gate BEFORE the feature exists is the point: the mint
        //    packet inherits a closed gate instead of having to remember to close one.
        GateData storage $ = _gate();
        $.complianceRequired[uint8(Action.SettleVenue)] = true;
        $.complianceRequired[uint8(Action.SettleMint)] = true;
    }

    // --------------------------------------------------------------------- //
    //                            The entry point                            //
    // --------------------------------------------------------------------- //

    /// @notice Settle one primary purchase against a third-party venue (family S2).
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
        uint8 action = uint8(Action.SettleVenue);

        bytes32 paramsHash = _verifyIntent(intent, intentSignature, buyerSignature);
        _bindCalldata(venueCalldata, intent);
        _bindAttestations(intent, paramsHash, kyc, fee);
        // Family S2 only: on a third-party venue we do not control the proceeds side, so an
        // issuer-side fee cannot be charged. Attesting one must revert rather than silently do
        // nothing. The mint family, where we ARE the issuer, does not carry this restriction.
        if (fee.makerFeeBps != 0) revert MakerFeeNotSupported();

        _consumeKycAndFee(intent.buyer, action, 0, kyc, fee);
        _consumeIntent(action, intent);

        // `fee.takerFeeBps` is carried into the family so it can cross-check `intent.buyerFee`
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
    function _paramsHashAllowed(uint8 action) internal view virtual override returns (bool) {
        return action == uint8(Action.SettleVenue) || action == uint8(Action.SettleMint);
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
    /// @param action   The action to toggle.
    /// @param required Whether a KYC attestation is required for it.
    function setComplianceRequired(Action action, bool required) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _gate().complianceRequired[uint8(action)] = required;
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
