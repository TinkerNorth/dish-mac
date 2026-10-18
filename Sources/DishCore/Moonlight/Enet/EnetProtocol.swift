// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The ENet wire the Moonlight control stream rides on, the subset a client
// needs: the connect handshake, reliable send and receive on one channel,
// acknowledgements, ping and disconnect. Ported to Swift from the MIT
// cgutman/enet C source at the commit Wolf pins (protocol.h, protocol.c,
// peer.c); see THIRD_PARTY.md. Every multi-byte field is big-endian.

import Foundation

public enum EnetProtocol {
    public static let commandAcknowledge: UInt8 = 1
    public static let commandConnect: UInt8 = 2
    public static let commandVerifyConnect: UInt8 = 3
    public static let commandDisconnect: UInt8 = 4
    public static let commandPing: UInt8 = 5
    public static let commandSendReliable: UInt8 = 6
    public static let commandSendUnreliable: UInt8 = 7
    public static let commandSendFragment: UInt8 = 8
    public static let commandSendUnsequenced: UInt8 = 9
    public static let commandBandwidthLimit: UInt8 = 10
    public static let commandThrottleConfigure: UInt8 = 11
    public static let commandSendUnreliableFragment: UInt8 = 12
    public static let commandMask: UInt8 = 0x0F
    public static let flagAcknowledge: UInt8 = 1 << 7
    public static let flagUnsequenced: UInt8 = 1 << 6

    /// The datagram header's 16-bit word: the peer id in the low twelve bits,
    /// the session id above them, and the two flags on top.
    public static let headerFlagCompressed: UInt16 = 1 << 14
    public static let headerFlagSentTime: UInt16 = 1 << 15
    public static let headerSessionMask: UInt16 = 3 << 12
    public static let headerSessionShift: UInt16 = 12
    public static let maximumPeerId: UInt16 = 0xFFF
    /// A session id neither side has assigned yet.
    public static let sessionIdUnset: UInt8 = 0xFF
    /// Connect, ping and disconnect ride the system channel; data rides channel 0.
    public static let systemChannel: UInt8 = 0xFF
    public static let dataChannel: UInt8 = 0
    public static let channelCount: UInt32 = 1

    public static let minimumMtu: UInt32 = 576
    public static let maximumMtu: UInt32 = 4096
    public static let minimumWindowSize: UInt32 = 4096
    public static let maximumWindowSize: UInt32 = 65536
    public static let defaultMtu: UInt32 = 1400
    public static let throttleInterval: UInt32 = 5000
    public static let throttleAcceleration: UInt32 = 2
    public static let throttleDeceleration: UInt32 = 2

    /// The peer liveness numbers the host on the other end uses too, so one
    /// side never gives up while the other still thinks the link is healthy.
    public static let pingIntervalMs: Int64 = 500
    public static let defaultRoundTripTimeMs: Int64 = 500
    public static let timeoutLimit = 32
    public static let timeoutMinimumMs: Int64 = 5000
    public static let timeoutMaximumMs: Int64 = 30000
    /// Reliable sequence numbers live in windows of this many, sixteen of
    /// them around the ring, and a command this many windows ahead is discarded.
    public static let reliableWindowSize: UInt16 = 0x1000
    public static let reliableWindows: UInt16 = 16
    public static let freeReliableWindows: UInt16 = 8

    public static let commandHeaderLength = 4
    public static let acknowledgeLength = 8
    public static let connectLength = 48
    public static let verifyConnectLength = 44
    public static let disconnectLength = 8
    public static let pingLength = 4
    public static let sendReliableHeaderLength = 6
    public static let sendUnreliableHeaderLength = 8
    public static let sendUnsequencedHeaderLength = 8
    public static let sendFragmentHeaderLength = 24
    public static let bandwidthLimitLength = 12
    public static let throttleConfigureLength = 16

