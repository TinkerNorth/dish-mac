# Contributing to Dish Mac

Thanks for contributing to the macOS client. This document captures the
conventions that are not obvious from reading the code: the gates, where code
goes, the shape of the code, and what CI enforces.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). By
participating, you agree to uphold it. Report unacceptable behavior to
`security@tinkernorth.com`.

## Getting set up

```bash
# 1) Install Xcode 26 or newer (Swift 6.2 tools; the tree is also verified on
#    the newest release Xcode)
# 2) Point git at the in-tree pre-commit hook
scripts/setup-hooks.sh
# 3) Run every CI gate against your worktree, in CI's order
scripts/ci-local.sh
```

`scripts/ci-local.sh` downloads the same SwiftFormat 0.61.1 and SwiftLint
0.65.0 release binaries CI pins (verified by SHA-256, into `.build/tools`),
then runs the format check, the strict lint, the debug build, the test build,
`swift test`, the release build and `bundle.sh`. A green run there is a green
`macos-ci.yml` run; `--quick` skips the release build and `--no-tests` skips
the suite. Homebrew's SwiftFormat and SwiftLint track their latest and will
flag rules the pins do not know; use the script's copies. A pin bump is a
deliberate commit that reformats the tree with it, in `macos-ci.yml`,
`scripts/ci-local.sh` and `THIRD_PARTY.md` together.

The pre-commit hook runs `swiftformat` (autofix, re-stages) and
`swiftlint --strict` on staged Swift files and skips when the tools are not
on your `PATH`; CI re-runs both, so anything that slips locally fails the PR.

## Where code goes

The app is four SwiftPM modules whose dependency arrows point one way, and the
layering is enforced in code: SwiftPM holds the graph, and
`Tests/ArchitectureTests` pins which frameworks each module may import.

| You have… | It goes in | May import |
|---|---|---|
| a wire codec, a crypto primitive, a protocol constant, or a `(state, event) -> result` decision with no IO | `DishCore` (`Sources/DishCore`) | Foundation, CryptoKit |
| a dataflow primitive | `DishKernel` (`Sources/DishKernel`) | Foundation, Combine |
| a socket, a request, a store, the controller bridge, a coordinator, or the composition root | `DishEngine` (`Sources/DishEngine`) | the engine's row in `ImportBoundariesTests`; never SwiftUI or AppKit |
| a view, a theme token, a localized word, a banner, or AppKit glue | `Dish` (`Sources/Dish`) | SwiftUI, AppKit, Combine, Foundation; never Network, Darwin, Security, GameController |

Within the engine, pick the primitive that matches what the thing does:

| You have… | Use |
|---|---|
| state owned from a socket, timer, cache or setting | `StateSource<S>` |
| one value purely derived from other state | `Composer<Out>` with a free-function transform |
| a side effect driven by a state | `Controller<S>` |
| durable keyed storage | `Repository<K, V>`, passing `RepositoryContract` |
| a request with one in-flight and one terminal shape | `AsyncState<T, E>` |
| imperative commands spanning several sources | a coordinator (`WifiConnectionManager`, `ConnectionHub`) |
| an IO boundary with no domain state | a gateway (`HTTPClient`, `PairingClient`, `SatelliteClient`) |

The rules, and why each exists, are in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).
Two that catch people out: a composer never performs IO (if it needs a socket
you are writing a source), and the engine never words anything (a failure is a
`ConnectionFailure` case; the app's `failureText` is the one place it becomes
a sentence). The engine's UI-facing surface is `package`; everything else is
`internal`, and tests reach it through `@testable import`.

## Touching the mark

