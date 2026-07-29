import { getContract, type Address, type GetContractReturnType, type PublicClient, type WalletClient } from "viem";
import { getEcsAddress } from "./deployments/index.js";
import { asseteraEcsAbi } from "./generated/contracts.js";

export interface ExchangeClientParams {
  /** Chain id used to resolve the exchange address (unless `address` is given). */
  chainId: number;
  publicClient: PublicClient;
  /** Optional — required only for state-changing calls. */
  walletClient?: WalletClient;
  /** Override the resolved address (e.g. a chain without a committed deployment). */
  address?: Address;
}

/**
 * A viem `getContract` instance bound to the AsseteraECS proxy for `chainId` — the non-React surface
 * used by services (the indexer, the Marketplace API). React apps should use the hooks from
 * `@asseteragmbh/evm-contracts/react`, which resolve the address automatically.
 */
export function createExchangeClient(
  params: ExchangeClientParams,
): GetContractReturnType<typeof asseteraEcsAbi, { public: PublicClient; wallet?: WalletClient }, Address> {
  const address = params.address ?? getEcsAddress(params.chainId);
  if (!address) {
    throw new Error(
      `@asseteragmbh/evm-contracts: no AsseteraECS deployment for chainId ${params.chainId}. ` +
        `Pass { address } explicitly, or deploy + regenerate first.`,
    );
  }
  return getContract({
    address,
    abi: asseteraEcsAbi,
    client: { public: params.publicClient, wallet: params.walletClient },
  });
}
