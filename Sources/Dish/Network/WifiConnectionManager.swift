// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import Foundation
import os

enum ConnectionEvent {
    case pairingRequired(DiscoveredServer)
    case error(String)
}

/// Owns the pool of live + remembered WiFi sessions. Each session runs its
/// own native socket, heartbeat and ACK loop so multiple servers can be
/// active in parallel. Mirrors `WifiConnectionManager.kt`.
@MainActor
final class WifiConnectionManager: ObservableObject {

    @Published private(set) var connections: [String: WifiConnection] = [:]
    @Published private(set) var discoveredServers: [DiscoveredServer] = []
    @Published private(set) var isScanning = false
    /// IDs currently in the pair-and-handshake flow. The connections page
    /// uses this to render a spinner per row.
    @Published private(set) var pairingInFlight: Set<String> = []
    /// True while any pooled connection is awaiting `MSG_CONTROLLER_ACK`.
    /// Aggregated from each `WifiConnection.isRegisteringController`.
    @Published private(set) var anyControllerRegistering = false
    let events = PassthroughSubject<ConnectionEvent, Never>()
    /// Forwarded from per-connection `slotRegistrationFailed` so
    /// `ConnectionHub` can roll back the local binding when the server
    /// rejects a controller add.
    let slotRegistrationFailed = PassthroughSubject<String, Never>()

    /// Per-path discovery logging so the broadcast vs mDNS hit-rate can be
    /// compared in the field (Task 1.6).
    private static let discoveryLog = Logger(
        subsystem: "com.tinkernorth.dish", category: "discovery"
    )

    private let store: ConnectionStore
    private lazy var deviceId = store.getOrCreateDeviceId()
    private let deviceName = Host.current().localizedName ?? "Mac"
    private var perConnCancellables: [String: Set<AnyCancellable>] = [:]

    init(store: ConnectionStore) {
        self.store = store
    }

    func get(_ id: String) -> WifiConnection? {
        connections[id]
    }

    /// Insert `conn` into the pool and start forwarding its per-connection
    /// signals (controller-ack errors + slot-registration-failed) into the
    /// manager-level event streams.
    private func register(_ conn: WifiConnection) {
        connections[conn.id] = conn
        var bag = Set<AnyCancellable>()
        conn.errorMessages
            .sink { [weak self] msg in self?.events.send(.error(msg)) }
            .store(in: &bag)
        conn.slotRegistrationFailed
            .sink { [weak self] slot in self?.slotRegistrationFailed.send(slot) }
            .store(in: &bag)
        conn.$isRegisteringController
            .sink { [weak self] _ in self?.recomputeAnyRegistering() }
            .store(in: &bag)
        perConnCancellables[conn.id] = bag
    }

    private func recomputeAnyRegistering() {
        anyControllerRegistering = connections.values.contains { $0.isRegisteringController }
    }

    // MARK: - Discovery

