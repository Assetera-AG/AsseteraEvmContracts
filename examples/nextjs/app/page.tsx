import { getDeployment } from "@asseteragmbh/evm-contracts";
import { LiveReads } from "./live";

const CHAIN_ID = 80002; // Polygon Amoy
const EXPLORER = "https://amoy.polygonscan.com/address/";

export default function Page() {
  const deployment = getDeployment(CHAIN_ID);

  if (!deployment) {
    return (
      <main>
        <h1>No deployment for chain {CHAIN_ID}</h1>
        <p>Deploy + commit the artifact, then rebuild the SDK.</p>
      </main>
    );
  }

  const link = (address: string) => (
    <a href={EXPLORER + address} target="_blank" rel="noreferrer">
      {address}
    </a>
  );

  return (
    <main>
      <h1>@asseteragmbh/evm-contracts — Amoy sample</h1>
      <p>
        Every address and ABI below is resolved from the SDK <strong>by chainId</strong> (<code>{deployment.caip2}</code>)
        — nothing is hardcoded.
      </p>

      <h2>Addresses ({deployment.caip2})</h2>
      <ul>
        <li>Exchange (proxy): {link(deployment.contracts.AsseteraExchange)}</li>
        <li>Forwarder: {link(deployment.contracts.Forwarder)}</li>
        <li>MockUSDC: {link(deployment.contracts.MockUSDC)}</li>
        <li>MockRWA: {link(deployment.contracts.MockRWA)}</li>
      </ul>

      <LiveReads />

      <hr style={{ margin: "2rem 0" }} />
      <p style={{ color: "#666", fontSize: 14 }}>
        Server component uses <code>getDeployment(80002)</code>; the live reads use the generated wagmi hooks from{" "}
        <code>@asseteragmbh/evm-contracts/react</code>. Services would use <code>createExchangeClient()</code> instead.
      </p>
    </main>
  );
}
