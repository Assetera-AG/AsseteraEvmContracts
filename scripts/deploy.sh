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
# Networks (the alias is a key in foundry.toml's [rpc_endpoints], and also Foundry's own chain alias):
#   testnets  amoy (80002)  sepolia (11155111)
#   mainnets  polygon (137)  mainnet (1, Ethereum)  base (8453)  optimism (10)
#             bsc (56, BNB Smart Chain)  arbitrum (42161, Arbitrum One)
#
# Because CreateX sits at the same canonical address on every one of these chains and the salt is
# NOT cross-chain protected, the proxy and the forwarder land on the SAME address on every chain for
# a given deployer. That parity is worth preserving; nothing here should change the deployer or the
# salt labels casually.
#
# Usage (from anywhere in the repo):
#   scripts/deploy.sh amoy                 # dry run, prints the addresses it would create
#   scripts/deploy.sh amoy --broadcast     # send it
#   scripts/deploy.sh polygon              # dry run against a MAINNET, always allowed
#   CONFIRM_MAINNET_DEPLOY=polygon scripts/deploy.sh polygon --broadcast
#
# ⚠️ MAINNET BROADCASTS ARE GATED HARDER THAN TESTNET ONES. On a mainnet, `--broadcast` additionally
#    requires all of the following. The first four have NO override at all; only the last one does,
#    and it is about publishing sources rather than about who controls the contracts:
#      • CONFIRM_MAINNET_DEPLOY must be set to the network name, spelled exactly. A mistyped
#        positional argument therefore cannot start a mainnet broadcast on its own.
#      • ALLOW_DEPLOYER_AS_ADMIN is REFUSED, not honoured. Admin holds upgrade authority over every
#        contract in the deployment; a "disposable" mainnet deployment is not a thing.
#      • ADMIN_ADDRESS must be set and must not be the deployer.
#      • KYC_SIGNER_ADDRESS, FEE_SIGNER_ADDRESS and SETTLEMENT_SIGNER_ADDRESS must all be set. On a
#        testnet an unset signer is a warning and silently falls back to the deployer; on a mainnet
#        that fallback would hand every operator role to the deploy key, so it is an error.
#      • DEPLOY_MOCKS must not be forced on. The faucet tokens are structurally testnet-only
#        (`_isTestnet` in script/DeployBase.sol), and DEPLOY_MOCKS is the one env that can override it.
#      • ETHERSCAN_API_KEY must be set, so the run verifies sources. Set ALLOW_UNVERIFIED_MAINNET=1
#        only if you have accepted that you will verify by hand afterwards.
#
# Env (from .env in the repo root, or the shell):
#   DEPLOYER_ADDRESS  — the keystore account's address, passed as --sender. Required.
#   DEPLOYER_ACCOUNT  — keystore name. Defaults to "assetera-deployer".
#   <NETWORK>_RPC_URL — AMOY_RPC_URL, SEPOLIA_RPC_URL, POLYGON_RPC_URL, MAINNET_RPC_URL, BASE_RPC_URL,
#                       OPTIMISM_RPC_URL, BSC_RPC_URL, ARBITRUM_RPC_URL. Resolved by foundry.toml's
#                       rpc_endpoints; use the SERVER-side RPC key, not a domain-restricted browser
#                       key, which 403s from a terminal.
#   ADMIN_ADDRESS, KYC_SIGNER_ADDRESS, FEE_SIGNER_ADDRESS, SETTLEMENT_SIGNER_ADDRESS, RELAYER_ADDRESS
#                     — every one of these silently DEFAULTS TO THE DEPLOYER if unset. Setting them is
#                       not optional on any deploy you intend to keep, and the first four are hard
#                       requirements on a mainnet broadcast.
#   ETHERSCAN_API_KEY — enables --verify. One Etherscan V2 key covers all eight networks (see the
#                       [etherscan] section of foundry.toml). Skipped with a warning on a testnet,
#                       required on a mainnet.
#   CONFIRM_MAINNET_DEPLOY — must equal the network name to broadcast to a mainnet. See above.
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

