# Standing up one offering's issuance venue

The operational sequence around [`script/DeployIssuanceVenue.s.sol`](../script/DeployIssuanceVenue.s.sol).
Follow this and a second offering can be brought online without opening the Solidity.

- **What it deploys:** one `AsseteraIssuanceVenue` — the per-token primary-sale contract
  `AsseteraPrimarySales` settles against when the asset is our own issuance.
- **When:** once per offering (per token, per price band, per round), during issuer onboarding.
  Deliberately **not** part of `Deploy.s.sol` — a venue is one-per-offering, on one chain, with an
  address that lives in the catalogue row rather than the SDK manifest.
- **Design of record:** [ADR-0047](https://github.com/Assetera-AG/AsseteraADRs/blob/main/adr/0047-per-token-primary-issuance-contract/README.md).
  Contract: [`src/primary/sale/AsseteraIssuanceVenue.sol`](../src/primary/sale/AsseteraIssuanceVenue.sol).

---

## 0. Preconditions

- `AsseteraPrimarySales` is deployed on the target chain and recorded in
  [`../../packages/sdk/src/deployments/<chainId>.json`](../../packages/sdk/src/deployments) — the
  script reads the router address from there.
- The **asset token** (ERC-20) exists on the same chain, and its owner (the issuer) can grant a
  minting right on it.
- The **settlement currency** (e.g. `mUSDC`) is a governed settlement currency for the platform.
- Foundry installed, `.env` filled from [`.env.sample`](../.env.sample) (the `VENUE_*` block), a
  **server-side** RPC key. Deployer key imported once: `cast wallet import assetera-deployer --interactive`.

---

## 1. Decide the eleven config values

`SaleConfig` is a named struct, not positional args, precisely so a transposed pair is visible.

| Field | Env var | Decided by | What it is |
|---|---|---|---|
| `admin` | `VENUE_ADMIN` | Contracts / governance | `DEFAULT_ADMIN_ROLE` — role administration, the purchase cap, `unpause`. **Safe multisig in production.** |
| `rateSetter` | `VENUE_RATE_SETTER` | Compliance | `RATE_SETTER_ROLE` — may move `unitPrice` within the immutable bounds and **nothing else**. The compliance officers who price the offering. |
| `pauser` | `VENUE_PAUSER` | Contracts / ops | `PAUSER_ROLE` — may stop purchases, **may not restart them**. |
| `treasurer` | `VENUE_TREASURY` | **The issuer** | `TREASURY_ROLE` — withdraws proceeds, rescues a stray token. |
| `router` | `VENUE_ROUTER` | — (auto) | The one address allowed to call `purchase`, `AsseteraPrimarySales`. Immutable. Defaults to the SDK manifest entry for this chain; set it only to override on a local run. |
| `settlementToken` | `VENUE_SETTLEMENT_TOKEN` | Compliance / catalogue | The currency the offering is sold in (`mUSDC`, 6 dp). |
| `assetToken` | `VENUE_ASSET_TOKEN` | The issuer | The ERC-20 this venue mints (`mRWA`, 18 dp). Must grant this venue its minting right — see step 4.1. |
| `unitPrice` | `VENUE_UNIT_PRICE` | Compliance | Price of **ONE WHOLE asset token, in the settlement token's smallest unit**. `mUSDC` 6 dp: 12.50 → `12_500_000`. |
| `minUnitPrice` | `VENUE_MIN_UNIT_PRICE` | Compliance | Inclusive floor for `unitPrice`, same units, **must be > 0**. `mUSDC`: one cent → `10_000`. |
| `maxUnitPrice` | `VENUE_MAX_UNIT_PRICE` | Compliance | Inclusive ceiling, same units. `mUSDC`: ten thousand → `10_000_000_000`. |
| `maxSettlementPerPurchaseWholeUnits` | `VENUE_MAX_SETTLEMENT_WHOLE` | Compliance | Per-purchase cap, in **whole** settlement tokens (converted on-chain by decimals). |

### 🔴 The four traps (ADR-0047 §"Four traps") — get these wrong and it is expensive after issuance starts

1. **T1 — our role must have provably no path to the proceeds.** No address holds both a
   rate/admin role and `TREASURY_ROLE`. `treasurer` is the **issuer**, never us. This is readable
   from the deployed roles, not asserted here.
2. **T2 — `rateSetter` must not be the settlement-operator signer.** One compromise would give both
   the price and the authorisation ("set the rate near zero, buy the issuance out through a KYC'd
   account"). Check `VENUE_RATE_SETTER` against the `settlement-operator` address in
   `AsseteraInfrastructure` (`modules/platform-apps/signer.tf`).
3. **T3 — every reprice emits `UnitPriceSet`.** The contract does this; don't route repricing
   around it.
4. **T4 — `VENUE_MAX_SETTLEMENT_WHOLE = 0` means the venue is CLOSED, not "unlimited".** Same
   fail-closed reading as the router's settlement cap. Set a real number, or leave `0` and open it
   in step 4.4. For "no cap", the venue does not support one — pick a number above any plausible
   purchase.

### The decimals trap

`unitPrice` and both bounds are **raw settlement-token amounts**, never decimal numbers. Worked
example, `mUSDC` (6 dp) paying for `mRWA` (18 dp):

| quantity | value | meaning |
|---|---|---|
| `unitPrice` | `12_500_000` | 12.50 mUSDC buys 1.0 mRWA |
| a 125.00 mUSDC purchase | `settlementIn = 125_000_000` | buyer receives 10 mRWA |
| `minUnitPrice` | `10_000` | one euro-cent floor |
| `maxUnitPrice` | `10_000_000_000` | ten-thousand mUSDC ceiling |

Getting `unitPrice` wrong by a factor of `10 ** 6` is the single most likely deployment mistake.

### Pre-flight checklist

- [ ] `minUnitPrice <= unitPrice <= maxUnitPrice`, and `minUnitPrice > 0`
- [ ] all three prices are **raw settlement units**, cross-checked against the worked example
- [ ] `settlementToken != assetToken`
- [ ] `rateSetter` is **not** the settlement-operator signer (T2)
- [ ] no address is both a rate/admin role and `treasurer` (T1); `treasurer` is the issuer
- [ ] every role address is set — an unset `VENUE_*` role **silently defaults to the deployer**
- [ ] `admin` is the Safe multisig on a real deployment

The constructor rejects: any zero address, `settlementToken == assetToken`, `minUnitPrice == 0` or
`minUnitPrice > maxUnitPrice`, and a token reporting more than 36 decimals.

---

## 2. Dry run

```bash
cp .env.sample .env          # fill the VENUE_* block + the deployer account

FORGE_SCRIPT=DeployIssuanceVenue.s.sol:DeployIssuanceVenue bash scripts/deploy.sh amoy
# equivalently, raw:
forge script script/DeployIssuanceVenue.s.sol:DeployIssuanceVenue --rpc-url amoy
```

Read the printed config back:

- `router` is the real `AsseteraPrimarySales` proxy for this chain
- `unitPrice` and `price bounds` are the raw numbers you meant
- `per-purchase cap (whole tokens)` is what you meant, and is **not** `0` unless you intend to open
  it later

---

## 3. Broadcast

```bash
FORGE_SCRIPT=DeployIssuanceVenue.s.sol:DeployIssuanceVenue bash scripts/deploy.sh amoy --broadcast
# add --verify on a public chain, or run `forge verify-contract` after
```

Record the printed address:

```
AsseteraIssuanceVenue deployed: 0x…
```

Nothing is written to `packages/sdk/src/deployments/` — that is by design. The address goes into
the catalogue in step 4.3.

---

## 4. The three things the script cannot do, in order

The script prints these. Detail:

### 4.1 The issuer grants the minting right

The asset token's owner (the **issuer**) grants the venue address permission to mint — the exact
call depends on the token (`grantRole(MINTER_ROLE, venue)`, `setMinter(venue, true)`, …). **Nothing
on our side checks this**: a missed grant fails at the *first purchase* — the asset token's own
mint revert (missing role), or `AssetDeliveryShortfall` if its `mint` silently no-ops — not at deploy.

### 4.2 Router admin: open the settlement currency

`setSettlementCap(settlementToken, wholeUnits)` on `AsseteraPrimarySales` for this chain — an unset
cap reads as "this currency cannot settle at all". Once per `(chain, settlement currency)`; skip if
another venue on this chain already sells in the same currency and the cap is set.

[`script/AdminCalldata.s.sol`](../script/AdminCalldata.s.sol) prints this as multisig fields and a
`cast send` line:

```bash
FEE_COLLECTOR_ADDRESS=0x… SETTLEMENT_CAP_WHOLE=100000 \
  bash scripts/forge-script.sh amoy AdminCalldata.s.sol:AdminCalldata -vv
```

That script also prints `setAllowedCollector` for the fee collector. The collector allowlist and
the signer's mirror of it (`settlement_allowed_collectors` in `AsseteraInfrastructure`) are an
**environment** concern, not per-offering — cross-check they are done, don't redo them here.

### 4.3 Catalogue: point the offering at the venue

On the offering's `token_pairs` row in the marketplace catalogue:

1. `primary_execution_kind = 'onchain_primary_mint'`
2. `issuance_venue_contract = <the address from step 3>`
3. `primary_market = true` (opens the sale — do this last)

> ⚠️ The script's console message still says `primary_sale_contract`. That predates AO-804. Use
> **`issuance_venue_contract`**. `primary_sale_contract` is the indexer's delivery-token override,
> and a venue address there silently repoints the token the indexer watches.

### 4.4 If you deployed with cap `0`

`admin` calls `setMaxSettlementPerPurchase(wholeUnits)` on the venue **before any sale**. Until
then every `purchase` reverts `PurchaseCapExceeded`.

---

## 5. Verify

```bash
cast call <venue> "ROUTER()(address)"                              --rpc-url amoy  # = AsseteraPrimarySales
cast call <venue> "unitPrice()(uint256)"                           --rpc-url amoy  # = your raw price
cast call <venue> "MIN_UNIT_PRICE()(uint256)" ; cast call <venue> "MAX_UNIT_PRICE()(uint256)"
cast call <venue> "maxSettlementPerPurchaseWholeUnits()(uint256)"  --rpc-url amoy  # > 0  ⇒ venue is open
cast call <venue> "SETTLEMENT_TOKEN()(address)"                    --rpc-url amoy
cast call <venue> "ASSET_TOKEN()(address)"                         --rpc-url amoy
```

> Note: the token/router/bounds getters are the immutables `ROUTER`, `SETTLEMENT_TOKEN`,
> `ASSET_TOKEN`, `MIN_UNIT_PRICE`, `MAX_UNIT_PRICE`. `unitPrice` and
> `maxSettlementPerPurchaseWholeUnits` are mutable state and lower-camel.

- Confirm the venue holds the asset token's minting right (token-specific check).
- Run one testnet purchase through the router: it should settle, emit `IssuanceMinted` from the
  venue and `PrimarySettled` from the router in the same transaction, with matching amounts.

---

## Operating the venue afterwards

| Action | Function | Role | Notes |
|---|---|---|---|
| Reprice within the bounds | `setUnitPrice(newPrice)` | `RATE_SETTER_ROLE` | Compliance. Emits `UnitPriceSet`. Reverts `UnitPriceOutOfBounds` outside `[min, max]`. |
| Change the per-purchase cap | `setMaxSettlementPerPurchase(wholeUnits)` | `DEFAULT_ADMIN_ROLE` | Emits `PurchaseCapSet` (whole + raw + decimals). |
| Stop purchases | `pause()` | `PAUSER_ROLE` | One-way. |
| Resume purchases | `unpause()` | `DEFAULT_ADMIN_ROLE` | |
| Withdraw proceeds | `withdraw(to, amount)` | `TREASURY_ROLE` | The issuer. Emits `ProceedsWithdrawn`. Works while paused. |
| Sweep a stray non-settlement token | `rescue(token, to, amount)` | `TREASURY_ROLE` | Reverts `RescueOfSettlementToken` if pointed at the settlement currency — proceeds only leave via `withdraw`. |

## A new round or a new price band

There is no upgrade path — the venue is immutable logic. Run this runbook again for a **new
venue**, point the catalogue row at it, and `pause()` the old one.
