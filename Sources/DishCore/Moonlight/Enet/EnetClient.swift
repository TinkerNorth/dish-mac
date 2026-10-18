// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// A minimal ENet client as a pure state machine: `connect`, `sendReliable`,
// `onDatagram` and `tick` return the datagrams the transport must send, and
// the host's reliable payloads queue in `received`. A monotonic clock and
// the random source are injected, so retransmit and ping timing are
// deterministic in a test. Not thread-safe: one session's owner serializes
// the calls. Ported from the MIT cgutman/enet fork Wolf pins (peer.c,
// protocol.c) and checked against it line by line; see THIRD_PARTY.md.

import Foundation

public final class EnetClient {
    public enum State: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
    }

    /// What the link did, for the session log.
    public struct Stats: Equatable, Sendable {
        public var acksSent = 0
        public var retransmits = 0
        public var unknownCommands = 0
        /// Reliable commands that arrived ahead of their turn and waited.
        public var heldOutOfOrder = 0
    }

    struct Outgoing {
        let channel: UInt8
        let reliableSequence: UInt16
        let command: Data
        var sentAtMs: Int64
        var sendAttempts: Int
        var roundTripTimeout: Int64
    }

    public internal(set) var state = State.disconnected
    /// Why the client gave up, for the log; nil while healthy.
    public internal(set) var disconnectReason: String?
    /// The host's reliable payloads, in order; the owner drains them.
    public internal(set) var received: [Data] = []
    public internal(set) var stats = Stats()
    public var roundTripMs: Int64? {
        sampled ? roundTripTime : nil
    }

    let connectData: UInt32
    let now: () -> Int64
    let random: () -> UInt32

    // Our identity: we are peer 0 to ourselves; the host's id for us and its
    // session ids come with VERIFY_CONNECT.
    let incomingPeerId: UInt16 = 0
    var outgoingPeerId = EnetProtocol.maximumPeerId
    var incomingSessionId = EnetProtocol.sessionIdUnset
    var outgoingSessionId = EnetProtocol.sessionIdUnset
    var connectId: UInt32 = 0
    var mtu = EnetProtocol.defaultMtu
    var windowSize = EnetProtocol.maximumWindowSize

    var channelReliableSequence: UInt16 = 0
    var systemReliableSequence: UInt16 = 0
    var incomingReliableSequence: UInt16 = 0
    /// Reliable commands ahead of their turn, delivered when the gap fills.
    var heldReliable: [UInt16: Data] = [:]
    static let heldReliableCeiling = 64

    /// Moves on an acknowledgement, as the fork's lastReceiveTime does: an
    /// acknowledgement is the one thing that proves the peer is still there.
    var lastReceiveMs: Int64 = 0
    var roundTripTime = EnetProtocol.defaultRoundTripTimeMs
    var roundTripTimeVariance: Int64 = 0
    var sampled = false
    /// The send time of the oldest overdue reliable command; the clock the
    /// give-up rule runs on, cleared by any acknowledgement.
    var earliestTimeoutMs: Int64 = 0
    var sentReliable: [Outgoing] = []

    public init(connectData: UInt32, now: @escaping () -> Int64, random: @escaping () -> UInt32) {
        self.connectData = connectData
        self.now = now
        self.random = random
    }

    /// Begin the handshake: the CONNECT datagram to send.
    public func connect() -> Data {
        state = .connecting
        disconnectReason = nil
        connectId = random()
        systemReliableSequence = 1
        let time = now()
        lastReceiveMs = time
        return track(channel: EnetProtocol.systemChannel, sequence: systemReliableSequence, command: buildConnect(), at: time)
    }

    /// Queue a reliable payload on channel 0: the datagram to send, or nil
    /// when not connected, so input for a dead session is dropped rather than
    /// framed into the void.
    public func sendReliable(_ payload: Data) -> Data? {
        guard state == .connected else { return nil }
        channelReliableSequence &+= 1
        var writer = ByteWriter(capacity: EnetProtocol.sendReliableHeaderLength + payload.count)
        let reliable = EnetProtocol.commandSendReliable | EnetProtocol.flagAcknowledge
        EnetWire.commandHeader(&writer, command: reliable, channel: EnetProtocol.dataChannel, reliableSequence: channelReliableSequence)
        writer.u16BE(UInt16(truncatingIfNeeded: payload.count))
        writer.append(payload)
        return track(channel: EnetProtocol.dataChannel, sequence: channelReliableSequence, command: writer.data, at: now())
    }

    /// The graceful, unsequenced DISCONNECT; nil when there is nothing to leave.
    public func disconnect() -> Data? {
        guard state != .disconnected else { return nil }
        state = .disconnected
        disconnectReason = disconnectReason ?? "local teardown"
        var writer = ByteWriter(capacity: EnetProtocol.disconnectLength)
        let unsequenced = EnetProtocol.commandDisconnect | EnetProtocol.flagUnsequenced
        EnetWire.commandHeader(&writer, command: unsequenced, channel: EnetProtocol.systemChannel, reliableSequence: 0)
        writer.u32BE(0)
        return wrap(writer.data, at: now())
    }

    /// The payloads delivered so far, handed over and cleared.
    public func takeReceived() -> [Data] {
        defer { received.removeAll() }
        return received
    }

    func deliver(_ payload: Data) {
        received.append(payload)
    }

    func giveUp(_ reason: String) {
        state = .disconnected
        disconnectReason = reason
    }

    /// One command in a datagram with the sent-time header.
    func wrap(_ command: Data, at time: Int64) -> Data {
        var writer = EnetWire.header(
            outgoingPeerId: outgoingPeerId,
            outgoingSessionId: outgoingSessionId,
            sentTime: UInt16(truncatingIfNeeded: time)
        )
        writer.append(command)
        return writer.data
    }

    func track(channel: UInt8, sequence: UInt16, command: Data, at time: Int64) -> Data {
        sentReliable.append(
            Outgoing(
                channel: channel,
                reliableSequence: sequence,
                command: command,
                sentAtMs: time,
                sendAttempts: 1,
                roundTripTimeout: peerRoundTripTimeout()
            )
        )
        return wrap(command, at: time)
    }

    private func buildConnect() -> Data {
        var writer = ByteWriter(capacity: EnetProtocol.connectLength)
        let connect = EnetProtocol.commandConnect | EnetProtocol.flagAcknowledge
        EnetWire.commandHeader(&writer, command: connect, channel: EnetProtocol.systemChannel, reliableSequence: systemReliableSequence)
        writer.u16BE(incomingPeerId)
        writer.u8(EnetProtocol.sessionIdUnset)
        writer.u8(EnetProtocol.sessionIdUnset)
        writer.u32BE(mtu)
        writer.u32BE(windowSize)
        writer.u32BE(EnetProtocol.channelCount)
        writer.u32BE(0)
        writer.u32BE(0)
        writer.u32BE(EnetProtocol.throttleInterval)
        writer.u32BE(EnetProtocol.throttleAcceleration)
        writer.u32BE(EnetProtocol.throttleDeceleration)
        writer.u32BE(connectId)
        writer.u32BE(connectData)
        return writer.data
    }
}
