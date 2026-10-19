// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The Moonlight control stream: the ENet handshake, the sealed reliable
// sends (pads, touch, motion, battery, the mouse, the keepalive, the
// termination) and the host's events back. The pure pieces (EnetClient,
// MoonlightControlSealer, MoonlightControlPacket, decodeMoonlightEvent) are
// composed over a swappable transport, so the whole lifecycle tests with a
// fake transport and a controlled clock; production plugs in a UDP socket.
//
// ONE LOCK OVER THE WHOLE PROTOCOL STATE, and it has to be. Input arrives on
// the controller threads while datagrams and the tick arrive on the
// transport's queue, and both reach the same ENet client and the same
// sealer. Neither is thread-safe, and the sealer's counter is the AES-GCM
// IV: two threads sealing at once could hand one IV to two packets, a real
// key-recovery bug and not merely a lost input. Events are dispatched
// outside the lock: a rumble sink is somebody else's code.

import DishCore
import Foundation

/// The datagram plumbing under the session: a UDP socket in production.
/// Datagrams from the host arrive on `onDatagram`, from one queue.
protocol MoonlightControlTransport: AnyObject {
    var onDatagram: ((Data) -> Void)? { get set }
    func send(_ datagram: Data)
    func close()
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
    private var lock = os_unfair_lock_s()
    private let enet: EnetClient
    private var sealer: MoonlightControlSealer
    private let rikey: Data
    private var stateValue = State.idle
    private var lastPingMs: Int64 = 0
    private var handshakeContinuation: CheckedContinuation<Bool, Never>?

    init(
        rikey: Data,
        connectData: UInt32,
        transport: MoonlightControlTransport,
        now: @escaping () -> Int64,
        random: @escaping () -> UInt32 = { UInt32.random(in: 0 ... UInt32.max) },
        onEvent: @escaping (MoonlightEvent) -> Void,
        onClosed: @escaping () -> Void
    ) {
        self.rikey = rikey
        self.transport = transport
        self.now = now
        self.onEvent = onEvent
        self.onClosed = onClosed
        enet = EnetClient(connectData: connectData, now: now, random: random)
        sealer = MoonlightControlSealer(rikey: rikey)
        transport.onDatagram = { [weak self] datagram in self?.received(datagram) }
    }

    var state: State {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return stateValue
    }

    var roundTripMs: Int64? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return enet.roundTripMs
    }

    /// Why the link ended, and what it did, for the session log.
    var linkReport: String {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
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
            os_unfair_lock_lock(&lock)
            stateValue = .connecting
            handshakeContinuation = continuation
            let first = enet.connect()
            os_unfair_lock_unlock(&lock)
            transport.send(first)
            pollHandshake(deadline: now() + Self.handshakeTimeoutMs)
        }
    }

    private func pollHandshake(deadline: Int64) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(Int(Self.handshakePollMs))) { [weak self] in
            guard let self else { return }
            os_unfair_lock_lock(&lock)
            guard handshakeContinuation != nil else {
                os_unfair_lock_unlock(&lock)
                return
            }
            if enet.state == .connected { return settleHandshake(connected: true) }
            if enet.state == .disconnected || now() >= deadline { return settleHandshake(connected: false) }
            let retransmits = enet.tick()
            os_unfair_lock_unlock(&lock)
            retransmits.forEach(transport.send)
            pollHandshake(deadline: deadline)
        }
    }

    /// Under the lock, which it releases.
    private func settleHandshake(connected: Bool) {
        let continuation = handshakeContinuation
        handshakeContinuation = nil
        stateValue = connected ? .connected : .closed
        if connected { lastPingMs = now() }
        os_unfair_lock_unlock(&lock)
        continuation?.resume(returning: connected)
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
    /// bit cleared, so the unplug and the arrival go under one hold of the
    /// lock, with no input frame able to land between them.
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
        os_unfair_lock_lock(&lock)
        var out: [Data] = []
        if stateValue == .connected, let sealed = sealer.seal(MoonlightInput.termination()), let datagram = enet.sendReliable(sealed) {
            out.append(datagram)
        }
        if let disconnect = enet.disconnect() { out.append(disconnect) }
        stateValue = .closed
        let continuation = handshakeContinuation
        handshakeContinuation = nil
        os_unfair_lock_unlock(&lock)
        out.forEach(transport.send)
        transport.close()
        continuation?.resume(returning: false)
    }

    private func sendPlaintext(_ plaintext: Data) {
        sendPlaintexts([plaintext])
    }

    /// Every outbound packet goes through the one sealer, so the whole stream
    /// shares the sequence the host derives each IV from; a dropped send
    /// spends no number.
    private func sendPlaintexts(_ plaintexts: [Data]) {
        os_unfair_lock_lock(&lock)
        guard stateValue == .connected else {
            os_unfair_lock_unlock(&lock)
            return
        }
        let datagrams = plaintexts.compactMap { plaintext in sealer.seal(plaintext).flatMap(enet.sendReliable) }
        os_unfair_lock_unlock(&lock)
        datagrams.forEach(transport.send)
    }

    // MARK: - Receive and tick

    private func received(_ datagram: Data) {
        os_unfair_lock_lock(&lock)
        let acks = enet.onDatagram(datagram)
        let events = enet.takeReceived().compactMap(open)
        let settled = stateValue == .connecting && (enet.state == .connected || enet.state == .disconnected)
        if settled {
            // Settles the handshake and releases the lock.
            settleHandshake(connected: enet.state == .connected)
        } else {
            os_unfair_lock_unlock(&lock)
        }
        acks.forEach(transport.send)
        events.forEach(onEvent)
    }

    /// Advance the clocks: retransmits, the ENet ping, the protocol's own
    /// keepalive (a host that hears nothing at this layer ends the session
    /// even while ENet underneath is healthy), and the link's end.
    func tick() {
        os_unfair_lock_lock(&lock)
        guard stateValue == .connected else {
            os_unfair_lock_unlock(&lock)
            return
        }
        var out = enet.tick()
        let time = now()
        if time - lastPingMs >= Self.pingIntervalMs, enet.state == .connected {
            lastPingMs = time
            if let sealed = sealer.seal(MoonlightInput.periodicPing()), let datagram = enet.sendReliable(sealed) { out.append(datagram) }
        }
        let gaveUp = enet.state == .disconnected
        if gaveUp { stateValue = .closed }
        os_unfair_lock_unlock(&lock)
        out.forEach(transport.send)
        if gaveUp { onClosed() }
    }

    /// Under the lock: a forged or garbled packet is dropped, never acted on.
    private func open(_ payload: Data) -> MoonlightEvent? {
        guard case let .plaintext(plaintext) = MoonlightControlPacket.open(key: .init(data: rikey), packet: payload) else { return nil }
        return decodeMoonlightEvent(plaintext)
    }
}
