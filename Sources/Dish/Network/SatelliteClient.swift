// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import CryptoKit
import Darwin
import Foundation

/// Encrypted UDP session to a single Satellite server — the Swift analogue of
/// `satellite_jni.cpp` on Android. Owns one raw POSIX socket, the ChaCha20
/// key/token, a monotonically-increasing nonce counter, a heartbeat sender
/// thread and an ACK receive thread.
///
/// Thread-safety:
///   * `sendReport` is called directly from the GameController callback thread
///     and must be lock-free on the hot path — we grab `sendLock` only for the
///     duration of one `sendto`.
///   * Every other mutating call is funneled through the public API which is
///     expected to run on the main actor or a background dispatch queue.
final class SatelliteClient {

    // MARK: - Message types (on-wire)

    private static let msgGamepadData: UInt16 = 0x0001
    private static let msgHeartbeatPing: UInt16 = 0x0002
    private static let msgHeartbeatAck: UInt16 = 0x0003
    private static let msgControllerAdd: UInt16 = 0x0004
    private static let msgControllerRemove: UInt16 = 0x0005
    private static let msgControllerAck: UInt16 = 0x0006
    private static let msgServerStatus: UInt16 = 0x0007
    private static let msgControllerType: UInt16 = 0x0008
    static let msgRumble: UInt16 = 0x0009

    /// Decoded `MSG_RUMBLE` payload. `lightbar*` are valid only when
    /// `hasLightbar` is true (the optional trailing 3-byte tail of the
    /// wire format).
    struct RumbleMessage {
        let controllerIndex: Int
        let strongMagnitude: UInt16
        let weakMagnitude: UInt16
        let durationMs: UInt16
        let hasLightbar: Bool
        let lightbarR: UInt8
        let lightbarG: UInt8
        let lightbarB: UInt8
    }

    static let heartbeatIntervalMs: UInt32 = 2000
    static let heartbeatMissMax = 5

    // MARK: - Session state

    var sock: Int32 = -1
    var dest = sockaddr_in()
    var token = [UInt8](repeating: 0, count: 4)
    private var key = SymmetricKey(data: Data(count: 32))
    var currentKey: SymmetricKey {
        key
    }

    let counter = AtomicCounter()
    let sendLock = NSLock()

    var heartbeatRunning = false
    let heartbeatQueue = DispatchQueue(label: "dish.satellite.heartbeat", qos: .utility)
    let ackQueue = DispatchQueue(label: "dish.satellite.ack", qos: .utility)
    var ackRunning = false

    var missedAcks = 0
    var connectionAlive = true
    /// Latest controller ACK packed as (requestType<<16)|(idx<<8)|result, or -1.
    var lastControllerAck: Int32 = -1
    var vigemAvailable: Int8 = -1
    var activeControllerCount: Int8 = -1

    /// Per-packet rumble dispatcher. Set from the main actor; invoked from
    /// the receive-loop dispatch queue. Guarded by `rumbleHandlerLock` so we
    /// can swap handlers without racing the receive loop.
    private var _rumbleHandler: ((RumbleMessage) -> Void)?
    private let rumbleHandlerLock = NSLock()
    var rumbleHandler: ((RumbleMessage) -> Void)? {
        get {
            rumbleHandlerLock.lock()
            defer { rumbleHandlerLock.unlock() }
            return _rumbleHandler
        }
        set {
            rumbleHandlerLock.lock()
            defer { rumbleHandlerLock.unlock() }
            _rumbleHandler = newValue
        }
    }

    // MARK: - Lifecycle

    /// Open a UDP socket aimed at `ip:port`. Returns `true` on success; on
    /// failure the client is left in a closed state and further calls no-op.
    @discardableResult
    func openSocket(ip: String, port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if fd < 0 { return false }

        // DSCP EF (Expedited Forwarding). macOS allows this without root on
        // loopback/LAN; on some Wi-Fi drivers it's silently dropped but never
        // errors — so treat failure as non-fatal, matching the Android JNI.
        var tos: Int32 = 0xB8
        _ = setsockopt(fd, IPPROTO_IP, IP_TOS, &tos, socklen_t(MemoryLayout<Int32>.size))

        // Prevent SIGPIPE from killing the process if the server vanishes mid-send.
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        // 500ms recv timeout — same as Android (so receiveAck loop can check cancel).
        var rtv = timeval(tv_sec: 0, tv_usec: 500_000)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rtv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        if inet_pton(AF_INET, ip, &addr.sin_addr) != 1 {
            close(fd)
            return false
        }

        self.sock = fd
        self.dest = addr
        return true
    }

    func closeSocket() {
        stopHeartbeat()
        ackRunning = false
        if sock >= 0 { close(sock)
            sock = -1
        }
    }

    /// Install the post-pair token + shared key. Resets the counter/ACK state.
    func setConnectionParams(token: Data, key: Data) {
        guard token.count == 4, key.count == 32 else { return }
        self.token = Array(token)
        self.key = SymmetricKey(data: key)
        counter.reset()
        missedAcks = 0
        connectionAlive = true
        lastControllerAck = -1
    }

    // MARK: - Encrypted send (hot path)

    /// Called directly from the GCController callback thread for minimum
    /// latency. One `sendto` per report, no buffering.
    func sendReport(
        controllerIndex: Int,
        buttons: UInt16,
        lt: UInt8,
        rt: UInt8,
        lx: Int16,
        ly: Int16,
        rx: Int16,
        ry: Int16
    ) {
        // Payload: controllerIndex(1) + XUSB_REPORT(12) = 13 bytes.
        var payload = [UInt8](repeating: 0, count: 13)
        payload[0] = UInt8(truncatingIfNeeded: controllerIndex)
        payload.withUnsafeMutableBufferPointer { buf in
            // XUSB_REPORT is little-endian on the wire.
            buf[1] = UInt8(truncatingIfNeeded: buttons)
            buf[2] = UInt8(truncatingIfNeeded: buttons >> 8)
            buf[3] = lt
            buf[4] = rt
            storeLE16(Int16(bitPattern: UInt16(lx) & 0xFFFF), into: buf, at: 5)
            storeLE16(ly, into: buf, at: 7)
            storeLE16(rx, into: buf, at: 9)
            storeLE16(ry, into: buf, at: 11)
        }
        sendEncrypted(msgType: Self.msgGamepadData, payload: payload)
    }

    private func storeLE16(_ value: Int16, into buf: UnsafeMutableBufferPointer<UInt8>, at offset: Int) {
        let unsigned = UInt16(bitPattern: value)
        buf[offset] = UInt8(truncatingIfNeeded: unsigned)
        buf[offset + 1] = UInt8(truncatingIfNeeded: unsigned >> 8)
    }

    func controllerAdd(index: Int, capabilities: UInt16) {
        var payload = [UInt8](repeating: 0, count: 3)
        payload[0] = UInt8(truncatingIfNeeded: index)
        putBE16(capabilities, into: &payload, at: 1)
        sendEncrypted(msgType: Self.msgControllerAdd, payload: payload)
    }

    func controllerRemove(index: Int) {
        sendEncrypted(
            msgType: Self.msgControllerRemove,
            payload: [UInt8(truncatingIfNeeded: index)]
        )
    }

    func sendControllerType(index: Int, type: Int) {
        sendEncrypted(
            msgType: Self.msgControllerType,
            payload: [
                UInt8(truncatingIfNeeded: index),
                UInt8(truncatingIfNeeded: type)
            ]
        )
    }

    func resetControllerAck() {
        lastControllerAck = -1
    }
}