`Resources/Dish.svg` is the fleet's app mark (`dish-linux/resources/brand/
dish-logo.svg`, byte for byte) and `Resources/Dish.icns` is rendered from it by
`scripts/render-icon.sh` (`brew install librsvg` for `rsvg-convert`; `iconutil`
ships with macOS). Change the mark across the fleet, copy it here, run the
script and commit both files; `BrandMarkTests` pins the geometry and
`BrandGlyphTests` the in-app glyph that mirrors it.

## Touching the UI

Every design value reaches its call site through a `DishTheme` or `DishFont`
name; [`DESIGN.md`](DESIGN.md) is the token reference. A view outside
`Theme.swift` writes no raw colour and no raw font size; `ThemeTokenTests`
fails the build on one. Every user-facing word reaches a view through `L10n`
(`Sources/Dish/L10n/`); its `StringCatalog` is the one reader of the compiled
catalog, and a view never holds an English literal. Derivation (a chip's text, a dot's
colour, a battery glyph) is a pure function under `Sources/Dish/UI/Mappers`,
tested in `Tests/DishTests`, never an expression inside a `body`. The shell,
the page rules and the kit rules are in [`docs/UI_CONTRACT.md`](docs/UI_CONTRACT.md).

## Translations

Six languages (en, bs, de, es, fr, pt-BR) live in one String Catalog,
`Sources/Dish/Resources/Localizable.xcstrings`. Xcode's build system compiles
it into per-language tables inside the resource bundle; SwiftPM's native build
system copies it verbatim, and nothing reads a verbatim catalog at run time, so
`scripts/compile-catalog.sh` compiles it wherever it landed: `bundle.sh` runs it
on the app, CI runs it before the tests, and `L10nTests` fails when a table is
missing. A new user-facing string needs its catalog
entry and all five translations in the same commit: `LocalizationTests` fails
on a key `L10n` uses that the catalog lacks, on a catalog entry no code uses,
and on any language missing a translation, because a missing translation is
not a blank, it is English shown to someone who does not read English.

## License headers

Every source file (`*.swift`) starts with:

```swift
// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
```

`LicenseHeaderTests` fails on a file without them. Don't introduce code under a
different license: the project is LGPL-3.0-or-later end-to-end (`LICENSE`,
`COPYING.GPL3`, source headers).

## Style

`.swiftformat` and `.swiftlint.yml` are authoritative for layout; run
`.build/tools/swiftformat .` to fix and `.build/tools/swiftlint lint --strict`
to check (after `scripts/ci-local.sh` has fetched them). This section is about
what a formatter cannot check.

### Zero warnings

Every Swift compiler warning fails the build: each first-party target in
`Package.swift` carries `.treatAllWarnings(as: .error)`, so `swift build` and
`swift test` stop on the first one, locally and in CI. SwiftLint runs
`--strict` for the same reason. A warning is fixed at its cause, never
suppressed: no `// swiftlint:disable`, no `@available(..., deprecated:)` added
only to quiet a call, no `-Wwarning` flag. `NoSuppressionsTests` scans for the
first.

The one exception is a warning whose right fix is out of this code's reach.
Today that is a single call: `SecKeychainCreate`, the only prompt-free,
entitlement-free way for an unsigned `swift test` runner to mint the TLS
identity the in-process satellite serves (a `SecIdentity` needs a key born in
a keychain, and macOS offers no non-deprecated keychain such a runner can
create). There the suppression sits on the smallest unit the compiler allows:
the `LegacyFileKeychain` target under `Tests/Support/`, one function, compiled
with `-suppress-warnings`, under a header comment that starts with `Marker:`
and names the fix that would retire it. The suppressed call is made nowhere
else, `PackageGraphTests` pins that it is the only such target, and a second
one needs the same justification in its header.

CI builds on the `macos-26` runner image with its default Xcode (26.x). The
tree must be warning-free there and on the newest release Xcode; a warning
only the newer compiler raises is a real finding, not noise, and is fixed the
same way.

### Shape of the code

These rules come from the Parchment library and are adapted where Swift,
SwiftUI or Combine make the literal form worse than the thing it is meant to
achieve. They apply to `Sources/` and `Tests/` alike, and they are the rules
the other Dish clients follow, so a fact ported between clients keeps its
shape.

- **As immutable and as static as possible.** `let` over `var`; a value known
  at compile time is a `static let` or a file-level `let`, never a literal in
  the middle of a function; `private` unless something outside needs it, and
  `package` only for what the app binds. A type that holds no state is a set
  of free functions or an `enum` of static functions, not a class. A `struct`
  unless identity or a lock demands a reference. SwiftLint's limits (a
  function over 60 lines or with a complexity over 15 fails the build;
  exhaustive `switch` arms do not count) are pinned by `LintConfigTests`.

- **Split values into simple, named steps.** One operation per line, with the
  result in a named `let` that says what it is, even when that reads longer:

  ```swift
  let startedStreaming = was == 0 && count > 0
  let stoppedStreaming = was > 0 && count == 0
  if startedStreaming { inhibitor.acquire(reason: reason) }
  ```

  not one five-term boolean. The names are the documentation, the debugger
  can show each value, and a test can pin each step.

