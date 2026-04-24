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
and trigger scaling, button bitfield, zero-on-disconnect fan-out), the
lock-free atomic counter under contention, the lenient beacon JSON decoder,
and the persisted-model codable round-trips. They run in ~0.1 s and do not
open sockets.

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
pushes. Use the PR template (`.github/pull_request_template.md`) to describe
the change, the manual test matrix, and any protocol-affecting bits.

> **Note on branch protection.** GitHub's branch-protection and repository-
> ruleset features are not available for private repositories on the free
> org plan this repo lives under, so direct pushes to `main` are not
> blocked at the platform level. Treat the PR-based flow as a convention
> and rely on the CI workflow as the quality gate.
