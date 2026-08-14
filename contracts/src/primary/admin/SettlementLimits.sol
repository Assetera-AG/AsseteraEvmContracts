// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IntentGate} from "../IntentGate.sol";
import {ISettlementLimits} from "../interfaces/ISettlementLimits.sol";

/// @title SettlementLimits
/// @notice A per-transaction cap on settled value, per settlement token. This module stores it,
///         compares against it, and — through `_authorizeSettlement` — CHARGES it, once, for
///         every settler family.
///
///         ⚠️ **The charge is central, and it did not use to be.** It was `VenueSettler`'s step
///         1, called by family S2 and by nothing else; `MintSettler` is a stub whose documented
///         preamble omitted it, so the mint family could have shipped with no cap applied and
///         nothing structural would have stopped it. A per-transaction cap each family opts into
///         is not a cap. It now sits in the preamble every family must run to burn the intent
///         nonce, so no family can debit without having been charged.
///
///         ⚠️ The number charged is `venueQuoteIn + buyerFee`, the FULL authorised debit, before
///         any external call, because the refund is not known until after a venue has been
///         called and a charge made afterwards would be a check made after the money moved. An
///         earlier revision of this file described the charge as "the amount actually debited,
///         after the refund is known"; that is not what happens and the wording is gone. The
///         full debit is the conservative reading: never below the net one, so the cap can only
///         ever bite earlier.
///
///         **Size this as a bound on BUGS, not as a loss limit.** See `ISettlementLimits` for
///         why the per-day cap that used to live here was withdrawn on 2026-08-14: what bounds a
///         compromised signer is the sum of live buyer allowances, not a number in this
///         contract, and any cap set high enough not to hinder a regulated brokerage sits above
///         that sum anyway. What a per-transaction cap catches, cheaply and reliably, is an
///         arithmetic or decimals mistake — a factor of a trillion between 6-decimal and
///         18-decimal units — which is a real and common failure in this kind of integration.
///         Ten to a hundred times the largest plausible order never fires in normal business and
///         still turns that bug into a revert.
///
///         **The cap is set in WHOLE TOKENS and stored in raw units.** That is how one setter
///         works across currencies with different decimals: `decimals()` is read once, in the
///         admin call, and never on the settlement path, which stays a pure comparison with no
///         external call. It also keeps the Safe calldata readable, which is the same reason
///         `ExchangeAdmin` is shaped the way it is.
///
/// @dev    ⚠️ **A ZERO cap means "no settlement in this token at all", not "unlimited".** Every
///         token starts unconfigured, so a currency nobody deliberately sized cannot be settled
///         in, and the same setter that opens a token closes it again. `_consumeSettlementLimit`
///         tests the zero explicitly rather than relying on `amountDebited > 0`, because a zero
///         debit against a zero cap would otherwise pass the comparison and wave an
///         unconfigured token through.
///
///         ⚠️ Do not reintroduce a venue or selector allowlist here. If a change starts to look
///         like `mapping(address => bool) allowed`, it is the wrong change; `ISettlementLimits`
///         records why in full.
abstract contract SettlementLimits is IntentGate, ISettlementLimits {
    /// @notice The most decimals a settlement currency may plausibly report. Well above the 18
    ///         of every stablecoin in use and far below the point where converting a whole-unit
    ///         cap overflows, so it rejects a nonsense token without constraining a real one.
    uint8 public constant MAX_SETTLEMENT_TOKEN_DECIMALS = 36;

    // --------------------------------------------------------------------- //
    //                            Public getters                              //
    // --------------------------------------------------------------------- //

    /// @inheritdoc ISettlementLimits
    /// @dev Zero is the fail-closed default and means the token cannot be settled in.
    function perTxCap(address token) public view returns (uint256) {
        return _primary().settlementPerTxCap[token];
    }

    /// @inheritdoc ISettlementLimits
    function perTxCapWholeUnits(address token) public view returns (uint256) {
        return _primary().settlementPerTxCapWholeUnits[token];
    }

    // --------------------------------------------------------------------- //
    //                             Admin surface                              //
    // --------------------------------------------------------------------- //

    /// @inheritdoc ISettlementLimits
    /// @dev `DEFAULT_ADMIN_ROLE` — the Safe multisig in production — following `ExchangeAdmin`
    ///      rather than a new ownership model: one setter, one event, calldata a human can read.
    ///      Deliberately NOT the settlement operator's role: the cap is a check on what that key
    ///      can do, so letting it raise its own ceiling would leave no ceiling.
    ///
    ///      `decimals()` is read HERE and only here. Reading it on the settlement path would put
    ///      an external call to a token contract inside the hot path, and would let an
    ///      upgradeable token change the meaning of an already-approved cap between the moment
    ///      it was signed off and the moment it is enforced. Converting once, at the point a
    ///      human authorised a number, is the version that can be audited.
    ///
    ///      ⚠️ Consequence worth knowing: if a settlement currency ever DID change its decimals
    ///      after a cap was set, the stored raw cap would silently mean something else. The
    ///      decimals in force at set time are therefore emitted on the event, so the record
    ///      shows what the number was converted against. Re-set the cap if that ever happens.
    function setSettlementCap(address token, uint256 wholeUnits) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();

        PrimaryData storage $ = _primary();

        // Closing a token needs no decimals and must keep working even for a token that has
        // stopped reporting them, so the zero case short-circuits before the external call.
        if (wholeUnits == 0) {
            $.settlementPerTxCap[token] = 0;
            $.settlementPerTxCapWholeUnits[token] = 0;
            emit SettlementCapSet(token, 0, 0, 0);
            return;
        }

        uint8 tokenDecimals = _tokenDecimals(token);
        // Checked arithmetic: a `wholeUnits` large enough to overflow at this scale panics
        // rather than wrapping, which still fails closed and leaves the token unsettleable.
        uint256 rawCap = wholeUnits * (10 ** uint256(tokenDecimals));

        $.settlementPerTxCap[token] = rawCap;
        $.settlementPerTxCapWholeUnits[token] = wholeUnits;

        emit SettlementCapSet(token, wholeUnits, rawCap, tokenDecimals);
    }

    // --------------------------------------------------------------------- //
    //                             Enforcement                                //
    // --------------------------------------------------------------------- //

    /// @dev Charge one settlement against the cap for its settlement token, and revert if it
    ///      does not fit.
    ///
    ///      A pure comparison: no external call, no conversion, no state write. The conversion
    ///      happened once, in `setSettlementCap`.
    ///
    ///      ⚠️ **Do not call this from a settler family.** It is called once, from
    ///      `_authorizeSettlement` below, which every family runs before it moves anything. An
    ///      earlier revision left the call to each family and `MintSettler`'s documented
    ///      preamble omitted it entirely, so the mint packet could have shipped with no cap
    ///      applied and nothing would have complained.
    ///
    /// @param token         The settlement currency being debited.
    /// @param amountDebited The amount this settlement puts at risk of being taken from the
    ///                      buyer: `venueQuoteIn + buyerFee`, the full authorised debit.
    function _consumeSettlementLimit(address token, uint256 amountDebited) internal virtual {
        uint256 cap = _primary().settlementPerTxCap[token];
        // ⚠️ The `cap == 0` test is load-bearing and not redundant with the comparison after it.
        //    A zero cap means "this token cannot settle", and a zero debit against a zero cap
        //    would pass `0 > 0`. That is not a hypothetical: a venue that consumed exactly
        //    nothing with a zero fee produces one, and it must not be the one debit an
        //    unconfigured currency accepts.
        if (cap == 0 || amountDebited > cap) revert PerTxCapExceeded(token, amountDebited, cap);
    }

    /// @dev 🔴 **The preamble EVERY settler family runs, and the reason the cap cannot be
    ///      skipped.** It binds both attestations to the intent, burns all three nonces, and
    ///      charges the value cap — in that order. Every signature on the path has already been
    ///      verified by `_verifyIntent` and by the two gates before a single nonce is burned, so
    ///      an invalid one still cannot spend the others.
    ///
    ///      ⚠️ **The cap is charged HERE rather than by each family, and that is the whole
    ///      point of the function existing.** It used to be `VenueSettler`'s step 1, called by
    ///      S2 and by nothing else: `MintSettler` is a stub, its documented preamble listed the
    ///      four steps a mint entry point must replicate and omitted the cap, and nothing
    ///      structural would have stopped the mint family shipping uncapped. A per-transaction
    ///      value cap that each family opts into is not a cap. A family cannot reach its own
    ///      money path without burning the intent nonce, it cannot burn the intent nonce without
    ///      calling this, and it cannot call this without being charged.
    ///
    ///      The number charged is `venueQuoteIn + buyerFee`, the FULL authorised debit, not the
    ///      net one — the refund is not known until after the venue has been called, and a
    ///      charge made afterwards would be a check made after the money moved. The full debit
    ///      is the conservative reading: never below the net one, so the cap can only bite
    ///      earlier. It is also the number a human sizing the cap is looking at, because it is
    ///      the most the buyer can be asked for. Both families debit the same way — the intent's
    ///      amount model is family-agnostic — so one number serves both.
    ///
    ///      This lives in the CAPS module rather than in the entry point because that is the
    ///      lowest point in the linearization that can reach the gates and the cap at once,
    ///      and because both families inherit it while neither inherits the other. It runs
    ///      AFTER `_verifyIntent`, which each family calls first: that one returns the
    ///      `paramsHash` this needs, and family S2 binds its venue calldata in between.
    ///
    /// @param action     The primary-sale action ordinal this settlement runs under.
    /// @param intent     The already-verified settlement intent.
    /// @param paramsHash The intent's EIP-712 struct hash, as returned by `_verifyIntent`.
    /// @param kycAtt     The compliance attestation.
    /// @param feeAtt     The fee attestation.
    function _authorizeSettlement(
        uint8 action,
        SettlementIntent calldata intent,
        bytes32 paramsHash,
        KycAttestation calldata kycAtt,
        FeeAttestation calldata feeAtt
    ) internal {
        _bindAttestations(intent, paramsHash, kycAtt, feeAtt);
        _consumeKycAndFee(intent.buyer, action, 0, kycAtt, feeAtt);
        _consumeIntent(action, intent);
        // LAST, and the position is deliberate. The cap is an operational limit rather than a
        // property of the request, so checking it ahead of the signatures would let a currency
        // nobody has sized yet report `PerTxCapExceeded` for a settlement whose real defect is a
        // bad signature — the wrong answer to the wrong question. It still runs before the
        // family is entered and therefore before the first token call.
        //
        // `IntentGate._verifyIntent` already evaluated this sum under checked arithmetic to
        // compare it against `maxSettlementIn`, so it cannot overflow.
        _consumeSettlementLimit(intent.settlementToken, intent.venueQuoteIn + intent.buyerFee);
    }

    /// @dev The token's decimals, or a revert naming the token. `decimals()` is not part of the
    ///      required ERC-20 interface, so a token may not implement it at all, and a
    ///      non-conforming one may return something that does not decode as `uint8`. Both are
    ///      caught here and both fail CLOSED — the cap is not set, so the token stays
    ///      unsettleable, which is the safe end of the trade.
    ///      ⚠️ A low-level `staticcall` rather than `try IERC20Metadata(token).decimals()`, and
    ///      that is not a style choice. `try` does NOT catch a contract that returns data which
    ///      cannot be decoded: the call itself succeeds, and the decode then reverts in this
    ///      contract's own frame, outside the `catch`. A token with code but no `decimals()`
    ///      returns exactly that — empty data — so the `try` form would bubble a bare revert
    ///      instead of the named error, and the operator would be told nothing. Found by
    ///      `test_ATokenThatDoesNotReportDecimalsCannotBeCapped`.
    function _tokenDecimals(address token) private view returns (uint8) {
        // An address with no code is the fat-fingered-address case: a call to it succeeds and
        // returns nothing, so it has to be rejected before the call rather than after.
        if (token.code.length == 0) revert TokenDecimalsUnavailable(token);

        (bool ok, bytes memory data) = token.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        if (!ok || data.length < 32) revert TokenDecimalsUnavailable(token);

        // Decoded as `uint256` on purpose. A non-conforming token can return a value that does
        // not fit in `uint8`, and decoding straight into one would revert unhelpfully; the
        // plausibility bound below rejects it with a named error instead.
        uint256 decoded = abi.decode(data, (uint256));
        if (decoded > MAX_SETTLEMENT_TOKEN_DECIMALS) revert TokenDecimalsImplausible(token, decoded);
        return uint8(decoded);
    }
}