- **One function, one flow.** When a function would hold two algorithms chosen
  by a condition, the condition dispatches to two named things that each do
  one thing, and the dispatcher does nothing else. An exhaustive `switch`
  over an enum with no `default` is the preferred form, because the compiler
  then checks that every case is handled: `classifyOpen` turns a session
  reply into an `OpenOutcome`, and `openSession` is one arm per case. A guard
  clause is not an algorithm: do not invent indirection where there is only
  one flow. A function that stays long because splitting it would make it
  worse says so at the top, in one or two lines.

- **A chain of `if`s over one byte is a table.** A per-bit or per-index
  mapping belongs in an array the code reads, not in a run of `if`s the
  reader has to diff against its twin: the GameController buttons are a
  table of key paths and wire buttons, read by `heldButtons` into one
  `WireButtonWord`.

- **A callback with a body gets a name.** A closure is fine as a
  one-expression forward (`{ [weak self] in self?.releaseAllInputs() }`), as
  the argument of a standard-library algorithm (`map`, `filter`, `first`), and
  as a SwiftUI view builder. A closure that carries an algorithm becomes a
  method, so it can be found, read and tested on its own, and a callback that
  is *stored* rather than called immediately prefers a method reference:

  ```swift
  processor.reportSender = sendReport
  ```

  This is Parchment's "no anonymous methods" narrowed to what Swift can
  express.

- **No singletons.** A stateless helper is a free function in the file that
  owns it. There is no `static var` and no `.shared` of our own; every
  collaborator is constructed by `AppModel`, the one composition root, and
  handed to whoever needs it, which is also what makes it replaceable in a
  test. `NSApplication.shared` and `NSWorkspace.shared` are read only in the
  app module, to build the engine's `LifecycleSignals`; `NoSuppressionsTests`
  pins both rules. A `static let` of an immutable value (a `Logger`, a table,
  a constant) is a constant, not a singleton.

- **No discarded results.** A value is either used or not produced. `_ =` is
  for a result the code deliberately ignores, and the line beside it says why
  (a best-effort socket option is the one case today).

- **Member naming.** Swift properties carry no prefix. Read-only state is
  `private(set)`; a lock-guarded backing store carries the `Box` suffix
  (`reportSenderBox`), which is the same "state, not scratch" signal
  Parchment's `m` prefix gives at the point of use.

