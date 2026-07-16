// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import CryptoKit
import Darwin
import DishCore
import Foundation

/// Encrypted protocol-1 UDP data-plane session to a single Satellite server —
/// the Swift analogue of dish-linux `Network/SatelliteClient` and the Android
/// `satellite_jni` UDP path. Owns one raw POSIX UDP socket, the per-session
/// ChaCha20-Poly1305 key/token, monotonic per-direction counters (starting
/// at 1), a heartbeat timer and a receive loop.
///
/// Topology is REST-only in protocol-1: this class carries STREAMS only
/// (input, heartbeat, motion, battery, touchpad up; heartbeat-ack, rumble,
/// lightbar, session-close down). The deleted topology opcodes 0x0004–0x0008
/// and 0x000E have no constants anywhere in this target — a stray reference
/// fails to compile (PLAN D5).
///
/// Crypto is delegated to `DishCore.SessionCrypto` (frozen, byte-exact vs the
/// satellite): nonce = `dir(1) | 0x00×7 | counter(4 BE)`, AAD = token(4 BE),
/// key = the HKDF-derived SESSION key — the pairing key never reaches this
/// class (contract §Crypto, gaps G1/G2).
///
/// Thread-safety (PLAN D6 lock-bridges; gap G19):
///   * `sendReport` is called directly from the GameController callback
///     thread and stays lock-free outside one params snapshot + the `sendto`
///     under `sendLock`.
///   * Session params (`key`/`token`) live in a `LockedBox` so a proactive
///     re-key (G4) can swap them while the hot paths read.
///   * Loop flags / liveness / counters are `Atomic*` bridges; the fd is
///     mutated only under `sendLock` and the receive loop is joined (bounded)
///     before the fd closes.
final class SatelliteClient {

    // MARK: - Cadence (contract §Liveness)

    static let heartbeatIntervalMs = ProtocolConstants.heartbeatIntervalMs
    static let heartbeatMissMax = ProtocolConstants.heartbeatMissMax

    // MARK: - Session state

    /// Socket fd (−1 when closed). Written only under `sendLock`; readers
    /// snapshot it via `socketSnapshot()`.
    private var sock: Int32 = -1
    private var dest = sockaddr_in()
    /// Endpoint the socket is aimed at — a same-endpoint `setConnectionParams`
    /// (the G4 re-key) keeps the socket so the hot path never blips.
    private var boundHost = ""
    private var boundPort: UInt16 = 0

    /// Per-session AEAD material, swapped whole on every (re-)PUT.
    struct SessionParams {
        var key = SymmetricKey(data: Data(count: ProtocolConstants.cryptoKeySize))
        var token: UInt32 = 0
    }

    let params = LockedBox(SessionParams())

    /// Client→server counter; post-increment, so the first packet after a
    /// `reset()` rides counter 1 (contract §Crypto). `current()` feeds the
    /// manager's proactive re-key poll (gap G4).
    let counter = AtomicCounter()
    /// Server→client replay guard: highest counter successfully DECRYPTED
    /// (a forged header can't advance it). First packet exempt while 0 (G3).
    let lastRecvCounter = AtomicCounter()
    let sendLock = NSLock()

    let heartbeatRunning = AtomicBool(false)
    let heartbeatQueue = DispatchQueue(label: "dish.satellite.heartbeat", qos: .utility)
    var heartbeatTimer: DispatchSourceTimer?
    let ackQueue = DispatchQueue(label: "dish.satellite.ack", qos: .utility)
    let ackRunning = AtomicBool(false)
    /// Balances the receive loop so `closeSocket` can join it (bounded by the
    /// 500 ms recv timeout) before the fd closes — no recv on a reused fd.
    let receiveDrained = DispatchGroup()

    /// Consecutive un-ACKed heartbeats. Bumped on the heartbeat timer, zeroed
    /// on the receive queue.
    let missedAcks = AtomicInt(0)
    /// Liveness flag. Written from the heartbeat/receive queues, read from
    /// the `WifiConnection` alive tick.
    let connectionAlive = AtomicBool(true)

