// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import CryptoKit
import DishCore
import Foundation
import os

/// What the manager tells the app: a satellite that wants a PIN, or a failure
/// the user may need to hear about.
package enum ConnectionEvent: Equatable {
    case pairingRequired(DiscoveredServer)
    case failure(ConnectionFailure)
}

/// Hosts whose presented TLS certificate mismatched the stored TOFU pin. The
/// pin verifier records on URLSession's delegate queue; the manager consumes
/// on the main actor, so a mismatch surfaces as an identity problem rather
/// than as "unreachable".
final class PinMismatchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: Set<String> = []

    func record(_ host: String) {
        lock.lock()
        defer { lock.unlock() }
        hosts.insert(host)
    }

    /// True, and clears the breadcrumb, when `host` mismatched since the last
    /// consume.
    func consume(_ host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return hosts.remove(host) != nil
    }
}

/// Who asked for a connect. Only a user-initiated attempt may surface a
/// failure; the automatic ones report through the row's state alone.
enum ConnectIntent {
    case userInitiated
    case autoReconnect
    case retryAfterDeath
}

/// Owns the pool of live and remembered satellite sessions. Each session runs
/// its own socket, heartbeat and alive tick, so several satellites stream in
/// parallel. The pairing, session, discovery and lifecycle flows live in the
/// extensions of the same name.
@MainActor
package final class WifiConnectionManager: ObservableObject {

    @Published package private(set) var connections: [String: WifiConnection] = [:]
    @Published package private(set) var discoveredServers: [DiscoveredServer] = []
    @Published package private(set) var isScanning = false
    /// Ids in the pair-and-handshake flow; the rows show a spinner.
    @Published package private(set) var pairingInFlight: Set<String> = []
    /// True while any pooled connection converges its slot over REST.
    @Published package private(set) var anyControllerRegistering = false
    /// Satellites that revoked this device's key, or never had one, and so
    /// read "Needs pairing" until a user-initiated pair succeeds.
    @Published package private(set) var staleSatelliteIds: Set<String> = []

    let events = PassthroughSubject<ConnectionEvent, Never>()
    /// The slot id the satellite refused to plug, so the hub rolls the
    /// binding back.
    let slotRegistrationFailed = PassthroughSubject<String, Never>()

    nonisolated static let discoveryLog = Logger(subsystem: "com.tinkernorth.dish", category: "discovery")

    let store: ConnectionStore
    /// Path-B approval poll cadence; tests shrink it.
    let approvalPolling: ApprovalPolling
    /// The LAN's two discovery paths as one call; tests script a LAN.
    let discovery: DiscoveryPaths
    lazy var deviceId = store.getOrCreateDeviceId()
    let deviceName = Host.current().localizedName ?? "Mac"
    let pinMismatches = PinMismatchLog()
    lazy var pairing = PairingClient(pinVerifier: makePinVerifier())
    lazy var http = HTTPClient(pinVerifier: makePinVerifier())
    /// In-flight path-B approval polls by connection id, so a re-issued
    /// request supersedes the prior poll and forget or disconnect cancels it.
    var approvalPolls: [String: Task<Void, Never>] = [:]
    /// Per-connection reconnect throttle on the backoff curve.
    var retry: [String: RetryState] = [:]
    var retryTasks: [String: Task<Void, Never>] = [:]
    /// Per-satellite client catalog, fetched at session open.
    var catalogs: [String: CatalogDTO] = [:]
    /// Per-satellite capabilities probe, fetched at session open.
    var capabilities: [String: ServerCapabilitiesDTO] = [:]
    /// The user's per-binding Emulate pick, read as each descriptor is built.
    let typeOverrides = ControllerTypeStore()
    /// The satellite's motion word per binding, from the apply results.
    let motionStatus = MotionBackendStatusStore()

    private var perConnCancellables: [String: Set<AnyCancellable>] = [:]
    /// Depth-counted so a superseded approval flow unwinding after its
    /// cancellation cannot clear the marker its successor holds.
    private var pairingDepth: [String: Int] = [:]

    init(store: ConnectionStore, approvalPolling: ApprovalPolling = .standard, discovery: DiscoveryPaths = .live) {
        self.store = store
        self.approvalPolling = approvalPolling
        self.discovery = discovery
    }

    // MARK: - Pairing-in-flight marker

    func beginPairing(_ id: String) {
        pairingDepth[id, default: 0] += 1
        pairingInFlight.insert(id)
    }

    func endPairing(_ id: String) {
        let depth = (pairingDepth[id] ?? 1) - 1
        if depth > 0 {
            pairingDepth[id] = depth
        } else {
            pairingDepth.removeValue(forKey: id)
            pairingInFlight.remove(id)
        }
    }

    // MARK: - Trust

    /// First contact pins the certificate's SHA-256 fingerprint for the host;
    /// a later certificate that differs is refused and breadcrumbed. The
    /// store's pin accessors are lock-guarded because this runs on
    /// URLSession's delegate queue.
    func makePinVerifier() -> PinVerifier {
        let store = store
        let mismatches = pinMismatches
        return { host, der in
            let presented = sha256FingerprintHex(der)
            switch tofuVerdict(pinned: store.certPin(host: host), presented: presented) {
            case .trustFirstUse:
                store.setCertPin(host: host, fingerprintHex: presented)
                return true
            case .match:
                return true
            case .mismatch:
                mismatches.record(host)
                return false
            }
        }
    }

    func get(_ id: String) -> WifiConnection? {
        connections[id]
    }

    // MARK: - Pool

    /// Insert `conn` into the pool and wire its signals: slot-apply failures
    /// roll the binding back, slot changes converge over REST, and a send
    /// counter near exhaustion re-keys the session.
    func register(_ conn: WifiConnection) {
        connections[conn.id] = conn
        var bag = Set<AnyCancellable>()
        conn.slotRegistrationFailed
            .sink { [weak self] slot in self?.slotRegistrationFailed.send(slot) }
            .store(in: &bag)
        conn.$isRegisteringController
            .sink { [weak self] _ in self?.recomputeAnyRegistering() }
            .store(in: &bag)
        conn.onTopologyChanged = { [weak self, weak conn] in
            guard let self, let conn else { return }
            Task { await self.syncBoundSlot(conn) }
        }
        conn.onRekeyNeeded = { [weak self, weak conn] in
            guard let self, let conn else { return }
            Task { await self.rekeySession(conn) }
        }
        perConnCancellables[conn.id] = bag
    }

    private func recomputeAnyRegistering() {
        anyControllerRegistering = connections.values.contains { $0.isRegisteringController }
    }

    /// The pool entry for `server`, created and registered on first use.
    func pooledConnection(for server: DiscoveredServer) -> WifiConnection {
        let id = WifiConnection.idFor(server)
        if let existing = connections[id] { return existing }
        let fresh = WifiConnection(id: id, server: server)
        register(fresh)
        return fresh
    }

    // MARK: - Scan state (written here; the discovery flow lives in its extension)

    /// True when a scan may start; a second request while one runs is dropped.
    func markScanStarted() -> Bool {
        if isScanning { return false }
        isScanning = true
        return true
    }

    func publishScan(_ servers: [DiscoveredServer]) {
        discoveredServers = servers
        isScanning = false
    }

    // MARK: - Stale markers

    func markStale(_ id: String) {
        if !staleSatelliteIds.contains(id) {
            staleSatelliteIds.insert(id)
        }
    }

    func clearStale(_ id: String) {
        if staleSatelliteIds.contains(id) {
            staleSatelliteIds.remove(id)
        }
    }

    // MARK: - Connect / disconnect / forget

    /// Idempotent: a second call while live or linking only refreshes the
    /// server record. A user action resets the backoff curve and lifts the
    /// replaced-session suppression.
    func connect(to server: DiscoveredServer, intent: ConnectIntent = .userInitiated) {
        let id = WifiConnection.idFor(server)
        if intent == .userInitiated { clearRetry(id) }
        if let existing = connections[id], existing.hasSession {
            existing.updateServer(server)
            return
        }
        let conn = pooledConnection(for: server)
        conn.updateServer(server)
        conn.markConnecting()
        Task { await pairAndConnect(conn: conn, server: server, intent: intent) }
    }

    /// The user's switches reach every pooled connection, whose descriptor
    /// claims only what the switches allow.
    func applyForwardingFlags(_ flags: ForwardingFlags) {
        for conn in connections.values {
            conn.setForwardingFlags(flags)
        }
    }

    /// The switches in force for one satellite's bound controller.
    func applyForwardingFlags(_ flags: ForwardingFlags, to connectionId: String) {
        connections[connectionId]?.setForwardingFlags(flags)
    }

    /// A failure is surfaced only for an attempt the user made; automatic
    /// attempts report through the row's state.
    func emitFailureIfUserInitiated(_ intent: ConnectIntent, _ failure: ConnectionFailure) {
        if intent == .userInitiated {
            events.send(.failure(failure))
        }
    }

    /// Graceful close: `DELETE /api/connections/{id}`. The row and the key
    /// survive, and no scheduled retry resurrects a session the user closed.
    func disconnect(id: String) {
        guard let conn = connections[id] else { return }
        cancelApprovalPoll(id)
        let server = conn.server
        let connectionId = conn.connectionId
        let did = deviceId
        let proof = proofFor(id)
        conn.markDisconnected()
        clearRetry(id)
        guard let connectionId else { return }
        let http = http
        Task.detached(priority: .utility) {
            await http.deleteSession(
                ip: server.ip,
                port: server.httpPort,
                connectionId: connectionId,
                deviceId: did,
                hmacProof: proof
            )
        }
    }

    /// Forget self-unpairs server-side (`DELETE /api/pair`) before the key is
    /// dropped, because the proof needs the key; then the row, the key, the
    /// pin, the catalog and every retry marker go.
    func forget(id: String) {
        cancelApprovalPoll(id)
        selfUnpair(id)
        disconnect(id: id)
        store.forget(id)
        connections.removeValue(forKey: id)
        perConnCancellables.removeValue(forKey: id)
        catalogs.removeValue(forKey: id)
        capabilities.removeValue(forKey: id)
        typeOverrides.clearConnection(id)
        motionStatus.clearConnection(id)
        clearStale(id)
        clearRetry(id)
        recomputeAnyRegistering()
    }

    private func selfUnpair(_ id: String) {
        let proof = proofFor(id)
        guard let endpoint = rememberedEndpoint(id), !proof.isEmpty else { return }
        let did = deviceId
        let http = http
        Task.detached(priority: .utility) {
            await http.unpair(ip: endpoint.ip, port: endpoint.httpPort, deviceId: did, hmacProof: proof)
        }
    }

    private func rememberedEndpoint(_ id: String) -> (ip: String, httpPort: Int)? {
        if let pooled = connections[id] {
            return (pooled.server.ip, pooled.server.httpPort)
        }
        return store.remembered().first { $0.id == id }.map { ($0.ip, $0.httpPort) }
    }

    // MARK: - Auth material

    /// The stored pairing key as raw bytes, or nil when absent or malformed.
    func pairingKeyData(for id: String) -> Data? {
        guard let hex = store.sharedKey(for: id), hex.count == 64,
              let data = hexToBytes(hex), data.count == 32 else { return nil }
        return data
    }

    /// The `X-Hmac-Proof` header value; empty when no key is stored.
    func proofFor(_ id: String) -> String {
        guard let key = pairingKeyData(for: id) else { return "" }
        return SessionCrypto.hmacProofHex(pairingKey: key, deviceId: deviceId)
    }

    /// The one funnel for every trust revocation (a terminal 401, a
    /// close-notify with the `unpaired` reason): drop only the key, park the
    /// row on "Needs pairing", tear the session and stop the retry curve.
    func handleTerminalAuth(_ id: String, loud: Bool) {
        store.forgetKey(for: id)
        markStale(id)
        clearRetry(id)
        connections[id]?.markDisconnected()
        if loud {
            events.send(.failure(.repairNeeded))
        }
    }

    // MARK: - Reconnect sweeps

    /// Reconnect every remembered satellite that is resting and whose retry
    /// is due. Silent by intent.
    func autoReconnectAll() {
        let now = Self.nowMs()
        for remembered in store.remembered() where isResting(remembered.id) {
            if let throttle = retry[remembered.id], throttle.suppressed || now < throttle.nextRetryAtMs {
                continue
            }
            connect(to: remembered.toDiscovered(), intent: .autoReconnect)
        }
    }

    private func isResting(_ id: String) -> Bool {
        guard let existing = connections[id] else { return true }
        return existing.state == .idle || existing.state == .stale
    }

    /// After a wake, sockets may be dead and addresses moved: resting rows
    /// reconnect now instead of waiting out the backoff curve. Suppressed
    /// rows (a session the satellite replaced) stay parked for the user.
    func resumeAfterWake() {
        for (id, state) in retry where !state.suppressed {
            clearRetry(id)
        }
        autoReconnectAll()
    }

    package func remembered() -> [RememberedWifi] {
        store.remembered()
    }
}
