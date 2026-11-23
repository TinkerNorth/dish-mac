# Security policy — TinkerNorth

This file covers the six TinkerNorth repositories that ship the
wireless-gamepad product end-to-end, and the website that publishes it:

- [`satellite`](https://github.com/TinkerNorth/satellite) — Satellite, the server (Windows / Linux / macOS)
- [`dish-android`](https://github.com/TinkerNorth/dish-android) — Dish for Android
- [`dish-ios`](https://github.com/TinkerNorth/dish-ios) — Dish for iOS (SwiftUI)
- [`dish-mac`](https://github.com/TinkerNorth/dish-mac) — Dish for macOS (SwiftUI)
- [`dish-windows`](https://github.com/TinkerNorth/dish-windows) — Dish for Windows (Qt6 / SDL2)
- [`dish-linux`](https://github.com/TinkerNorth/dish-linux) — Dish for Linux (Qt6 / SDL2)
- [`dish-website`](https://github.com/TinkerNorth/dish-website) — <https://dish.tinkernorth.com>

Each repo has its own `CONTRIBUTING.md#security` section with
ecosystem-specific local commands; this file is the single source of
truth for **(1) reporting a vulnerability**, **(2) what we do with the
report**, and **(3) how a downstream consumer verifies a release
artifact**.

---

## Reporting a vulnerability

**Do not file a public issue for a suspected vulnerability.**

Use one of:

1. **GitHub private vulnerability reporting** — open the repo, click
   *Security → Report a vulnerability*. This is preferred because it
   creates a tracked advisory and a private discussion thread.
2. **Email** — `security@tinkernorth.com` (PGP key on request).
   Include the repo, version (commit SHA or release tag), reproduction
   steps, and impact.

Please do **not** test exploits against infrastructure you don't own.
The on-LAN threat model already covers an attacker with packet-injection
ability on the local network — that's the documented design boundary,
not a bug.

### Response SLA

| Severity | Triage acknowledgement | Initial assessment | Fix target |
|---|---|---|---|
| Critical (CVSS >= 9.0) | 1 business day | 3 business days | 14 days, coordinated disclosure |
| High (CVSS 7.0–8.9)    | 2 business days | 5 business days | 30 days |
| Medium / Low           | 5 business days | 10 business days | next minor release |

If we miss the SLA, you may publish 90 days after the original report
date regardless. We'd rather know than not know.

### Scope

In scope:

- All the repos above.
- Release artifacts attached to GitHub Releases for any of the repos above.
- The wire protocol (protocol 4, which every client here offers — the single source of truth is
  [`satellite/docs/contract.md`](https://github.com/TinkerNorth/satellite/blob/main/docs/contract.md)):
  the HTTPS `:9443` control plane (TOFU-pinned self-signed TLS, HMAC
  proof-of-key headers, declarative session PUT) and the UDP `:9876` data
  plane (ChaCha20-Poly1305-IETF under per-session HKDF keys, per-direction
  counters, replay guard).
- The pairing flow (PIN paths A/B on `:9443`) + the loopback-only admin
  HTTP/SSE web UI exposed by `satellite`.

Out of scope:

- Anything that requires the attacker to already have local privileges
  on the user's PC (root, Administrator, ability to drop binaries in
  `%APPDATA%`, etc.).
- The vendored ViGEmBus driver itself — file with [nefarius/ViGEmBus](https://github.com/nefarius/ViGEmBus).
- DoS via raw network flooding — UDP without rate-limit is a known
  trade-off for hot-path latency; mitigations belong in the network
  fabric, not the protocol.

---

## Supported versions

| Repo | Supported | Notes |
|---|---|---|
| `satellite` | latest minor on `main`; previous minor for 90 days | Windows is the canonical target; Linux is supported; macOS virtual pads require the virtual-HID entitlement (unentitled builds fall back to an inert backend) |
| `dish-android` | latest minor on `main`; previous minor for 90 days | minSdk 24 |
| `dish-ios` | latest minor on `main`; previous minor for 90 days | iOS 26+ |
| `dish-windows` | latest minor on `main`; previous minor for 90 days | 64-bit Windows 10 (1809 or newer) and Windows 11 |
| `dish-linux` | latest minor on `main`; previous minor for 90 days | tracks the oldest LTS the release CI builds against |
| `dish-mac` | latest minor on `main`; previous minor for 90 days | macOS 13+ |

Patch releases (`X.Y.Z+1`) are issued on demand for the latest minor;
the previous minor only receives backports for high/critical fixes.

---

## How CI prevents vulnerable code from shipping

Each repo runs the same shape of gates:

**On every PR** (blocking):

- Action-pin lint — every `uses:` line must reference a 40-char SHA.
- Allowlist expiry — `.security/allowlist.yaml` entries must be unexpired.
- Dependency review — GitHub advisory DB (PR-only; it runs once the
  repository's Dependency graph setting is on).
- OSV-Scanner — vendored components + manifest deps; ecosystem-specific
  scope (see each repo's `security.yml`).
- Gitleaks — secret scanning over the worktree.
- CodeQL — `cpp` for `satellite` / `dish-linux`, `swift` for `dish-mac` and `dish-ios`,
  `java-kotlin` + `cpp` for `dish-android`.

**On every tagged release** (also blocking):

- Re-run of every PR-time gate against the tagged commit.
- Required-secrets gate — advisory by default. With the platform signing
  secrets (Windows Authenticode, Apple Developer ID + notarization,
  Android keystore) the artifact is signed; without them a stable tag
  still ships `-unsigned` with a warning, unless the repository variable
  `ENFORCE_RELEASE_SIGNING` is `true`, which fails the tag instead. Dish
  for macOS has no Developer ID yet and ships unsigned that way, ad-hoc
  signed, with Gatekeeper's Open Anyway steps in the release notes.
- Artifact-level vulnerability scan — Anchore Grype (a pinned binary), fails
  on CRITICAL/HIGH.
- SBOM generation — Syft (a pinned binary), both SPDX-JSON and
  CycloneDX-JSON.
- `SHA256SUMS` over every artifact and the SBOMs.
- Cosign keyless signing — every file and `SHA256SUMS` get a
  `<file>.sigstore.json` bundle, anchored in the Sigstore transparency log.
  The same steps run on every pull request as a dry run with a throwaway key.
- SLSA L3 build provenance — `slsa-framework/slsa-github-generator`
  emits `<repo>.intoto.jsonl`.

The result: a known-vulnerable dep, a missing signature, or a tampered
binary all fail the release before any artifact lands on the GitHub
Release page.

---

## Verifying a release artifact (consumer recipe)

This recipe works the same way for every release, every repo, every
platform; only the artifact filenames change. Releases cut after the shared
release-hardening workflow landed carry one Sigstore bundle per file
(`<file>.sigstore.json`); earlier releases (dish-mac up to 1.4.0) carry a
`.sig` and a `.crt` per file and are verified the second way below. The tag is
bare `X.Y.Z` in every command.

### 0) Pre-requisites

```bash
# cosign 3.x: brew install cosign, or a release binary from
# github.com/sigstore/cosign/releases (check it against cosign_checksums.txt)
```

### 1) Download every file from the Release

```bash
TAG=X.Y.Z
REPO=<repo>     # satellite, dish-android, dish-ios, dish-mac, dish-windows, dish-linux
gh release download "$TAG" -R "TinkerNorth/$REPO" -D "$REPO-$TAG"
cd "$REPO-$TAG"
```

You should see the platform artifacts, `SHA256SUMS` with its signature,
`<product>.sbom.spdx.json` and `<product>.sbom.cdx.json`, and
`<product>.intoto.jsonl` (the SLSA L3 provenance).

### 2) Releases after the shared workflow: one bundle per file

```bash
# SHA256SUMS was signed by this repository's release workflow, on this tag.
cosign verify-blob \
  --bundle SHA256SUMS.sigstore.json \
  --certificate-identity "https://github.com/TinkerNorth/$REPO/.github/workflows/_release_harden.yml@refs/tags/$TAG" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  SHA256SUMS

# Every file you downloaded matches it (macOS: shasum -a 256 -c).
sha256sum --ignore-missing -c SHA256SUMS
```

The identity is exact, not a regular expression, and names
`_release_harden.yml` because the certificate's identity is the workflow that
ran the signing step. To verify one file on its own, run the same
`cosign verify-blob` with `--bundle <file>.sigstore.json` and `<file>`.

### 3) Releases up to dish-mac 1.4.0: `.sig` and `.crt`

These were signed by `release.yml` itself. cosign 3 still verifies them with
the deprecated flags (it prints two deprecation lines):

```bash
cosign verify-blob \
  --certificate SHA256SUMS.crt --signature SHA256SUMS.sig \
  --certificate-identity "https://github.com/TinkerNorth/$REPO/.github/workflows/release.yml@refs/tags/$TAG" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  SHA256SUMS
shasum -a 256 -c SHA256SUMS
```

(Run against dish-mac 1.4.0 with cosign 3.1.4: `Verified OK`, every file `OK`.
Other repositories' earlier releases name `release.yml` or `_release_harden.yml`
in the identity; read the workflow out of the certificate.)

### 4) The SLSA L3 provenance

`<product>.intoto.jsonl` is a Sigstore bundle whose statement names every
released file by SHA-256. It is signed by the SLSA generator at the exact
commit the workflow pins, which `slsa-verifier` refuses ("invalid ref") because
that is not a release tag, so verify it with cosign, naming the generator's
commit from the provenance's `builder.id`:

```bash
cosign verify-blob-attestation \
  --bundle "dish-mac.intoto.jsonl" --new-bundle-format --type slsaprovenance \
  --certificate-identity "https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml@f7dd8c54c2067bafc12ca7a55595d5ee9b75204a" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  dish-mac.zip
```

(`Verified OK` against dish-mac 1.4.0. The commit is the generator v2.1.0 the
workflow pins; use the one in the provenance you are checking.)

### 5) (Optional) Inspect the SBOM

```bash
jq -S . dish-mac.sbom.spdx.json | less
```

---

## Known gaps

- **Branch protection on `main`.** The repos run on a
  free org plan that does not expose required-status-check enforcement
  for private repositories. Direct pushes to `main` are blocked by
  convention only; the per-repo CI workflows are the de-facto gate.
  See the matching `README.md` in each repo for the full text.
- **Vendored-header scanners.** `satellite/lib/` and
  `satellite/vigem/include/` are not understood by ecosystem scanners.
  We feed OSV-Scanner a synthetic `osv-scanner.toml` derived from
  [`lib/VENDORED.md` in TinkerNorth/satellite](https://github.com/TinkerNorth/satellite/blob/main/lib/VENDORED.md), and the
  `vendored-freshness` CI job fails if any `Last-vendored:` date is
  more than 90 days old. This is best-effort, not exhaustive — file an
  advisory if you spot a vendored component that's missing from
  `VENDORED.md`.
- **macOS virtual pads are entitlement-gated.** The macOS satellite
  backend synthesizes virtual DualShock 4 controllers via
  `IOHIDUserDevice`, which requires the
  `com.apple.developer.hid.virtual.device` entitlement. Production
  (signed) builds carry it; CI artifacts and local unentitled builds
  detect the missing entitlement at runtime and fall back to the
  historical inert backend: the protocol stack runs, but every
  controller descriptor applies as `backendUnavailable`. The CI
  artifact name (`satellite-macos-stub-...`) reflects that fallback.
  Don't open a vulnerability report for the absence of virtual-gamepad
  creation in an unentitled build — it's the documented, probe-enforced
  fallback.
