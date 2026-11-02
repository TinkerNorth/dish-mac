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
/// Thread-safety (gap G19), with no lock on the send or receive path:
///   * Every sender holds the send gate from claiming its counter to its
///     `sendto`, so the session's datagrams leave in counter order, and a
///     re-key (G4) or a socket change holds it too: no send seals under a
///     retiring key with a fresh counter, or writes to a closing fd.
///   * The receive loop takes each key generation and handler set through a
///     mailbox and reads into its own buffer; loop flags, liveness, the
///     replay guard, the fd and the send counter are atomic words, and the
///     receive loop is joined (bounded) before the fd closes.
final class SatelliteClient {

    // MARK: - Cadence (contract §Liveness)

    static let heartbeatIntervalMs = ProtocolConstants.heartbeatIntervalMs
    static let heartbeatMissMax = ProtocolConstants.heartbeatMissMax

    // MARK: - Session state

    /// Held by one sender from claiming a counter to its `sendto`, and by a
    /// re-key or a socket change.
    let gate = SendGate()
    /// The socket fd, −1 when closed: written under the gate, read by the
    /// senders under it and by the receive loop, which is joined first.
    private let fdWord = AtomicWord.allocate(-1)
    /// Under the gate.
    private var dest = sockaddr_in()
    /// Endpoint the socket is aimed at — a same-endpoint `setConnectionParams`
    /// (the G4 re-key) keeps the socket so the hot path never blips. Under the gate.
    private var boundHost = ""
    private var boundPort: UInt16 = 0
    /// The datagram's way out: `sendto`, or a test's stand-in.
    let sendDatagram: SocketSend

    /// The key and token the last session PUT installed: read and replaced
    /// only under the gate, where a re-key also restarts the counter, so no
    /// send pairs one generation's key with the other's counter.
    private var generation = SessionGeneration.unkeyed
    /// The last counter claimed, post-increment from 0 so a generation's
    /// first packet rides counter 1 (contract §Crypto): claimed under the
    /// gate, read anywhere by the re-key poll.
    private let sendCounterWord = AtomicWord.allocate()
    /// The version the session settled on, which picks the 0x000C shape:
    /// written by `setConnectionParams`, read by the touchpad sender.
    private let protocolVersionWord = AtomicWord.allocate(Int64(ProtocolConstants.protocolVersionWhenAbsent))
    /// Each new generation, for the receive loop.
    let generationMail = Mailbox<SessionGeneration>()
    /// Owned by the receive loop: the generation it opens datagrams under.
    var receiveGeneration = SessionGeneration.unkeyed

    init(sendDatagram: @escaping SocketSend = SatelliteClient.systemSend) {
        self.sendDatagram = sendDatagram
    }

    /// One packet's (key, token, sequence) drawn in one gate hold — the
    /// seal must never mix generations with a concurrent re-key swap.
    func nextSendMaterial() -> (key: SymmetricKey, token: UInt32, sequence: UInt64) {
        gate.hold { (generation.key, generation.token, claimCounter()) }
    }

    /// The caller holds the gate.
    private func claimCounter() -> UInt64 {
        UInt64(bitPattern: sendCounterWord.fetchAddRelaxed(1)) &+ 1
    }

    /// Server→client replay guard: highest counter successfully DECRYPTED
    /// (a forged header can't advance it). First packet exempt while 0 (G3).
    let lastRecvCounter = AtomicCounter()

    let heartbeatRunning = AtomicBool(false)
    let heartbeatQueue = ThreadRole.heartbeat.queue(label: "dish.satellite.heartbeat", qos: .userInteractive)
    var heartbeatTimer: DispatchSourceTimer?
    let ackQueue = ThreadRole.receive.queue(label: "dish.satellite.ack", qos: .userInteractive)
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

