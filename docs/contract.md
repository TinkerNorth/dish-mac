# Dish ↔ Satellite contract: client notes (macOS)

The protocol contract (REST surface, UDP streams, crypto, liveness,
identity) lives in ONE place: **`satellite/docs/contract.md`** in the
[TinkerNorth/satellite](https://github.com/TinkerNorth/satellite) repo. This
client implements protocol 1 against it; this file only records the
macOS-side mapping. When code and contract disagree, the contract wins.

## Where the contract lands in this app

The pure protocol layer is the `DishCore` SwiftPM target (Foundation +
CryptoKit only — the compiler enforces that the wire/crypto/policy code
stays IO-free). The imperative shell in `Sources/Dish/Network` owns sockets,
URLSession, and stores.

| Contract concept | dish-mac home |
|---|---|
| HKDF session key, `hmacProof`, packet AEAD (dir-nonce, AAD = token) | `Sources/DishCore/Wire/SessionCrypto.swift` (cross-repo pinned vectors: `Tests/DishCoreTests/SessionCryptoVectorTests.swift`) |
| Packet framing (`token(4)‖counter(4)` header, `msgType‖msgLen‖payload` inner frame) | `Sources/DishCore/Wire/PacketCodec.swift` |
| Stream payload codecs — input(13), motion(17), battery(3), touchpad(16 incl. `eventTimeMs`) up; `HeartbeatAck` / `RumbleCommand` / `LightbarCommand` down | `Sources/DishCore/Wire/Encoders.swift` |
| Protocol constants (v1 opcodes, deleted topology opcodes absent-with-comment, caps, apply results, touchpad modes, cadences/sizes) | `Sources/DishCore/ProtocolConstants.swift` |
| Reconcile rules (epoch/bitmap drift → GET → benign-adopt vs re-PUT) + `counterNeedsRepush` re-key threshold | `Sources/DishCore/Reducers/Reconcile.swift` |
| Close-notify 0x000F reason → follow-up action policy | `Sources/DishCore/Reducers/CloseNotify.swift` |
| Exponential reconnect backoff (1 s → 60 s cap) | `Sources/DishCore/Reducers/Backoff.swift` |
| Latency readout (64-sample RTT window, p50 ÷ 2, single-in-flight ping) | `Sources/DishCore/Reducers/LatencyWindow.swift` |
| TOFU verdict ladder (`trustFirstUse` / `match` / `mismatch`) + SHA-256 DER fingerprint | `Sources/DishCore/Reducers/Tofu.swift` |
| REST error model (terminal 401 codes, 409, 503, transport) | `Sources/DishCore/Reducers/RestOutcome.swift` |
| TOFU TLS enforcement (pin on first contact, abort handshake on mismatch) | `Sources/Dish/Network/TofuTrustDelegate.swift`, composed by `WifiConnectionManager.makePinVerifier` |
| Wire DTOs (ControllerDescriptor, session/controller/pair responses, host-feature grants) | `Sources/Dish/Network/RestModels.swift` |
| Authed REST routes (session PUT/GET/DELETE, per-slot PUT/DELETE, self-unpair; `X-Device-Id` + `X-Hmac-Proof` headers) | `Sources/Dish/Network/HTTPClient.swift` |
| Pairing paths A + B (`POST /api/pair`, `GET /api/pair/status` poll) + outcome classification | `Sources/Dish/Network/PairingClient.swift` |
| Session lifecycle: declarative PUT, HKDF key handoff, proactive re-key, live per-slot converge | `Sources/Dish/Network/WifiConnectionManager+Session.swift` |
| Connect/pair flows, terminal-401 key drop + stale marker, forget → self-unpair, identity-changed UX | `Sources/Dish/Network/WifiConnectionManager.swift` + `WifiConnectionManager+Pairing.swift` |
| UDP data plane: socket, per-direction counters from 1, replay guard, heartbeat timer, receive loop | `Sources/Dish/Network/SatelliteClient.swift` + `SatelliteClient+IO.swift` |
| Per-session liveness (2 s heartbeat, alive tick, enriched-ack snapshot, close-reason surfacing) | `Sources/Dish/Network/WifiConnection.swift` |
| Satellite identity: `mid:<machineId>` keying, legacy-ghost collapse, DHCP re-home, TOFU pin registry | `Sources/Dish/Network/ConnectionStore.swift` |
| Pairing-key storage (Keychain; in-memory impl for tests) | `Sources/Dish/Network/KeyStore.swift` |
| Discovery: mDNS `_satellite._udp` + TXT (`mid`, ports) | `Sources/Dish/Network/MdnsBrowser.swift` |
| Discovery: legacy UDP `:9879` beacon (fallback) | `Sources/Dish/Network/LANDiscovery.swift` |

Test double: `Tests/DishTests/Support/FakeSatellite/` is an in-process
protocol-1 satellite (REST + UDP, independent CryptoKit crypto asserted
against the same pinned vectors) that the control-plane, data-plane and
`Integration*` suites drive end-to-end.

## Client behaviours required by the contract

- **Declarative topology.** A bind carries the FULL descriptor (type, caps,
  touchpad routing); slots absent from the PUT array are unplugged
  server-side. While live, single-slot changes ride
  `PUT /api/connections/{id}/controllers/{idx}` so the session token never
  rotates for a toggle; the full-session PUT runs on connect, re-key and
  reconcile. Zero-controller sessions are valid.
- **Session key ≠ pairing key.** Every session PUT re-derives
  `HKDF-SHA256(pairingKey, sessionSalt, token)`; the pairing key never
  reaches `SatelliteClient`. Counters restart at 1 per direction per key.
- **Terminal 401.** `code: NOT_PAIRED | BAD_PROOF` drops the stored pairing
  key, parks the remembered row on the "Needs pairing" marker, and STOPS
  retrying. Only a fresh user-initiated pair recovers. Loud only for
  user-initiated intents.
- **Terminal 409.** Protocol-version skew surfaces the version-mismatch
  message and keeps the key — version skew is not trust loss.
- **Proactive re-key.** When the send counter crosses `0xF0000000` the
  manager re-PUTs on the same socket (fresh token/salt/key); a session that
  exhausts anyway goes silent, never wraps.
- **Close-notify (0x000F).** Authenticated, best-effort, parsed into
  `DishCore.CloseReason` and surfaced through `WifiConnection.onSessionClose`;
  the alive tick reaps the session either way. Reason policy:
  `unpaired` is terminal, `replaced` stays down, `shutdown`/`kicked`
  re-enter bounded backoff.
- **Identity.** Satellites are keyed on `machineId` (`mid:<machineId>`)
  alone; endpoint (`wifi:ip:port`) only when a machineId was never seen.
  A machineId re-appearing under a new address re-homes the row and
  migrates the TOFU pin.
- **TOFU.** First HTTPS contact pins the cert's SHA-256 DER fingerprint per
  host; a later mismatch aborts the handshake before any request bytes flow
  and surfaces the "security identity changed" message, not "unreachable".
- **Pairing.** No PIN-free path. Path A: operator PIN typed here. Path B:
  this dish shows a PIN, the operator approves on the satellite, the key
  arrives via the status poll exactly once. Forget self-unpairs server-side
  (`DELETE /api/pair`) BEFORE dropping the local key.

## Contract surfaces this client does not consume yet

`GET /api/catalog` and `GET /api/server/capabilities` are not fetched —
there is no "Emulate" picker yet; every bind requests the Xbox target
(catalog type 0), so the catalog/capabilities probes have nothing to render.
The session PUT carries `hostFeatures` (sent as `mouseControl: false`) and
decodes the grant shape, but no host-input stream ships yet, and
`touchpadMode` stays `off`. These are UI-layer follow-ups; the wire/REST
layers above already carry everything they need.