- **Prefer a test to a comment.** Behaviour that needs explaining gets a test
  named for the behaviour. A comment is the last resort for a constraint that
  genuinely cannot be tested (a platform quirk, a wire-format byte layout, a
  lock order, a framework's threading contract), states why in one or two
  lines, and never narrates what the next line does. Exempt, because the
  constraint is untestable by construction: the pin-map headers in
  `.github/workflows/`, the usage headers in `scripts/`, and `Package.swift`,
  where a comment explains what a setting is holding back. Deferred work goes
  in [`Tests/PARITY.md`](Tests/PARITY.md) or an issue, never a `TODO`.

## Tests

| Target | Covers | Reaches |
|---|---|---|
| `Tests/DishCoreTests` | the pure core: cross-repo interop vectors (hex-exact with satellite, dish-linux, dish-android, dish-windows), every codec and reducer | `DishCore` |
| `Tests/DishKernelTests` | every kernel primitive, through the shared probes | `DishKernel` |
| `Tests/DishEngineTests` | the engine against `FakeSatellite`, an in-process satellite with independently written crypto: control plane, data plane, lifecycle, reconcile, the bridge's pure conversions; plus `IntegrationLiveSatelliteE2ETests` against the real satellite binary (`scripts/e2e_local.sh`) | `@testable import DishEngine` |
| `Tests/DishTests` | the app layer where it decides: the AppKit signal mapping, the notification queue, the UI mappers | `@testable import Dish` |
| `Tests/ArchitectureTests` | the rules of the repository, read from the tree | the file system |
| `Tests/Support/*` | the shared probes, the repository contract, and the one deprecated keychain call | regular targets the test targets depend on |

### Test-driven, every flow

- **Red first.** Write the failing test, watch it fail for the reason you
  expect, then write the code. A test that has never failed has not been
  shown to test anything; when adding a test for behaviour that already
  exists, break the behaviour on purpose and watch the test catch it. Say in
  the PR which tests failed before the change.

- **Cover every flow, not every line.** Each branch a function can take, each
  early return, each end of a clamp or a loop, and each state a machine can
  be in when the new code runs gets its own case, named for the behaviour it
  pins (`testAfterARekeyTheReplayGuardStartsOverAndTheOldMaterialIsDead`),
  not for the function it calls. If a branch has no test, either it is dead
  and goes, or it needs one.

- **Assume nothing; validate with a probe.** Where behaviour depends on a
  framework (what `GCMotion` reports, when `@Published` delivers, what
  `Bundle.module` resolves inside a `.app`), prove it with a test or a
  throwaway probe before writing the code that assumes it. Keep the test if
  it pins a dependency; delete it if it was only a probe.

- **Test where the behaviour lives.** A decision in its reducer's test, a
  byte layout in `EncodersTests`, a conversion in the bridge's pure function
  tests, a flow in the engine suites over loopback, and only what genuinely
  needs the window in the app. A test that reaches two layers down is
  testing the wrong thing.

- **Knowledge written twice is checked by a test.** When the same fact lives
  in two places (a lint threshold and `CONTRIBUTING.md`, a wire constant and
  the contract, a catalog key and a translation), a test walks one and
  requires the other.

- **Tests follow the same shape rules.** A fixture is a named type, not a
  closure that builds one; a helper with a body gets a name; a test that is
  longer than the thing it tests is usually two tests (the journeys under
  `Integration*` are named steps for that reason).

## Branching & PRs

- All changes land on `main` via pull request: no direct pushes.
- Commits and PR descriptions name no tool. No `Co-Authored-By` trailer for an
  assistant, no "Generated with …" footer: the author of record is the person
  who opened the PR, whatever helped write it.
- Use the PR template (`.github/pull_request_template.md`) to describe the
  change, the tests that failed before it, the manual test matrix you ran
  (controller types tried, pairing scenarios), and call out anything that
  touches the wire protocol. Anything user-facing adds a line under
  `## [Unreleased]` in `CHANGELOG.md`, and a row change in
  `Tests/PARITY.md` lands in the same change.
- Keep commits focused; squash noisy fixup commits before review.

> **Note on branch protection.** GitHub's branch-protection features are not
> available for this repository's plan, so direct pushes to `main` are not
> blocked at the platform level. Treat the PR-based flow as a convention and
> rely on CI as the quality gate.

## What CI runs

Build + style:

- `macos-ci.yml`, on `macos-26`: `swiftformat --lint`, `swiftlint --strict`,
  the debug build, `swift test --parallel`, the release build and
  `./bundle.sh release` (uploads `Dish.app` as an artifact). Every target
  builds with warnings as errors.
- `version-consistency.yml`: `VERSION` is the source; `CHANGELOG.md`'s top
  heading and `bundle.sh`'s plist values must agree with it.
- `e2e.yml`, on `macos-26`: checks out the satellite at the release tag the
  workflow pins (`SATELLITE_TAG`), builds it from source and runs
  `scripts/e2e_local.sh`, the same loopback end-to-end a developer runs:
  pairing (the typed PIN, and the operator's approval and decline answered
  on the satellite's admin API), the TOFU pin, the session PUT, encrypted
  UDP both ways, the graceful close and the self-unpair against the real
  binary. The runner is
  unentitled, so the slot applies as `backendUnavailable` and the driver
  asserts that honest path.

Security gates (also blocking):

- `security.yml`: action-pin lint, vulnerability allowlist expiry,
  OSV-Scanner, gitleaks secret scan, GitHub `dependency-review-action`.
- `codeql.yml`: CodeQL `swift` analysis (security-extended +
  security-and-quality query packs).

If any step fails, the PR is blocked. `scripts/ci-local.sh` runs the build and
style gates locally in the same order.

## Security

### Adding a vulnerability allowlist entry

Open a PR that adds an entry to [`.security/allowlist.yaml`](.security/allowlist.yaml)
(see the schema in the file). Required fields: `cve`, `reason`, `owner`,
`expires`. CI rejects the PR if any field is missing or `expires` is in the
past. Renew or remove on or before `expires`.

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

Each GitHub Release ships `dish-X.Y.Z.zip` (signed and notarized when the
Apple secrets exist, `dish-X.Y.Z-unsigned.zip` until they do) and its
stable-name copy `dish-mac.zip`, `*.sig`/`*.crt` (cosign keyless),
`SHA256SUMS` + `SHA256SUMS.sig`/`*.crt`, the SPDX + CycloneDX SBOMs, and
`dish-mac.intoto.jsonl` (SLSA L3).

```bash
shasum -a 256 -c SHA256SUMS

cosign verify-blob \
  --certificate SHA256SUMS.crt \
  --signature   SHA256SUMS.sig \
  --certificate-identity-regexp '^https://github\.com/TinkerNorth/dish-mac/\.github/workflows/release\.yml@refs/tags/[0-9].*$' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  SHA256SUMS

slsa-verifier verify-artifact \
  --provenance-path dish-mac.intoto.jsonl \
  --source-uri      github.com/TinkerNorth/dish-mac \
  --source-tag      X.Y.Z \
  dish-X.Y.Z.zip
```

The full cross-repo verification recipe lives in [`SECURITY.md`](SECURITY.md).

## Cutting a release

`release.yml` runs on a bare `MAJOR.MINOR.PATCH` tag (no `v` prefix, e.g.
`1.2.3`) or a `workflow_dispatch` with a tag input. It re-runs the security
gates against the tagged commit, asserts the tag equals `VERSION`, builds
Release, signs and notarizes `Dish.app` when the five Apple secrets are
present, scans and signs every artifact, emits the SBOMs and the SLSA
provenance, and publishes the GitHub Release. The signing gate is advisory,
as the satellite's and the Windows client's are: without the secrets a stable
tag still ships, unsigned, with a warning in the run and a note at the top of
the release; the versioned zip then carries `-unsigned` while `dish-mac.zip`
keeps its name, because `latest.json` and the website read it by name. Set
the repository variable `ENFORCE_RELEASE_SIGNING=true` to make missing
secrets fail a stable tag again. Adding the secrets turns signing on with no
change to the workflow.

Before you tag:

- **Bump `VERSION`** in a pull request of its own ("Bump the version to X.Y.Z
  and date the changelog"), turning `## [Unreleased]` into
  `## [X.Y.Z] - YYYY-MM-DD` and updating the compare link.
  `version-consistency.yml` fails a PR that moves one without the other.
- **Update `PRIVACY.md` first** if anything about data collection changed.
- **Keep `packaging/Dish.entitlements` honest.** The release signature carries
  it under the hardened runtime; a new restricted capability (camera, location,
  automation) needs its entitlement there or the signed build is denied it.

After the workflow finishes, download `dish-mac.zip`, check it against
`SHA256SUMS`, run `spctl --assess --type execute Dish.app` (it passes only for
a signed and notarized build; an unsigned one is opened through System
Settings › Privacy & Security › Open Anyway), launch it and pair once. The
asset names `dish-X.Y.Z.zip`, `dish-mac.zip` and `SHA256SUMS` are a permanent
API.

## Touching the hot path

The GameController `valueChangedHandler` thread runs at controller polling
rate and must never block. If you're modifying `GameControllerInput`,
`GamepadInputProcessor`, `InputRouting` or `SatelliteClient.sendReport`:

- No `Task`, no `await`, no main-actor hop on the send path.
- No Combine on the per-event chain; direct calls only.
- One locked read of the routing table and the client's own send lock are the
  only locks allowed; hold each briefly.
- Preserve `IP_TOS = 0xB8` (DSCP EF) and `SO_NOSIGPIPE` on every send.
- Where a shape rule and the hot path disagree, the hot path wins and the
  reason goes in a test name, not a comment.

## Touching the wire protocol

The macOS, Android, Windows and Linux clients all talk to the same `satellite`
server and must produce byte-identical traffic. The contract is specified in
ONE place, `satellite/docs/contract.md`; this repo's
[`docs/contract.md`](docs/contract.md) maps each concept to the Swift file
implementing it. Never restate contract facts in code comments; link them.

Ground rules when changing anything wire-adjacent:

- All protocol logic that can be pure lives in `DishCore`. Wire bytes are
  pinned by the cross-repo interop vectors in
  `Tests/DishCoreTests/SessionCryptoVectorTests.swift`, the same hex as the
  satellite, dish-linux, dish-android and dish-windows suites. If a vector
  test fails, you broke the protocol, not the test.
- AEAD: ChaCha20-Poly1305 IETF under the per-session HKDF key; nonce =
  `dir(1) | 0x00×7 | counter(4 BE)`; AAD = token; counters start at 1 per
  direction and never wrap.
- Topology is REST-only (declarative `PUT /api/connections` on `:9443`). The
  deleted protocol-0 topology opcodes must stay deleted; a stray reference
  should fail to compile.
- Any change here is `[wire-coordinated]` in `CHANGELOG.md` and lands with
  `dish-android`, `dish-linux`, `dish-windows` and `satellite` in the same
  release cycle, vectors updated in lockstep on every end.

## Reporting bugs

Use the issue templates under `.github/ISSUE_TEMPLATE/`. Include the macOS
version, Mac model, controller make/model, and the relevant `Console.app`
excerpt around the misbehavior.