    /// Latest enriched heartbeat ack (epoch/bitmap/backend/count) packed in
    /// one word, zero while none: stored by the receive loop, polled by the
    /// 1 Hz alive tick for the reconcile loop (gap G9 parse side).
    private let heartbeatAckWord = AtomicWord.allocate()
    /// Latched SESSION_CLOSE reason byte, −1 while none (dish-linux
    /// `sessionCloseReason_`). Reset by `setConnectionParams`.
    let sessionCloseReason = AtomicInt(-1)

    /// One-way latency estimate off the heartbeat round trip (gap G13). The
    /// heartbeat timer arms the ping clock and the main actor reads it, under
    /// the lock; the receive loop only leaves each ack's arrival time.
    private var latencyLock = TrackedLock(NSLock(), "satellite.latency")
    private var latencyWindow = LatencyWindow()
    /// An ack's arrival time the window has not paired yet, zero while none:
    /// left by the receive loop, taken by whoever next holds `latencyLock`.
    private let pendingAckMs = AtomicWord.allocate()
    /// The receive loop's one datagram buffer, owned by the loop.
    let receiveBuffer = UnsafeMutableRawBufferPointer.allocate(
        byteCount: ProtocolConstants.udpDatagramMaxBytes,
        alignment: MemoryLayout<UInt64>.alignment
    )

    // MARK: - Callbacks out of the client (PLAN §4 seam)

    /// The handlers as their setters left them, set on the main actor and
    /// posted whole to the receive loop, which calls its own copy.
    private let handlerSet = LockedBox(ReceiveHandlers(), name: "satellite.handlers")
    private let handlerMail = Mailbox<ReceiveHandlersBox>()
    /// Owned by the receive loop: the set it calls, refreshed from the mail.
    var receiveHandlers = ReceiveHandlers()

    /// Fired on the receive queue for every parsed MSG_RUMBLE (0x0009).
    var onRumble: ((RumbleCommand) -> Void)? {
        get { handlerSet.get().rumble }
        set { updateHandlers { $0.rumble = newValue } }
    }

    /// Fired on the receive queue for every parsed MSG_LIGHTBAR (0x000D).
    var onLightbar: ((LightbarCommand) -> Void)? {
        get { handlerSet.get().lightbar }
        set { updateHandlers { $0.lightbar = newValue } }
    }

    /// Fired on the receive queue for every parsed MSG_TRIGGER_EFFECTS (0x0010).
    var onTriggerEffects: ((TriggerEffectsCommand) -> Void)? {
        get { handlerSet.get().triggerEffects }
        set { updateHandlers { $0.triggerEffects = newValue } }
    }

    /// Fired on the receive queue for every parsed MSG_PLAYER_LEDS (0x0011).
    var onPlayerLeds: ((PlayerLedsCommand) -> Void)? {
        get { handlerSet.get().playerLeds }
        set { updateHandlers { $0.playerLeds = newValue } }
    }

    /// Fired on the receive queue for every parsed MSG_SPEAKER_AUDIO (0x0013).
    var onSpeakerAudio: ((AudioFrame) -> Void)? {
        get { handlerSet.get().speakerAudio }
        set { updateHandlers { $0.speakerAudio = newValue } }
    }

    /// Fired on the receive queue for every parsed MSG_HAPTIC_AUDIO (0x0015).
    var onHapticAudio: ((AudioFrame) -> Void)? {
        get { handlerSet.get().hapticAudio }
        set { updateHandlers { $0.hapticAudio = newValue } }
    }

    /// Fired on the receive queue for every parsed MSG_MIC_LED (0x0014).
    var onMicLed: ((MicLedCommand) -> Void)? {
        get { handlerSet.get().micLed }
        set { updateHandlers { $0.micLed = newValue } }
    }

    /// Fired on the receive queue for an authenticated MSG_SESSION_CLOSE
    /// (0x000F); an unknown FUTURE reason byte degrades to `.shutdown` (the
    /// transient default arm, like the C++ ports). The client also drops
    /// `connectionAlive` so the alive tick reaps without the death wait
    /// (gap G10 parse side).
    var onSessionClose: ((CloseReason) -> Void)? {
        get { handlerSet.get().sessionClose }
        set { updateHandlers { $0.sessionClose = newValue } }
    }

