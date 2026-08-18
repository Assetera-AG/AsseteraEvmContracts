#!/usr/bin/env bash
# Deploy the exchange stack to a live network, signing from an ENCRYPTED KEYSTORE.
#
# Why a keystore rather than PRIVATE_KEY in the environment: the deployer key is not a high-value
# secret (it holds no role, cannot upgrade, cannot move funds) but it IS the input that decides every
# deterministic address in the deployment. A plaintext key in a dotfile leaks into shell history,
# process listings and backups for no benefit. `cast wallet import <name> --interactive` stores it
# encrypted under ~/.foundry/keystores and costs one passphrase prompt per deploy.
#
#   cast wallet import assetera-deployer --interactive
#
# ⚠️ DRY RUN IS THE DEFAULT. Pass --broadcast to actually send. A dry run computes and prints every
#    address without touching a chain and without modifying the committed deployment record, so it is
#    the last chance to notice that the deployer, the salt labels or the admin are not what you think.
#    Compare its addresses against the ones you expect BEFORE broadcasting; they are permanent.
#
# Usage (from anywhere in the repo):
#   scripts/deploy.sh amoy                 # dry run, prints the addresses it would create
#   scripts/deploy.sh amoy --broadcast     # send it
#   scripts/deploy.sh sepolia --broadcast
#
# Env (from .env in the repo root, or the shell):
#   DEPLOYER_ADDRESS  — the keystore account's address, passed as --sender. Required.
#   DEPLOYER_ACCOUNT  — keystore name. Defaults to "assetera-deployer".
#   AMOY_RPC_URL / SEPOLIA_RPC_URL — resolved by foundry.toml's rpc_endpoints; use the SERVER-side
#                       RPC key, not a domain-restricted browser key, which 403s from a terminal.
#   ADMIN_ADDRESS, KYC_SIGNER_ADDRESS, FEE_SIGNER_ADDRESS, SETTLEMENT_SIGNER_ADDRESS, RELAYER_ADDRESS
#                     — every one of these silently DEFAULTS TO THE DEPLOYER if unset. Setting them is
#                       not optional on any deploy you intend to keep.
#   ETHERSCAN_API_KEY — enables --verify. Skipped with a warning when absent, rather than failing the
#                       run after the contracts are already on chain.
set -euo pipefail

NETWORK="${1:-}"
BROADCAST=0
shift || true
for arg in "$@"; do
  case "$arg" in
    --broadcast) BROADCAST=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 1 ;;
  esac
done

case "$NETWORK" in
  amoy|sepolia) ;;
  "") echo "usage: scripts/deploy.sh <amoy|sepolia> [--broadcast]" >&2; exit 1 ;;
  *)  echo "unknown network '$NETWORK' (expected amoy or sepolia)" >&2; exit 1 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Load the repo-root .env if present, for the address variables below. Foundry loads it too, but only
# for the ${VAR} references inside foundry.toml — CLI arguments are this script's job.
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "$ROOT/.env"
  set +a
fi

ACCOUNT="${DEPLOYER_ACCOUNT:-assetera-deployer}"
SENDER="${DEPLOYER_ADDRESS:-}"

if [[ -z "$SENDER" ]]; then
  echo "DEPLOYER_ADDRESS is not set (put it in .env or export it)." >&2
  echo "It must be the address of keystore account '$ACCOUNT':" >&2
  echo "  cast wallet address --account $ACCOUNT" >&2
  exit 1
fi

# Substring match, not anchored: `cast wallet list` prints entries as "0x<name> (Local)", so anchoring
# to the start of the line looks correct and never matches.
if ! cast wallet list 2>/dev/null | grep -qF "$ACCOUNT"; then
  echo "no keystore account named '$ACCOUNT' (~/.foundry/keystores)." >&2
  echo "Create it once with:  cast wallet import $ACCOUNT --interactive" >&2
  exit 1
fi

# --- Refuse a broadcast whose roles were never set -------------------------------------------------
# Every role address in Deploy.s.sol falls back to the DEPLOYER when its variable is unset. That default
# is right for a throwaway anvil run and wrong everywhere else, and it fails silently: the deploy
# succeeds, the record looks plausible, and the deployer quietly holds admin plus every operator role on
# a live contract. Leaving one chain's value in .env while deploying another is the same mistake wearing
# a disguise, which is why the admin check compares against the deployer rather than merely testing that
# something is set.
#
# Set ALLOW_DEPLOYER_AS_ADMIN=1 for a genuinely disposable deploy.
if [[ "$BROADCAST" -eq 1 && "${ALLOW_DEPLOYER_AS_ADMIN:-0}" != "1" ]]; then
  norm() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
  if [[ -z "${ADMIN_ADDRESS:-}" ]]; then
    echo "ADMIN_ADDRESS is not set, so admin would default to the deployer $SENDER." >&2
    echo "That gives the key that signed this broadcast permanent upgrade authority. Set it." >&2
    exit 1
  fi
  if [[ "$(norm "$ADMIN_ADDRESS")" == "$(norm "$SENDER")" ]]; then
    echo "ADMIN_ADDRESS equals the deployer ($SENDER)." >&2
    echo "Admin can upgrade the implementation, i.e. replace all the code. It must not be the deploy key." >&2
    echo "Re-run with ALLOW_DEPLOYER_AS_ADMIN=1 only if this deployment is disposable." >&2
    exit 1
  fi
  for v in KYC_SIGNER_ADDRESS FEE_SIGNER_ADDRESS SETTLEMENT_SIGNER_ADDRESS; do
    if [[ -z "${!v:-}" ]]; then
      echo "⚠️  $v is not set - it will default to the deployer $SENDER."
    fi
  done
  echo "→ admin=$ADMIN_ADDRESS  (confirm this is right for $NETWORK, not another chain's value)"
fi

ARGS=(script script/Deploy.s.sol:Deploy --rpc-url "$NETWORK" --account "$ACCOUNT" --sender "$SENDER")

if [[ "$BROADCAST" -eq 1 ]]; then
  ARGS+=(--broadcast)
  if [[ -n "${ETHERSCAN_API_KEY:-}" ]]; then
    ARGS+=(--verify)
  else
    echo "⚠️  ETHERSCAN_API_KEY not set - deploying WITHOUT source verification."
    echo "    Verify later with: forge verify-contract --chain $NETWORK <address> <Contract>"
  fi
else
  echo "→ DRY RUN on $NETWORK. Nothing is sent, and the deployment record is not modified."
  echo "  Re-run with --broadcast once the addresses below are the ones you expect."
fi

echo "→ network=$NETWORK  account=$ACCOUNT  sender=$SENDER"
cd "$ROOT/contracts"
exec forge "${ARGS[@]}"
