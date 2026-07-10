"use client";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import { http, WagmiProvider, createConfig } from "wagmi";
import { polygonAmoy } from "wagmi/chains";

// Target Amoy — the chain the exchange is deployed on. LearningFront will point at Sepolia (or whatever
// chain we deploy to); the SDK resolves addresses by chainId either way, so only this config changes.
const config = createConfig({
  chains: [polygonAmoy],
  transports: { [polygonAmoy.id]: http() },
});

const queryClient = new QueryClient();

export function Providers({ children }: { children: ReactNode }) {
  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    </WagmiProvider>
  );
}
