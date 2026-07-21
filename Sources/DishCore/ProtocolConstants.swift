// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Pure protocol-1 constants + tiny wire-string mappers shared by the wire
// layer, the REST DTO parsers and the pure reducers. Mirrors the authoritative
// satellite/src/core/types.h subset the CLIENT needs (opcodes, caps, apply
// results, touchpad modes, controller types, crypto/timeout sizes). Ports
// dish-linux src/Models/Protocol.h — see satellite/docs/contract.md.

import Foundation

/// Protocol-1 wire + REST constants (contract SSOT: `satellite/docs/contract.md`).
public enum ProtocolConstants {

    /// REST + wire protocol version. Rides in every pairing/session request so
    /// any future change is gateable (contract §Versioning).
    public static let protocolVersion = 1

    // MARK: - UDP opcodes (contract §UDP messages)

    // Topology-mutation opcodes 0x0004 (ADD), 0x0005 (REMOVE), 0x0006 (ACK),
    // 0x0007 (SERVER_STATUS), 0x0008 (TYPE) and 0x000E (CAPS_UPDATE) are
    // DELETED in protocol-1 — they are intentionally NOT defined here so a
    // stray reference fails to compile. Topology mutation is REST-only, and
    // server status rides in every enriched heartbeat ack.

    /// c→s: ctrlIdx(1) + GamepadReport(12, XUSB layout, LE).
    public static let msgInput: UInt16 = 0x0001
    /// c→s: empty payload.
    public static let msgHeartbeat: UInt16 = 0x0002
    /// s→c: enriched ack — see `HeartbeatAck`.
    public static let msgHeartbeatAck: UInt16 = 0x0003
    /// s→c: ctrlIdx(1) + strong/weak/durationMs (3 × u16 BE).
    public static let msgRumble: UInt16 = 0x0009
    /// c→s: ctrlIdx(1) + gyro/accel (6 × i16 LE) + timestampDeltaUs(u32 LE).
    public static let msgMotion: UInt16 = 0x000A
    /// c→s: ctrlIdx(1) + level(1) + status(1).
    public static let msgBattery: UInt16 = 0x000B
    /// c→s: ctrlIdx(1) + 15 bytes — see `Encoders.touchpadPayload`.
    public static let msgTouchpad: UInt16 = 0x000C
    /// s→c: ctrlIdx(1) + r(1) + g(1) + b(1).
    public static let msgLightbar: UInt16 = 0x000D
    /// s→c: reason(1) — see `CloseReason`.
    public static let msgSessionClose: UInt16 = 0x000F

    // MARK: - Wire sizes (contract §Crypto / §UDP messages)

    /// Cleartext packet header: token(4 BE) + counter(4 BE).
    public static let headerSize = 8
    /// Inner frame header: msgType(2 BE) + msgLen(2 BE).
    public static let innerHeaderSize = 4
    /// Poly1305 authentication tag appended to every ciphertext.
    public static let authTagSize = 16
    /// pairingKey / sessionKey length in bytes.
    public static let cryptoKeySize = 32
    /// ChaCha20-Poly1305-IETF nonce length in bytes.
    public static let cryptoNonceSize = 12
    /// HKDF salt minted by the server per session PUT.
    public static let sessionSaltSize = 8

    /// MSG_INPUT inner payload: ctrlIdx(1) + XUSB report(12 LE).
    public static let inputPayloadBytes = 13
    /// MSG_MOTION inner payload: ctrlIdx(1) + 6 × i16 LE + u32 LE.
    public static let motionPayloadBytes = 17
    /// MSG_BATTERY inner payload: ctrlIdx(1) + level(1) + status(1).
    public static let batteryPayloadBytes = 3
    /// MSG_TOUCHPAD payload length AFTER the 1-byte ctrlIdx: flags(1) +
    /// f0(id1+x2+y2) + f1(id1+x2+y2) + eventTimeMs(u32 LE) = 15 bytes
    /// (16 with ctrlIdx). The trailing eventTimeMs is the protocol-1 addition
    /// (was 12); the server requires msgLen >= 16 inner, so a legacy 12-byte
    /// body is dropped.
    public static let touchpadPayloadBytes = 15
    /// MSG_HEARTBEAT_ACK payload: backendAvailable(1) + count(1) +
    /// epoch(u16 BE) + bitmap(u16 BE). Drives the reconcile loop.
    public static let heartbeatAckPayloadBytes = 6
    /// MSG_RUMBLE payload: ctrlIdx(1) + strong(2 BE) + weak(2 BE) + dur(2 BE).
    public static let rumblePayloadBytes = 7
    /// MSG_LIGHTBAR payload: ctrlIdx(1) + r(1) + g(1) + b(1).
    public static let lightbarPayloadBytes = 4

    // MARK: - Liveness (contract §Liveness)

    /// Heartbeat cadence — 2000 ms (NOT the 250 ms the pre-contract docs claimed).
    public static let heartbeatIntervalMs = 2000
    /// Consecutive missed acks before the link displays "not responding".
    public static let heartbeatMissNotResponding = 2
    /// Consecutive missed acks before the link counts as dead.
    public static let heartbeatMissMax = 5
    // (The satellite's REST-liveness reaper grace — 15 s of provisional
    // liveness after a session PUT — is server-side policy the client never
    // consults; its former mirror constant here was dropped as dead, W4C-F1.)

