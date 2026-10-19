// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// A Moonlight host's control port on loopback, as far as a session needs one:
// the ENet handshake answered, every reliable command acknowledged, each sealed
// packet opened with the session's rikey and recorded by kind, and the host's
// own events sent back sealed. One peer at a time, as a host's port has one.

import CryptoKit
import Foundation
import Network
@testable import DishCore

final class FakeMoonlightControlHost: @unchecked Sendable {
    struct Arrival: Equatable {
        let number: UInt8
        let type: UInt8
        let capabilities: UInt8
        let buttons: UInt32
    }

    struct Frame: Equatable {
        let number: UInt16
        let mask: UInt16
        let buttons: UInt32
    }

    /// What the peer sent, opened and sorted by kind.
    struct Seen: Equatable {
        var connects = 0
        var pings = 0
        var keepalives = 0
        var terminations = 0
        var disconnects = 0
        var unopened = 0
        var arrivals: [Arrival] = []
        var frames: [Frame] = []
    }

    /// The id this host gives its peer and the session it opens for it.
    static let peerId: UInt16 = 0x42
    static let sessionId: UInt8 = 2

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dish.test.moonlight-control-host")
    private var listener: NWListener?
    private var peer: NWConnection?
    private var key: SymmetricKey?
    private var sealer: MoonlightControlSealer?
    private var outgoingReliable: UInt16 = 0
    private var seen = Seen()
    private(set) var port: UInt16 = 0

    /// The session key the launch minted; the packets open with it from here on.
    func adopt(rikey: Data) {
        lock.lock()
        key = SymmetricKey(data: rikey)
        sealer = MoonlightControlSealer(rikey: rikey)
        lock.unlock()
    }