# --- The network list, and the ONE place that decides what counts as a mainnet ---------------------
# Both facts live in this single case so they cannot drift apart. Every mainnet guard below keys off
# IS_MAINNET and nothing else re-derives it, so adding a network here is the whole change: a name that
# is not listed is rejected outright, and a listed mainnet cannot quietly inherit the testnet guard set.
# CHAIN_ID is carried for the operator-facing echo only; the chain the run actually talks to is decided
# by the RPC endpoint, and Foundry compares the two itself.
NETWORKS="amoy sepolia polygon mainnet base optimism bsc arbitrum"
IS_MAINNET=0
case "$NETWORK" in
  amoy)     CHAIN_ID=80002 ;;
  sepolia)  CHAIN_ID=11155111 ;;
  polygon)  CHAIN_ID=137;   IS_MAINNET=1 ;;
  mainnet)  CHAIN_ID=1;     IS_MAINNET=1 ;;
  base)     CHAIN_ID=8453;  IS_MAINNET=1 ;;
  optimism) CHAIN_ID=10;    IS_MAINNET=1 ;;
  bsc)      CHAIN_ID=56;    IS_MAINNET=1 ;;
  arbitrum) CHAIN_ID=42161; IS_MAINNET=1 ;;
  "") echo "usage: scripts/deploy.sh <network> [--broadcast]" >&2
      echo "networks: $NETWORKS" >&2
      exit 1 ;;
  *)  echo "unknown network '$NETWORK' (expected one of: $NETWORKS)" >&2; exit 1 ;;
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

# --- Refuse a mainnet broadcast that was not asked for in words ------------------------------------
# The only thing separating `scripts/deploy.sh amoy --broadcast` from a live-money deploy is one
# mistyped word, and the argument is the first thing on the line where a typo is least visible. So a
# mainnet broadcast additionally has to name the network a second time, in the environment, where it
# cannot be reached by an up-arrow and an edited character. A dry run is deliberately NOT gated: it
# touches nothing, and making the safe path harder than the dangerous one trains people to skip it.
#
# This and the override refusal below run BEFORE the keystore checks on purpose: whether the run was
# meant at all is a cheaper question than whether the operator holds the key, and answering it first
# means a mistyped mainnet never gets as far as a passphrase prompt.
if [[ "$IS_MAINNET" -eq 1 && "$BROADCAST" -eq 1 ]]; then
  if [[ "${CONFIRM_MAINNET_DEPLOY:-}" != "$NETWORK" ]]; then
    echo "REFUSING a mainnet broadcast to '$NETWORK' (chain $CHAIN_ID) without explicit confirmation." >&2
    echo "Re-run as:  CONFIRM_MAINNET_DEPLOY=$NETWORK scripts/deploy.sh $NETWORK --broadcast" >&2
    echo "Do the dry run first (drop --broadcast) and check every printed address." >&2
    exit 1
  fi
  # ALLOW_DEPLOYER_AS_ADMIN=1 is the testnet escape hatch from the admin check further down. On a
  # mainnet it is refused rather than honoured: admin can replace the implementation behind the proxy,
  # i.e. replace all the code, on contracts holding other people's assets. There is no disposable
  # mainnet deployment, so an operator reaching for the override here has misread the situation and the
  # right answer is to stop, not to warn and continue.
  if [[ "${ALLOW_DEPLOYER_AS_ADMIN:-0}" == "1" ]]; then
    echo "ALLOW_DEPLOYER_AS_ADMIN=1 is REFUSED on mainnet '$NETWORK' (chain $CHAIN_ID)." >&2
    echo "It exists for disposable testnet deploys only. Admin holds permanent upgrade authority over" >&2
    echo "every contract in this deployment; it must be a separate, custodied address." >&2
    exit 1
  fi
  # The mock faucet tokens are open-mint. `_isTestnet` in script/DeployBase.sol already excludes them
  # from every chain that is not 31337/80002/11155111, but Deploy.s.sol reads DEPLOY_MOCKS as an
  # override, so a stale export in a shell is the one route by which a mainnet run could mint a token
  # anyone can print. Refuse it here rather than trusting that nobody has one.
  case "$(printf '%s' "${DEPLOY_MOCKS:-}" | tr '[:upper:]' '[:lower:]')" in
    ""|false|0) ;;
    *) echo "DEPLOY_MOCKS='${DEPLOY_MOCKS}' is set while deploying to mainnet '$NETWORK'." >&2
       echo "The mock faucet tokens are open-mint and must never exist on a mainnet. Unset it." >&2
       exit 1 ;;
  esac
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

