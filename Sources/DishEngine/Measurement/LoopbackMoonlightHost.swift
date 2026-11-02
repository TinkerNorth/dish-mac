// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import CryptoKit
import Darwin
import DishCore
import Foundation
import os

/// A Moonlight host's control port on the loopback, as far as a session needs
/// one and as fast as one socket and one thread allow: CONNECT is answered
/// with VERIFY_CONNECT, every command that asks is acknowledged, and every
/// sealed packet is opened with the session's rikey and kept as the host read
/// it, stamped after the decrypt. Its rumble and RGB-LED events go back sealed
/// as its own reliable commands. For the bench and the lock-law test; its lock
/// is untracked, out of the counts it takes.
package final class LoopbackMoonlightHost: Sendable {
    /// One command the peer sent, as the host read it. A sealed packet that
    /// opened adds its control sequence and plaintext type, an input packet
    /// its input type and the pad it names, a CONTROLLER_MULTI its right
    /// stick's X.
    package struct Received: Equatable {
        package var command: UInt8
        package var channel: UInt8
        package var reliableSequence: UInt16
        package var seq: UInt32?
        package var type: UInt16?
        package var inputType: UInt32?
        package var controller: UInt16?
        package var rightX: Int16 = 0
        package var ns: UInt64 = 0

        /// The command's number, its flags masked off.
        package var number: UInt8 {
            command & EnetProtocol.commandMask
        }
    }

    /// The id the host gives its peer and the session it opens for it.
    static let peerId: UInt16 = 0x42
    static let sessionId: UInt8 = 2
    private static let rikeyBytes = 16
    /// Where a CONNECT's connect id sits in its body, past the peer id, the
    /// session ids and eight u32 limits.
    private static let connectIdOffset = 36
    /// Where a sealed packet carries its control sequence, past its type and length.
    private static let controlSeqOffset = 4

    package let port: UInt16
    /// The key a launch would have minted, for the session to seal with.
    package let rikey: Data
    private let key: SymmetricKey
    private let fd: Int32
    private let running = AtomicBool(false)
    private let finished = DispatchSemaphore(value: 0)
    private let delivered = AtomicCounter()
    private let state: OSAllocatedUnfairLock<HostState>

    /// `capacity` commands are kept between takes; later ones are dropped uncounted.
    package init(capacity: Int) throws {
        let socket = try LoopbackSocket()
        let rikey = Data((0 ..< Self.rikeyBytes).map { _ in UInt8.random(in: .min ... .max) })
        port = socket.port
        fd = socket.fd
        self.rikey = rikey
        key = SymmetricKey(data: rikey)
        state = OSAllocatedUnfairLock(initialState: HostState(capacity: capacity, rikey: rikey))
    }

    deinit {
        close(fd)
    }

    /// Every datagram that left whole: answers, acknowledgements and events.
    package var datagramsSent: Int {
        Int(delivered.current())
    }

    /// Starts the host's own thread.
    package func start() {
        guard !running.getAndSet(true) else { return }
        let thread = Thread { [self] in
            receiveLoop()
            finished.signal()
        }
        thread.name = "LoopbackMoonlightHost"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops the thread and waits for it.
    package func stop() {
        guard running.getAndSet(false) else { return }
        finished.wait()
    }

    /// What the peer sent since the last take, in arrival order.
    package func take() -> [Received] {
        state.withLock { held in
            let taken = held.received
            held.received.removeAll(keepingCapacity: true)
            return taken
        }
    }

    /// Forgets what arrived so far: the next take starts here.
    package func clear() {
        state.withLock { $0.received.removeAll(keepingCapacity: true) }
    }

    /// RUMBLE_DATA for one pad: an unused word, the pad, the low and the high motor.
    package func sendRumble(controller: UInt16, low: UInt16, high: UInt16) {
        var plaintext = ByteWriter(capacity: 14)
        plaintext.u16LE(MoonlightProtocol.eventRumbleData)
        plaintext.u16LE(10)
        plaintext.u32LE(0)
        plaintext.u16LE(controller)
        plaintext.u16LE(low)
        plaintext.u16LE(high)
        sendEvent(plaintext.data)
    }

    /// RGB_LED for one pad.
    package func sendRgbLed(controller: UInt16, red: UInt8, green: UInt8, blue: UInt8) {
        var plaintext = ByteWriter(capacity: 9)
        plaintext.u16LE(MoonlightProtocol.eventRgbLed)
        plaintext.u16LE(5)
        plaintext.u16LE(controller)
        plaintext.u8(red)
        plaintext.u8(green)
        plaintext.u8(blue)
        sendEvent(plaintext.data)
    }

    /// One event sealed as the host's next reliable command on channel 0,
    /// sent under the lock so the sequences leave in order; nothing leaves
    /// before the peer has connected.
    private func sendEvent(_ plaintext: Data) {
        let fd = fd
        let delivered = delivered
        state.withLock { held in
            guard let peer = held.peer, let sealed = held.sealer.seal(plaintext) else { return }
            held.outgoingReliable &+= 1
            var writer = hostHeader()
            EnetWire.commandHeader(
                &writer,
                command: EnetProtocol.commandSendReliable | EnetProtocol.flagAcknowledge,
                channel: EnetProtocol.dataChannel,
                reliableSequence: held.outgoingReliable
            )
            writer.u16BE(UInt16(truncatingIfNeeded: sealed.count))
            writer.append(sealed)
            if sendDatagram(writer.data, fd: fd, to: peer) { delivered.increment() }
        }
    }

    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: Int(EnetProtocol.maximumMtu))
        while running.get() {
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &from) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                        recvfrom(fd, raw.baseAddress, raw.count, 0, address, &fromLength)
                    }
                }
            }
            guard count > 0 else { continue }
            handle(Data(buffer[0 ..< count]), from: LoopbackPeer(from))
        }
    }

    /// Every command in the datagram is walked, as the fork walks them, and
    /// each one that asks is acknowledged with the datagram's sent time.
    private func handle(_ datagram: Data, from peer: LoopbackPeer) {
        var reader = ByteReader(datagram)
        guard let header = EnetWire.readDatagramHeader(&reader), !header.compressed else { return }
        while reader.remaining >= EnetProtocol.commandHeaderLength, let command = EnetWire.readCommandHeader(&reader) {
            guard let size = EnetProtocol.size(ofCommand: command.number),
                  let body = reader.take(size - EnetProtocol.commandHeaderLength),
                  let payload = countedPayload(command.number, body: body, &reader) else { return }
            act(on: command, body: body, payload: payload, from: peer)
            if command.wantsAcknowledge, let sentTime = header.sentTime {
                reply(acknowledgement(of: command, sentTime: sentTime), to: peer)
            }
        }
    }

    /// The counted payload a SEND_* command carries after its fixed header;
    /// empty for the commands that carry none, nil when the datagram is short.
    private func countedPayload(_ number: UInt8, body: Data, _ reader: inout ByteReader) -> Data? {
        guard let offset = EnetProtocol.dataLengthOffset(ofCommand: number) else { return Data() }
        var bodyReader = ByteReader(body)
        guard bodyReader.skip(offset - EnetProtocol.commandHeaderLength), let length = bodyReader.u16BE() else { return nil }
        return reader.take(Int(length))
    }

    private func act(on command: EnetCommandHeader, body: Data, payload: Data, from peer: LoopbackPeer) {
        var received = Received(command: command.command, channel: command.channel, reliableSequence: command.reliableSequence)
        switch command.number {
        case EnetProtocol.commandConnect:
            answerConnect(body, from: peer)
        case EnetProtocol.commandSendReliable:
            read(sealed: payload, into: &received)
        default:
            break
        }
        received.ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let kept = received
        state.withLock { $0.keep(kept) }
    }

    /// The host's answer to CONNECT: its id for the peer, the session it
    /// opened, its limits, and the peer's connect id echoed. The address it
    /// came from is where the events go.
    private func answerConnect(_ connect: Data, from peer: LoopbackPeer) {
        var reader = ByteReader(connect)
        guard reader.skip(Self.connectIdOffset), let connectId = reader.u32BE() else { return }
        state.withLock { $0.peer = peer }
        var writer = hostHeader()
        EnetWire.commandHeader(
            &writer,
            command: EnetProtocol.commandVerifyConnect | EnetProtocol.flagAcknowledge,
            channel: EnetProtocol.systemChannel,
            reliableSequence: 1
        )
        writer.u16BE(Self.peerId)
        writer.u8(Self.sessionId)
        writer.u8(Self.sessionId)
        for limit in [EnetProtocol.defaultMtu, EnetProtocol.maximumWindowSize, EnetProtocol.channelCount, 0, 0] {
            writer.u32BE(limit)
        }
        for throttle in [EnetProtocol.throttleInterval, EnetProtocol.throttleAcceleration, EnetProtocol.throttleDeceleration] {
            writer.u32BE(throttle)
        }
        writer.u32BE(connectId)
        reply(writer.data, to: peer)
    }

    /// A sealed control packet opened with the session key, stamped once it
    /// is; one that does not open keeps only its ENet fields.
    private func read(sealed packet: Data, into received: inout Received) {
        guard case let .plaintext(plaintext) = MoonlightControlPacket.open(key: key, packet: packet) else { return }
        var header = ByteReader(packet)
        var reader = ByteReader(plaintext)
        guard header.skip(Self.controlSeqOffset), let seq = header.u32LE(), let type = reader.u16LE() else { return }
        received.seq = seq
        received.type = type
        // The length and the big-endian data size stand between the type and the input type.
        guard type == MoonlightProtocol.packetInputData, reader.skip(6), let inputType = reader.u32LE() else { return }
        received.inputType = inputType
        switch inputType {
        case MoonlightInputType.controllerMulti:
            // The header word, then the pad; its mask, the middle word, the
            // buttons, the triggers and the left stick stand before the right X.
            guard reader.skip(2), let controller = reader.u16LE(), reader.skip(12), let rightX = reader.u16LE() else { return }
            received.controller = controller
            received.rightX = Int16(bitPattern: rightX)
        case MoonlightInputType.controllerArrival, MoonlightInputType.controllerTouch, MoonlightInputType.controllerMotion,
             MoonlightInputType.controllerBattery:
            received.controller = reader.u8().map(UInt16.init)
        default:
            break
        }
    }

    private func reply(_ datagram: Data, to peer: LoopbackPeer) {
        if sendDatagram(datagram, fd: fd, to: peer) { delivered.increment() }
    }

    private func acknowledgement(of command: EnetCommandHeader, sentTime: UInt16) -> Data {
        var writer = hostHeader()
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
}