    func start() throws -> UInt16 {
        let params = NWParameters.udp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            lock.lock()
            let previous = peer
            peer = connection
            lock.unlock()
            previous?.cancel()
            connection.start(queue: queue)
            receive(connection)
        }
        port = try FakeSatelliteNet.startAndAwaitReady(listener, queue: queue)
        self.listener = listener
        return port
    }

    func stop() {
        listener?.cancel()
        lock.lock()
        let open = peer
        peer = nil
        lock.unlock()
        open?.cancel()
    }

    func snapshot() -> Seen {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    /// One of the host's events, sealed and sent as its next reliable command.
    func sendEvent(_ plaintext: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard let peer, let sealed = sealer?.seal(plaintext) else { return }
        outgoingReliable &+= 1
        var writer = EnetWire.header(outgoingPeerId: 0, outgoingSessionId: Self.sessionId, sentTime: Self.clock())
        EnetWire.commandHeader(
            &writer,
            command: EnetProtocol.commandSendReliable | EnetProtocol.flagAcknowledge,
            channel: EnetProtocol.dataChannel,
            reliableSequence: outgoingReliable
        )
        writer.u16BE(UInt16(sealed.count))
        writer.append(sealed)
        peer.send(content: writer.data, completion: .contentProcessed { _ in })
    }

    // MARK: - The peer's datagrams

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data { handle(data, from: connection) }
            receive(connection)
        }
    }

    /// Every command in the datagram is walked, as the fork walks them; a
    /// CONNECT is answered with VERIFY_CONNECT and anything asking for an
    /// acknowledgement gets one.
    private func handle(_ datagram: Data, from connection: NWConnection) {
        var reader = ByteReader(datagram)
        guard let header = EnetWire.readDatagramHeader(&reader), let sentTime = header.sentTime else { return }
        var replies: [Data] = []
        while reader.remaining >= EnetProtocol.commandHeaderLength, let command = EnetWire.readCommandHeader(&reader) {
            guard let size = EnetProtocol.size(ofCommand: command.number),
                  let body = reader.take(size - EnetProtocol.commandHeaderLength) else { break }
            let payload = countedPayload(command.number, body: body, &reader)
            if let reply = act(on: command, body: body, payload: payload, sentTime: sentTime) { replies.append(reply) }
        }
        for reply in replies {
            connection.send(content: reply, completion: .contentProcessed { _ in })
        }
    }

    private func countedPayload(_ number: UInt8, body: Data, _ reader: inout ByteReader) -> Data {
        guard let offset = EnetProtocol.dataLengthOffset(ofCommand: number) else { return Data() }
        var bodyReader = ByteReader(body)
        guard bodyReader.skip(offset - EnetProtocol.commandHeaderLength), let length = bodyReader.u16BE() else { return Data() }
        return reader.take(Int(length)) ?? Data()
    }

    private func act(on command: EnetCommandHeader, body: Data, payload: Data, sentTime: UInt16) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        switch command.number {
        case EnetProtocol.commandConnect:
            seen.connects += 1
            return verifyConnect(echoing: body)
        case EnetProtocol.commandSendReliable:
            record(payload)
        case EnetProtocol.commandPing:
            seen.pings += 1
        case EnetProtocol.commandDisconnect:
            seen.disconnects += 1
        default:
            break
        }
        guard command.wantsAcknowledge else { return nil }
        return acknowledge(command, sentTime: sentTime)
    }

    /// The host's answer to CONNECT: its id for the peer, the session it
    /// opened, its limits, and the peer's connect id echoed, which the peer
    /// checks before it goes live.
    private func verifyConnect(echoing connect: Data) -> Data {
        var reader = ByteReader(connect)
        _ = reader.skip(36)
        let connectId = reader.u32BE() ?? 0
        var writer = EnetWire.header(outgoingPeerId: 0, outgoingSessionId: Self.sessionId, sentTime: Self.clock())
        EnetWire.commandHeader(
            &writer,
            command: EnetProtocol.commandVerifyConnect | EnetProtocol.flagAcknowledge,
            channel: EnetProtocol.systemChannel,
            reliableSequence: 1
        )
        writer.u16BE(Self.peerId)
        writer.u8(Self.sessionId)
        writer.u8(Self.sessionId)
        writer.u32BE(EnetProtocol.defaultMtu)
        writer.u32BE(EnetProtocol.maximumWindowSize)
        writer.u32BE(EnetProtocol.channelCount)
        writer.u32BE(0)
        writer.u32BE(0)
        writer.u32BE(EnetProtocol.throttleInterval)
        writer.u32BE(EnetProtocol.throttleAcceleration)
        writer.u32BE(EnetProtocol.throttleDeceleration)
        writer.u32BE(connectId)
        return writer.data
    }

    private func acknowledge(_ command: EnetCommandHeader, sentTime: UInt16) -> Data {
        var writer = EnetWire.header(outgoingPeerId: 0, outgoingSessionId: Self.sessionId, sentTime: Self.clock())
        EnetWire.commandHeader(
            &writer,
            command: EnetProtocol.commandAcknowledge,
            channel: command.channel,
            reliableSequence: command.reliableSequence
        )
        writer.u16BE(command.reliableSequence)
        writer.u16BE(sentTime)
        return writer.data
    }

    /// A sealed control packet, opened and filed: the keepalive, the goodbye,
    /// or an input packet by its kind.
    private func record(_ sealed: Data) {
        guard let key, case let .plaintext(plain) = MoonlightControlPacket.open(key: key, packet: sealed) else {
            seen.unopened += 1
            return
        }
        var reader = ByteReader(Data(plain))
        switch reader.u16LE() {
        case MoonlightProtocol.packetTermination: seen.terminations += 1
        case MoonlightProtocol.packetPeriodicPing: seen.keepalives += 1
        case MoonlightProtocol.packetInputData: recordInput(Data(plain))
        default: break
        }
    }

    private func recordInput(_ plain: Data) {
        var reader = ByteReader(plain)
        guard reader.skip(8), let inputType = reader.u32LE() else { return }
        switch inputType {
        case MoonlightInputType.controllerArrival:
            guard let number = reader.u8(), let type = reader.u8(), let capabilities = reader.u8(), reader.skip(1),
                  let buttons = reader.u32LE() else { return }
            seen.arrivals.append(Arrival(number: number, type: type, capabilities: capabilities, buttons: buttons))
        case MoonlightInputType.controllerMulti:
            // headerA, number, mask, midB, buttons; then the triggers, the four
            // sticks and tailA before buttonFlags2.
            guard reader.skip(2), let number = reader.u16LE(), let mask = reader.u16LE(), reader.skip(2), let low = reader.u16LE(),
                  reader.skip(12), let high = reader.u16LE() else { return }
            seen.frames.append(Frame(number: number, mask: mask, buttons: UInt32(low) | UInt32(high) << 16))
        default:
            break
        }
    }

    private static func clock() -> UInt16 {
        UInt16(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }
}