    // MARK: - Latency readout (dish-linux Util/LatencyWindow.h; android #138)

    /// Sliding heartbeat-RTT window capacity — 64 samples span ~2 min at the
    /// 2 s cadence, so the median answers "now", not "since session open".
    public static let latencyWindowCapacity = 64

    // MARK: - Send-counter exhaustion (contract §Crypto)

    /// Clients SHOULD proactively re-PUT (fresh token/salt/key; counters back
    /// to 1) once the UDP send counter crosses this — a counter can never wrap.
    /// See `counterNeedsRepush(_:)`.
    public static let counterRepushThreshold: UInt32 = 0xF000_0000

    // MARK: - Controller capability bits (descriptor caps word)

    public static let capAnalogTriggers: UInt16 = 0x0001
    public static let capRumble: UInt16 = 0x0002
    public static let capMotion: UInt16 = 0x0004
    public static let capLightbar: UInt16 = 0x0008

    // MARK: - Controller types (catalog ids / descriptor `type`)

    public static let controllerTypeXbox: UInt8 = 0
    public static let controllerTypePlayStation: UInt8 = 1

    /// A session carries at most 16 controller slots (also the enriched-ack
    /// bitmap breadth).
    public static let maxControllersPerConnection = 16

    // MARK: - Battery wire constants

    /// `level` byte meaning "percentage unknown" (status may still be known).
    public static let batteryLevelUnknown: UInt8 = 0xFF

    // MARK: - 401 machine-readable causes (contract §Error model)

    /// Either code is TERMINAL: drop the key, surface "re-pair needed", stop
    /// retrying. Carried in the 401 body `{"error":"unauthorized","code":...}`.
    public static let authCodeNotPaired = "NOT_PAIRED"
    public static let authCodeBadProof = "BAD_PROOF"

    // MARK: - Host-feature deny reasons (protocol constants, never localized)

    public static let hostDenyNotSupported = "notSupported"
    public static let hostDenyBackendUnavailable = "backendUnavailable"
    public static let hostDenyDenied = "denied"
}

/// Battery status byte on the wire — must match `satellite/src/core/types.h`
/// (`BATTERY_STATUS_*`). Values are stable across platforms.
public enum BatteryStatus: UInt8, Sendable {
    case unknown = 0
    case discharging = 1
    case charging = 2
    case full = 3
    case wired = 4
}

/// Per-controller apply outcome from the session PUT / per-controller PUT
/// response. The wire form is the lowercase string (protocol constant, never
/// localized); the numeric code mirrors satellite `APPLY_*` so error mappings
/// stay re-keyable onto strings.
public enum ApplyResult: UInt8, Sendable {
    case ok = 0
    case noSlots = 1
    case pluginFailed = 2
    case replugFailed = 3
    case backendUnavailable = 4
    case invalidType = 5
    case invalidIndex = 6
    /// An unrecognised string a newer server invented — treated as not-live
    /// rather than guessing success/failure.
    case unknown = 0xFF

    /// The wire string for this result (`"ok"`, `"noSlots"`, …).
    public var wireName: String {
        switch self {
        case .ok: "ok"
        case .noSlots: "noSlots"
        case .pluginFailed: "pluginFailed"
        case .replugFailed: "replugFailed"
        case .backendUnavailable: "backendUnavailable"
        case .invalidType: "invalidType"
        case .invalidIndex: "invalidIndex"
        case .unknown: "unknown"
        }
    }

    /// Parse a wire apply-result string. Unrecognised strings map to
    /// `.unknown` — the caller treats the slot as not-live.
    public init(wireName: String) {
        switch wireName {
        case "ok": self = .ok
        case "noSlots": self = .noSlots
        case "pluginFailed": self = .pluginFailed
        case "replugFailed": self = .replugFailed
        case "backendUnavailable": self = .backendUnavailable
        case "invalidType": self = .invalidType
        case "invalidIndex": self = .invalidIndex
        default: self = .unknown
        }
    }

    /// A slot is LIVE (streams keep flowing) when the descriptor applied OK,
    /// or when a replug failed: the previous pad is left untouched and
    /// `appliedType` reports the type still in force. Every other code means
    /// the slot is not plugged.
    public var slotIsLive: Bool {
        self == .ok || self == .replugFailed
    }
}

/// Touchpad routing modes (descriptor `touchpadMode`; wire form is the string).
public enum TouchpadMode: UInt8, Sendable {
    case ds4 = 0
    case mouse = 1
    case off = 2

    /// The wire string (`"ds4"` / `"mouse"` / `"off"`).
    public var wireName: String {
        switch self {
        case .ds4: "ds4"
        case .mouse: "mouse"
        case .off: "off"
        }
    }

    /// Parse a wire mode string; unknown → `.off` (the server's default too).
    public init(wireName: String) {
        switch wireName {
        case "ds4": self = .ds4
        case "mouse": self = .mouse
        default: self = .off
        }
    }
}