    func startDiscovery() {
        if isScanning { return }
        isScanning = true
        Task.detached(priority: .userInitiated) { [weak self] in
            // Two discovery paths in parallel: the legacy UDP broadcast beacon
            // (LANDiscovery) and mDNS / Bonjour (MdnsBrowser). mDNS reaches
            // servers on subnets that drop broadcast; the beacon stays as the
            // fallback for satellites that predate the mDNS responder. Results
            // are merged by stable id so a server heard on both appears once.
            async let broadcast = Task.detached { LANDiscovery.discover() }.value
            async let mdns = MdnsBrowser.discover()
            let broadcastList = await broadcast
            let mdnsList = await mdns
            let merged = Self.mergeDiscovered(broadcast: broadcastList, mdns: mdnsList)
            let summary =
                "broadcast=\(broadcastList.count) mdns=\(mdnsList.count) merged=\(merged.count)"
            Self.discoveryLog.info("discovery scan: \(summary, privacy: .public)")
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.discoveredServers = merged
                self.isScanning = false
                if merged.isEmpty {
                    self.events.send(.error("No servers found — check your network"))
                }
            }
        }
    }

    /// Merge the two discovery paths by stable id, tagging each server's
    /// `source`. A server heard on both paths becomes `.both`; otherwise it
    /// carries the path that surfaced it. Result is name-sorted. Pure +
    /// `nonisolated` so it can be unit-tested without sockets or the main actor.
    nonisolated static func mergeDiscovered(
        broadcast: [DiscoveredServer],
        mdns: [DiscoveredServer]
    ) -> [DiscoveredServer] {
        var byId: [String: DiscoveredServer] = [:]
        for var server in broadcast {
            server.source = .broadcast
            byId[server.id] = server
        }
        for var server in mdns {
            server.source = byId[server.id] != nil ? .both : .mdns
            byId[server.id] = server
        }
        return byId.values.sorted { $0.name < $1.name }
    }

    // MARK: - Connect / Pair / Disconnect

    /// Idempotent: a second call while live/linking just refreshes the
    /// server record without restarting the handshake.
    func connect(to server: DiscoveredServer) {
        let id = WifiConnection.idFor(server)
        if let existing = connections[id] {
            if existing.state == .live || existing.state == .linking {
                existing.updateServer(server)
                return
            }
        }
        let conn = connections[id] ?? {
            let newConn = WifiConnection(id: id, server: server)
            register(newConn)
            return newConn
        }()
        conn.updateServer(server)
        conn.markConnecting()
        Task { await pairAndConnect(conn: conn, server: server) }
    }

    private func pairAndConnect(conn: WifiConnection, server: DiscoveredServer) async {
        let id = WifiConnection.idFor(server)
        // Auto-reconnect fast path: if we already have a shared key saved for
        // this server, skip the TCP pair handshake entirely and go straight
        // to `openSession`. A moved/offline server then fails fast in the
        // HTTP layer instead of bouncing through pair → PairingRequired and
        // trapping the user behind a PIN prompt that can't be satisfied.
        // Mirrors dish-android PR #43.
        if let saved = store.sharedKey(for: id), saved.count == 64 {
            await openSession(conn: conn, server: server)
            return
        }
        // Snapshot main-actor state so the detached task doesn't need to hop.
        let did = deviceId, dname = deviceName
        pairingInFlight.insert(conn.id)
        defer { pairingInFlight.remove(conn.id) }
        // Empty PIN is the "already-paired, re-use saved shared key" path.
        let pair = await Task.detached(priority: .userInitiated) {
            PairingClient.pair(
                ip: server.ip,
                port: server.pairPort,
                deviceId: did,
                deviceName: dname,
                pin: ""
            )
        }.value
        switch PairingClient.classify(pair) {
        case let .success(sharedKey):
            store.setSharedKey(sharedKey, for: id)
            await openSession(conn: conn, server: server)
        case .authRequired:
            conn.markDisconnected()
            events.send(.pairingRequired(server))
        case let .unreachable(msg):
            conn.markDisconnected()
            events.send(.error("Server unreachable — has it moved networks? (\(msg))"))
        }
    }

    /// Finish pairing with a user-supplied PIN.
    func pairWithPin(_ server: DiscoveredServer, pin: String) {
        let id = WifiConnection.idFor(server)
        let conn = connections[id] ?? {
            let newConn = WifiConnection(id: id, server: server)
            register(newConn)
            return newConn
        }()
        conn.markConnecting()
        let did = deviceId, dname = deviceName
        Task {
            pairingInFlight.insert(conn.id)
            defer { pairingInFlight.remove(conn.id) }
            let pair = await Task.detached(priority: .userInitiated) {
                PairingClient.pair(
                    ip: server.ip,
                    port: server.pairPort,
                    deviceId: did,
                    deviceName: dname,
                    pin: pin
                )
            }.value
            switch PairingClient.classify(pair) {
            case let .success(sharedKey):
                store.setSharedKey(sharedKey, for: id)
                await openSession(conn: conn, server: server)
            case .authRequired:
                conn.markDisconnected()
                events.send(.error(pair.error ?? "Pairing failed"))
            case let .unreachable(msg):
                conn.markDisconnected()
                events.send(.error("Server unreachable — has it moved networks? (\(msg))"))
            }
        }
    }

    private func openSession(conn: WifiConnection, server: DiscoveredServer) async {
        let id = WifiConnection.idFor(server)
        guard let keyHex = store.sharedKey(for: id),
              keyHex.count == 64,
              let keyData = hexToBytes(keyHex), keyData.count == 32 else
        {
            conn.markDisconnected()
            events.send(.error("No shared key — re-pair needed"))
            return
        }
        let resp = await HTTPClient.connect(
            ip: server.ip,
            port: server.httpPort,
            deviceId: deviceId
        )
        guard let connId = resp.connectionId,
              let tokenHex = resp.token,
              let tokenData = hexToBytes(tokenHex), tokenData.count == 4 else
        {
            conn.markDisconnected()
            events.send(.error("Error: \(resp.error ?? "connection failed")"))
            return
        }
        let client = SatelliteClient()
        guard client.openSocket(ip: server.ip, port: server.udpPort) else {
            conn.markDisconnected()
            return
        }
        client.setConnectionParams(token: tokenData, key: keyData)
        store.remember(server)
        conn.markConnected(client: client, connectionId: connId) { [weak self] in
            self?.disconnect(id: conn.id)
        }
    }

    func disconnect(id: String) {
        guard let conn = connections[id] else { return }
        let server = conn.server
        let cid = conn.connectionId
        let did = deviceId
        conn.markDisconnected()
        if let cid {
            Task.detached(priority: .utility) {
                _ = await HTTPClient.disconnect(
                    ip: server.ip,
                    port: server.httpPort,
                    connectionId: cid,
                    deviceId: did
                )
            }
        }
    }

    func forget(id: String) {
        disconnect(id: id)
        store.forget(id)
        connections.removeValue(forKey: id)
        perConnCancellables.removeValue(forKey: id)
        recomputeAnyRegistering()
    }

    /// Reconnect every remembered server that isn't already live. Safe to call
    /// on every app-foreground — all paths are idempotent.
    func autoReconnectAll() {
        for remembered in store.remembered() {
            let existing = connections[remembered.id]
            if existing?.state != .live {
                connect(to: remembered.toDiscovered())
            }
        }
    }

    func remembered() -> [RememberedWifi] {
        store.remembered()
    }
}
