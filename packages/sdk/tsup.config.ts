import { defineConfig } from "tsup";

// Multi-entry build (ADR-0026 D6): the root client + a zero-runtime-dep `./contracts` data entry.
// `./react` (wagmi hooks) is added in Phase 3 alongside the @wagmi/cli codegen.
export default defineConfig({
  entry: ["src/index.ts", "src/contracts/index.ts"],
  format: ["esm", "cjs"],
  dts: true,
  sourcemap: true,
  clean: true,
  treeshake: true,
  external: ["viem"],
});
