import { hashDomain, type Address, type Hex, type PublicClient } from "viem";

/**
 * ERC-2612 permit support for `permitAndCall`, which BOTH deployed contracts expose:
 * `AsseteraECS` (approve + trade in one transaction, AO-298) and `AsseteraPrimarySales`
 * (permit + `settlePrimary` in one transaction, AO-713). Nothing here is specific to either —
 * `spender` is whichever contract you are calling.
 *
 * The contract does not need this — it hands `v`, `r`, `s` straight to the token, which checks them
 * against its own domain. The client does, because **you cannot assume a token's EIP-712 domain name
 * is its `name()`**, and getting it wrong produces a signature the token silently rejects:
 * `permitAndCall` returns `permitAccepted: false` and the trade then fails on the allowance.
 *
 * Two real settlement currencies break the naive assumption:
 *   - **EUROP** hashed a different string into its domain separator than the one `name()` returns.
 *   - **USDC** predates ERC-5267, so `eip712Domain()` reverts and you cannot simply ask the token.
 *
 * The faucet tokens on playground pass their own `name()` to `ERC20Permit`, so they agree and
 * playground cannot catch either case. Resolve the domain with {@link resolvePermitDomain} instead
 * of assuming it.
 */

const EIP712_DOMAIN_ABI = [
  {
    type: "function",
    name: "eip712Domain",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "fields", type: "bytes1" },
      { name: "name", type: "string" },
      { name: "version", type: "string" },
      { name: "chainId", type: "uint256" },
      { name: "verifyingContract", type: "address" },
      { name: "salt", type: "bytes32" },
      { name: "extensions", type: "uint256[]" },
    ],
  },
  {
    type: "function",
    name: "DOMAIN_SEPARATOR",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "bytes32" }],
  },
  { type: "function", name: "name", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
  {
    type: "function",
    name: "nonces",
    stateMutability: "view",
    inputs: [{ name: "owner", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
] as const;

/** The ERC-2612 `Permit` struct, for `signTypedData`. */
export const PERMIT_TYPES = {
  Permit: [
    { name: "owner", type: "address" },
    { name: "spender", type: "address" },
    { name: "value", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

/** Domain versions worth trying when a token has no readable `eip712Domain()`. */
const DEFAULT_CANDIDATE_VERSIONS = ["1", "2"];

const EIP712_DOMAIN_TYPES = {
  EIP712Domain: [
    { name: "name", type: "string" },
    { name: "version", type: "string" },
    { name: "chainId", type: "uint256" },
    { name: "verifyingContract", type: "address" },
  ],
} as const;

/**
 * The four-field EIP-712 domain every settlement currency we trade uses. Deliberately narrower than
 * viem's `TypedDataDomain`: a `salt`-bearing or field-omitting domain is not something to guess at,
 * so {@link resolvePermitDomain} throws rather than returning a partial one.
 */
export interface PermitDomain {
  name: string;
  version: string;
  chainId: number;
  verifyingContract: Address;
}

function domainSeparatorOf(domain: PermitDomain): Hex {
  // `chainId` is `number` on the way out because that is what viem's `signTypedData` takes; the
  // hasher wants the `uint256` as a bigint.
  return hashDomain({ domain: { ...domain, chainId: BigInt(domain.chainId) }, types: EIP712_DOMAIN_TYPES });
}

export interface ResolvePermitDomainArgs {
  publicClient: PublicClient;
  /** The ERC-20 whose permit is being signed. */
  token: Address;
  /**
   * Extra domain names to try, beyond the token's own `name()`. Add the value here when you know a
   * token diverges (EUROP) rather than discovering it in production.
   */
  candidateNames?: string[];
  /** Domain versions to try. Defaults to `["1", "2"]` — USDC uses `"2"`. */
  candidateVersions?: string[];
}

/**
 * Work out the EIP-712 domain a token will actually verify a permit against.
 *
 * Order of attack:
 *   1. Read ERC-5267 `eip712Domain()`. If it answers, use it — but still check the result against
 *      `DOMAIN_SEPARATOR()` when the token exposes one, because a token can report a domain it does
 *      not verify against.
 *   2. Otherwise read `DOMAIN_SEPARATOR()` and search: for each candidate name (the token's `name()`
 *      first, then anything the caller supplied) and each candidate version, hash the domain and
 *      compare. The first exact match is the answer.
 *
 * Throws if nothing matches, rather than returning a domain that produces a rejected signature.
 * A throw here is a signature that would have failed silently on chain.
 *
 * Not handled: domains that include a `salt`, or that omit `chainId` / `verifyingContract`. No
 * settlement currency we trade uses one; if that changes, extend the search rather than guessing.
 */
export async function resolvePermitDomain(args: ResolvePermitDomainArgs): Promise<PermitDomain> {
  const { publicClient, token } = args;
  const read = { address: token, abi: EIP712_DOMAIN_ABI } as const;

  const chainId = await publicClient.getChainId();
  const separator = await publicClient
    .readContract({ ...read, functionName: "DOMAIN_SEPARATOR" })
    .catch(() => undefined);

  const reported = await publicClient.readContract({ ...read, functionName: "eip712Domain" }).catch(() => undefined);
  if (reported) {
    const [, name, version, reportedChainId, verifyingContract] = reported;
    const domain: PermitDomain = { name, version, chainId: Number(reportedChainId), verifyingContract };
    if (!separator || domainSeparatorOf(domain) === separator) return domain;
    // The token reports a domain it does not verify against. Fall through to the search.
  }

  if (!separator) {
    throw new Error(
      `@asseteragmbh/evm-contracts: ${token} exposes neither a usable eip712Domain() nor a ` +
        `DOMAIN_SEPARATOR(), so its permit domain cannot be resolved. It may not support ERC-2612.`,
    );
  }

  const ownName = await publicClient.readContract({ ...read, functionName: "name" }).catch(() => undefined);
  const names = [...(ownName ? [ownName] : []), ...(args.candidateNames ?? [])];
  const versions = args.candidateVersions ?? DEFAULT_CANDIDATE_VERSIONS;

  for (const name of names) {
    for (const version of versions) {
      const domain: PermitDomain = { name, version, chainId, verifyingContract: token };
      if (domainSeparatorOf(domain) === separator) return domain;
    }
  }

  throw new Error(
    `@asseteragmbh/evm-contracts: could not match ${token}'s DOMAIN_SEPARATOR() against any candidate ` +
      `domain (names tried: ${names.map((n) => JSON.stringify(n)).join(", ") || "none"}; versions tried: ` +
      `${versions.join(", ")}). Signing a permit against a guessed domain produces a signature the token ` +
      `rejects, so pass the real domain name via candidateNames instead.`,
  );
}

/** Read a token's current ERC-2612 nonce for `owner`. */
export async function getPermitNonce(publicClient: PublicClient, token: Address, owner: Address): Promise<bigint> {
  return publicClient.readContract({
    address: token,
    abi: EIP712_DOMAIN_ABI,
    functionName: "nonces",
    args: [owner],
  });
}

export interface PermitSignatureParts {
  v: number;
  r: Hex;
  s: Hex;
}

/** Split a 65-byte permit signature into the `v`, `r`, `s` that `permitAndCall` takes. */
export function splitPermitSignature(signature: Hex): PermitSignatureParts {
  if (signature.length !== 132) {
    throw new Error(`@asseteragmbh/evm-contracts: expected a 65-byte signature, got ${(signature.length - 2) / 2}`);
  }
  return {
    r: `0x${signature.slice(2, 66)}`,
    s: `0x${signature.slice(66, 130)}`,
    v: Number.parseInt(signature.slice(130, 132), 16),
  };
}
