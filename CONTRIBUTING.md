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

CI runs SwiftFormat 0.61.1 and SwiftLint 0.65.0, pinned by version and
SHA-256 in `macos-ci.yml` (release binaries, not Homebrew's latest). Homebrew
may hand you newer ones with extra rules; the tree is formatted for the pinned
versions, so a rule the pins do not know is not a CI failure, and bumping the
pins is a deliberate commit that reformats the tree with them.

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

Build + style:

- `macos-ci.yml`: `swiftformat --lint`, `swiftlint --strict`, debug
  build, `swift test`, release build + `./bundle.sh release`. Uploads
  `Dish.app` as a CI artifact.

Security gates (also blocking):

- `security.yml`: action-pin lint, vulnerability allowlist expiry,
  OSV-Scanner, gitleaks secret scan, GitHub `dependency-review-action`
  (consumes `Package.resolved` for SwiftPM).
- `codeql.yml`: CodeQL `swift` analysis (security-extended +
  security-and-quality query packs).

If any step fails, the PR is blocked.

## Security

### Adding a vulnerability allowlist entry

Open a PR that adds an entry to [`.security/allowlist.yaml`](.security/allowlist.yaml)
(see the schema in the file). Required fields: `cve`, `reason`, `owner`,
`expires`. CI rejects the PR if any field is missing or `expires` is in
the past. Renew or remove on or before `expires`.

### Running security checks locally

```bash
# Action-pin lint (40-char SHA enforcement on every uses: line)
grep -REn '^\s*uses:' .github/workflows/ \
  | grep -vE '@[0-9a-f]{40}\b' \
  || echo "all pinned"

# Allowlist expiry
python3 - <<'PY'
import datetime, yaml, sys
data = yaml.safe_load(open('.security/allowlist.yaml').read()) or {}
for e in data.get('exceptions', []) or []:
    if datetime.date.fromisoformat(str(e['expires'])) < datetime.date.today():
        print('EXPIRED:', e); sys.exit(1)
PY

# OSV-Scanner against the worktree (picks up Package.resolved)
osv-scanner --recursive --skip-git .

# Gitleaks
gitleaks detect --no-banner --redact --source .
```

### Verifying a release artifact

Each GitHub Release ships the signed + notarized `dish-vX.Y.Z.zip`,
`*.sig`/`*.crt` (cosign keyless), `SHA256SUMS` + `SHA256SUMS.sig`/`*.crt`,
the SPDX + CycloneDX SBOMs, and `dish-mac.intoto.jsonl` (SLSA L3).

```bash
shasum -a 256 -c SHA256SUMS

cosign verify-blob \
  --certificate SHA256SUMS.crt \
  --signature   SHA256SUMS.sig \
  --certificate-identity-regexp '^https://github\.com/TinkerNorth/dish-mac/\.github/workflows/release\.yml@refs/tags/v.*$' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  SHA256SUMS

slsa-verifier verify-artifact \
  --provenance-path dish-mac.intoto.jsonl \
  --source-uri      github.com/TinkerNorth/dish-mac \
  --source-tag      vX.Y.Z \
  dish-vX.Y.Z.zip
```

The full cross-repo verification recipe lives in
[`SECURITY.md`](SECURITY.md).

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
server and must produce byte-identical traffic. The contract (protocol 1)
is specified in ONE place — `satellite/docs/contract.md`; this repo's
[`docs/contract.md`](docs/contract.md) maps each concept to the Swift file
implementing it. Never restate contract facts in code comments — link them.

Ground rules when changing anything wire-adjacent:

- All protocol logic that can be pure lives in the `DishCore` target
  (Foundation + CryptoKit only). Wire bytes are pinned by the cross-repo
  interop vectors in `Tests/DishCoreTests/SessionCryptoVectorTests.swift` —
  the same hex as the satellite / dish-linux / dish-android / dish-windows
  suites. If a vector test fails, you broke the protocol, not the test.
- AEAD: ChaCha20-Poly1305 IETF under the per-session HKDF key; nonce =
  `dir(1) | 0x00×7 | counter(4 BE)`; AAD = token; counters start at 1 per
  direction and never wrap.
- Topology is REST-only (declarative `PUT /api/connections` on `:9443`).
  The deleted protocol-0 topology opcodes must stay deleted — a stray
  reference should fail to compile.
- Any change here must be coordinated with `dish-android`, `dish-linux`,
  `dish-windows`, and `satellite` in the same PR / release cycle, vectors
  updated in lockstep on every end.

## Reporting bugs

Use the issue templates under `.github/ISSUE_TEMPLATE/`. Include the
macOS version, Mac model, controller make/model, and the relevant
`Console.app` excerpt around the misbehavior.
