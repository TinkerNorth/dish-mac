// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The receive side: every command in a datagram is walked, the ones this
// client never sends included, because a peer packs acknowledgements and
// control commands together and a command that cannot be measured costs
// every command behind it. A live Sunshine host sends a reliable
// BANDWIDTH_LIMIT about a second after the peer connects; a client that
// bails on it never acknowledges it, the host's queue never empties, and
// the host drops the peer five seconds later.

import Foundation

extension EnetClient {
    /// Feed a received datagram; the acknowledgements to send come back and
    /// the host's reliable payloads land in `received`.
    public func onDatagram(_ datagram: Data) -> [Data] {
        var reader = ByteReader(datagram)
        guard let header = EnetWire.readDatagramHeader(&reader), !header.compressed, headerIsOurs(header) else { return [] }
        let time = now()
        var acks: [Data] = []
        while reader.remaining >= EnetProtocol.commandHeaderLength, let command = EnetWire.readCommandHeader(&reader) {
            guard handle(command, &reader, header: header, at: time, acks: &acks) else { break }
        }
        return acks
    }

    /// Before VERIFY_CONNECT the host addresses us as peer 0xFFF; after it,
    /// as peer 0 under the session it assigned, and anything else is a stale
    /// datagram from an earlier session on this port.
    private func headerIsOurs(_ header: EnetDatagramHeader) -> Bool {
        guard header.peerId == incomingPeerId || header.peerId == EnetProtocol.maximumPeerId else { return false }
        guard outgoingPeerId < EnetProtocol.maximumPeerId else { return true }
        return header.sessionId == incomingSessionId
    }

    /// One command: measure it, read its payload, act on the ones that
    /// matter, acknowledge it if it asks. False ends the walk.
    private func handle(
        _ command: EnetCommandHeader,
        _ reader: inout ByteReader,
        header: EnetDatagramHeader,
        at time: Int64,
        acks: inout [Data]
    ) -> Bool {
        guard let size = EnetProtocol.size(ofCommand: command.number) else {
            stats.unknownCommands += 1
            return false
        }
        guard let body = reader.take(size - EnetProtocol.commandHeaderLength),
              let payload = readPayload(command.number, body: body, &reader) else { return false }
        switch command.number {
        case EnetProtocol.commandVerifyConnect:
            guard verifyConnect(body, at: time) else { return false }
        case EnetProtocol.commandAcknowledge:
            guard acknowledge(command, body: body, at: time) else { return false }
        case EnetProtocol.commandSendReliable:
            guard state == .connected, command.channel == EnetProtocol.dataChannel else { return false }
            receiveReliable(sequence: command.reliableSequence, payload: payload)
        case EnetProtocol.commandDisconnect:
            giveUp("peer sent DISCONNECT")
        default:
            break
        }
        guard command.wantsAcknowledge else { return true }
        // The fork refuses to acknowledge a command that arrived without a
        // sent time and abandons the rest of the datagram; both ends then
        // agree on what was and was not acknowledged.
        guard let sentTime = header.sentTime else { return false }
        acks.append(buildAcknowledge(command, sentTime: sentTime, at: time))
        stats.acksSent += 1
        return true
    }

    /// The counted payload a SEND_* command carries after its fixed header;
    /// empty for the commands that carry none, nil when the datagram is short.
    private func readPayload(_ number: UInt8, body: Data, _ reader: inout ByteReader) -> Data? {
        guard let offset = EnetProtocol.dataLengthOffset(ofCommand: number) else { return Data() }
        var bodyReader = ByteReader(body)
        guard bodyReader.skip(offset - EnetProtocol.commandHeaderLength), let length = bodyReader.u16BE() else { return nil }
        return reader.take(Int(length))
    }

