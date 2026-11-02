// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import CryptoKit
import Darwin
import DishCore
import Foundation

/// A satellite's data plane on the loopback, as fast as one socket and one
/// thread allow: each uplink datagram is opened with the session key and kept
/// as its type, pad, right stick and arrival time; a heartbeat is answered
/// with its ack; rumble and light-bar commands go back to the port the client
/// sends from. For the bench and the lock-law test.
package final class LoopbackSatellite: @unchecked Sendable {
    /// One uplink datagram as it arrived, after its decrypt.
    package struct Arrival: Equatable {
        package let msgType: UInt16
        package let controllerIndex: UInt8
        package let rx: Int16
        package let ry: Int16
        package let ns: UInt64
    }

    private static let ackPayload = Data([1, 1, 0, 0, 0, 1])
    private static let rxOffset = 9
    private static let ryOffset = 11

    package let port: UInt16
    package let token: UInt32
    package let key: SymmetricKey
    private let fd: Int32
    private let capacity: Int
    private let arrivals: UnsafeMutablePointer<Arrival>
    private var recorded = 0
    private let downlink = Downlink()
    private let receiving = RunFlag()
    private let finished = DispatchSemaphore(value: 0)

    /// `capacity` arrivals are kept per run; later ones are dropped uncounted.
    package init(capacity: Int) throws {
        let socket = try LoopbackSocket()
        port = socket.port
        fd = socket.fd
        self.capacity = capacity
        token = UInt32.random(in: 1 ... UInt32.max)
        key = SymmetricKey(size: .bits256)
        arrivals = .allocate(capacity: capacity)
    }

    deinit {
        close(fd)
        arrivals.deallocate()
    }

    /// Starts a run on the satellite's own thread.
    package func start() {
        recorded = 0
        receiving.set(true)
        let thread = Thread { [self] in
            receiveLoop()
            finished.signal()
        }
        thread.name = "LoopbackSatellite"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Ends the run and hands back what arrived, in arrival order.
    package func stop() -> [Arrival] {
        receiving.set(false)
        finished.wait()
        return Array(UnsafeBufferPointer(start: arrivals, count: recorded))
    }

    /// Every downlink datagram that left: commands and heartbeat acks.
    package var downlinkSent: Int {
        downlink.sent
    }

    /// Nothing leaves until the client has sent once, since its port is
    /// learned then.
    package func sendRumble(controllerIndex: UInt8, strong: UInt16, weak: UInt16, durationMs: UInt16) {
        let payload = Data([controllerIndex] + bigEndian(strong) + bigEndian(weak) + bigEndian(durationMs))
        downlink.send(fd: fd, msgType: ProtocolConstants.msgRumble, payload: payload, key: key, token: token)
    }

    package func sendLightbar(controllerIndex: UInt8, red: UInt8, green: UInt8, blue: UInt8) {
        let payload = Data([controllerIndex, red, green, blue])
        downlink.send(fd: fd, msgType: ProtocolConstants.msgLightbar, payload: payload, key: key, token: token)
    }

    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: ProtocolConstants.udpDatagramMaxBytes)
        while receiving.get() {
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
            receive(Data(buffer[0 ..< count]), from: from)
        }
    }

    private func receive(_ datagram: Data, from address: sockaddr_in) {
        guard let (header, box) = PacketCodec.parse(datagram), header.token == token else { return }
        guard let plain = try? SessionCrypto.open(box, key: key, direction: .up, counter: header.counter, token: token),
              let inner = PacketCodec.parseInner(plain) else { return }
        let arrivedNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        downlink.learn(address)
        record(inner, at: arrivedNs)
        guard inner.msgType == ProtocolConstants.msgHeartbeat else { return }
        downlink.send(fd: fd, msgType: ProtocolConstants.msgHeartbeatAck, payload: Self.ackPayload, key: key, token: token)
    }

    private func record(_ inner: PacketCodec.InnerMessage, at arrivedNs: UInt64) {
        guard recorded < capacity else { return }
        let payload = inner.payload
        let carriesSticks = inner.msgType == ProtocolConstants.msgInput && payload.count >= ProtocolConstants.inputPayloadBytes
        let arrival = Arrival(
            msgType: inner.msgType,
            controllerIndex: payload.first ?? UInt8.max,
            rx: carriesSticks ? littleEndian16(payload, at: Self.rxOffset) : 0,
            ry: carriesSticks ? littleEndian16(payload, at: Self.ryOffset) : 0,
            ns: arrivedNs
        )
        (arrivals + recorded).initialize(to: arrival)
        recorded += 1
    }
}

private func bigEndian(_ value: UInt16) -> [UInt8] {
    [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
}

private func littleEndian16(_ data: Data, at offset: Int) -> Int16 {
    let low = UInt16(data[data.startIndex + offset])
    let high = UInt16(data[data.startIndex + offset + 1]) << 8
    return Int16(bitPattern: low | high)
}

/// The downlink's counter and the client's address, under one lock so the
/// counters leave in order. The harness's own locks stay untracked, out of
/// the counts they take.
private final class Downlink: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var counter: UInt32 = 0
    private var client: sockaddr_in?
    private var delivered = 0

    var sent: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return delivered
    }

    func learn(_ address: sockaddr_in) {
        os_unfair_lock_lock(&lock)
        if client == nil { client = address }
        os_unfair_lock_unlock(&lock)
    }

    /// Lost like any datagram when the socket refuses it.
    func send(fd: Int32, msgType: UInt16, payload: Data, key: SymmetricKey, token: UInt32) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard var destination = client else { return }
        counter &+= 1
        let inner = PacketCodec.innerFrame(msgType: msgType, payload: payload)
        guard let box = try? SessionCrypto.seal(inner, key: key, direction: .down, counter: counter, token: token) else { return }
        let datagram = PacketCodec.frame(token: token, counter: counter, box: box)
        let written = datagram.withUnsafeBytes { raw in
            withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    sendto(fd, raw.baseAddress, raw.count, 0, address, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if written == datagram.count { delivered += 1 }
    }
}

/// Whether the satellite's thread keeps receiving; untracked like `Downlink`.
private final class RunFlag: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var value = false

    func set(_ newValue: Bool) {
        os_unfair_lock_lock(&lock)
        value = newValue
        os_unfair_lock_unlock(&lock)
    }

    func get() -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return value
    }
}
