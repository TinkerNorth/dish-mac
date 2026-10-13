## What changes, and why

<!-- Two or three sentences. Name the behaviour a user or a developer sees, not the files. -->

## Kind of change

- [ ] Fix
- [ ] Feature
- [ ] Refactor (behaviour unchanged)
- [ ] Docs, CI or repo plumbing
- [ ] Wire protocol or pairing flow (`[wire-coordinated]` in CHANGELOG; the satellite and the sibling clients need the matching change)

## Shape of the code (CONTRIBUTING, "Shape of the code")

- [ ] Immutable by default; one flow per function; named steps instead of comments.
- [ ] Every `switch` is exhaustive, with no `default`.
- [ ] No singleton, no mutable static, no discarded result, no lint suppression.
- [ ] The engine vends data; words and colours reach a view only through `L10n`, `DishTheme` and `DishFont`.

## Tests

- [ ] Red first: a test failed before the change and passes after it.
- [ ] Every new flow has a test, including the empty, error and loading shapes.
- [ ] A new user-facing string has its catalog entry and all five translations.
- [ ] `scripts/ci-local.sh` passes (format, lint strict, build, tests, release build, bundle).
- [ ] Manual check on macOS: <!-- what you clicked, with which controller and satellite -->

## Bookkeeping

- [ ] `CHANGELOG.md` has a line under `[Unreleased]`.
- [ ] `Tests/PARITY.md` is updated if a row changed.
- [ ] `docs/ARCHITECTURE.md` or `DESIGN.md` is updated if a rule or a token changed.
