// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The Moonlight control stream: the ENet handshake, the sealed reliable
// sends (pads, touch, motion, battery, the mouse, the keepalive, the
// termination) and the host's events back. The pure pieces (EnetClient,
// MoonlightControlPacket, decodeMoonlightEvent) are composed over a
// swappable transport and a swappable cipher, so the whole lifecycle tests
// with a fake transport and a controlled clock; production plugs in a UDP
// socket and AES-GCM under the session's rikey.
//
// ONE LOCK OVER THE ENET CLIENT, AND ONLY ITS BOOKKEEPING UNDER IT. Input
// arrives on the controller threads while datagrams and the tick arrive on
// their queues, and all of them reach the same ENet client, which is not
// thread-safe. The crypto stays outside: every outbound packet claims its
// control sequence, the AES-GCM IV, from one atomic counter before it is
// sealed, so two threads can never seal under one IV, and the host's packets
// are taken out under the lock and opened after it. Events are dispatched
// outside the lock: a rumble sink is somebody else's code.

import CryptoKit
import DishCore
import Foundation

/// The datagram plumbing under the session: a UDP socket in production.
/// Datagrams from the host arrive on `onDatagram`, from one queue.
protocol MoonlightControlTransport: AnyObject {
    var onDatagram: ((Data) -> Void)? { get set }
    func send(_ datagram: Data)
    func close()
}

/// The control stream's crypto under one session's key: the seal of an
/// outbound packet under the control sequence it claimed, and the open of a
/// host packet under the sequence it carries.
struct MoonlightControlCipher {
    let seal: (_ seq: UInt32, _ plaintext: Data) -> Data?
    let open: (_ packet: Data) -> MoonlightControlPacket.Opened

    /// AES-GCM under the rikey, the key made once for the session.
    static func aesGcm(rikey: Data) -> MoonlightControlCipher {
        let key = SymmetricKey(data: rikey)
        return MoonlightControlCipher(
            seal: { seq, plaintext in MoonlightControlPacket.seal(key: key, seq: seq, plaintext: plaintext) },
            open: { packet in MoonlightControlPacket.open(key: key, packet: packet) }
        )
    }
}

