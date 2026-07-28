#!/usr/bin/env bash
# Storage-layout guard for the upgradeable AsseteraExchange proxy.
#
# The proxy's storage layout is a hard upgrade-safety invariant: a new
# implementation may only *append* storage (shrinking `__gap`), never move,
# retype, or reorder an existing slot. This script snapshots the layout so any
# change — including one introduced indirectly by an OpenZeppelin dependency
# bump — shows up as a reviewable diff instead of a silent slot shift.
#
# Because the OZ v5 upgradeable bases use ERC-7201 namespaced storage, a clean
# minor dependency bump produces a ZERO-line diff here. Any diff on a dep bump
# is therefore a genuine red flag that must be reviewed before merging.
#
# STRUCT MEMBERS ARE PART OF THE SNAPSHOT (AC-833). The top-level table alone has
# a blind spot: `_orders`/`_offers` are mappings, so adding, reordering or
# retyping a field INSIDE `Order`/`Offer` does not move a single top-level slot
# and produced a zero-line diff. Appending to a struct held in a mapping is
# upgrade-safe (each value sits at its own hashed slot), but reordering or
# retyping one is not — and the guard could not tell those apart. The per-struct
# member layout below closes that gap.
#
# Usage:
#   bash script/storage-layout.sh          # check working tree vs the snapshot (CI mode)
#   bash script/storage-layout.sh write    # regenerate the snapshot after an *intended* change
set -euo pipefail

cd "$(dirname "$0")/.."

CONTRACT="AsseteraExchange"
SNAPSHOT="storage/${CONTRACT}.txt"
CURRENT="$(mktemp)"
trap 'rm -f "$CURRENT"' EXIT

{
  forge inspect "$CONTRACT" storage-layout
  echo
  echo "=== struct members (slot/offset within each struct) ==="
  forge inspect "$CONTRACT" storage-layout --json | python3 script/struct-layout.py
} >"$CURRENT"

mkdir -p storage

if [[ "${1:-check}" == "write" ]]; then
  cp "$CURRENT" "$SNAPSHOT"
  echo "✅ wrote storage snapshot -> $SNAPSHOT"
  exit 0
fi

if [[ ! -f "$SNAPSHOT" ]]; then
  echo "❌ no snapshot at $SNAPSHOT — run: bash script/storage-layout.sh write"
  exit 1
fi

if diff -u <(tr -d '\r' <"$SNAPSHOT") <(tr -d '\r' <"$CURRENT"); then
  echo "✅ ${CONTRACT} storage layout unchanged"
else
  cat >&2 <<'EOF'

❌ AsseteraExchange storage layout CHANGED.

  The proxy's storage layout is an upgrade-safety invariant. Review the diff above:
    - New trailing vars that shrink `__gap`   -> expected for a deliberate upgrade.
    - Fields APPENDED to a struct held in a mapping (Order/Offer)
                                              -> safe; each value has its own hashed slot.
    - Any moved / retyped / reordered slot     -> UNSAFE; will corrupt the live proxy.
    - Any reordered / retyped STRUCT MEMBER    -> UNSAFE for the same reason.

  If this change was introduced by a dependency bump and you did NOT intend it,
  do not merge. If it is an intended, upgrade-safe change, re-baseline with:
    bash script/storage-layout.sh write
EOF
  exit 1
fi