/// What the receive thread and the senders of events share, under the host's lock.
private struct HostState {
    let capacity: Int
    var received: [LoopbackMoonlightHost.Received] = []
    var sealer: MoonlightControlSealer
    var peer: LoopbackPeer?
    var outgoingReliable: UInt16 = 0

    init(capacity: Int, rikey: Data) {
        self.capacity = capacity
        sealer = MoonlightControlSealer(rikey: rikey)
        received.reserveCapacity(capacity)
    }

    mutating func keep(_ command: LoopbackMoonlightHost.Received) {
        guard received.count < capacity else { return }
        received.append(command)
    }
}

/// Where a datagram came from, and so where the answer goes.
private struct LoopbackPeer {
    let address: in_addr_t
    let port: in_port_t

    init(_ from: sockaddr_in) {
        address = from.sin_addr.s_addr
        port = from.sin_port
    }

    var socketAddress: sockaddr_in {
        var socketAddress = sockaddr_in()
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_addr.s_addr = address
        socketAddress.sin_port = port
        return socketAddress
    }
}

/// The datagram header the host sends under: it is peer 0 to the client,
/// under the session it opened, with its own clock as the sent time.
private func hostHeader() -> ByteWriter {
    let nowMs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1_000_000
    return EnetWire.header(
        outgoingPeerId: 0,
        outgoingSessionId: LoopbackMoonlightHost.sessionId,
        sentTime: UInt16(truncatingIfNeeded: nowMs)
    )
}

/// True when the whole datagram left; a refused one is lost like any datagram.
private func sendDatagram(_ datagram: Data, fd: Int32, to peer: LoopbackPeer) -> Bool {
    var destination = peer.socketAddress
    let written = datagram.withUnsafeBytes { raw in
        withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { target in
                sendto(fd, raw.baseAddress, raw.count, 0, target, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
    return written == datagram.count
}