norm() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# --- Refuse a broadcast whose roles were never set -------------------------------------------------
# Every role address in Deploy.s.sol falls back to the DEPLOYER when its variable is unset. That default
# is right for a throwaway anvil run and wrong everywhere else, and it fails silently: the deploy
# succeeds, the record looks plausible, and the deployer quietly holds admin plus every operator role on
# a live contract. Leaving one chain's value in .env while deploying another is the same mistake wearing
# a disguise, which is why the admin check compares against the deployer rather than merely testing that
# something is set.
#
# Set ALLOW_DEPLOYER_AS_ADMIN=1 for a genuinely disposable deploy. The `IS_MAINNET` disjunct is what
# makes the override testnet-only: on a mainnet this block is entered whatever the override says, and a
# mainnet run that set it never reaches here anyway because the earlier gate already refused it.
if [[ "$BROADCAST" -eq 1 && ("$IS_MAINNET" -eq 1 || "${ALLOW_DEPLOYER_AS_ADMIN:-0}" != "1") ]]; then
  if [[ -z "${ADMIN_ADDRESS:-}" ]]; then
    echo "ADMIN_ADDRESS is not set, so admin would default to the deployer $SENDER." >&2
    echo "That gives the key that signed this broadcast permanent upgrade authority. Set it." >&2
    exit 1
  fi
  if [[ "$(norm "$ADMIN_ADDRESS")" == "$(norm "$SENDER")" ]]; then
    echo "ADMIN_ADDRESS equals the deployer ($SENDER)." >&2
    echo "Admin can upgrade the implementation, i.e. replace all the code. It must not be the deploy key." >&2
    if [[ "$IS_MAINNET" -eq 1 ]]; then
      echo "There is no override for this on a mainnet." >&2
    else
      echo "Re-run with ALLOW_DEPLOYER_AS_ADMIN=1 only if this deployment is disposable." >&2
    fi
    exit 1
  fi
  # The operator-role signers. On a testnet an unset signer is a nuisance you can redeploy your way out
  # of, so it warns. On a mainnet the same silence hands KYC, fee and settlement signing authority to the
  # deploy key on a contract that cannot be redeployed, so it is fatal and stated one variable at a time
  # rather than as a single "some of these are missing".
  MISSING=0
  for v in KYC_SIGNER_ADDRESS FEE_SIGNER_ADDRESS SETTLEMENT_SIGNER_ADDRESS; do
    if [[ -z "${!v:-}" ]]; then
      if [[ "$IS_MAINNET" -eq 1 ]]; then
        echo "$v is not set - it would default to the deployer $SENDER." >&2
        MISSING=1
      else
        echo "⚠️  $v is not set - it will default to the deployer $SENDER."
      fi
    fi
  done
  if [[ "$MISSING" -eq 1 ]]; then
    echo "Every operator-role signer must be set explicitly for a mainnet broadcast." >&2
    exit 1
  fi
  # RELAYER_ADDRESS and OPERATOR_ADDRESS are recorded for reference only (no role is granted from them
  # in Deploy.s.sol), so they warn on every network rather than blocking a mainnet run.
  if [[ "$IS_MAINNET" -eq 1 ]]; then
    for v in RELAYER_ADDRESS OPERATOR_ADDRESS; do
      if [[ -z "${!v:-}" ]]; then
        echo "⚠️  $v is not set - the deployment record will list the deployer $SENDER for it."
      fi
    done
  fi
  echo "→ admin=$ADMIN_ADDRESS  (confirm this is right for $NETWORK, not another chain's value)"
fi

ARGS=(script script/Deploy.s.sol:Deploy --rpc-url "$NETWORK" --account "$ACCOUNT" --sender "$SENDER")

if [[ "$BROADCAST" -eq 1 ]]; then
  ARGS+=(--broadcast)
  if [[ -n "${ETHERSCAN_API_KEY:-}" ]]; then
    ARGS+=(--verify)
  elif [[ "$IS_MAINNET" -eq 1 && "${ALLOW_UNVERIFIED_MAINNET:-0}" != "1" ]]; then
    # Unverified mainnet bytecode is not something you can quietly fix later: until it is verified, no
    # counterparty can read what they are trusting. One Etherscan V2 key covers every network in
    # foundry.toml's [etherscan] section, so there is nothing to procure per chain.
    echo "ETHERSCAN_API_KEY is not set, so this mainnet deploy would publish UNVERIFIED sources." >&2
    echo "Set it, or re-run with ALLOW_UNVERIFIED_MAINNET=1 if you accept verifying by hand after." >&2
    exit 1
  else
    echo "⚠️  ETHERSCAN_API_KEY not set - deploying WITHOUT source verification."
    echo "    Verify later with: forge verify-contract --chain $NETWORK <address> <Contract>"
  fi
else
  echo "→ DRY RUN on $NETWORK. Nothing is sent, and the deployment record is not modified."
  echo "  Re-run with --broadcast once the addresses below are the ones you expect."
fi

if [[ "$IS_MAINNET" -eq 1 && "$BROADCAST" -eq 1 ]]; then
  echo "→ MAINNET BROADCAST: $NETWORK (chain $CHAIN_ID). These addresses are permanent."
fi

echo "→ network=$NETWORK  chain=$CHAIN_ID  account=$ACCOUNT  sender=$SENDER"
cd "$ROOT/contracts"
exec forge "${ARGS[@]}"
