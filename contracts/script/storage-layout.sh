#!/usr/bin/env bash
# Storage-layout guard for EVERY upgradeable proxy in this repo — `AsseteraECS` (the exchange)
# and `AsseteraPrimarySales` (the primary-sales router).
#
# A proxy's storage layout is a hard upgrade-safety invariant: a new implementation may only
# *append* storage (shrinking `__gap`), never move, retype, or reorder an existing slot. This
# script snapshots each layout so any change — including one introduced indirectly by an
# OpenZeppelin dependency bump — shows up as a reviewable diff instead of a silent slot shift.
#
# Because the OZ v5 upgradeable bases use ERC-7201 namespaced storage, a clean minor dependency
# bump produces a ZERO-line diff here. Any diff on a dep bump is therefore a genuine red flag
# that must be reviewed before merging.
#
# ⚠️ `AsseteraPrimarySales` HAS NO LINEAR STORAGE TODAY, every region of it being ERC-7201
# namespaced, so its snapshot is near-empty — and that is the correct, useful result rather than
# a sign the guard is not wired. The guard's job on that contract is to shout the day somebody
# adds a linear state variable, which is precisely the mistake the namespacing exists to
# prevent. The guard was `AsseteraECS`-only until the review of PR #58, where it was repeatedly
# quoted as evidence that the primary-sales work is upgrade-safe while saying nothing about it.
#
# STRUCT MEMBERS ARE PART OF THE SNAPSHOT (AC-833). The top-level table alone has a blind spot:
# `_orders`/`_offers` are mappings, so adding, reordering or retyping a field INSIDE
# `Order`/`Offer` does not move a single top-level slot and produced a zero-line diff. Appending
# to a struct held in a mapping is upgrade-safe (each value sits at its own hashed slot), but
# reordering or retyping one is not — and the guard could not tell those apart. The per-struct
# member layout below closes that gap.
#
# Usage:
#   bash script/storage-layout.sh          # check working tree vs the snapshots (CI mode)
#   bash script/storage-layout.sh write    # regenerate the snapshots after an *intended* change
set -euo pipefail

cd "$(dirname "$0")/.."

# Every proxy whose layout is an upgrade-safety invariant. Add a contract here the day it gets
# its own proxy — a proxy nobody snapshotted is a proxy nobody can prove is upgrade-safe.
CONTRACTS=(AsseteraECS AsseteraPrimarySales)

MODE="${1:-check}"
CURRENT="$(mktemp)"
trap 'rm -f "$CURRENT"' EXIT

mkdir -p storage

failed=0

for CONTRACT in "${CONTRACTS[@]}"; do
  SNAPSHOT="storage/${CONTRACT}.txt"

  # ⚠️ Drop the contract's build artifact first, and do NOT "optimise" this away. `forge build`
  # writes artifacts WITHOUT a `storageLayout` section, and `forge inspect` then sees an
  # up-to-date artifact and declines to recompile — so the very next command fails with
  # "storage layout missing from artifact". A fresh CI checkout does not hit it; a local
  # edit-then-build loop hits it every time, which is exactly when the guard is worth running.
  # Removing the artifact forces the one recompile that emits the layout. `out/` is the
  # gitignored build directory, so this costs a rebuild of one file and nothing else.
  rm -rf "out/${CONTRACT}.sol"

  {
    forge inspect "$CONTRACT" storage-layout
    echo
    echo "=== struct members (slot/offset within each struct) ==="
    forge inspect "$CONTRACT" storage-layout --json | python3 script/struct-layout.py
  } >"$CURRENT"

  if [[ "$MODE" == "write" ]]; then
    cp "$CURRENT" "$SNAPSHOT"
    echo "✅ wrote storage snapshot -> $SNAPSHOT"
    continue
  fi

  if [[ ! -f "$SNAPSHOT" ]]; then
    echo "❌ no snapshot at $SNAPSHOT — run: bash script/storage-layout.sh write"
    exit 1
  fi

  if diff -u <(tr -d '\r' <"$SNAPSHOT") <(tr -d '\r' <"$CURRENT"); then
    echo "✅ ${CONTRACT} storage layout unchanged"
  else
    failed=1
    cat >&2 <<EOF

❌ ${CONTRACT} storage layout CHANGED.

  The proxy's storage layout is an upgrade-safety invariant. Review the diff above:
    - New trailing vars that shrink \`__gap\`   -> expected for a deliberate upgrade.
    - Fields APPENDED to a struct held in a mapping (Order/Offer)
                                              -> safe; each value has its own hashed slot.
    - Any moved / retyped / reordered slot     -> UNSAFE; will corrupt the live proxy.
    - Any reordered / retyped STRUCT MEMBER    -> UNSAFE for the same reason.
    - Any NEW top-level slot on a contract whose storage is meant to be entirely ERC-7201
      namespaced (AsseteraPrimarySales)        -> almost certainly a mistake; namespace it.

  If this change was introduced by a dependency bump and you did NOT intend it,
  do not merge. If it is an intended, upgrade-safe change, re-baseline with:
    bash script/storage-layout.sh write
EOF
  fi
done

exit "$failed"
