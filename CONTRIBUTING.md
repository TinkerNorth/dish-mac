# Contributing to Dish Mac

Thanks for your interest in improving the macOS client! This document
captures the conventions that aren't obvious from skimming the code.

## Getting set up

```bash
# 1) Install Xcode 15+ Command Line Tools (`xcode-select --install`)
# 2) Install the formatter + linter
brew install swiftformat swiftlint
# 3) Point git at the in-tree pre-commit hook
./scripts/setup-hooks.sh
```

The pre-commit hook runs `swiftformat` (autofix, re-stages) and
`swiftlint --strict` on staged Swift files. It skips gracefully if the
tools aren't installed — CI re-runs both in strict mode, so anything that
slips locally fails the PR.

## License headers

Every source file (`*.swift`) starts with:

```swift
// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
```

New files must include both lines. Don't introduce code under a different
license — the project is LGPL-3.0-or-later end-to-end (`LICENSE`,
`COPYING.GPL3`, source headers).

## Style

- Swift 5.9+, 4-space indent, ~120-column soft limit. `.swiftformat` and
  `.swiftlint.yml` are authoritative — run `swiftformat Sources Tests` to
  autofix and `swiftlint lint --strict Sources Tests` to lint.
- `AppModel` is the single source of truth — every published field is on
  `AppModel`, and the UI binds to it via `@EnvironmentObject` /
  `@ObservedObject`. Don't introduce competing observable objects.
- The hot path uses raw POSIX sockets and `os_unfair_lock` — not
  `NWConnection` or Combine — to keep `sendto()` allocation-free.

## Branching & PRs

- All changes land on `main` via pull request — no direct pushes.
- Use the PR template (`.github/pull_request_template.md`) to describe
  the change, the manual test matrix you ran (controller types tried,
  pairing scenarios), and call out anything that touches the wire protocol.
- Keep commits focused; squash noisy fixup commits before review.

> **Note on branch protection.** GitHub's branch-protection features are
> not available for private repos on the free org plan, so direct pushes
> to `main` are not blocked at the platform level. Treat the PR-based
> flow as a convention and rely on CI as the quality gate.

## What CI runs

`.github/workflows/macos-ci.yml` runs on every PR:

1. `swiftformat --lint` over the source tree.
2. `swiftlint lint --strict --reporter github-actions-logging`.
3. `swift build --configuration debug`.
4. `swift test --parallel --enable-code-coverage` (XCTest).
5. `swift build --configuration release` + `./bundle.sh release`.
6. Uploads `Dish.app` as a CI artifact.

If any step fails, the PR is blocked.

## Touching the hot path

The GameController `valueChangedHandler` thread runs at controller polling
rate and must never block. If you're modifying `GameControllerInput`,
`GamepadInputProcessor`, or `SatelliteClient.sendReport`:

- No `Task`, no `await`, no main-actor hop on the send path.
- No `Combine` `.sink` on the per-event chain — direct callback only.
- The `RoutingTable` `os_unfair_lock` is the only lock allowed; hold it briefly.
- Preserve `IP_TOS = 0xB8` (DSCP EF) and `SO_NOSIGPIPE` on every send.

## Touching the wire protocol

The macOS, Android, and Linux clients all talk to the same `satellite`
server and must produce byte-identical traffic:

- AEAD: ChaCha20-Poly1305 IETF, 12-byte big-endian nonce derived from a
  monotonic counter.
- Packet layout: `token(4) | counter(4) | ciphertext+tag`, with the
  4-byte token as AAD.
- XUSB report: 12 bytes, little-endian.
- Ports: discovery UDP 9879, pairing TCP 9878, HTTP TCP 9877,
  streaming UDP 9876.

Any change here must be coordinated with `dish-android`, `dish-linux`,
and `satellite` in the same PR / release cycle.

## Reporting bugs

Use the issue templates under `.github/ISSUE_TEMPLATE/`. Include the
macOS version, Mac model, controller make/model, and the relevant
`Console.app` excerpt around the misbehavior.
