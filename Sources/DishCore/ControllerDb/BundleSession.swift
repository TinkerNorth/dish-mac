// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The client's own view of one host session for the diagnostics bundle:
// each slot as asked and as applied, the last heartbeat ack, the round
// trip, and how many messages of each kind went each way.

import Foundation

/// The message kinds the client sends, in the bundle's words. 0x000C is the
/// touchpad frame on a version-1 session and the pointer frame after; both
/// count as `pointer`.
public enum WireSentKind: Int, CaseIterable, Sendable {
    case input
    case heartbeat
    case motion
    case battery
    case pointer
    case mic

    public var name: String {
        switch self {
        case .input: "input"
        case .heartbeat: "heartbeat"
        case .motion: "motion"
        case .battery: "battery"
        case .pointer: "pointer"
        case .mic: "mic"
        }
    }
}

/// The message kinds a host sends, in the bundle's words.
public enum WireReceivedKind: Int, CaseIterable, Sendable {
    case heartbeatAck
    case rumble
    case lightbar
    case triggerEffects
    case playerLeds
    case micLed
    case speaker
    case haptic
    case sessionClose

    public var name: String {
        switch self {
        case .heartbeatAck: "heartbeatAck"
        case .rumble: "rumble"
        case .lightbar: "lightbar"
        case .triggerEffects: "triggerEffects"
        case .playerLeds: "playerLeds"
        case .micLed: "micLed"
        case .speaker: "speaker"
        case .haptic: "haptic"
        case .sessionClose: "sessionClose"
        }
    }
}

/// The counter a sent message type bumps; nil for a type the client never
/// sends. Read once per datagram on the send path.
public func wireSentKind(_ msgType: UInt16) -> WireSentKind? {
    switch msgType {
    case ProtocolConstants.msgInput: .input
    case ProtocolConstants.msgHeartbeat: .heartbeat
    case ProtocolConstants.msgMotion: .motion
    case ProtocolConstants.msgBattery: .battery
    case ProtocolConstants.msgTouchpad: .pointer
    case ProtocolConstants.msgMicAudio: .mic
    default: nil
    }
}

/// The counter a received message type bumps; nil for a type the client
/// does not know.
public func wireReceivedKind(_ msgType: UInt16) -> WireReceivedKind? {
    switch msgType {
    case ProtocolConstants.msgHeartbeatAck: .heartbeatAck
    case ProtocolConstants.msgRumble: .rumble
    case ProtocolConstants.msgLightbar: .lightbar
    case ProtocolConstants.msgTriggerEffects: .triggerEffects
    case ProtocolConstants.msgPlayerLeds: .playerLeds
    case ProtocolConstants.msgMicLed: .micLed
    case ProtocolConstants.msgSpeakerAudio: .speaker
    case ProtocolConstants.msgHapticAudio: .haptic
    case ProtocolConstants.msgSessionClose: .sessionClose
    default: nil
    }
}

/// Every count by kind, read off a session's counters at one instant.
public struct WireCounts: Equatable, Sendable {
    public let sent: [WireSentKind: Int]
    public let received: [WireReceivedKind: Int]

    public init(sent: [WireSentKind: Int] = [:], received: [WireReceivedKind: Int] = [:]) {
        self.sent = sent
        self.received = received
    }
}

/// One slot of the session as the client asked for it and the host applied it.
public struct BundleSessionSlot: Equatable, Sendable {
    public let index: Int
    public let record: String?
    public let requestedType: String
    /// Nil until the host answered for the slot.
    public let appliedType: String?
    public let backend: String?
    public let result: String?
    /// Nil on a host whose protocol has no such mode.
    public let touchpadMode: String?

    public init(
        index: Int,
        record: String?,
        requestedType: String,
        appliedType: String?,
        backend: String?,
        result: String?,
        touchpadMode: String?
    ) {
        self.index = index
        self.record = record
        self.requestedType = requestedType
        self.appliedType = appliedType
        self.backend = backend
        self.result = result
        self.touchpadMode = touchpadMode
    }
}