final class MoonlightControlSession: @unchecked Sendable {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case closed
    }

    static let handshakeTimeoutMs: Int64 = 5000
    static let handshakePollMs: Int64 = 100
    static let pingIntervalMs: Int64 = 500

    private let transport: MoonlightControlTransport
    private let now: () -> Int64
    private let onEvent: (MoonlightEvent) -> Void
    private let onClosed: () -> Void
    private let cipher: MoonlightControlCipher
    /// The sequences the session's packets have claimed: one atomic step per
    /// packet, so a claim needs no lock and no two packets share one.
    private let sequencesClaimed = AtomicCounter()
    /// Whether a send goes out at all, read before it claims a sequence;
    /// written with the state, under the lock.
    private let sending = AtomicBool(false)
    private var lock = TrackedLock(os_unfair_lock_s(), "moonlight.session")
    private let enet: EnetClient
    private var stateValue = State.idle
    private var lastPingMs: Int64 = 0
    private var handshakeContinuation: CheckedContinuation<Bool, Never>?

    convenience init(
        rikey: Data,
        connectData: UInt32,
        transport: MoonlightControlTransport,
        now: @escaping () -> Int64,
        random: @escaping () -> UInt32 = { UInt32.random(in: 0 ... UInt32.max) },
        onEvent: @escaping (MoonlightEvent) -> Void,
        onClosed: @escaping () -> Void
    ) {
        self.init(
            cipher: .aesGcm(rikey: rikey),
            connectData: connectData,
            transport: transport,
            now: now,
            random: random,
            onEvent: onEvent,
            onClosed: onClosed
        )
    }

    init(
        cipher: MoonlightControlCipher,
        connectData: UInt32,
        transport: MoonlightControlTransport,
        now: @escaping () -> Int64,
        random: @escaping () -> UInt32,
        onEvent: @escaping (MoonlightEvent) -> Void,
        onClosed: @escaping () -> Void
    ) {
        self.cipher = cipher
        self.transport = transport
        self.now = now
        self.onEvent = onEvent
        self.onClosed = onClosed
        enet = EnetClient(connectData: connectData, now: now, random: random)
        transport.onDatagram = { [weak self] datagram in self?.received(datagram) }
    }

    var state: State {
        lock.lock()
        defer { lock.unlock() }
        return stateValue
    }

    var roundTripMs: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return enet.roundTripMs
    }

    /// Why the link ended, and what it did, for the session log.
    var linkReport: String {
        lock.lock()
        defer { lock.unlock() }
        let stats = enet.stats
        let counts = "acks \(stats.acksSent), retransmits \(stats.retransmits), unknown \(stats.unknownCommands)"
        return "\(enet.disconnectReason ?? "closed"); \(counts)"
    }

    // MARK: - Handshake

    /// Sends CONNECT and waits for VERIFY_CONNECT, retransmitting on the
    /// poll until the deadline; room for two retransmits on a busy link, as
    /// the three clients wait the same five seconds.
    func connect() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            lock.lock()
            enter(.connecting)
            handshakeContinuation = continuation
            let first = enet.connect()
            lock.unlock()
            transport.send(first)
            pollHandshake(deadline: now() + Self.handshakeTimeoutMs)
        }
    }

    private func pollHandshake(deadline: Int64) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(Int(Self.handshakePollMs))) { [weak self] in
            guard let self else { return }
            lock.lock()
            guard handshakeContinuation != nil else {
                lock.unlock()
                return
            }
            if enet.state == .connected { return settleHandshake(connected: true) }
            if enet.state == .disconnected || now() >= deadline { return settleHandshake(connected: false) }
            let retransmits = enet.tick()
            lock.unlock()
            retransmits.forEach(transport.send)
            pollHandshake(deadline: deadline)
        }
    }

    /// Under the lock, which it releases.
    private func settleHandshake(connected: Bool) {
        let continuation = handshakeContinuation
        handshakeContinuation = nil
        enter(connected ? .connected : .closed)
        if connected { lastPingMs = now() }
        lock.unlock()
        continuation?.resume(returning: connected)
    }

    /// Under the lock: the state, and with it whether sends go out.
    private func enter(_ state: State) {
        stateValue = state
        sending.set(state == .connected)
    }

    // MARK: - Sends

    /// HOT PATH: one pad's state, sealed and sent on channel 0; dropped when not connected.
    func sendControllerState(_ frame: MoonlightInput.PadFrame) {
        sendPlaintext(MoonlightInput.controllerMulti(frame))
    }

    func sendControllerArrival(_ arrival: MoonlightInput.PadArrival) {
        sendPlaintext(MoonlightInput.controllerArrival(arrival))
    }

    /// Plug a number back in as another pad: the host skips an arrival for a
    /// number it holds and drops the pad on the frame that names it with its
    /// bit cleared, so the unplug and the arrival take two consecutive ENet
    /// sequences in one hold of the lock, with no input frame able to land
    /// between them.
    func sendControllerReplug(number: UInt8, otherPadsMask: UInt16, arrival: MoonlightInput.PadArrival) {
        let unplug = MoonlightInput.controllerMulti(MoonlightInput.PadFrame(controller: number, activeMask: otherPadsMask))
        sendPlaintexts([unplug, MoonlightInput.controllerArrival(arrival)])
    }

    func sendControllerTouch(controller: UInt8, emission: MoonlightTouchEmission) {
        let packet = MoonlightInput.controllerTouch(
            controller: controller,
            event: emission.event,
            pointerId: emission.pointerId,
            x: emission.x,
            y: emission.y,
            pressure: emission.pressure
        )
        sendPlaintext(packet)
    }

    func sendControllerMotion(controller: UInt8, type: UInt8, x: Float, y: Float, z: Float) {
        sendPlaintext(MoonlightInput.controllerMotion(controller: controller, type: type, x: x, y: y, z: z))
    }

    func sendControllerBattery(controller: UInt8, state: UInt8, percentage: UInt8) {
        sendPlaintext(MoonlightInput.controllerBattery(controller: controller, state: state, percentage: percentage))
    }

    func sendMouseMoveRel(deltaX: Int16, deltaY: Int16) {
        sendPlaintext(MoonlightInput.mouseMoveRel(deltaX: deltaX, deltaY: deltaY))
    }

    func sendMouseButton(down: Bool, button: UInt8) {
        sendPlaintext(MoonlightInput.mouseButton(down: down, button: button))
    }

    func sendMouseScroll(amount: Int16) {
        sendPlaintext(MoonlightInput.mouseScroll(amount: amount))
    }

    /// Graceful teardown: TERMINATION, then the ENet disconnect, then the socket.
    func stop() {
        let termination = sending.get() ? seal(MoonlightInput.termination()) : nil
        lock.lock()
        var out: [Data] = []
        if stateValue == .connected, let termination, let datagram = enet.sendReliable(termination) {
            out.append(datagram)
        }
        if let disconnect = enet.disconnect() { out.append(disconnect) }
        enter(.closed)
        let continuation = handshakeContinuation
        handshakeContinuation = nil
        lock.unlock()
        out.forEach(transport.send)
        transport.close()
        continuation?.resume(returning: false)
    }

    private func sendPlaintext(_ plaintext: Data) {
        sendPlaintexts([plaintext])
    }

    /// Each packet is sealed before the lock under the next control sequence;
    /// the lock covers only the ENet framing and tracking, so a send never
    /// waits on another thread's crypto. A send while the link is not up
    /// spends no sequence. The host opens every packet under the sequence it
    /// carries, so two threads' packets may reach ENet in either order.
    private func sendPlaintexts(_ plaintexts: [Data]) {
        guard sending.get() else { return }
        let sealed = plaintexts.compactMap(seal)
        lock.lock()
        guard stateValue == .connected else {
            lock.unlock()
            return
        }
        let datagrams = sealed.compactMap(enet.sendReliable)
        lock.unlock()
        datagrams.forEach(transport.send)
    }

    /// The plaintext sealed under the next control sequence.
    private func seal(_ plaintext: Data) -> Data? {
        let seq = UInt32(truncatingIfNeeded: sequencesClaimed.incrementAndGet() &- 1)
        return cipher.seal(seq, plaintext)
    }

    // MARK: - Receive and tick

    /// The ENet bookkeeping under the lock: the acknowledgements, the host's
    /// payloads taken out, the handshake settled. The payloads are opened
    /// after it, in the order they came, on the transport's one queue.
    private func received(_ datagram: Data) {
        lock.lock()
        let acks = enet.onDatagram(datagram)
        let payloads = enet.takeReceived()
        let settled = stateValue == .connecting && (enet.state == .connected || enet.state == .disconnected)
        if settled {
            // Settles the handshake and releases the lock.
            settleHandshake(connected: enet.state == .connected)
        } else {
            lock.unlock()
        }
        acks.forEach(transport.send)
        payloads.compactMap(open).forEach(onEvent)
    }

    /// Advance the clocks: retransmits, the ENet ping, the protocol's own
    /// keepalive (a host that hears nothing at this layer ends the session
    /// even while ENet underneath is healthy), and the link's end. The
    /// keepalive is sealed after the lock, like any send.
    func tick() {
        lock.lock()
        guard stateValue == .connected else {
            lock.unlock()
            return
        }
        let out = enet.tick()
        let time = now()
        let keepaliveDue = time - lastPingMs >= Self.pingIntervalMs && enet.state == .connected
        if keepaliveDue { lastPingMs = time }
        let gaveUp = enet.state == .disconnected
        if gaveUp { enter(.closed) }
        lock.unlock()
        out.forEach(transport.send)
        if keepaliveDue { sendPlaintext(MoonlightInput.periodicPing()) }
        if gaveUp { onClosed() }
    }

    /// A forged or garbled packet is dropped, never acted on.
    private func open(_ payload: Data) -> MoonlightEvent? {
        guard case let .plaintext(plaintext) = cipher.open(payload) else { return nil }
        return decodeMoonlightEvent(plaintext)
    }
}
