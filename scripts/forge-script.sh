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
#   scripts/forge-script.sh <amoy|sepolia|local> <Script.s.sol:Contract> [extra forge args...]
# e.g.
#   scripts/forge-script.sh amoy Verify.s.sol:Verify -vv
#   scripts/forge-script.sh amoy AdminCalldata.s.sol:AdminCalldata -vv
#
# Read-only by design: it never passes --broadcast. Deploys go through scripts/deploy.sh, which also
# handles keystore signing.
set -euo pipefail

NETWORK="${1:-}"
TARGET="${2:-}"
if [[ -z "$NETWORK" || -z "$TARGET" ]]; then
  echo "usage: scripts/forge-script.sh <amoy|sepolia|local> <Script.s.sol:Contract> [forge args...]" >&2
  exit 1
fi
shift 2

case "$NETWORK" in
  amoy|sepolia|local) ;;
  *) echo "unknown network '$NETWORK' (expected amoy, sepolia or local)" >&2; exit 1 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# `set -a` is the whole point: it marks everything sourced as exported, so it survives into forge.
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "$ROOT/.env"
  set +a
fi

# Fail with the useful message rather than forge's, which names the alias and not the cause.
VAR="$(printf '%s' "$NETWORK" | tr '[:lower:]' '[:upper:]')_RPC_URL"
if [[ "$NETWORK" != "local" && -z "${!VAR:-}" ]]; then
  echo "$VAR is not set." >&2
  echo "Put it in $ROOT/.env (this script exports it for you), e.g.:" >&2
  echo "  $VAR=https://<host>/v3/<server-side key>" >&2
  echo "Use a SERVER-side RPC key: a domain-restricted browser key is matched on Origin and 403s here." >&2
  exit 1
fi

cd "$ROOT/contracts"
exec forge script "script/$TARGET" --rpc-url "$NETWORK" "$@"
