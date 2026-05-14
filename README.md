# Dish Mac

Native macOS client for the Satellite wireless-gamepad server. Mirrors the
functionality of the Dish Android client: LAN discovery, PIN pairing,
encrypted UDP input streaming (ChaCha20-Poly1305), heartbeats, and multiple
parallel server sessions.

## Architecture

```
SwiftUI (MainView, ConnectionsView)
  └── AppModel (ObservableObject)
        ├── ConnectionHub      ── aggregates live + remembered sessions
        ├── WifiConnectionManager
        │     └── WifiConnection (per-server)
        │           └── SatelliteClient  ── encrypted UDP + heartbeat + ACK loop
        ├── LANDiscovery       ── UDP broadcast listener on :9879
        ├── PairingClient      ── TCP pair handshake on :9878
        ├── HTTPClient         ── POST/DELETE /api/connections on :9877
        └── GameControllerInput ── GameController.framework push callbacks
              └── GamepadInputProcessor → SatelliteClient.sendReport()
```

## Low-latency strategies (mirrored from Android)

- **Direct `sendto()` from the input callback thread.** The GameController
  `valueChangedHandler` fires on every button/axis change and invokes the
  native socket send inline — no queue, no Combine, no async hop. Same pattern
  as `Kotlin → JNI → sendto` on Android.
- **Raw POSIX UDP socket** (not `NWConnection`) so we can set `IP_TOS = 0xB8`
  (DSCP EF class, expedited forwarding) and bypass Network.framework's
  internal queueing.
- **CryptoKit.ChaChaPoly** produces the exact same wire format as libsodium's
  `crypto_aead_chacha20poly1305_ietf` used by the Android JNI and the
  Satellite server.
- **Per-session heartbeat + ACK threads** on dedicated dispatch queues so the
  hot input path is never contended by book-keeping traffic.
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
  the TCP pair handshake entirely when a 64-char shared key is already on
  disk, going straight to `openSession`. A moved server then fails fast in
  the HTTP layer rather than bouncing through pair → `PairingRequired`.
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
  │  • ack receive queue │      │  • per-conn handler  │      │    .applyRumble(...) │
  │  • parseRumblePayload│      │    (installed by     │      │      └─► RumbleActua-│
  │  • dispatch to       │      │     AppModel from    │      │           tor.apply  │
  │    rumbleHandler     │      │     wifi.$connections│      │           (per ctrl) │
  └──────────────────────┘      └──────────────────────┘      └──────────┬───────────┘
                                                                         │
                                                                         ▼
                                                          GCController.haptics +
                                                          CHHapticEngine per locator
                                                          (.leftHandle / .rightHandle)
```

The wire format is documented in
[`satellite/README.md`](https://github.com/TinkerNorth/satellite#rumble-return-path).
On the dish-mac side:

* **Parser** — `SatelliteClient.parseRumblePayload` is a pure static
  decoder so unit tests can exercise byte layouts without a live socket
  (see `Tests/DishTests/SatelliteClientRumbleTests.swift`).
* **Routing** — `AppModel.installRumbleHandlers` runs on every
  `wifi.$connections` change and attaches a handler that resolves
  `connId → slotId → deviceId` via the `ConnectionHub` bindings, then
  calls `GameControllerInput.applyRumble`.
* **Actuation** — `RumbleActuator` keeps two `CHHapticEngine` instances
  per controller (one for `.leftHandle`, one for `.rightHandle`). Each
  rumble packet builds a tiny `CHHapticPattern` with intensity scaled
  from 0..65535 to CoreHaptics's 0..1, and a fresh per-call player so we
  don't pay engine start-up latency per packet. `controller.light?.color`
  is set when the satellite published a DS4 lightbar colour.
* **No haptics → silent no-op.** Legacy MFi pads that don't expose
  `controller.haptics` skip actuation entirely; the player just doesn't
  feel rumble — same outcome as if the satellite never sent the packet.

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
└── Sources/Dish/
    ├── DishApp.swift            # @main SwiftUI entry
    ├── AppModel.swift           # top-level ObservableObject
    ├── Models/                  # DiscoveredServer, PairResponse, ...
    ├── Network/                 # sockets, crypto, discovery, pairing, HTTP
    ├── Input/                   # GameController bridge + XUSB mapping
    ├── Util/                    # telemetry, hex
    └── UI/                      # SwiftUI views + theme
```

## Protocol parity

All message types, byte layouts, port numbers and JSON shapes match the
Android client verbatim so both can talk to the same server and appear
identical to it:

| Field            | Value            |
| ---------------- | ---------------- |
| Discovery port   | UDP 9879 (listen)|
| Pairing port     | TCP 9878         |
| HTTP API port    | TCP 9877         |
| Streaming port   | UDP 9876         |
| AEAD             | ChaCha20-Poly1305 IETF |
| Nonce            | counter, BE, left-padded to 12 bytes |
| Packet layout    | `token(4) \| counter(4) \| ciphertext+tag` |
| AAD              | token (4 bytes)  |
| XUSB report      | 12 bytes, little-endian |
| Heartbeat period | 2 s              |
| Miss threshold   | 5 consecutive    |

## Testing

```bash
swift test
```

Unit tests cover the hex/byte-packing utilities, the XUSB input mapping (axis
and trigger scaling, button bitfield, per-device deadzone application,
zero-on-disconnect fan-out), the lock-free atomic counter under contention,
the lenient beacon JSON decoder, the persisted-model codable round-trips, the
`PairingClient.classify` outcome arms (success / authRequired / unreachable),
and the `ScreenWakeController` acquire/release lifecycle via a fake
`DisplaySleepInhibitor` (so the suite never has to touch IOKit). They run in
~0.1 s and do not open sockets.

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
