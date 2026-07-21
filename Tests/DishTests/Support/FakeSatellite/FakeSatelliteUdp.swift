// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// FakeSatellite UDP data plane (contract §Packet format / §UDP messages).
//
// Decrypts uplink datagrams with per-token session keys, enforces the
// per-direction replay guard (`counter <= last` dropped, counters start
// at 1), records typed frames for assertions, answers heartbeats with the
// enriched ack (backendAvailable | count | epoch u16 BE | bitmap u16 BE —
// each knob-overridable), and injects downlink rumble / lightbar /
// close-notify frames encrypted with the session key.

import Foundation
import Network

final class FakeSatelliteUdp {

    private let store: FakeSatelliteStore
    private let queue = DispatchQueue(label: "fake-satellite.udp")
    private var listener: NWListener?
    private let connectionsLock = NSLock()
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    init(store: FakeSatelliteStore) {
        self.store = store
    }

    @discardableResult
    func start() throws -> UInt16 {
        let params = NWParameters.udp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.track(connection)
            connection.start(queue: self.queue)
            self.receiveLoop(connection)
        }
        port = try FakeSatelliteNet.startAndAwaitReady(listener, queue: queue)
        self.listener = listener
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connectionsLock.lock()
        let open = connections
        connections = []
        connectionsLock.unlock()
        open.forEach { $0.cancel() }
    }

    private func track(_ connection: NWConnection) {
        connectionsLock.lock()
        connections.append(connection)
        connectionsLock.unlock()
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.handleDatagram(data, on: connection)
            }
            if error == nil {
                self.receiveLoop(connection)
            } else {
                connection.cancel()
            }
        }
    }

    // MARK: - Uplink

    private func handleDatagram(_ raw: Data, on connection: NWConnection) {
        let outbound = store.with { state -> Data? in
            guard let header = FakeSatelliteCrypto.parseDatagram(raw) else { return nil }
            guard let session = state.sessions[header.token] else {
                state.unknownTokenDrops += 1
                return nil
            }
            // Replay guard (contract §Crypto): drop counter <= last; the
            // first packet is exempt by construction while last == 0.
            guard header.counter > session.lastUpCounter else {
                state.replayDrops += 1
                return nil
            }
            guard let inner = try? FakeSatelliteCrypto.open(
                header.box,
                key: session.key,
                direction: .clientToServer,
                counter: header.counter,
                token: header.token
            ), let frame = FakeSatelliteCrypto.parseInner(inner) else {
                state.authFailDrops += 1
                return nil
            }
            session.lastUpCounter = header.counter
            session.reply = connection
            let payload = Data(frame.payload)
            state.frames.append(FakeSatelliteFrame(
                opcode: frame.msgType,
                counter: header.counter,
                payload: payload,
                detail: FakeSatelliteFrame.parseDetail(opcode: frame.msgType, payload: payload)
            ))
            guard frame.msgType == FakeSatelliteOpcode.heartbeat else { return nil }
            state.heartbeatCount += 1
            return Self.sealDown(
                opcode: FakeSatelliteOpcode.heartbeatAck,
                payload: Self.ackPayload(state: state),
                session: session
            )
        }
        if let outbound {
            connection.send(content: outbound, completion: .contentProcessed { _ in })
        }
    }

    /// Enriched heartbeat ack (contract §0x0003): backendAvailable(1) |
    /// totalActiveControllers(1) | epoch(u16 BE) | activeBitmap(u16 BE).
    private static func ackPayload(state: FakeSatelliteStore.State) -> Data {
        let derivedBitmap = state.controllers.reduce(UInt16(0)) { acc, ctrl in
            let idx = ctrl["ctrlIdx"] as? Int ?? 0
            guard idx >= 0, idx < 16 else { return acc }
            return acc | (1 << UInt16(idx))
        }
        let backend = state.ackBackendAvailableOverride ?? true
        let count = state.ackCountOverride ?? UInt8(clamping: state.controllers.count)
        let epoch = state.ackEpochOverride ?? state.epoch
        let bitmap = state.ackBitmapOverride ?? derivedBitmap
        return Data([backend ? 1 : 0, count])
            + FakeSatelliteCrypto.be16(epoch)
            + FakeSatelliteCrypto.be16(bitmap)
    }

    // MARK: - Downlink

    /// Seals one server→client datagram for `session`, advancing its down
    /// counter. Must be called under the store lock.
    private static func sealDown(opcode: UInt16, payload: Data, session: FakeSatelliteSession) -> Data? {
        session.downCounter &+= 1
        let inner = FakeSatelliteCrypto.encodeInner(msgType: opcode, payload: payload)
        return try? FakeSatelliteCrypto.sealDatagram(
            inner: inner,
            key: session.key,
            direction: .serverToClient,
            counter: session.downCounter,
            token: session.token
        )
    }

    /// Sends an encrypted downlink frame to the ACTIVE session's last known
    /// reply flow. Returns false when there is no session or no uplink has
    /// been seen yet (no reply path — close-notify is best-effort by design).
    @discardableResult
    func sendToActive(opcode: UInt16, payload: Data) -> Bool {
        let prepared = store.with { state -> (Data, NWConnection)? in
            guard let token = state.activeToken,
                  let session = state.sessions[token],
                  let reply = session.reply,
                  let datagram = Self.sealDown(opcode: opcode, payload: payload, session: session) else { return nil }
            return (datagram, reply)
        }
        guard let (datagram, reply) = prepared else { return false }
        reply.send(content: datagram, completion: .contentProcessed { _ in })
        return true
    }

    /// Sends close-notify to a SPECIFIC session (e.g. `replaced` to the OLD
    /// token when a new PUT rotates the session, `unpaired` on self-unpair).
    @discardableResult
    func sendClose(_ reason: FakeSatelliteCloseReason, to session: FakeSatelliteSession) -> Bool {
        let prepared = store.with { _ -> (Data, NWConnection)? in
            guard let reply = session.reply,
                  let datagram = Self.sealDown(
                      opcode: FakeSatelliteOpcode.sessionClose,
                      payload: Data([reason.rawValue]),
                      session: session
                  ) else { return nil }
            return (datagram, reply)
        }
        guard let (datagram, reply) = prepared else { return false }
        reply.send(content: datagram, completion: .contentProcessed { _ in })
        return true
    }
}
