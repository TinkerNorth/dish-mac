// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import CryptoKit
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
    /// True while any pooled connection is still converging its bound slot
    /// over the per-slot REST routes (descriptor PUT/DELETE while live).
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
    /// Keyed by `DiscoveredServer.id` (`mid:<machineId>`, or the legacy
    /// `wifi:<ip>:<port>` fallback for satellites with no machineId — the
    /// same key `connections[...]` and the store use) — no separate typed
    /// `SatelliteId` exists on the Mac client, and matching the
    /// connection-pool key avoids a parallel id space the UI would have to
    /// reconcile.
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
    /// Authenticated REST gateway (sessions/controllers/unpair), same TOFU
    /// delegate composition.
    lazy var http = HTTPClient(pinVerifier: makePinVerifier())
    /// In-flight path-B approval polls, keyed by connection id, so a
    /// re-issued request supersedes the prior poll and forget/disconnect can
    /// cancel it.
    var approvalPolls: [String: Task<Void, Never>] = [:]
    /// Per-connection reconnect throttle on the `DishCore.backoffDelayMs`
    /// curve (gap G14). Mutated only by the `+Lifecycle` split
    /// (`scheduleRetry` / `suppressRetry` / `clearRetry`); user action clears
    /// everything. `internal` for the split + the lifecycle tests.
    var retry: [String: RetryState] = [:]
    /// The armed one-shot retry task per connection (fires
    /// `connect(intent: .retryAfterDeath)` when the backoff delay elapses).
    /// Superseded on re-schedule, cancelled by `clearRetry`/`suppressRetry`.
    var retryTasks: [String: Task<Void, Never>] = [:]

    init(store: ConnectionStore) {
        self.store = store
    }

    /// `pairingInFlight` mutation helpers for the `+Pairing` split (the
    /// published set keeps its `private(set)`). Depth-counted: a superseded
    /// approval flow unwinding after cancellation must not clear the marker
    /// its successor holds under the same id.
    private var pairingDepth: [String: Int] = [:]

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
    /// signals (slot apply errors + slot-registration-failed) into the
    /// manager-level event streams, plus install the data-plane hooks: slot
    /// changes converge over the per-slot REST routes, and the send counter
    /// approaching exhaustion triggers a proactive re-PUT (gap G4).
    /// (Internal for the `+Pairing` split.)
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
                // Re-home remembered satellites whose machineId matched under
                // a new address (DHCP move): the store refreshes rows in
                // place, and any idle pool entry re-points so the next
                // connect targets the current endpoint (gap G11; mirrors
                // dish-linux startDiscovery).
                self.store.refreshFromDiscovery(merged)
                let pool = self.connections
                for server in merged {
                    guard let conn = pool[server.id], conn.state == .idle else { continue }
                    conn.updateServer(server)
                }
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
        // A user action resets the backoff curve AND lifts the
        // replaced-session suppression — the user outranks both (gap G14).
        if intent == .userInitiated { clearRetry(id) }
        if let existing = connections[id] {
            // Faltering is still a live session — reconnecting over it would
            // kick a link that's mid-recovery (dish-linux connectTo).
            if existing.state == .live || existing.state == .linking || existing.state == .faltering {
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

    // `openSession` (the declarative session PUT + HKDF key handoff), the
    // proactive re-key and the per-slot converge live in
    // `WifiConnectionManager+Session.swift` — the same file split the
    // pairing flows use.

    /// Graceful close: `DELETE /api/connections/{id}` (authed; no notify —
    /// the closer already knows).
    func disconnect(id: String) {
        guard let conn = connections[id] else { return }
        cancelApprovalPoll(id)
        let server = conn.server
        let cid = conn.connectionId
        let did = deviceId
        let proof = proofFor(id)
        conn.markDisconnected()
        // An explicit disconnect parks the row — no scheduled silent retry
        // should resurrect a session the user just closed.
        clearRetry(id)
        if let cid {
            let http = http
            Task.detached(priority: .utility) {
                await http.deleteSession(
                    ip: server.ip,
                    port: server.httpPort,
                    connectionId: cid,
                    deviceId: did,
                    hmacProof: proof
                )
            }
        }
    }

    /// Forget also self-unpairs server-side (`DELETE /api/pair`,
    /// best-effort): the satellite drops this deviceId so its operator list
    /// stays truthful (contract §Pairing Delete; gap G16). Needs the proof,
    /// so it must run BEFORE the key is deleted.
    func forget(id: String) {
        cancelApprovalPoll(id)
        let endpoint: (ip: String, httpPort: Int)? =
            connections[id].map { ($0.server.ip, $0.server.httpPort) }
                ?? store.remembered().first { $0.id == id }.map { ($0.ip, $0.httpPort) }
        let proof = proofFor(id)
        if let endpoint, !proof.isEmpty {
            let did = deviceId
            let http = http
            Task.detached(priority: .utility) {
                await http.unpair(
                    ip: endpoint.ip,
                    port: endpoint.httpPort,
                    deviceId: did,
                    hmacProof: proof
                )
            }
        }
        disconnect(id: id)
        store.forget(id)
        connections.removeValue(forKey: id)
        perConnCancellables.removeValue(forKey: id)
        // The satellite is gone from the saved list — any stale marker or
        // armed retry for it would dangle on (or resurrect) a row that no
        // longer exists.
        clearStale(id)
        clearRetry(id)
        recomputeAnyRegistering()
    }

    // MARK: - Auth material (contract §hmacProof)

    /// The stored pairing key as raw bytes, or nil when absent/malformed.
    /// (Internal for the `+Session` split.)
    func pairingKeyData(for id: String) -> Data? {
        guard let hex = store.sharedKey(for: id), hex.count == 64,
              let data = hexToBytes(hex), data.count == 32 else { return nil }
        return data
    }

    /// `hex(HMAC-SHA256(pairingKey, "satellite-proof:" + deviceId))` for the
    /// `X-Hmac-Proof` header; empty when no key is stored.
    func proofFor(_ id: String) -> String {
        guard let key = pairingKeyData(for: id) else { return "" }
        return SessionCrypto.hmacProofHex(pairingKey: key, deviceId: deviceId)
    }

    /// Terminal auth (401 NOT_PAIRED / BAD_PROOF on any authed route, and
    /// close-notify(unpaired) via `handleClose`): the satellite revoked our
    /// trust. The ONE funnel for every trust-revocation path — drops ONLY the
    /// key (the remembered row survives and parks on the persistent "Needs
    /// pairing" marker instead of silently deleting the satellite), tears the
    /// session, and STOPS the retry curve — re-pairing needs the user, so
    /// silent retries would just hammer a server that already said no.
    /// Loud only when the user has context for the failure (gaps G6/G15).
    func handleTerminalAuth(_ id: String, loud: Bool) {
        store.forgetKey(for: id)
        markStale(id)
        clearRetry(id)
        connections[id]?.markDisconnected()
        if loud {
            events.send(.error(Self.repairNeededMessage))
        }
    }

    /// Reconnect every remembered server that isn't already live. Safe to call
    /// on every app-foreground — all paths are idempotent.
    ///
    /// Passes `.autoReconnect` so a server that's down on cold start fails
    /// silently (the row chip carries the feedback). A banner here would
    /// fire on every launch where a remembered satellite is offline, which
    /// is noise the user didn't ask for.
    ///
    /// Respects the per-connection backoff curve and the replaced-session
    /// suppression (gap G14): a row whose armed retry hasn't come due — or
    /// that close-notify(replaced) parked until the user acts — is skipped.
    func autoReconnectAll() {
        let now = Self.nowMs()
        for remembered in store.remembered() {
            let existing = connections[remembered.id]
            let resting = existing == nil || existing?.state == .idle || existing?.state == .stale
            guard resting else { continue }
            if let throttle = retry[remembered.id], throttle.suppressed || now < throttle.nextRetryAtMs {
                continue
            }
            connect(to: remembered.toDiscovered(), intent: .autoReconnect)
        }
    }

    /// Wake-from-sleep: sockets may be dead and the IP may have moved, so
    /// resting rows reconnect NOW instead of waiting out the backoff curve.
    /// Suppressed rows (close-notify `replaced`) stay parked — only the user
    /// lifts those.
    func resumeAfterWake() {
        for (id, state) in retry where !state.suppressed {
            clearRetry(id)
        }
        autoReconnectAll()
    }

    func remembered() -> [RememberedWifi] {
        store.remembered()
    }
}
