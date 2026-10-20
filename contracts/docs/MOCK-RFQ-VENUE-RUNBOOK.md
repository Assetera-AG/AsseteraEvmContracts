# Mock RFQ venue on testnets

A testnet-only fixture that lets `AsseteraPrimarySales` **buy** and **sell** against an RFQ venue
where no real issuer is deployed. It is issuer-agnostic: the quote names the tokens.

- **What it deploys:** `MockRFQVenue` ([`test/mocks/MockRFQVenue.sol`](../test/mocks/MockRFQVenue.sol))
  and the mock stock `mAAPL` (`FaucetToken`, "Mock Apple", 18 decimals).
- **Settlement currency:** `mUSDC`, already recorded on Sepolia and Amoy.
- **NOT for production.** `mAAPL` has a permissionless `mint` and the venue mints through it. The
  deploy script refuses any chain id other than 31337, 80002 or 11155111.

---

## The quote

A quote is an EIP-712 message signed by the configured `quoteSigner` (an off-chain test RFQ
provider). Domain: name `MockRFQVenue`, version `1`, the target chain id, the venue address.

```
Quote(uint8 side,address paymentToken,uint256 paymentAmount,address assetToken,uint256 assetAmount,address recipient,bytes32 quoteId,uint256 expiry)
```

| Field | Meaning |
|---|---|
| `side` | `0` = BUY (the venue sells the asset), `1` = SELL (the venue buys it back) |
| `paymentToken`, `paymentAmount` | the settlement currency and the exact amount moved |
| `assetToken`, `assetAmount` | the asset and the exact amount moved |
| `recipient` | who receives the minted side |
| `quoteId` | unique; each id fills once, ever |
| `expiry` | last valid timestamp, inclusive |

**Recipient rules:**

- **BUY** — `recipient` is the buyer. The venue pulls `paymentAmount` of `paymentToken` from the
  router and mints `assetAmount` of `assetToken` to the buyer, so the router measures a real asset
  delta at the buyer.
- **SELL** — `recipient` is the **router**, not the seller. The venue pulls `assetAmount` from the
  router, keeps it (the token has no burn), and mints `paymentAmount` to the router; the router
  measures its own currency delta and forwards the net to the seller. A quote naming the seller
  here settles with zero proceeds and reverts on the seller's floor.

`hashQuote(quote)` returns the digest to sign. `QUOTE_TYPE` and `QUOTE_TYPEHASH` are published on
the contract so a signer does not re-derive them.

The venue refuses an expired, reused, wrongly signed or wrong-side quote with a named error:
`QuoteExpired`, `QuoteAlreadyUsed`, `InvalidQuoteSignature`, `WrongQuoteSide`.

---

## Deploy

The fixture deploy is separate from the platform stack. It reuses the wrapper's keystore signing
and its dry-run default:

```bash
MOCK_RFQ_QUOTE_SIGNER=0x<off-chain test RFQ provider> \
ALLOW_DEPLOYER_AS_ADMIN=1 \
FORGE_SCRIPT=DeployMockRFQVenue.s.sol:DeployMockRFQVenue \
  bash scripts/deploy.sh sepolia --broadcast
```

As for any other deploy, the wrapper also needs the keystore account: `DEPLOYER_ADDRESS` (the
account's address, passed as `--sender`) and, if it is not the default, `DEPLOYER_ACCOUNT`. Import it
once with `cast wallet import assetera-deployer --interactive`. `SEPOLIA_RPC_URL` must be exported,
which the wrapper reads from the repo-root `.env`.

For Amoy, use `amoy` in place of `sepolia`. Without `--broadcast` the command simulates, prints the
addresses and leaves the deployment record untouched.

`ALLOW_DEPLOYER_AS_ADMIN=1` is required only because the wrapper's admin check belongs to the
proxy stack; this script deploys no proxy and grants no admin role. The venue's owner is the
deployer.

The script appends two keys to `packages/sdk/src/deployments/<chainId>.json`:

```json
"mAAPL": "0x…",
"mockRfqVenue": "0x…"
```

Both fixtures use CREATE3 with fixed salt labels, so a re-run from the same deployer reuses the
same addresses. A re-run with a different `MOCK_RFQ_QUOTE_SIGNER` is refused; rotate the signer on
the deployed venue with `setQuoteSigner` as its owner instead.

The Sepolia and Amoy records already carry the addresses this script produces from the recorded
deployer, so the SDK can type them before the first broadcast. Until the command above is run, those
addresses have no code on chain.

---

## Use it

1. Open a settlement cap for `mUSDC` on the router if this chain has none (the router deploys
   CLOSED, and an unset cap means the currency cannot settle).
2. Sign a quote with the provider key over `hashQuote`, then hand the router
   `abi.encodeCall(MockRFQVenue.buy, (quote, signature))` or `…sell…` as `venueCalldata`, bound by
   hash and selector in the intent exactly as a real venue's calldata is.
3. After the first settlement, confirm on chain:
   - BUY: the buyer's asset balance rose by `assetAmount`, and the venue holds `paymentAmount`.
   - SELL: the venue holds `assetAmount`, and the seller received `paymentAmount` net of the fee.

SDK accessors: `getMockRfqVenueAddress(chainId)`, `getMockAaplAddress(chainId)` and
`mockRfqVenueAbi` from `@asseteragmbh/evm-contracts/contracts`.
