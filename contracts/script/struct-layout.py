#!/usr/bin/env python3
"""Render the per-struct member layout from `forge inspect ... storage-layout --json`.

Companion to storage-layout.sh. The top-level storage table treats `_orders` /
`_offers` as a single mapping slot and says nothing about the struct behind it,
so a field added, reordered or retyped INSIDE `Order`/`Offer` produced a
zero-line diff in the snapshot. That is a blind spot on exactly the kind of
change AC-833 made: appending to a struct held in a mapping is upgrade-safe,
but reordering or retyping one would corrupt every existing entry, and the
guard could not tell those two apart.

Reads the JSON layout on stdin, writes a stable, diffable rendering on stdout.
"""

import json
import sys


def main() -> int:
    types = json.load(sys.stdin).get("types") or {}
    for name in sorted(types):
        members = types[name].get("members")
        if not members:
            continue
        print()
        print(name)
        for m in members:
            slot = str(m["slot"]).rjust(4)
            offset = str(m["offset"]).rjust(2)
            print("  slot {}  offset {}  {}: {}".format(slot, offset, m["label"], m["type"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