    /// Changes the set and posts it whole: one post for any number of handlers.
    func updateHandlers(_ change: (inout ReceiveHandlers) -> Void) {
        handlerSet.mutate { handlers in
            change(&handlers)
            handlerMail.post(ReceiveHandlersBox(handlers))
        }
    }

    /// The receive loop's step before a dispatch: one relaxed load while no
    /// handler changed.
    func refreshReceiveHandlers() {
        if let fresh = handlerMail.take() { receiveHandlers = fresh.handlers }
    }

    // MARK: - Lifecycle

    /// Install the post-PUT session material (PLAN §4 seam): aim the socket at
    /// `host:udpPort` (kept when unchanged — the re-key path), swap in the
    /// token + the HKDF-DERIVED session key, and restart every per-session
    /// mirror: counters back to 1/0, replay guard, liveness, enriched-ack
    /// snapshot, close latch, latency window. Call after every session PUT.
    ///
    /// Returns false (leaving the client closed) when the socket cannot be
    /// aimed at the endpoint. An endpoint CHANGE stops and joins the loops
    /// before the old fd closes (the manager builds a fresh client per
    /// connect; only a same-endpoint re-key happens live) — the caller must
    /// restart them.
    @discardableResult
    func setConnectionParams(
        host: String,
        udpPort: UInt16,
        token: UInt32,
        sessionKey: SymmetricKey,
        protocolVersion: Int = ProtocolConstants.protocolVersionWhenAbsent
    ) -> Bool {
        guard ensureSocket(host: host, udpPort: udpPort) else { return false }
        let fresh = SessionGeneration(key: sessionKey, token: token)
        gate.hold {
            generation = fresh
            sendCounterWord.store(0)
        }
        protocolVersionWord.store(Int64(protocolVersion))
        generationMail.post(fresh)
        lastRecvCounter.set(0)
        missedAcks.set(0)
        connectionAlive.set(true)
        heartbeatAckWord.store(0)
        sessionCloseReason.set(-1)
        latencyLock.lock()
        pendingAckMs.store(0)
        latencyWindow.reset()
        latencyLock.unlock()
        return true
    }

    func closeSocket() {
        stopHeartbeat()
        stopReceiveLoop()
        let retired = gate.hold { () -> Int32 in
            boundHost = ""
            boundPort = 0
            return Int32(truncatingIfNeeded: fdWord.exchange(-1))
        }
        if retired >= 0 { close(retired) }
    }

    deinit {
        // Safety net for the rare drop-without-markConnected path (the
        // connection torn down while openSession was in flight): both loop
        // stops are no-ops when never started, and the fd must not outlive
        // the client.
        closeSocket()
        fdWord.deallocate()
        sendCounterWord.deallocate()
        protocolVersionWord.deallocate()
        heartbeatAckWord.deallocate()
        pendingAckMs.deallocate()
        receiveBuffer.deallocate()
    }

    /// Open (or keep) the UDP socket aimed at `host:udpPort`. DSCP EF +
    /// no-SIGPIPE + 500 ms recv timeout, matching the sibling clients.
    private func ensureSocket(host: String, udpPort: UInt16) -> Bool {
        let (alreadyBound, replacing) = gate.hold { () -> (Bool, Bool) in
            let open = fdWord.load() >= 0
            let same = open && host == boundHost && udpPort == boundPort
            return (same, open && !same)
        }
        if alreadyBound { return true }

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

        // Endpoint swap on an open client: the loops must stop and the
        // receive loop must be JOINED before its fd closes — the same
        // ordering `closeSocket` upholds (no recv on a reused fd).
        if replacing { closeSocket() }

        let stale = gate.hold { () -> Int32 in
            dest = addr
            boundHost = host
            boundPort = udpPort
            return Int32(truncatingIfNeeded: fdWord.exchange(Int64(fd)))
        }
        if stale >= 0 { close(stale) }
        return true
    }