    /// Latest enriched heartbeat ack (epoch/bitmap/backend/count), polled by
    /// the 1 Hz alive tick for the reconcile loop (gap G9 parse side).
    private let lastHeartbeatAck = LockedBox<HeartbeatAck?>(nil)
    /// Latched SESSION_CLOSE reason byte, −1 while none (dish-linux
    /// `sessionCloseReason_`). Reset by `setConnectionParams`.
    let sessionCloseReason = AtomicInt(-1)

    /// One-way latency estimate off the heartbeat round trip (gap G13). The
    /// heartbeat timer arms the ping clock; the receive queue pairs acks.
    private let latencyLock = NSLock()
    private var latencyWindow = LatencyWindow()

    // MARK: - Callbacks out of the client (PLAN §4 seam)

    /// Fired on the receive queue for every parsed MSG_RUMBLE (0x0009).
    private let rumbleBox = LockedBox<((RumbleCommand) -> Void)?>(nil)
    var onRumble: ((RumbleCommand) -> Void)? {
        get { rumbleBox.get() }
        set { rumbleBox.set(newValue) }
    }

    /// Fired on the receive queue for every parsed MSG_LIGHTBAR (0x000D).
    private let lightbarBox = LockedBox<((LightbarCommand) -> Void)?>(nil)
    var onLightbar: ((LightbarCommand) -> Void)? {
        get { lightbarBox.get() }
        set { lightbarBox.set(newValue) }
    }

    /// Fired on the receive queue for an authenticated MSG_SESSION_CLOSE
    /// (0x000F); an unknown FUTURE reason byte degrades to `.shutdown` (the
    /// transient default arm, like the C++ ports). The client also drops
    /// `connectionAlive` so the alive tick reaps without the death wait
    /// (gap G10 parse side).
    private let sessionCloseBox = LockedBox<((CloseReason) -> Void)?>(nil)
    var onSessionClose: ((CloseReason) -> Void)? {
        get { sessionCloseBox.get() }
        set { sessionCloseBox.set(newValue) }
    }

    // MARK: - Lifecycle

    /// Install the post-PUT session material (PLAN §4 seam): aim the socket at
    /// `host:udpPort` (kept when unchanged — the re-key path), swap in the
    /// token + the HKDF-DERIVED session key, and restart every per-session
    /// mirror: counters back to 1/0, replay guard, liveness, enriched-ack
    /// snapshot, close latch, latency window. Call after every session PUT.
    ///
    /// Returns false (leaving the client closed) when the socket cannot be
    /// aimed at the endpoint. Endpoint CHANGES require the loops stopped —
    /// the manager builds a fresh client per connect; only a same-endpoint
    /// re-key happens live.
    @discardableResult
    func setConnectionParams(
        host: String,
        udpPort: UInt16,
        token: UInt32,
        sessionKey: SymmetricKey
    ) -> Bool {
        guard ensureSocket(host: host, udpPort: udpPort) else { return false }
        params.set(SessionParams(key: sessionKey, token: token))
        counter.reset()
        lastRecvCounter.set(0)
        missedAcks.set(0)
        connectionAlive.set(true)
        lastHeartbeatAck.set(nil)
        sessionCloseReason.set(-1)
        latencyLock.lock()
        latencyWindow.reset()
        latencyLock.unlock()
        return true
    }

    func closeSocket() {
        stopHeartbeat()
        stopReceiveLoop()
        sendLock.lock()
        defer { sendLock.unlock() }
        if sock >= 0 {
            close(sock)
            sock = -1
        }
        boundHost = ""
        boundPort = 0
    }

    deinit {
        // Safety net for the rare drop-without-markConnected path (the
        // connection torn down while openSession was in flight): both loop
        // stops are no-ops when never started, and the fd must not outlive
        // the client.
        closeSocket()
    }

