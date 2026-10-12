# Third-party notices

Dish for macOS is licensed [LGPL-3.0-or-later](LICENSE). This file lists every
third-party component that is linked into `Dish.app`, embedded in it as a
resource, or used only to build and test it, and states what someone
redistributing the binary has to do.

The app has no third-party code in it. `Package.swift` declares no package
dependencies, so the binary links only Apple's system frameworks, and the
in-process test satellite under `Tests/DishEngineTests/Support/FakeSatellite/`
is first-party code with its own independently written crypto.

---

## 1. Summary

| Component | Version | SPDX | How it reaches the user | Attribution obligation |
|---|---|---|---|---|
| Apple system frameworks (Foundation, Combine, SwiftUI, AppKit, Network, Security, CryptoKit, GameController, CoreHaptics, IOKit, os) | the macOS the app runs on | Apple SDK license | Dynamically linked against the user's macOS. Nothing is bundled. | None for redistributors of the app |
| [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) | 0.61.1 | `MIT` | Build and CI only, as a pinned release binary. Not in the app. | None for redistributors of the app |
| [SwiftLint](https://github.com/realm/SwiftLint) | 0.65.0 | `MIT` | Build and CI only, as a pinned release binary. Not in the app. | None for redistributors of the app |

Everything under `Resources/` and `Sources/Dish/UI/BrandIcon.swift` is original
TinkerNorth artwork, covered by this repository's own license.

## 2. Reused facts, not reused code

Two sets of published facts are implemented here from their documentation,
not copied as code:

- **The XUSB (XInput) gamepad report layout and button bits**, from Microsoft's
  XInput documentation: the 12-byte report `MSG_INPUT` carries and the
  `XINPUT_GAMEPAD_*` button constants in `GamepadInputProcessor.Buttons`.
- **The wire protocol** itself, specified in the TinkerNorth satellite
  repository's `docs/contract.md` and shared by every Dish client: byte
  layouts, the HKDF and HMAC constructions, the AEAD nonce rule and the REST
  surface. The interop vectors in `Tests/DishCoreTests/SessionCryptoVectorTests.swift`
  are the same hex every sibling pins.

## 3. Keeping this in sync

`Package.swift`'s `dependencies` list is the source of truth for linked code.
A pull request that adds a package dependency also adds a row to the summary
above, commits `Package.resolved` (currently ignored because there is nothing
to resolve), and extends `.gitleaks.toml` and the SBOM expectations in
`release.yml` if the component needs it. `scripts/ci-local.sh` and
`.github/workflows/macos-ci.yml` carry the pinned tool versions above; a tool
bump updates both and this table in one commit.

## 4. Reporting an attribution problem

Open an issue, or for anything that may need to stay private, use the
security contact in [`SECURITY.md`](SECURITY.md).