    /// Whether the socket is open; a sender checks again under the gate.
    var isOpen: Bool {
        fdWord.load() >= 0
    }

    /// The fd the receive loop reads, which `closeSocket` joins before the
    /// fd closes.
    var receiveFd: Int32 {
        Int32(truncatingIfNeeded: fdWord.load())
    }

    /// The caller holds the gate: the fd, or −1, and where it sends.
    func sendTarget() -> (fd: Int32, dest: sockaddr_in) {
        (Int32(truncatingIfNeeded: fdWord.load()), dest)
    }

    /// The caller holds the gate: the next counter, with the generation it
    /// seals under.
    func claimSend() -> (generation: SessionGeneration, sequence: UInt64) {
        (generation, claimCounter())
    }

    // MARK: - Reconcile / re-key / latency snapshots (PLAN §4 seam)

    /// Latest enriched heartbeat ack, or nil before the first one this
    /// session. Thread-safe; polled by the 1 Hz alive tick.
    func heartbeatAckSnapshot() -> HeartbeatAck? {
        HeartbeatAck(packed: heartbeatAckWord.load())
    }

    func storeHeartbeatAck(_ ack: HeartbeatAck) {
        heartbeatAckWord.store(ack.packed)
    }

    /// Current send counter (the last value used), for the proactive re-PUT
    /// guard `DishCore.counterNeedsRepush` (gap G4). Clamping, not
    /// truncating: past exhaustion the poll must keep reading "re-PUT
    /// needed", never wrap back under the threshold.
    var sendCounter: UInt32 {
        UInt32(clamping: UInt64(bitPattern: sendCounterWord.load()))
    }

    /// Places the send counter, under the gate: production only ever
    /// restarts it; tests place it near a threshold without billions of sends.
    func placeSendCounter(_ value: UInt64) {
        gate.hold { sendCounterWord.store(Int64(bitPattern: value)) }
    }

    /// The settled version, for the touchpad frame's shape.
    var settledProtocolVersion: Int {
        Int(protocolVersionWord.loadRelaxed())
    }

    /// Median heartbeat RTT halved (symmetric-path one-way estimate) + the
    /// sample count the UI shows beside the figure. Nil until the first
    /// paired ack; zeroed by `setConnectionParams` (gap G13).
    func latencySnapshot() -> (p50OneWayMs: Double?, samples: Int) {
        latencyLock.lock()
        defer { latencyLock.unlock() }
        pairPendingAck()
        return (latencyWindow.p50OneWayMs(), latencyWindow.sampleCount)
    }

    /// The round trips the Diagnostics window shows.
    func latencySummary() -> LatencySummary {
        latencyLock.lock()
        defer { latencyLock.unlock() }
        pairPendingAck()
        return latencyWindow.summary()
    }

    /// Stamp the single-in-flight ping clock (heartbeat timer). The 5 s loss
    /// reclaim + never-overwrite rule live in `DishCore.LatencyWindow`.
    func armLatencyPing(nowMs: Int64) {
        latencyLock.lock()
        defer { latencyLock.unlock() }
        pairPendingAck()
        latencyWindow.armPing(nowMs: nowMs)
    }

    /// An arriving heartbeat ack (receive queue): its time waits for the next
    /// holder of the window to pair it with the in-flight ping. A second ack
    /// before then could only find the ping consumed, as the window decides.
    func recordLatencyAck(nowMs: Int64) {
        // An ack already waiting keeps its time; this one finds its ping consumed.
        _ = pendingAckMs.compareExchange(expected: 0, desired: max(nowMs, 1))
    }

    /// Pairs the ack the receive loop left, if any; the caller holds `latencyLock`.
    private func pairPendingAck() {
        let ackMs = pendingAckMs.exchange(0)
        if ackMs != 0 { latencyWindow.ackReceived(nowMs: ackMs) }
    }

    /// Monotonic milliseconds for the latency clock (never 0 in practice, so
    /// `LatencyWindow`'s 0-sentinel stays free).
    static func monotonicNowMs() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }
}
