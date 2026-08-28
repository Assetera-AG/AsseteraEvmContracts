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
  /**
   * UUPS implementation addresses, for upgrade diffing.
   *
   * ⚠️ This is a SNAPSHOT, not a live view of the chain, exactly as `metadata` below is. A proxy's
   * implementation changes whenever the admin multisig executes an upgrade, and that happens without
   * this package being rebuilt: the record is only as fresh as the last release that followed an
   * upgrade. Version 7.0.0 shipped with pre-upgrade addresses for this reason.
   *
   * The staleness window matters most for the field's own stated purpose. If you are diffing to answer
   * "is this proxy running the code I expect", read the ERC-1967 implementation slot from the chain and
   * compare it to this, rather than trusting this alone:
   *
   * ```ts
   * const recorded = getDeployment(chainId).implementations.AsseteraPrimarySales;
   * const live = await client.getStorageAt({
   *   address: getDeployment(chainId).contracts.AsseteraPrimarySales,
   *   slot: "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc",
   * });
   * ```
   *
   * `contracts` above has no such caveat: those are proxy addresses and they do NOT move on an upgrade,
   * which is why nothing that merely transacts needs to care about any of this.
   */
  implementations: Record<string, Address>;
  /**
   * Who held which role **at initialization**.
   *
   * ⚠️ This is not a live view of the chain. Roles granted or revoked after the deploy never appear
   * here, and on a long-lived deployment they will have been. Treat it as provenance, not as access
   * control: if you need to know who holds a role right now, ask the contract.
   */
  metadata: {
    deployer: Address;
    admin: Address;
    operator: Address;
    kycSigner: Address;
    feeSigner: Address;
    /** Absent on records written before the primary-sales router existed. */
    settlementSigner?: Address;
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
 * Prefer this over `getContractAddress(chainId, "AsseteraECS")`: a typed accessor is the thing a
 * rename has to break visibly, whereas a string key silently returns `undefined` forever.
 *
 * @example
 * ```ts
 * const ecs = getEcsAddress(80002);
 * ```
 */
export function getEcsAddress(chainId: number): Address | undefined {
  return getContractAddress(chainId, "AsseteraECS");
}

/**
 * The AsseteraPrimarySales router proxy address for a chain.
 *
 * ⚠️ A **different address** from {@link getEcsAddress}, with its own EIP-712 domain, its own roles
 * and its own events. Do not point one address filter at both.
 *
 * `undefined` on a chain whose deployment record predates the router.
 *
 * @example
 * ```ts
 * const router = getPrimarySalesAddress(80002);
 * ```
 */
export function getPrimarySalesAddress(chainId: number): Address | undefined {
  return getContractAddress(chainId, "AsseteraPrimarySales");
}

/**
 * @deprecated Use {@link getEcsAddress}. `AsseteraExchange` was renamed to `AsseteraECS` in 4.0.0;
 *             this alias is kept so consumers do not hard-break on the function API. The address it
 *             returns is unchanged.
 */
export function getExchangeAddress(chainId: number): Address | undefined {
  return getEcsAddress(chainId);
}
