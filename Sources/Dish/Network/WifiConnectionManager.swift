// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import Foundation

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
    let events = PassthroughSubject<ConnectionEvent, Never>()

    private let store: ConnectionStore
    private lazy var deviceId = store.getOrCreateDeviceId()
    private let deviceName = Host.current().localizedName ?? "Mac"

    init(store: ConnectionStore) {
        self.store = store
    }

    func get(_ id: String) -> WifiConnection? {
        connections[id]
    }

    // MARK: - Discovery

    func startDiscovery() {
        if isScanning { return }
        isScanning = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let found = LANDiscovery.discover()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.discoveredServers = found
                self.isScanning = false
                if found.isEmpty {
                    self.events.send(.error("No servers found — check your network"))
                }
            }
        }
    }

    // MARK: - Connect / Pair / Disconnect

    /// Idempotent: a second call while CONNECTED/CONNECTING just refreshes
    /// the server record without restarting the handshake.
    func connect(to server: DiscoveredServer) {
        let id = WifiConnection.idFor(server)
        if let existing = connections[id] {
            if existing.state == .connected || existing.state == .connecting {
                existing.updateServer(server)
                return
            }
        }
        let conn = connections[id] ?? {
            let c = WifiConnection(id: id, server: server)
            connections[id] = c
            return c
        }()
        conn.updateServer(server)
        conn.markConnecting()
        Task { await pairAndConnect(conn: conn, server: server) }
    }

    private func pairAndConnect(conn: WifiConnection, server: DiscoveredServer) async {
        // Snapshot main-actor state so the detached task doesn't need to hop.
        let did = deviceId, dname = deviceName
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
        guard pair.ok, let sharedKey = pair.sharedKey else {
            conn.markDisconnected()
            events.send(.pairingRequired(server))
            return
        }
        store.setSharedKey(sharedKey, for: WifiConnection.idFor(server))
        await openSession(conn: conn, server: server)
    }

    /// Finish pairing with a user-supplied PIN.
    func pairWithPin(_ server: DiscoveredServer, pin: String) {
        let id = WifiConnection.idFor(server)
        let conn = connections[id] ?? {
            let c = WifiConnection(id: id, server: server)
            connections[id] = c
            return c
        }()
        conn.markConnecting()
        let did = deviceId, dname = deviceName
        Task {
            let pair = await Task.detached(priority: .userInitiated) {
                PairingClient.pair(
                    ip: server.ip,
                    port: server.pairPort,
                    deviceId: did,
                    deviceName: dname,
                    pin: pin
                )
            }.value
            guard pair.ok, let sharedKey = pair.sharedKey else {
                conn.markDisconnected()
                events.send(.error(pair.error ?? "Pairing failed"))
                return
            }
            store.setSharedKey(sharedKey, for: WifiConnection.idFor(server))
            await openSession(conn: conn, server: server)
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
    }

    /// Reconnect every remembered server that isn't already live. Safe to call
    /// on every app-foreground — all paths are idempotent.
    func autoReconnectAll() {
        for remembered in store.remembered() {
            let existing = connections[remembered.id]
            if existing?.state != .connected {
                connect(to: remembered.toDiscovered())
            }
        }
    }

    func remembered() -> [RememberedWifi] {
        store.remembered()
    }
}
