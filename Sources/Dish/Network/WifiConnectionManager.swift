// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import Foundation
import os

enum ConnectionEvent {
    case pairingRequired(DiscoveredServer)
    case error(String)
}

/// Thread-safe breadcrumb log of hosts whose presented TLS cert mismatched
/// the stored TOFU pin. The `PinVerifier` (URLSession delegate queue) records;
/// the manager's failure paths consume so a mismatch abort surfaces as the
/// honest "identity changed" message instead of a generic "unreachable" —
/// mirrors dish-android's IDENTITY_CHANGED_MSG UX.
final class PinMismatchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: Set<String> = []

    func record(_ host: String) {
        lock.lock()
        defer { lock.unlock() }
        hosts.insert(host)
    }

    /// True (and clears the breadcrumb) when `host` mismatched since the
    /// last consume.
    func consume(_ host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return hosts.remove(host) != nil
    }
}

/// Why a connect attempt was initiated. The same connect path is shared
/// between three callers with very different user-feedback expectations:
///
/// - `userInitiated` — the user tapped Connect / a discovered row. Failures
///   SHOULD surface a banner (the user just took an action that's about to
///   silently fail otherwise).
/// - `autoReconnect` — fired on app launch by `autoReconnectAll`. Failures
///   MUST be silent: a banner on every cold start where a server is down
///   would be pure noise.
/// - `retryAfterDeath` — fired by the alive-poll's onDead path after a short
///   backoff. Same silence policy as `autoReconnect`: the row chip's natural
///   Connecting → Online / Saved transition is the only feedback the user
///   needs. Ports `ConnectIntent.RETRY_AFTER_DEATH` from
///   `SatelliteConnectionManager.kt`.
enum ConnectIntent { case userInitiated, autoReconnect, retryAfterDeath }

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
    /// Persistent "Needs pairing" markers — the server has forgotten this
    /// device's shared key (or we never opened a session with our stored one)
    /// so the row chip needs to read `.stale` until a fresh user-initiated
    /// pair re-establishes us, *not* fall back to `.saved` between the failed
    /// silent retry and the next user tap. Set when an auto-reconnect /
    /// retry-after-death lands on `authRequired`; cleared the moment a live
    /// session is established (or the user forgets the satellite). Mirrors
    /// `staleSatelliteIds` in `dish-android/SatelliteConnectionManager.kt`.
    ///
    /// Keyed by `DiscoveredServer.id` (the `wifi:<ip>:<port>` string the
    /// rest of this layer already uses for `connections[...]` and the store)
    /// — no separate typed `SatelliteId` exists on the Mac client, and
    /// matching the connection-pool key avoids a parallel id space the UI
    /// would have to reconcile.
    @Published private(set) var staleSatelliteIds: Set<String> = []
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

    // The stored properties below are `internal` (not `private`) because the
    // pairing flows live in `WifiConnectionManager+Pairing.swift` — Swift
    // scopes `private` to the file, and weakening the lint limits instead of
    // splitting the file is not an option.

    let store: ConnectionStore
    lazy var deviceId = store.getOrCreateDeviceId()
    let deviceName = Host.current().localizedName ?? "Mac"
    private var perConnCancellables: [String: Set<AnyCancellable>] = [:]
    /// TOFU mismatch breadcrumbs recorded by the pin verifier (see
    /// `PinMismatchLog`).
    let pinMismatches = PinMismatchLog()
    /// Pairing gateway with the TOFU delegate installed. Lazy: the verifier
    /// composition needs `store`.
    lazy var pairing = PairingClient(pinVerifier: makePinVerifier())
    /// In-flight path-B approval polls, keyed by connection id, so a
    /// re-issued request supersedes the prior poll and forget/disconnect can
    /// cancel it.
    var approvalPolls: [String: Task<Void, Never>] = [:]

    init(store: ConnectionStore) {
        self.store = store
    }

    /// `pairingInFlight` mutation helpers for the `+Pairing` split (the
    /// published set keeps its `private(set)`).
    func beginPairing(_ id: String) {
        pairingInFlight.insert(id)
    }

    func endPairing(_ id: String) {
        pairingInFlight.remove(id)
    }

    /// TOFU (gap G7): first contact pins the cert's SHA-256 DER fingerprint
    /// for this host; any later cert that differs is rejected (anti-MITM) and
    /// the mismatch is breadcrumbed for the honest error message. The store's
    /// pin accessors are lock-guarded because this runs on URLSession's
    /// delegate queue. Composes DishCore's pure verdict ladder.
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

    /// Insert `conn` into the pool and start forwarding its per-connection
    /// signals (controller-ack errors + slot-registration-failed) into the
    /// manager-level event streams. (Internal for the `+Pairing` split.)
    func register(_ conn: WifiConnection) {
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

    // MARK: - Stale markers

    /// Insert a satellite into the persistent "Needs pairing" set. Idempotent
    /// (already-stale ids stay a single entry). `internal` rather than
    /// `private` so the unit tests can pin the set-mutation contract without
    /// having to drive a real pair handshake — same seam pattern the Android
    /// equivalent (`markStale` in `SatelliteConnectionManager.kt`) uses for
    /// its own tests.
    func markStale(_ id: String) {
        if !staleSatelliteIds.contains(id) {
            staleSatelliteIds.insert(id)
        }
    }

    /// Drop a satellite from the stale set. Idempotent — calling on an id
    /// that wasn't stale is a no-op (the published value doesn't churn,
    /// which keeps SwiftUI diffs cheap).
    func clearStale(_ id: String) {
        if staleSatelliteIds.contains(id) {
            staleSatelliteIds.remove(id)
        }
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
    ///
    /// `intent` decides whether downstream failures emit a user-visible
    /// banner. The default `.userInitiated` matches the legacy behaviour
    /// (callers like the Connect button); `autoReconnectAll` + the
    /// alive-poll's silent retry pass `.autoReconnect` / `.retryAfterDeath`
    /// so a server that's down on launch / silently drops a session doesn't
    /// fire a banner the user didn't ask for.
    func connect(to server: DiscoveredServer, intent: ConnectIntent = .userInitiated) {
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
        Task { await pairAndConnect(conn: conn, server: server, intent: intent) }
    }

    /// Emit a `ConnectionEvent.error` only when the user has a recent mental
    /// model for "I asked for this". Background auto-reconnects + silent
    /// retries after a heartbeat death already have all the feedback the
    /// user needs in the row chip; a banner on top would be noise.
    /// (Internal for the `+Pairing` split.)
    func emitErrorIfUserInitiated(_ intent: ConnectIntent, _ message: String) {
        if intent == .userInitiated {
            events.send(.error(message))
        }
    }

    func openSession(
        conn: WifiConnection,
        server: DiscoveredServer,
        intent: ConnectIntent
    ) async {
        let id = WifiConnection.idFor(server)
        guard let keyHex = store.sharedKey(for: id),
              keyHex.count == 64,
              let keyData = hexToBytes(keyHex), keyData.count == 32 else
        {
            conn.markDisconnected()
            // Silent retry / cold-launch reconnect with no usable key on
            // disk: the only useful next step is a fresh user-initiated
            // pair, so mark the row "Needs pairing" until that happens.
            // User-initiated callers already get the explicit banner.
            if intent != .userInitiated {
                markStale(id)
            }
            emitErrorIfUserInitiated(intent, "No shared key — re-pair needed")
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
            emitErrorIfUserInitiated(intent, "Error: \(resp.error ?? "connection failed")")
            return
        }
        let client = SatelliteClient()
        guard client.openSocket(ip: server.ip, port: server.udpPort) else {
            conn.markDisconnected()
            return
        }
        client.setConnectionParams(token: tokenData, key: keyData)
        store.remember(server)
        // Successful authenticated session: any "Needs pairing" marker we
        // set on a prior failed silent retry no longer applies. Clearing
        // here (rather than in the caller) covers all three intents —
        // userInitiated, autoReconnect, retryAfterDeath — uniformly.
        clearStale(id)
        conn.markConnected(client: client, connectionId: connId) { [weak self] in
            // Heartbeats stopped. The alive-poll already flipped the wire
            // state to `.stale` before invoking us; tear down the dead
            // session and kick a short-backoff silent reconnect attempt
            // using the saved shared key. If the satellite is just
            // momentarily unreachable (Wi-Fi roam, brief drop) the chip
            // glides Online → Connecting… → Online without a banner. If
            // the outage persists, the silent retry fails and the chip
            // lands on `.saved` / `.ready` — still no banner, because the
            // user didn't ask for this attempt. Ports
            // `SatelliteConnectionManager.kt` AUTO_RETRY_BACKOFF_MS.
            guard let self else { return }
            let staleServer = server
            self.disconnect(id: conn.id)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.autoRetryBackoffNs)
                guard let self else { return }
                if self.connections[conn.id]?.state == .idle {
                    self.connect(to: staleServer, intent: .retryAfterDeath)
                }
            }
        }
    }

    /// Delay before the alive-poll's onDead path attempts a silent reconnect.
    /// Short enough that a momentary Wi-Fi drop self-heals before the user
    /// navigates away in frustration; long enough that a real outage doesn't
    /// burn the satellite's TCP/UDP buffers with back-to-back retries. The
    /// retry path uses `.retryAfterDeath` so it's silent on failure.
    private static let autoRetryBackoffNs: UInt64 = 1_500_000_000

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
        cancelApprovalPoll(id)
        disconnect(id: id)
        store.forget(id)
        connections.removeValue(forKey: id)
        perConnCancellables.removeValue(forKey: id)
        // The satellite is gone from the saved list — any stale marker for
        // it would dangle on a row that no longer exists.
        clearStale(id)
        recomputeAnyRegistering()
    }

    /// Reconnect every remembered server that isn't already live. Safe to call
    /// on every app-foreground — all paths are idempotent.
    ///
    /// Passes `.autoReconnect` so a server that's down on cold start fails
    /// silently (the row chip carries the feedback). A banner here would
    /// fire on every launch where a remembered satellite is offline, which
    /// is noise the user didn't ask for.
    func autoReconnectAll() {
        for remembered in store.remembered() {
            let existing = connections[remembered.id]
            if existing?.state != .live {
                connect(to: remembered.toDiscovered(), intent: .autoReconnect)
            }
        }
    }

    func remembered() -> [RememberedWifi] {
        store.remembered()
    }
}
