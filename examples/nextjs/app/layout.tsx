import type { ReactNode } from "react";
import { Providers } from "./providers";

export const metadata = {
  title: "Assetera EVM contracts — Next.js sample",
  description: "Resolves the exchange on Amoy from @asseteragmbh/evm-contracts by chainId.",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body style={{ fontFamily: "system-ui, sans-serif", maxWidth: 720, margin: "3rem auto", padding: "0 1rem" }}>
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
