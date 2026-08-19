/**
 * Pure data entry (`@asseteragmbh/evm-contracts/contracts`) — ABIs `as const` + per-chain address helpers,
 * with **no React/wagmi runtime**. This is what the Subsquid indexer, the Marketplace API, and any non-viem
 * consumer import (ADR-0026 D6).
 */
// ⚠️ This list is EXPLICIT, not a `export *`. Adding a function to `../deployments/index.ts` therefore
//    does NOT make it reachable by consumers, and nothing fails to compile to tell you: the symbol simply
//    is not on the package. That is exactly how `getPrimarySalesAddress` shipped invisible in 5.0.0.
//    Anything added there has to be added here in the same change.
//
//    The generated per-chain address maps (`asseteraEcsAddress`, `asseteraPrimarySalesAddress`) are
//    deliberately NOT re-exported, even though they are populated. The deployment records are the single
//    source of truth and the accessors below read them; exporting a second, separately generated copy of
//    the same addresses would create two sources that can disagree, and the one a consumer reached for
//    would be an accident of which import they happened to write.
export {
  asseteraEcsAbi,
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
  getPrimarySalesAddress,
  getSupportedChainIds,
  type Deployment,
} from "../deployments/index.js";
