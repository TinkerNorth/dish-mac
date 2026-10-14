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
| [sentry-cocoa](https://github.com/getsentry/sentry-cocoa) | 9.30.1 | `MIT` | Compiled into the app from the pinned Swift package; armed only by an official release build (the one kind that carries a reporting address) with *Share crash reports* on. See [`PRIVACY.md`](PRIVACY.md), section 3. | Keep the copyright and permission notice below |

Everything under `Resources/` and `Sources/Dish/UI/BrandIcon.swift` is original
TinkerNorth artwork, covered by this repository's own license.

## 2. Reused facts, not reused code

Three sets of published facts are implemented here from their documentation,
not copied as code:

- **The XUSB (XInput) gamepad report layout and button bits**, from Microsoft's
  XInput documentation: the 12-byte report `MSG_INPUT` carries and the
  `XINPUT_GAMEPAD_*` button constants in `GamepadInputProcessor.Buttons`.
- **The wire protocol** itself, specified in the TinkerNorth satellite
  repository's `docs/contract.md` and shared by every Dish client: byte
  layouts, the HKDF and HMAC constructions, the AEAD nonce rule and the REST
  surface. The interop vectors in `Tests/DishCoreTests/SessionCryptoVectorTests.swift`
  are the same hex every sibling pins.
- **The Moonlight (GameStream) host protocol**, under `Sources/DishCore/Moonlight/`,
  learned from the documentation and the MIT-licensed host implementation of
  Wolf (games-on-whales/wolf): the control-packet AES-GCM construction and its
  IV rule, the CONTROLLER_* and mouse wire layouts, the host event bodies and
  the media ping. Section 2b records that reuse of adapted logic. The byte-exact
  fixtures under `Tests/DishCoreTests/Moonlight/` are Wolf's published vectors
  and captures, the same hex dish-android, dish-linux and dish-windows pin. No
  GPL-licensed Moonlight code (moonlight-common-c, moonlight-qt,
  moonlight-android, Sunshine, Apollo) was consulted or copied.

## 2a. sentry-cocoa

sentry-cocoa 9.30.1. SPDX `MIT`. Upstream:
<https://github.com/getsentry/sentry-cocoa>.

The crash reporter behind the *Share crash reports* switch, pinned exactly in
`Package.swift` and reached only through the `DishCrashUpload` module, so
the engine never imports it. A build arms it only with an address in its
`Info.plist`, which only `release.yml` supplies.

```
Copyright (c) 2015 Sentry (https://sentry.io) and individual contributors.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## 2b. Wolf (Moonlight protocol reference)

Wolf, SPDX `MIT`. Upstream: <https://github.com/games-on-whales/wolf>.

**No Wolf source is compiled into Dish.** Wolf is an MIT-licensed Moonlight
*host*; its protocol documentation (`control-specs.adoc`, `input-data.adoc`,
`http-pairing.adoc`) and source (`control.hpp`) were the reference for this
project's own Moonlight *client* implementation under
`Sources/DishCore/Moonlight/`. Adapted logic includes the control-packet
AES-GCM IV construction (the low byte of the sequence alone), the encrypted
frame layout with its tag before the ciphertext, the CONTROLLER_* and mouse
struct layouts and the host event bodies. These were re-implemented against
Dish's own architecture; the byte-exact test fixtures are Wolf's published
vectors and captures.

```
Copyright (c) 2021-2024 Games on Whales

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Deliberately NOT consulted, to keep this LGPL-3.0 project clear of GPL-3.0
Moonlight code: moonlight-common-c, moonlight-qt, moonlight-android, Sunshine,
Apollo. Wolf's documentation and MIT source were sufficient.

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
