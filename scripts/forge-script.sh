#!/usr/bin/env bash
# Run a read-only Foundry script against a network, with the repo-root .env loaded.
#
# Why this exists: `forge` loads a `.env` from the FOUNDRY PROJECT ROOT, which is `contracts/`, but the
# repo's `.env` lives at the workspace root next to `package.json`, because it also carries values the
# JavaScript side reads. So `cd contracts && forge script --rpc-url amoy` fails with
# "environment variable `AMOY_RPC_URL` not found" even when the value is sitting in the .env you just
# edited. `source .env` in your own shell does not save you either: without `set -a` the variables are
# shell-local and never reach the child process npm spawns.
#
# Both failures point at the RPC alias, which makes them read like a missing RPC URL rather than a
# missing export, so they cost more time than they should.
#
# Usage (from anywhere in the repo):
#   scripts/forge-script.sh <network> <Script.s.sol:Contract> [extra forge args...]
# e.g.
#   scripts/forge-script.sh polygon Verify.s.sol:Verify -vv
#   scripts/forge-script.sh polygon AdminCalldata.s.sol:AdminCalldata -vv
#
# Read-only by design: it never passes --broadcast. Deploys go through scripts/deploy.sh, which also
# handles keystore signing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FOUNDRY_TOML="$ROOT/contracts/foundry.toml"

# --- The network list is READ, not restated -------------------------------------------------------
# `--rpc-url <alias>` is resolved by forge from `[rpc_endpoints]` in foundry.toml, so that table is
# already the source of truth for which names are valid. An allowlist written out here by hand is a
# second copy of the same fact, and it drifted: the six mainnets were added to foundry.toml and to
# deploy.sh, but this script kept refusing everything except amoy/sepolia/local, so there was no way
# to run Verify or AdminCalldata against a mainnet at all. Since the router deploys CLOSED (an unset
# settlement cap reads as zero, which means that currency cannot settle), AdminCalldata is what
# produces the transactions that open it. The drift was not cosmetic: it blocked the step immediately
# after a mainnet deploy.
#
# Reading the table means adding a chain to foundry.toml is the whole change, here and in forge, and
# the two cannot disagree again. The env var NAME comes from the same line rather than being
# re-derived by uppercasing the alias, so an endpoint that does not follow that convention still
# resolves.
read_rpc_table() {
  awk '
    /^[[:space:]]*\[rpc_endpoints\][[:space:]]*$/ { in_table = 1; next }
    /^[[:space:]]*\[/                             { in_table = 0 }
    !in_table                                     { next }
    /^[[:space:]]*#/                              { next }
    /=/ {
      alias = $0; sub(/[[:space:]]*=.*/, "", alias); gsub(/[[:space:]]/, "", alias)
      if (alias == "") next
      var = ""
      if (match($0, /\$\{[A-Za-z_][A-Za-z0-9_]*\}/)) {
        var = substr($0, RSTART + 2, RLENGTH - 3)
      }
      print alias, var
    }
  ' "$FOUNDRY_TOML"
}

if [[ ! -f "$FOUNDRY_TOML" ]]; then
  echo "cannot find $FOUNDRY_TOML - the network list is read from its [rpc_endpoints] table." >&2
  exit 1
fi

RPC_TABLE="$(read_rpc_table)"
NETWORKS="$(printf '%s\n' "$RPC_TABLE" | awk 'NF {print $1}' | paste -sd' ' -)"

if [[ -z "$NETWORKS" ]]; then
  echo "no [rpc_endpoints] entries found in $FOUNDRY_TOML." >&2
  exit 1
fi

NETWORK="${1:-}"
TARGET="${2:-}"
if [[ -z "$NETWORK" || -z "$TARGET" ]]; then
  echo "usage: scripts/forge-script.sh <network> <Script.s.sol:Contract> [forge args...]" >&2
  echo "networks: $NETWORKS" >&2
  exit 1
fi
shift 2

# The env var this alias needs, taken from the line that declares it. Empty for a literal URL such as
# `local`, which needs nothing exported. A miss here is what rejects an unknown network.
if ! VAR="$(printf '%s\n' "$RPC_TABLE" | awk -v n="$NETWORK" '$1 == n { print $2; found = 1 } END { exit !found }')"; then
  echo "unknown network '$NETWORK' (expected one of: $NETWORKS)" >&2
  echo "Networks come from [rpc_endpoints] in $FOUNDRY_TOML - add it there first." >&2
  exit 1
fi

# `set -a` is the whole point: it marks everything sourced as exported, so it survives into forge.
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "$ROOT/.env"
  set +a
fi

# Fail with the useful message rather than forge's, which names the alias and not the cause.
if [[ -n "$VAR" && -z "${!VAR:-}" ]]; then
  echo "$VAR is not set." >&2
  echo "Put it in $ROOT/.env (this script exports it for you), e.g.:" >&2
  echo "  $VAR=https://<host>/v3/<server-side key>" >&2
  echo "Use a SERVER-side RPC key: a domain-restricted browser key is matched on Origin and 403s here." >&2
  exit 1
fi

cd "$ROOT/contracts"
exec forge script "script/$TARGET" --rpc-url "$NETWORK" "$@"
