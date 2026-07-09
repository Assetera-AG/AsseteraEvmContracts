"use client";

import {
  useReadAsseteraExchangePaused,
  useReadAsseteraExchangeTotalOrders,
  useReadAsseteraExchangeVersion,
} from "@asseteragmbh/evm-contracts/react";
import { polygonAmoy } from "wagmi/chains";

// Generated wagmi hooks — the exchange address is auto-resolved from the SDK's baked per-chain map, so we
// never pass an address. These read live from Amoy through the wagmi transport.
export function LiveReads() {
  const chainId = polygonAmoy.id;
  const version = useReadAsseteraExchangeVersion({ chainId });
  const totalOrders = useReadAsseteraExchangeTotalOrders({ chainId });
  const paused = useReadAsseteraExchangePaused({ chainId });

  const show = (q: { data?: unknown; isLoading: boolean; error: unknown }) =>
    q.isLoading ? "…" : q.error ? "error" : String(q.data);

  return (
    <section>
      <h2>Live reads (Amoy)</h2>
      <ul>
        <li>
          <code>version()</code>: {show(version)}
        </li>
        <li>
          <code>totalOrders()</code>: {show(totalOrders)}
        </li>
        <li>
          <code>paused()</code>: {show(paused)}
        </li>
      </ul>
      <p style={{ color: "#666", fontSize: 14 }}>
        No address passed to any hook — resolved from <code>@asseteragmbh/evm-contracts</code> by chainId.
      </p>
    </section>
  );
}
