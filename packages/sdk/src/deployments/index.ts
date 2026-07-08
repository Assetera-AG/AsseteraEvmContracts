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

/** A named contract address on a chain (e.g. `AsseteraExchange`, `Forwarder`, `MockUSDC`). */
export function getContractAddress(chainId: number, name: string): Address | undefined {
  return getDeployment(chainId)?.contracts[name];
}

/** The exchange proxy address for a chain. */
export function getExchangeAddress(chainId: number): Address | undefined {
  return getContractAddress(chainId, "AsseteraExchange");
}
