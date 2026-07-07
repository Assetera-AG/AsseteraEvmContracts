<!-- Title: Conventional Commit, e.g. `feat(exchange): add per-pair taker fee`. Branch: feat/AC-###-slug -->

## What & why

<!-- What does this change and why. Link the Jira issue: AC-### -->

Closes AC-

## Changes

-

## Checklist

- [ ] `forge fmt --check` passes (formatting)
- [ ] `solhint` passes (no errors)
- [ ] `forge build` compiles
- [ ] `forge test -vvv` green; new/changed behaviour is covered by tests
- [ ] Events touched? `docs/INDEXER_EVENT_SCHEMA.md` updated
- [ ] Storage layout of upgradeable contracts preserved (append-only) for `AsseteraExchange`
- [ ] Docs / NatSpec updated where relevant
