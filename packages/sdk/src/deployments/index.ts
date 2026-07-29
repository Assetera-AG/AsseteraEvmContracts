import type { Address } from "viem";
import { deployments } from "./deployments.gen";

/** A single network's deployment record — mirrors `packages/sdk/src/deployments/<chainId>.json` (ADR-0026). */
export interface Deployment {
  chainId: number;
  /** CAIP-2 chain id, e.g. `eip155:137` (ADR-0006). */
  caip2: string;
  /** CAIP-2 namespace, always `eip155` for this (EVM) package. */
  namespace: string;
  /** Consumer-facing addresses (the exchange is the proxy). */
  contracts: Record<string, Address>;
  /** UUPS implementation addresses, for upgrade diffing. */
  implementations: Record<string, Address>;
  metadata: {
    deployer: Address;
    admin: Address;
    operator: Address;
    kycSigner: Address;
    relayer: Address;
    deployBlock: number;
    deployTimestamp: number;
  };
}

const byChainId = deployments as unknown as Record<number, Deployment>;

/** Chain ids with a committed deployment. */
export function getSupportedChainIds(): number[] {
  return Object.keys(byChainId).map(Number);
}

/** The full deployment record for a chain, or `undefined` if none is committed. */
export function getDeployment(chainId: number): Deployment | undefined {
  return byChainId[chainId];
}

/** A named contract address on a chain (e.g. `AsseteraECS`, `Forwarder`, `MockUSDC`). */
export function getContractAddress(chainId: number, name: string): Address | undefined {
  return getDeployment(chainId)?.contracts[name];
}

/**
 * The AsseteraECS (Execution, Clearing & Settlement) proxy address for a chain.
 *
 * @example
 * ```ts
 * const ecs = getEcsAddress(80002); // 0x58c3Fb1B69ca985A5461CcEfFd0Fe590b653F213
 * ```
 */
export function getEcsAddress(chainId: number): Address | undefined {
  return getContractAddress(chainId, "AsseteraECS");
}

/**
 * @deprecated Use {@link getEcsAddress}. `AsseteraExchange` was renamed to `AsseteraECS` in 4.0.0;
 *             this alias is kept so consumers do not hard-break on the function API. The address it
 *             returns is unchanged.
 */
export function getExchangeAddress(chainId: number): Address | undefined {
  return getEcsAddress(chainId);
}