    /// Open (or keep) the UDP socket aimed at `host:udpPort`. DSCP EF +
    /// no-SIGPIPE + 500 ms recv timeout, matching the sibling clients.
    private func ensureSocket(host: String, udpPort: UInt16) -> Bool {
        sendLock.lock()
        defer { sendLock.unlock() }
        if sock >= 0, host == boundHost, udpPort == boundPort { return true }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = udpPort.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if fd < 0 { return false }

        // DSCP EF (Expedited Forwarding). Best-effort: some Wi-Fi drivers
        // silently strip TOS but never error — matching the sibling clients.
        var tos: Int32 = 0xB8
        _ = setsockopt(fd, IPPROTO_IP, IP_TOS, &tos, socklen_t(MemoryLayout<Int32>.size))
        // Prevent SIGPIPE from killing the process if the server vanishes.
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        // 500 ms recv timeout so the receive loop can poll `ackRunning`.
        var rtv = timeval(tv_sec: 0, tv_usec: 500_000)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rtv, socklen_t(MemoryLayout<timeval>.size))

        if sock >= 0 { close(sock) }
        sock = fd
        dest = addr
        boundHost = host
        boundPort = udpPort
        return true
    }

    /// Run `body` with the fd + destination under `sendLock` — the send
    /// path's mutual exclusion with `closeSocket`, so a datagram can never
    /// race onto a closed (and possibly reused) fd.
    func withSocketLocked<T>(_ body: (Int32, sockaddr_in) -> T) -> T {
        sendLock.lock()
        defer { sendLock.unlock() }
        return body(sock, dest)
    }

    /// fd + destination snapshot for the receive path (fd mutation stays
    /// behind `sendLock`; the receive loop is joined before the fd closes).
    func socketSnapshot() -> (fd: Int32, dest: sockaddr_in) {
        withSocketLocked { fd, dest in (fd, dest) }
    }

    var isOpen: Bool {
        socketSnapshot().fd >= 0
    }

    // MARK: - Reconcile / re-key / latency snapshots (PLAN §4 seam)

    /// Latest enriched heartbeat ack, or nil before the first one this
    /// session. Thread-safe; polled by the 1 Hz alive tick.
    func heartbeatAckSnapshot() -> HeartbeatAck? {
        lastHeartbeatAck.get()
    }

    func storeHeartbeatAck(_ ack: HeartbeatAck) {
        lastHeartbeatAck.set(ack)
    }

    /// Current send counter (the last value used), for the proactive re-PUT
    /// guard `DishCore.counterNeedsRepush` (gap G4). Clamping, not
    /// truncating: past exhaustion the poll must keep reading "re-PUT
    /// needed", never wrap back under the threshold.
    var sendCounter: UInt32 {
        UInt32(clamping: counter.current())
    }

    /// Median heartbeat RTT halved (symmetric-path one-way estimate) + the
    /// sample count the UI shows beside the figure. Nil until the first
    /// paired ack; zeroed by `setConnectionParams` (gap G13).
    func latencySnapshot() -> (p50OneWayMs: Double?, samples: Int) {
        latencyLock.lock()
        defer { latencyLock.unlock() }
        return (latencyWindow.p50OneWayMs(), latencyWindow.sampleCount)
    }

    /// Stamp the single-in-flight ping clock (heartbeat timer). The 5 s loss
    /// reclaim + never-overwrite rule live in `DishCore.LatencyWindow`.
    func armLatencyPing(nowMs: Int64) {
        latencyLock.lock()
        defer { latencyLock.unlock() }
        latencyWindow.armPing(nowMs: nowMs)
    }

    /// Pair an arriving heartbeat ack with the in-flight ping (receive queue).
    func recordLatencyAck(nowMs: Int64) {
        latencyLock.lock()
        defer { latencyLock.unlock() }
        latencyWindow.ackReceived(nowMs: nowMs)
    }

    /// Monotonic milliseconds for the latency clock (never 0 in practice, so
    /// `LatencyWindow`'s 0-sentinel stays free).
    static func monotonicNowMs() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    // MARK: - Encrypted send: input (hot path)

    /// Called directly from the GCController callback thread for minimum
    /// latency. One `sendto` per report, no buffering. MSG_INPUT (0x0001):
    /// full-state snapshot per packet — never delta-encoded.
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
        sendEncrypted(
            msgType: ProtocolConstants.msgInput,
            payload: Encoders.inputPayload(
                controllerIndex: UInt8(truncatingIfNeeded: controllerIndex),
                buttons: buttons,
                lt: lt,
                rt: rt,
                lx: lx,
                ly: ly,
                rx: rx,
                ry: ry
            )
        )
    }

    // MARK: - Motion (IMU)

    /// Forward a single IMU sample (MSG_MOTION 0x000A). Scale: gyro ±2000
    /// deg/s, accel ±4 g over int16; right-handed frame, +X right, +Y up,
    /// +Z toward player — senders apply the rotation, receivers do not.
    /// `timestampDeltaUs` is µs since the previous motion packet for the same
    /// controller (0 on the first). Hot path: GCMotion callback thread.
    func sendMotion(
        controllerIndex: Int,
        gyroX: Int16, gyroY: Int16, gyroZ: Int16,
        accelX: Int16, accelY: Int16, accelZ: Int16,
        timestampDeltaUs: UInt32
    ) {
        sendEncrypted(
            msgType: ProtocolConstants.msgMotion,
            payload: Encoders.motionPayload(
                controllerIndex: UInt8(truncatingIfNeeded: controllerIndex),
                gyroX: gyroX,
                gyroY: gyroY,
                gyroZ: gyroZ,
                accelX: accelX,
                accelY: accelY,
                accelZ: accelZ,
                timestampDeltaUs: timestampDeltaUs
            )
        )
    }

    // MARK: - Battery

    /// Forward a battery snapshot (MSG_BATTERY 0x000B). `level` is 0...100,
    /// or `ProtocolConstants.batteryLevelUnknown` (0xFF) for status-only
    /// readers; senders with no battery information at all MUST NOT call.
    func sendBattery(controllerIndex: Int, level: UInt8, status: BatteryStatus) {
        sendEncrypted(
            msgType: ProtocolConstants.msgBattery,
            payload: Encoders.batteryPayload(
                controllerIndex: UInt8(truncatingIfNeeded: controllerIndex),
                level: level,
                status: status
            )
        )
    }

    // MARK: - Touchpad

    // One argument per wire field (contract §0x000C); a struct wrapper would
    // only add an indirection — same precedent as the sibling senders.
    // swiftlint:disable function_parameter_count

    /// Forward a touchpad sample (MSG_TOUCHPAD 0x000C) — the 16-byte
    /// protocol-1 payload incl. the trailing `eventTimeMs` (sender-side
    /// sample uptime, ms; u32 LE at offset 12). The server drops legacy
    /// 12-byte bodies (gap G12). Coordinates are normalised int16; the caller
    /// scales. Hot path: GameController touchpad callback thread.
    func sendTouchpad(
        controllerIndex: Int,
        finger0Active: Bool, finger0Id: UInt8, finger0X: Int16, finger0Y: Int16,
        finger1Active: Bool, finger1Id: UInt8, finger1X: Int16, finger1Y: Int16,
        buttonPressed: Bool,
        eventTimeMs: UInt32
    ) {
        sendEncrypted(
            msgType: ProtocolConstants.msgTouchpad,
            payload: Encoders.touchpadPayload(
                controllerIndex: UInt8(truncatingIfNeeded: controllerIndex),
                finger0Active: finger0Active,
                finger0Id: finger0Id,
                finger0X: finger0X,
                finger0Y: finger0Y,
                finger1Active: finger1Active,
                finger1Id: finger1Id,
                finger1X: finger1X,
                finger1Y: finger1Y,
                buttonPressed: buttonPressed,
                eventTimeMs: eventTimeMs
            )
        )
    }

    // swiftlint:enable function_parameter_count
}
