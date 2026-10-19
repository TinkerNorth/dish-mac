// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The UDP under a Moonlight session: the control stream's socket, and the
// pings that keep the host's video and audio ports open. One long-lived
// socket per media stream, and it has to be: the host learns where to send
// from the source address of the ping and streams back to that socket, so a
// throwaway socket per ping tells it a new port every time. Whatever arrives
// on them is read and thrown away; an unread socket fills its buffer and
// starts dropping, which some stacks show the far end as a dead peer.

import DishCore
import Foundation
import Network

/// A connected UDP socket to the host's control port, delivering what the
/// host sends on one queue.
final class UdpControlTransport: MoonlightControlTransport, @unchecked Sendable {
    static let readyTimeout: TimeInterval = 5
    /// How long a close waits for the datagrams already handed over before
    /// it cuts the socket anyway.
    static let drainTimeout: TimeInterval = 1

    var onDatagram: ((Data) -> Void)?
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var readyContinuation: CheckedContinuation<Bool, Never>?
    /// Datagrams handed to the socket and not yet processed, and whether a
    /// close is waiting on them.
    private var inFlight = 0
    private var closing = false

    init(address: String, port: UInt16, queue: DispatchQueue = DispatchQueue(label: "dish.moonlight.control-udp", qos: .userInteractive)) {
        self.queue = queue
        connection = NWConnection(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port) ?? .any, using: .udp)
    }

    /// Opens the socket; false when the path never becomes ready.
    func start() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            readyContinuation = continuation
            lock.unlock()
            connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + Self.readyTimeout) { [weak self] in self?.settleReady(false) }
        }
    }

    func send(_ datagram: Data) {
        lock.lock()
        inFlight += 1
        lock.unlock()
        connection.send(content: datagram, completion: .contentProcessed { [weak self] _ in self?.processed() })
    }

    /// Cuts the socket once every datagram already handed over has left, or
    /// after `drainTimeout`: a TERMINATION or a DISCONNECT cancelled behind
    /// is one the host never hears.
    func close() {
        lock.lock()
        closing = true
        let idle = inFlight == 0
        lock.unlock()
        if idle {
            connection.cancel()
            return
        }
        queue.asyncAfter(deadline: .now() + Self.drainTimeout) { [weak self] in self?.connection.cancel() }
    }

    private func processed() {
        lock.lock()
        inFlight -= 1
        let last = closing && inFlight == 0
        lock.unlock()
        if last { connection.cancel() }
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            settleReady(true)
            receive()
        case .failed, .cancelled, .waiting:
            settleReady(false)
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func settleReady(_ ready: Bool) {
        lock.lock()
        let continuation = readyContinuation
        readyContinuation = nil
        lock.unlock()
        continuation?.resume(returning: ready)
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data, !data.isEmpty { onDatagram?(data) }
            receive()
        }
    }
}

/// The host's media ports pinged every half second from one socket each.
final class MoonlightMediaPinger: @unchecked Sendable {
    static let intervalMs = 500

    private final class Lane: @unchecked Sendable {
        let connection: NWConnection
        init(address: String, port: UInt16) {
            connection = NWConnection(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port) ?? .any, using: .udp)
        }
    }

    private let lanes: [Lane]
    private let payload: String
    private let queue = DispatchQueue(label: "dish.moonlight.media-ping")
    private var timer: DispatchSourceTimer?
    private var sequence: UInt32 = 0
    private let sent = LockedBox(0)

    /// The lanes the SETUPs named; a port the host did not name gets none.
    init(address: String, videoPort: UInt16?, audioPort: UInt16?, payload: String) {
        lanes = [videoPort, audioPort].compactMap { $0 }.map { Lane(address: address, port: $0) }
        self.payload = payload
    }

    var mode: String {
        MoonlightMediaPing.usable(payload) ? "SS_PING" : "legacy PING"
    }

    var pingsSent: Int {
        sent.get()
    }

    /// The first ping goes out at once: the host counts its initial-ping
    /// deadline from its own session start, not from when the control link comes up.
    func start() {
        for lane in lanes {
            lane.connection.start(queue: queue)
            drain(lane)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(Self.intervalMs), leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.ping() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        lanes.forEach { $0.connection.cancel() }
    }

    private func ping() {
        let datagram = MoonlightMediaPing.usable(payload) ? MoonlightMediaPing
            .ssPing(payload: payload, sequence: sequence) : MoonlightMediaPing.legacy
        sequence &+= 1
        for lane in lanes {
            lane.connection.send(content: datagram, completion: .contentProcessed { _ in })
        }
        sent.mutate { $0 += 1 }
    }

    private func drain(_ lane: Lane) {
        lane.connection.receiveMessage { [weak self] _, _, _, error in
            guard let self, error == nil else { return }
            drain(lane)
        }
    }
}
