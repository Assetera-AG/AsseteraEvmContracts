/**
 * Pure data entry (`@asseteragmbh/evm-contracts/contracts`) — ABIs `as const` + per-chain address helpers,
 * with **no React/wagmi runtime**. This is what the Subsquid indexer, the Marketplace API, and any non-viem
 * consumer import (ADR-0026 D6).
 */
export {
  asseteraEcsAbi,
  // No address map yet — `asseteraPrimarySalesAddress` is `{}` until the deploy script has run (AO-552).
  asseteraPrimarySalesAbi,
  erc2771ForwarderAbi,
  faucetTokenAbi,
} from "../generated/contracts.js";
export {
  getContractAddress,
  getDeployment,
  getEcsAddress,
  /** @deprecated use `getEcsAddress` */
  getExchangeAddress,
  getSupportedChainIds,
  type Deployment,
} from "../deployments/index.js";