public struct BundleSessionFacts: Equatable, Sendable {
    public let slots: [BundleSessionSlot]
    /// Nil until the first enriched ack.
    public let ack: HeartbeatAck?
    public let latency: LatencySummary
    /// Nil on a host whose messages the client does not count by kind.
    public let counts: WireCounts?

    public init(slots: [BundleSessionSlot], ack: HeartbeatAck?, latency: LatencySummary, counts: WireCounts?) {
        self.slots = slots
        self.ack = ack
        self.latency = latency
        self.counts = counts
    }
}

/// A controller type in the words its host's catalog uses for it, or its
/// number when the catalog does not name it.
public func controllerTypeName(_ type: Int, slugs: [Int: String]) -> String {
    slugs[type].flatMap { $0.isEmpty ? nil : $0 } ?? String(type)
}

// MARK: - The encoded shape

struct BundleSessionFile: Encodable {
    struct Slot: Encodable {
        let index: Int
        let record: String?
        let requestedType: String
        let appliedType: String?
        let backend: String?
        let result: String?
        let touchpadMode: String?

        private enum CodingKeys: String, CodingKey {
            case index, record, requestedType, appliedType, backend, result, touchpadMode
        }

        /// A field the client does not know is null, as the contract asks.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(index, forKey: .index)
            try container.encode(record, forKey: .record)
            try container.encode(requestedType, forKey: .requestedType)
            try container.encode(appliedType, forKey: .appliedType)
            try container.encode(backend, forKey: .backend)
            try container.encode(result, forKey: .result)
            try container.encode(touchpadMode, forKey: .touchpadMode)
        }
    }

    struct Ack: Encodable {
        let backendAvailable: Bool
        let activeControllers: Int
        let epoch: Int
        let activeBitmap: String
    }

    struct Rtt: Encodable {
        let p50Ms: Double?
        let p99Ms: Double?
        let samples: Int

        private enum CodingKeys: String, CodingKey { case p50Ms, p99Ms, samples }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(p50Ms, forKey: .p50Ms)
            try container.encode(p99Ms, forKey: .p99Ms)
            try container.encode(samples, forKey: .samples)
        }
    }

    let slots: [Slot]
    let ack: Ack?
    let rtt: Rtt
    let sent: [String: Int]?
    let received: [String: Int]?

    private enum CodingKeys: String, CodingKey { case slots, ack, rtt, sent, received }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(slots, forKey: .slots)
        try container.encode(ack, forKey: .ack)
        try container.encode(rtt, forKey: .rtt)
        try container.encode(sent, forKey: .sent)
        try container.encode(received, forKey: .received)
    }
}

/// Every kind is written, a zero included, so a reader tells "none sent"
/// from "not counted".
func bundleSession(_ facts: BundleSessionFacts) -> BundleSessionFile {
    BundleSessionFile(
        slots: facts.slots.map { slot in
            BundleSessionFile.Slot(
                index: slot.index,
                record: slot.record,
                requestedType: slot.requestedType,
                appliedType: slot.appliedType,
                backend: slot.backend,
                result: slot.result,
                touchpadMode: slot.touchpadMode
            )
        },
        ack: facts.ack.map { ack in
            BundleSessionFile.Ack(
                backendAvailable: ack.backendAvailable,
                activeControllers: Int(ack.activeCount),
                epoch: Int(ack.epoch),
                activeBitmap: String(format: "%04x", UInt32(ack.bitmap))
            )
        },
        rtt: BundleSessionFile.Rtt(p50Ms: facts.latency.p50RttMs, p99Ms: facts.latency.p99RttMs, samples: facts.latency.samples),
        sent: facts.counts.map(sentFile),
        received: facts.counts.map(receivedFile)
    )
}

private func sentFile(_ counts: WireCounts) -> [String: Int] {
    Dictionary(uniqueKeysWithValues: WireSentKind.allCases.map { ($0.name, counts.sent[$0] ?? 0) })
}

private func receivedFile(_ counts: WireCounts) -> [String: Int] {
    Dictionary(uniqueKeysWithValues: WireReceivedKind.allCases.map { ($0.name, counts.received[$0] ?? 0) })
}
