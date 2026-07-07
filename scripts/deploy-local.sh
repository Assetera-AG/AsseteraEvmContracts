#!/usr/bin/env bash
# Deploy the exchange stack to a local anvil node (ADR-0026).
#
# anvil ships the plain 0x4e59 CREATE2 deployer but NOT CreateX, so we etch CreateX's runtime bytecode onto
# the node (idempotent) before broadcasting. On live chains CreateX already exists, so `deploy:<network>`
# just runs `forge script … --broadcast` directly. Deterministic addresses are identical either way.
set -euo pipefail

RPC="${RPC_URL:-http://127.0.0.1:8545}"
CREATEX="0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Default anvil account #0 (well-known test key; never a real funded key).
KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

if ! cast code "$CREATEX" --rpc-url "$RPC" 2>/dev/null | grep -q '^0x..'; then
  echo "→ etching CreateX onto local anvil ($CREATEX)"
  BYTECODE=$(grep -oE 'hex"[0-9a-fA-F]+"' "$ROOT/contracts/lib/createx-forge/script/CreateX.d.sol" | head -1 | sed -E 's/hex"//; s/"//')
  cast rpc anvil_setCode "$CREATEX" "0x${BYTECODE}" --rpc-url "$RPC" >/dev/null
fi

cd "$ROOT/contracts"
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC" --broadcast --private-key "$KEY"
