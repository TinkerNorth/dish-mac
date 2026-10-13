# Dish ↔ Satellite contract: client notes (macOS)

The protocol contract (REST surface, UDP streams, crypto, liveness,
identity) lives in ONE place: **`satellite/docs/contract.md`** in the
[TinkerNorth/satellite](https://github.com/TinkerNorth/satellite) repo. This
client offers protocol 3 and still speaks 1; this file only records the
macOS-side mapping. When code and contract disagree, the contract wins.

## Where the contract lands in this app

The pure protocol layer is the `DishCore` SwiftPM target (Foundation +
CryptoKit only — the compiler enforces that the wire/crypto/policy code
stays IO-free). The imperative shell in `Sources/DishEngine/Network` owns sockets,
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
| TOFU TLS enforcement (pin on first contact, abort handshake on mismatch) | `Sources/DishEngine/Network/TofuTrustDelegate.swift`, composed by `WifiConnectionManager.makePinVerifier` |
| Wire DTOs (ControllerDescriptor, session/controller/pair responses, host-feature grants) | `Sources/DishEngine/Network/RestModels.swift` |
| Authed REST routes (session PUT/GET/DELETE, per-slot PUT/DELETE, self-unpair; `X-Device-Id` + `X-Hmac-Proof` headers) | `Sources/DishEngine/Network/HTTPClient.swift` |
| Pairing paths A + B (`POST /api/pair`, `GET /api/pair/status` poll) + outcome classification | `Sources/DishEngine/Network/PairingClient.swift` |
| Session lifecycle: declarative PUT, HKDF key handoff, proactive re-key, live per-slot converge | `Sources/DishEngine/Network/WifiConnectionManager+Session.swift` |
| Connect/pair flows, terminal-401 key drop + stale marker, forget → self-unpair, identity-changed UX | `Sources/DishEngine/Network/WifiConnectionManager.swift` + `WifiConnectionManager+Pairing.swift` |
| UDP data plane: socket, per-direction counters from 1, replay guard, heartbeat timer, receive loop | `Sources/DishEngine/Network/SatelliteClient.swift` + `SatelliteClient+IO.swift` |
| Per-session liveness (2 s heartbeat, alive tick, enriched-ack snapshot, close-reason surfacing) | `Sources/DishEngine/Network/WifiConnection.swift` |
| Satellite identity: `mid:<machineId>` keying, legacy-ghost collapse, DHCP re-home, TOFU pin registry | `Sources/DishEngine/Network/ConnectionStore.swift` |
| Pairing-key storage (Keychain; in-memory impl for tests) | `Sources/DishEngine/Network/KeyStore.swift` |
| Discovery: mDNS `_satellite._udp` + TXT (`mid`, ports) | `Sources/DishEngine/Network/MdnsBrowser.swift` |
| Discovery: legacy UDP `:9879` beacon (fallback) | `Sources/DishEngine/Network/LANDiscovery.swift` |
| Versioning: the offer, the 409 range, the settled version that keys the frames, the compat chip | `Sources/DishCore/Reducers/ProtocolNegotiation.swift`, applied by `lowerOfferOrFail` and `adoptGrant` in `Sources/DishEngine/Network/WifiConnectionManager+Session.swift` |
| 0x000C POINTER frame (version 2) beside the 16-byte TOUCHPAD frame | `Sources/DishCore/Wire/Encoders.swift` (`pointerPayload`), chosen by the settled version in `SatelliteClient.sendTouchpad` |
| TRIGGER_EFFECTS 0x0010 and PLAYER_LEDS 0x0011 return paths | `Sources/DishCore/Wire/FeedbackCommands.swift`, `Sources/DishEngine/Input/DualSenseTriggerEffect.swift`, `Sources/DishEngine/Input/GameControllerInput+ReturnPath.swift` |
| Descriptor caps as promises (the hardware AND the user's switch), `touchpadMode` | `Sources/DishEngine/Network/DescriptorCaps.swift` |
| `touchpadMode` ∈ `off`/`ds4`/`mouse` from the controller's pick, the type's `modes` and the host's `mouseControl`; the session's `hostFeatures.mouseControl` request and its grant | `Sources/DishCore/Reducers/TouchpadModeResolve.swift`; `WifiConnection.wantsMouseControl`, carried by every session PUT in `WifiConnectionManager+Session.swift` and converged by `convergeHostFeatures` through the re-key path when a pick flips mid-session |
| `GET /api/server/capabilities` | `Sources/DishEngine/Network/ServerCapabilities.swift`, cached by `WifiConnectionManager.fetchCapabilities`; the host layer of the capability table (`hostProbeFacts`) |
| Catalog version 2: `catalogVersion`, `emulates`, the feature slugs, `modes`, `requires` | `Sources/DishEngine/Network/CatalogModels.swift`; `emulatedControllerType`, `offerableTypes` and `typeFeatureFacts` in `DescriptorCaps.swift` (the Emulate picker and the type layer of the capability table); the catalog is read before the first session PUT |
| The apply result's `motion.sinkSupportedForType` / `motion.backendOk` | `ControllerApplyDto` in `RestModels.swift`, recorded per binding in `MotionBackendStatusStore`, folded by `motionIndicatorFor` in `Sources/DishCore/Reducers/MotionIndicator.swift` |
| Controller audio frames: MIC_AUDIO 0x0012 up, SPEAKER_AUDIO 0x0013 and HAPTIC_AUDIO 0x0015 down (`ctrlIdx(1) + seq(u16 BE) + one Opus packet`), MIC_LED 0x0014, the mic-mute button bit, the 1500-byte datagram ceiling | `Sources/DishCore/Wire/AudioFrames.swift`; the receive buffer in `SatelliteClient+IO.swift` is `ProtocolConstants.udpDatagramMaxBytes` |
| The receiver's reorder window (two frames, loss declared at the second packet ahead, resync after two gaps) | `Sources/DishCore/Reducers/AudioJitterWindow.swift` |
| The audio plan: `capMic`/`capSpeaker`/`capHapticAudio` from the route and the switches, the mic armed by the session, the host's `controllerAudio` verdict and the system's leave, mute as zero packets, the app-wide mic word | `Sources/DishCore/Reducers/ControllerAudioPolicy.swift`; the probe's block folded by `ServerCapabilitiesDTO.audioVerdict` |
| The pad's USB audio function (Core Audio HAL), its match to a pad by family, Opus through AudioToolbox, the HAL output and input units, the microphone permission | `Sources/DishEngine/Audio/` (`PadAudioDevices`, `PadAudioRoutes`, `OpusCodec`, `AudioUnits`, `MicPermission`), driven by `ControllerAudioEngine` and wired by `AudioPipeline` |

Test double: `Tests/DishEngineTests/Support/FakeSatellite/` is an in-process
satellite that accepts a configurable protocol range (1...3 by default, like
the real one), settles and echoes the offer, decodes both 0x000C shapes, and
injects every return path (REST + UDP, independent CryptoKit crypto asserted
against the same pinned vectors); the control-plane, data-plane, negotiation
and `Integration*` suites drive it end-to-end.

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

The catalog's `image` references are decoded and not drawn; the picker names
a type, it does not picture it. Controller audio is consumed in full but has not yet been heard
on a pad: the engine is proven over fake ports and the fake satellite, as the
architecture notes say.
