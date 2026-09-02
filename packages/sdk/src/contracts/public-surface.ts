/**
 * A compile-time guard on the public surface of `@asseteragmbh/evm-contracts/contracts`.
 *
 * `contracts/index.ts` re-exports an EXPLICIT list of names rather than `export *`. That is deliberate,
 * because it keeps generated internals off the package. It also has a failure mode with no symptom:
 * adding a function to `../deployments/index.ts` and forgetting to list it there compiles cleanly,
 * publishes cleanly, and the symbol is simply absent for every consumer. Nothing anywhere fails.
 *
 * That is not hypothetical. `getPrimarySalesAddress` was added, reviewed, merged and published in 5.0.0
 * while being unreachable, and it was found by a consumer trying to import it, which is the most expensive
 * place to find it.
 *
 * So the surface is asserted here. `tsc --noEmit` already runs in CI, and a missing export becomes a type
 * error in this file rather than a discovery someone makes downstream after a release.
 *
 * @remarks
 * Not part of any build entry (`tsup.config.ts` builds `src/index.ts`, `src/contracts/index.ts` and
 * `src/react/index.ts`), so nothing here is bundled or published. It exists only to be typechecked.
 *
 * When you intentionally add or remove a public export, update this list in the same change. If you are
 * deleting a name, that is a breaking change to the package and belongs in the release notes.
 */
import * as contracts from "./index.js";

/** Every name the `/contracts` entry is contracted to expose. */
type RequiredExports =
  | "asseteraEcsAbi"
  | "asseteraIssuanceVenueAbi"
  | "asseteraPrimarySalesAbi"
  | "erc2771ForwarderAbi"
  | "faucetTokenAbi"
  | "getContractAddress"
  | "getDeployment"
  | "getEcsAddress"
  | "getExchangeAddress"
  | "getPrimarySalesAddress"
  | "getSupportedChainIds";

/**
 * Fails to compile if any name above is missing from the entry point.
 *
 * The assignment is the assertion: `keyof typeof contracts` must be assignable FROM `RequiredExports`,
 * which can only hold if every required name is actually exported.
 */
const _surface: Record<RequiredExports, unknown> = contracts;
void _surface;

/**
 * Both address accessors must return the same shape, so a consumer can treat "the exchange" and "the
 * settlement router" uniformly and handle `undefined` once. They are different addresses, and a chain
 * whose deployment record predates the router returns `undefined` for it.
 */
const _shape: (chainId: number) => `0x${string}` | undefined = contracts.getPrimarySalesAddress;
void _shape;
