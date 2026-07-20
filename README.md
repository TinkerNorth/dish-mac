# Dish Mac

Native macOS client for the Satellite wireless-gamepad server. Mirrors the
functionality of the Dish Android and Linux clients: LAN discovery (mDNS +
legacy beacon), PIN pairing over TOFU-pinned TLS, declarative REST topology,
encrypted UDP input streaming (ChaCha20-Poly1305 under per-session HKDF
keys), heartbeats, and multiple parallel server sessions. Speaks
**protocol 1** — see [Protocol](#protocol).

## Architecture

```
SwiftUI (MainView, ConnectionsView)
  └── AppModel (ObservableObject)
        ├── ConnectionHub      ── aggregates live + remembered sessions
        ├── WifiConnectionManager
        │     └── WifiConnection (per-server)
        │           └── SatelliteClient  ── encrypted UDP data plane on :9876
        ├── MdnsBrowser        ── mDNS/Bonjour `_satellite._udp` discovery
        ├── LANDiscovery       ── legacy UDP beacon listener on :9879 (fallback)
        ├── PairingClient      ── HTTPS POST /api/pair + path-B status poll on :9443
        ├── HTTPClient         ── declarative PUT/GET/DELETE /api/connections on :9443
        │     └── TofuTrustDelegate ── TOFU cert pinning on both HTTPS gateways
        └── GameControllerInput ── GameController.framework push callbacks
              └── GamepadInputProcessor → SatelliteClient.sendReport()

DishCore (SwiftPM library target; Foundation + CryptoKit ONLY —
          the import allowlist is pinned by CorePurityTests)
  ── the pure protocol core: wire codecs, session crypto
     (HKDF/AEAD/proof), protocol constants, policy reducers
     (reconcile, backoff, close-notify, TOFU verdicts, latency window).
```

## Low-latency strategies (mirrored from Android)

- **Direct `sendto()` from the input callback thread.** The GameController
  `valueChangedHandler` fires on every button/axis change and invokes the
  native socket send inline — no queue, no Combine, no async hop. Same pattern
  as `Kotlin → JNI → sendto` on Android.
- **Raw POSIX UDP socket** (not `NWConnection`) so we can set `IP_TOS = 0xB8`
  (DSCP EF class, expedited forwarding) and bypass Network.framework's
  internal queueing.
- **CryptoKit.ChaChaPoly** produces the exact same AEAD bytes as libsodium's
  `crypto_aead_chacha20poly1305_ietf` used by the Android JNI and the
  Satellite server — same nonce/AAD construction, same HKDF-derived
  per-session key, pinned byte-for-byte by the cross-repo interop vectors in
  `Tests/DishCoreTests/SessionCryptoVectorTests.swift`.
- **Per-session heartbeat timer + receive loop** on dedicated dispatch queues
  so the hot input path is never contended by book-keeping traffic.
- **`SO_NOSIGPIPE`** on every socket so a server disconnect can't kill the
  process.

## Cross-platform behaviour parity

The following behaviours mirror dish-android and dish-linux, so user-visible
behaviour stays predictable across platforms:

- **Display-sleep inhibitor while streaming.** A `ScreenWakeController` reads
  `hub.bindings × hub.connections`, derives a streaming-slot count, and flips
  an `IOPMAssertion` of type `kIOPMAssertionTypePreventUserIdleDisplaySleep`
  on every 0↔positive transition. The assertion is released automatically on
  the last unbind / disconnect, so a forgotten session doesn't pin the
  display awake forever.
- **Connection state recovery.** `PairingClient` carries a `reachable` flag
  on every response (true iff we got a JSON body back). The manager classifies
  the outcome into `success | authRequired | unreachable` and routes
  accordingly — a moved/offline server now surfaces a clean
  *"Server unreachable — has it moved networks?"* error instead of trapping
  the user behind an unanswerable PIN prompt. Mirrors dish-android PR #43.
- **Auto-reconnect fast path.** `WifiConnectionManager.pairAndConnect` skips
  the pair handshake entirely when a 64-char shared key is already stored,
  going straight to `openSession`'s declarative PUT. A moved server then
  fails fast in the HTTP layer rather than bouncing through pair →
  `PairingRequired`.
- **Per-device deadzones.** `GamepadInputProcessor` carries a per-device
  `Deadzones { stickFlat, triggerFlat }` table; reports are filtered
  (`|v| <= flat → 0`) before they leave the processor. The default profile
  (~10 % stick / ~5 % trigger) is installed by `GameControllerInput` when each
  controller attaches; macOS 14+ can later override per-device by reading
  `GCAxisInput.deadband`. Mirrors Android's per-device `flat` pipeline.
- **Device-capability log on attach.** Every newly-connected controller logs
  a one-shot `DEVCAPS` line via `os_log` carrying the stable id, vendor
  name, product category, and which optional inputs are present. Aimed at
  users reporting *"my pad doesn't work"* — same idea as Android's
  SatelliteJNI `DEVCAPS` log.

## Rumble (return path)

Rumble flows the opposite direction to the input hot path. A game on the
satellite host writes to the virtual controller's vibration channel, the
satellite forwards a `MSG_RUMBLE = 0x0009` packet back over the encrypted
UDP socket, and the dish actuates the matching `GCController` via
GameController.framework's haptics surface.

```
  ┌──────────────────────┐      ┌──────────────────────┐      ┌──────────────────────┐
  │ SatelliteClient      │ ───► │ WifiConnection       │ ───► │ GameControllerInput  │
  │  • receive loop +    │      │  • per-conn handler  │      │    .applyRumble(...) │
  │    AEAD open         │      │    (installed by     │      │      └─► RumbleActua-│
  │  • RumbleCommand.parse│     │     AppModel from    │      │           tor.apply  │
  │  • dispatch to onRumble│    │     wifi.$connections│      │           (per ctrl) │
  └──────────────────────┘      └──────────────────────┘      └──────────┬───────────┘
                                                                         │
                                                                         ▼
                                                          GCController.haptics +
                                                          CHHapticEngine per locator
                                                          (.leftHandle / .rightHandle)
```

The `MSG_RUMBLE` inner payload is a fixed 7 bytes — `ctrlIdx(1) +
strongMagnitude(2 BE) + weakMagnitude(2 BE) + durationMs(2 BE)`. On the
dish-mac side:

* **Parser** — `DishCore.RumbleCommand.parse` is a pure decoder so unit
  tests can pin byte layouts without a live socket
  (`Tests/DishCoreTests/EncodersTests.swift`); the receive pipeline around
  it — header parse, replay guard, AEAD open, dispatch — is driven with
  satellite-sealed datagrams in
  `Tests/DishTests/SatelliteClientRumbleTests.swift`.
* **Routing** — `AppModel.installRumbleHandlers` runs on every
  `wifi.$connections` change and attaches a handler that resolves
  `connId → slotId → deviceId` via the `ConnectionHub` bindings, then
  calls `GameControllerInput.applyRumble`.
* **Actuation** — `RumbleActuator` keeps two `CHHapticEngine` instances
  per controller (one for `.leftHandle`, one for `.rightHandle`). Each
  rumble packet builds a tiny `CHHapticPattern` with intensity scaled
  from 0..65535 to CoreHaptics's 0..1, and a fresh per-call player so we
  don't pay engine start-up latency per packet.
* **No haptics → silent no-op.** MFi pads that don't expose
  `controller.haptics` skip actuation entirely; the player just doesn't
  feel rumble — same outcome as if the satellite never sent the packet.

## Light bar (return path)

The light bar is its own return path, separate from rumble. A game on the
satellite host sets the virtual controller's LED colour, the satellite
forwards a `MSG_LIGHTBAR = 0x000D` packet, and the dish writes the colour to
the matching `GCController.light` via GameController.framework.

The `MSG_LIGHTBAR` inner payload is 4 bytes — `ctrlIdx(1) + R(1) + G(1) +
B(1)` — decoded by `DishCore.LightbarCommand.parse` (a pure decoder,
unit-tested without a live socket). It routes through the same
`SatelliteClient → WifiConnection → AppModel` chain as rumble, ending at
`GameControllerInput.applyLightbar`, which sets `GCColor` on the
`@MainActor`.

* **Separate from rumble.** `RumbleActuator` never touches
  `controller.light`. Vibration and the light bar are gated and routed
  independently, so turning Rumble off in Settings does not affect the
  light bar (and vice versa).
* **`CAP_LIGHTBAR` (0x0008).** When a bound controller exposes an
  addressable RGB light (`GCController.light != nil`), the dish OR's
  `CAP_LIGHTBAR` into the controller descriptor's capability word
  (alongside `CAP_ANALOG_TRIGGERS` / `CAP_RUMBLE` / `CAP_MOTION`) — the
  descriptor rides the declarative session/controller PUT; topology never
  rides UDP in protocol 1.
* **`LightbarMode` setting.** `FeatureSettings.lightbarMode` is a
  two-case picker in Settings — *Follow game* (apply the host game's
  colour) or *Off* (leave the LED untouched). Unlike the other features
  it is a mode, not a plain toggle, mirroring DS4Windows / DualSenseX;
  it collapses to a single `lightbar` boolean in the thread-safe
  `ForwardingFlags` snapshot the receive-thread handlers read. *Off*
  suppresses the `MSG_LIGHTBAR` colour.
* **No light → silent no-op.** Controllers without a light bar (Xbox
  pads) ignore `MSG_LIGHTBAR`; `applyLightbar` resolves `controller.light`
  to `nil` and returns.

## Requirements

- macOS 13 (Ventura) or newer
- Swift 5.9+ toolchain (ships with Xcode 15 / Command Line Tools)
- A compatible gamepad (Xbox, PlayStation, or any MFi controller)
- A Satellite server reachable on your LAN

## Build & Run

```bash
cd dish-mac
swift build
swift run Dish
```

For a release build:
```bash
swift build -c release
./.build/release/Dish
```

## Project Layout

```
dish-mac/
├── Package.swift
├── Sources/DishCore/            # pure protocol core (Foundation + CryptoKit only)
│   ├── ProtocolConstants.swift  # protocol-1 opcodes, caps, sizes, cadences
│   ├── Wire/                    # SessionCrypto (HKDF/AEAD/proof), PacketCodec, Encoders
│   └── Reducers/                # reconcile, backoff, close-notify, TOFU, latency, REST outcomes
├── Sources/Dish/
│   ├── DishApp.swift            # @main SwiftUI entry
│   ├── AppModel.swift           # top-level ObservableObject
│   ├── Models/                  # DiscoveredServer, FeatureSettings, ...
│   ├── Network/                 # sockets, discovery, pairing, REST, TOFU, stores
│   ├── Input/                   # GameController bridge + XUSB mapping
│   ├── Util/                    # telemetry, hex
│   └── UI/                      # SwiftUI views + theme
├── Tests/DishCoreTests/         # pinned interop vectors + pure-reducer suites
├── Tests/DishTests/             # app-target unit + integration suites
│   └── Support/FakeSatellite/   # in-process protocol-1 satellite for tests
├── docs/contract.md             # contract pointer + concept→file mapping
└── scripts/e2e_local.sh         # loopback e2e against the real satellite binary
```

## Protocol

This client speaks **protocol 1**. The client ↔ server contract — REST
surface, UDP streams, crypto, liveness, identity — is specified in ONE
place: [`satellite/docs/contract.md`][contract] in the TinkerNorth/satellite
repo. Nothing in this README restates it; when in doubt, the contract wins.
[`docs/contract.md`](docs/contract.md) in this repo maps each contract
concept to the Swift file that implements it.

The shape, in two lines:

- **Control plane** — HTTPS REST on `:9443` (self-signed TLS, trust is
  TOFU cert-pinning). PIN pairing mints a per-device 32-byte pairing key;
  every authenticated route carries `X-Device-Id` + `X-Hmac-Proof`;
  topology is **declarative** — the client PUTs its complete desired
  controller set to `/api/connections` and the server converges.
- **Data plane** — UDP on `:9876`, ChaCha20-Poly1305-IETF under a
  per-session key: `HKDF-SHA256(pairingKey, sessionSalt, token)`, salt and
  token minted per session PUT. Streams only (input/heartbeat/motion/
  battery/touchpad up; heartbeat-ack/rumble/lightbar/close-notify down) —
  topology never rides UDP.

Discovery is mDNS `_satellite._udp` (primary) plus the legacy UDP `:9879`
beacon (fallback). The wire bytes are identical across dish-android,
dish-linux, dish-windows and dish-mac; the shared interop vectors in
`Tests/DishCoreTests/SessionCryptoVectorTests.swift` are pinned hex-exact
against the sibling repos' test suites, so any drift fails all of them.

[contract]: https://github.com/TinkerNorth/satellite/blob/main/docs/contract.md

## Testing

```bash
swift test
```

Three layers, all in the one SwiftPM test run:

- **`Tests/DishCoreTests`** — the pure core: cross-repo pinned interop
  vectors (HKDF / HMAC proof / AEAD — hex-exact with satellite, dish-linux,
  dish-android and dish-windows) and exhaustive reducer suites (reconcile,
  backoff, close-notify, TOFU verdicts, latency window, REST outcomes).
  No sockets, milliseconds.
- **`Tests/DishTests` unit suites** — hex/byte-packing, XUSB input mapping
  (axis/trigger scaling, button bitfield, per-device deadzones,
  zero-on-disconnect fan-out), the atomic counter under contention, beacon
  and REST DTO decoding, persisted-model round-trips, the rumble/light-bar
  return-path pipeline against satellite-sealed datagrams, pairing outcome
  classification, and the `ScreenWakeController` lifecycle via a fake
  `DisplaySleepInhibitor`.
- **`Tests/DishTests` live suites** — `Support/FakeSatellite/` is an
  in-process protocol-1 satellite (HTTPS pairing + session REST, encrypted
  UDP with replay guard, enriched acks, close-notify/rumble/lightbar
  injection, its own independently-implemented CryptoKit crypto asserted
  against the same pinned vectors). The control-plane, data-plane and
  `Integration*` end-to-end suites drive the real manager/connection/client
  stack against it over loopback sockets, synchronized by bounded waiters —
  no sleeps, but expect the full run to take seconds, not milliseconds.

For an end-to-end check against the **real** satellite server binary (build
headless, pair, stream, tear down over loopback), see
[`scripts/e2e_local.sh`](scripts/e2e_local.sh).

## Development

Install the tooling once:
```bash
brew install swiftlint swiftformat
```

Wire up the pre-commit hook (runs format + lint on staged Swift files):
```bash
./scripts/setup-hooks.sh
```

Format / lint manually:
```bash
swiftformat Sources Tests
swiftlint lint --strict Sources Tests
```

## Contributing

Changes should land on `main` through a pull request. The `macOS CI`
workflow (`.github/workflows/macos-ci.yml`) runs `swift build`, `swift test`,
`swiftformat --lint`, and `swiftlint --strict` on every PR and on `main`
pushes. The `Security` workflow (`.github/workflows/security.yml`) and
`CodeQL` workflow (`.github/workflows/codeql.yml`) run alongside it —
action-pin lint, OSV-Scanner, gitleaks, dependency review, allowlist-
expiry check, and CodeQL `swift` analysis. Use the PR template
(`.github/pull_request_template.md`) to describe the change, the manual
test matrix, and any protocol-affecting bits.

> **Note on branch protection.** GitHub's branch-protection and repository-
> ruleset features are not available for private repositories on the free
> org plan this repo lives under, so direct pushes to `main` are not
> blocked at the platform level. Treat the PR-based flow as a convention
> and rely on the CI workflows as the quality gate.

## Security

Vulnerability disclosure: [`SECURITY.md`](SECURITY.md). Every
release ships cosign keyless signatures, SHA256SUMS, SBOMs (SPDX +
CycloneDX), and SLSA L3 provenance — see
[`CONTRIBUTING.md#security`](CONTRIBUTING.md#security) for the
verification recipe.

## License

Distributed under the terms of the **GNU Lesser General Public License v3.0
or later**. See [`LICENSE`](LICENSE) (LGPL) and [`COPYING.GPL3`](COPYING.GPL3)
(the GPL v3 the LGPL incorporates by reference).