    /// The host's answer to CONNECT: its id for us, the session ids, and a
    /// smaller MTU or window if it wants one. The fork refuses a reply whose
    /// throttle parameters or connect id are not ours.
    private func verifyConnect(_ body: Data, at time: Int64) -> Bool {
        guard state == .connecting else { return true }
        var reader = ByteReader(body)
        guard let peerId = reader.u16BE(), let incoming = reader.u8(), let outgoing = reader.u8(),
              let theirMtu = reader.u32BE(), let theirWindow = reader.u32BE(), let channels = reader.u32BE(),
              reader.skip(8), let interval = reader.u32BE(), let acceleration = reader.u32BE(), let deceleration = reader.u32BE(),
              let theirConnectId = reader.u32BE() else { return false }
        guard (1 ... 255).contains(channels), interval == EnetProtocol.throttleInterval, acceleration == EnetProtocol.throttleAcceleration,
              deceleration == EnetProtocol.throttleDeceleration, theirConnectId == connectId else
        {
            giveUp("VERIFY_CONNECT names another connection")
            return false
        }
        outgoingPeerId = peerId
        incomingSessionId = incoming
        outgoingSessionId = outgoing
        mtu = min(mtu, max(EnetProtocol.minimumMtu, min(EnetProtocol.maximumMtu, theirMtu)))
        windowSize = min(windowSize, max(EnetProtocol.minimumWindowSize, min(EnetProtocol.maximumWindowSize, theirWindow)))
        sentReliable.removeAll { $0.channel == EnetProtocol.systemChannel && $0.reliableSequence == 1 }
        earliestTimeoutMs = 0
        lastReceiveMs = time
        state = .connected
        return true
    }

    /// The fork's enet_protocol_handle_acknowledge: the echoed sent time,
    /// widened against our clock, gives the round-trip sample; one from the
    /// future is ignored whole; then the smoothed estimate, every step rounded
    /// up as the fork rounds it, and the acknowledged command leaves the queue.
    private func acknowledge(_ command: EnetCommandHeader, body: Data, at time: Int64) -> Bool {
        var reader = ByteReader(body)
        guard let receivedSequence = reader.u16BE(), let receivedSentTime = reader.u16BE() else { return false }
        let elapsed = ((time & 0xFFFF) &- Int64(receivedSentTime)) & 0xFFFF
        guard elapsed <= 0x7FFF else { return true }
        sampleRoundTrip(max(elapsed, 1))
        lastReceiveMs = max(time, 1)
        earliestTimeoutMs = 0
        sentReliable.removeAll { $0.channel == command.channel && $0.reliableSequence == receivedSequence }
        return true
    }

    private func sampleRoundTrip(_ sample: Int64) {
        guard sampled else {
            roundTripTime = sample
            roundTripTimeVariance = (sample + 1) / 2
            sampled = true
            return
        }
        roundTripTimeVariance -= (roundTripTimeVariance + 3) / 4
        if sample >= roundTripTime {
            let difference = sample - roundTripTime
            roundTripTimeVariance += (difference + 3) / 4
            roundTripTime += (difference + 7) / 8
        } else {
            let difference = roundTripTime - sample
            roundTripTimeVariance += (difference + 3) / 4
            roundTripTime -= (difference + 7) / 8
        }
    }

    /// In-order delivery on the 16-bit ring, as the fork's reliable windows
    /// gate it: a command already delivered is acknowledged by the caller but
    /// not delivered twice; one ahead of its turn waits for the gap to fill;
    /// one too far ahead is discarded.
    private func receiveReliable(sequence: UInt16, payload: Data) {
        let window = sequence / EnetProtocol.reliableWindowSize + (sequence < incomingReliableSequence ? EnetProtocol.reliableWindows : 0)
        let currentWindow = incomingReliableSequence / EnetProtocol.reliableWindowSize
        guard window >= currentWindow, window < currentWindow + EnetProtocol.freeReliableWindows - 1 else { return }
        guard sequence != incomingReliableSequence, heldReliable[sequence] == nil else { return }
        let distance = sequence &- incomingReliableSequence
        guard distance <= 0x7FFF else { return }
        if distance > 1 {
            guard heldReliable.count < Self.heldReliableCeiling else { return }
            stats.heldOutOfOrder += 1
        }
        heldReliable[sequence] = payload
        while let next = heldReliable.removeValue(forKey: incomingReliableSequence &+ 1) {
            incomingReliableSequence &+= 1
            deliver(next)
        }
    }

    private func buildAcknowledge(_ command: EnetCommandHeader, sentTime: UInt16, at time: Int64) -> Data {
        var writer = ByteWriter(capacity: EnetProtocol.acknowledgeLength)
        EnetWire.commandHeader(
            &writer,
            command: EnetProtocol.commandAcknowledge,
            channel: command.channel,
            reliableSequence: command.reliableSequence
        )
        writer.u16BE(command.reliableSequence)
        writer.u16BE(sentTime)
        return wrap(writer.data, at: time)
    }
}
