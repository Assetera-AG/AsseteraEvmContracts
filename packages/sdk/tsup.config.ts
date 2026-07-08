import { defineConfig } from "tsup";

// Multi-entry build (ADR-0026 D6):
//   .          → viem-first: ABIs, addresses, client factory (no React)
//   ./contracts → pure data: ABIs + address helpers, zero runtime deps
//   ./react     → generated wagmi hooks
export default defineConfig({
  entry: ["src/index.ts", "src/contracts/index.ts", "src/react/index.ts"],
  format: ["esm", "cjs"],
  dts: true,
  sourcemap: true,
  clean: true,
  treeshake: true,
  external: ["viem", "wagmi", "react", "react-dom", "@tanstack/react-query"],
});