    /// The fixed on-wire size of one command, protocol.c's `commandSizes`
    /// table exactly; the SEND_* sizes are the header alone, a counted
    /// payload follows. Every number is here, the ones this client never
    /// sends included: a peer bundles several commands into one datagram, so
    /// a command that cannot be measured costs every command behind it.
    public static func size(ofCommand number: UInt8) -> Int? {
        switch number {
        case commandAcknowledge: acknowledgeLength
        case commandConnect: connectLength
        case commandVerifyConnect: verifyConnectLength
        case commandDisconnect: disconnectLength
        case commandPing: pingLength
        case commandSendReliable: sendReliableHeaderLength
        case commandSendUnreliable: sendUnreliableHeaderLength
        case commandSendFragment, commandSendUnreliableFragment: sendFragmentHeaderLength
        case commandSendUnsequenced: sendUnsequencedHeaderLength
        case commandBandwidthLimit: bandwidthLimitLength
        case commandThrottleConfigure: throttleConfigureLength
        default: nil
        }
    }

    /// Where, inside a SEND_* command's fixed header, the u16 count of the
    /// payload that follows it sits; nil for a command that carries none.
    public static func dataLengthOffset(ofCommand number: UInt8) -> Int? {
        switch number {
        case commandSendReliable: commandHeaderLength
        case commandSendUnreliable, commandSendUnsequenced, commandSendFragment, commandSendUnreliableFragment: commandHeaderLength + 2
        default: nil
        }
    }
}

/// One command's header: the command byte, the channel, the reliable sequence.
struct EnetCommandHeader: Equatable {
    let command: UInt8
    let channel: UInt8
    let reliableSequence: UInt16

    var number: UInt8 {
        command & EnetProtocol.commandMask
    }

    var wantsAcknowledge: Bool {
        command & EnetProtocol.flagAcknowledge != 0
    }
}

/// What the datagram header says about the whole datagram.
struct EnetDatagramHeader: Equatable {
    let peerId: UInt16
    let sessionId: UInt8
    let sentTime: UInt16?
    let compressed: Bool
}

enum EnetWire {
    /// The outer header: before VERIFY_CONNECT the peer field is 0xFFF with no
    /// session bits; after it, the host's id for us and its session id.
    static func header(outgoingPeerId: UInt16, outgoingSessionId: UInt8, sentTime: UInt16) -> ByteWriter {
        var writer = ByteWriter(capacity: 64)
        let assigned = outgoingPeerId < EnetProtocol.maximumPeerId
        var word = outgoingPeerId & EnetProtocol.maximumPeerId
        if assigned { word |= (UInt16(outgoingSessionId) << EnetProtocol.headerSessionShift) & EnetProtocol.headerSessionMask }
        word |= EnetProtocol.headerFlagSentTime
        writer.u16BE(word)
        writer.u16BE(sentTime)
        return writer
    }

    static func commandHeader(_ writer: inout ByteWriter, command: UInt8, channel: UInt8, reliableSequence: UInt16) {
        writer.u8(command)
        writer.u8(channel)
        writer.u16BE(reliableSequence)
    }

    static func readDatagramHeader(_ reader: inout ByteReader) -> EnetDatagramHeader? {
        guard let word = reader.u16BE() else { return nil }
        let compressed = word & EnetProtocol.headerFlagCompressed != 0
        let hasSentTime = word & EnetProtocol.headerFlagSentTime != 0
        var sentTime: UInt16?
        if hasSentTime {
            guard let time = reader.u16BE() else { return nil }
            sentTime = time
        }
        let sessionId = UInt8((word & EnetProtocol.headerSessionMask) >> EnetProtocol.headerSessionShift)
        return EnetDatagramHeader(
            peerId: word & EnetProtocol.maximumPeerId,
            sessionId: sessionId,
            sentTime: sentTime,
            compressed: compressed
        )
    }

    static func readCommandHeader(_ reader: inout ByteReader) -> EnetCommandHeader? {
        guard let command = reader.u8(), let channel = reader.u8(), let sequence = reader.u16BE() else { return nil }
        return EnetCommandHeader(command: command, channel: channel, reliableSequence: sequence)
    }
}
