// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Pairing flows for `WifiConnectionManager` (contract §Pairing, gaps
// G5/G16): the keyed fast path, operator-PIN path A, client-PIN path B with
// its `/api/pair/status` approval poll, and the shared outcome routing
// (version mismatch, identity change, unreachable). Split from the manager
// core the same way `SatelliteClient+IO` splits the client.

import Foundation

extension WifiConnectionManager {

    /// Kept identical to dish-android's user-facing strings so users see the
    /// same text on any client.
    static let identityChangedMessage =
        "This satellite's security identity changed. If it was reinstalled, forget it here and pair again."
    static let protocolMismatchMessage =
        "This app and the satellite speak different protocol versions. Update both to the latest version."
    static let approvalDeclinedMessage = "The satellite declined the pairing request."
    static let approvalTimeoutMessage = "No response from the satellite. The pairing request timed out."
    static let repairNeededMessage = "This satellite no longer recognizes this device. Re-pair needed."

    /// Path-B poll cadence — matches the satellite's 2-minute pairing-request
    /// TTL: stop waiting once the request can no longer be accepted on the
    /// other side. Mutable so tests can shrink the cadence.
    static var approvalPollIntervalMs = 2000
    static var approvalTimeoutMs = 120_000

    // MARK: - Connect-time pairing

    func pairAndConnect(
        conn: WifiConnection,
        server: DiscoveredServer,
        intent: ConnectIntent
    ) async {
        let id = WifiConnection.idFor(server)
        // Auto-reconnect fast path: if we already have a shared key saved for
        // this server, skip the pair handshake entirely and go straight to
        // the session PUT. A moved/offline server then fails fast in the
        // HTTP layer instead of bouncing through pair → PairingRequired and
        // trapping the user behind a PIN prompt that can't be satisfied.
        // Mirrors dish-android PR #43 / dish-linux pairAndConnect.
        if let saved = store.sharedKey(for: id), saved.count == 64 {
            await openSession(conn: conn, server: server, intent: intent)
            return
        }
        // No key + non-user intent: nothing to pair against — auto paths
        // never spam the PIN prompt. The row chip parks on "Needs pairing".
        if intent != .userInitiated {
            conn.markDisconnected()
            markStale(id)
            return
        }
        beginPairing(conn.id)
        defer { endPairing(conn.id) }
        // Empty PIN: protocol-1 has NO PIN-free path (the historical
        // "already paired → hand back the key" short-circuit is deleted), so
        // this doubles as the reachability + protocol-version probe before
        // the PIN sheet pops.
        let pair = await pairing.pair(
            ip: server.ip,
            port: server.pairPort,
            deviceId: deviceId,
            deviceName: deviceName,
            pin: ""
        )
        switch PairingClient.classify(pair) {
        case let .success(sharedKey):
            store.setSharedKey(sharedKey, for: id)
            clearStale(id)
            await openSession(conn: conn, server: server, intent: intent)
        case .authRequired, .pendingApproval:
            // (.pendingApproval can't happen without a clientPin; folded in
            // for exhaustiveness.) The server is up and wants a PIN — pop
            // the dialog.
            conn.markDisconnected()
            events.send(.pairingRequired(server))
        case .versionMismatch:
            conn.markDisconnected()
            events.send(.error(Self.protocolMismatchMessage))
        case let .unreachable(msg):
            conn.markDisconnected()
            events.send(.error(unreachableMessage(server, fallback: msg)))
        }
    }

    /// The honest failure line for a transport-level abort: a TOFU pin
    /// mismatch is an identity problem, not a connectivity one.
    func unreachableMessage(_ server: DiscoveredServer, fallback: String) -> String {
        if pinMismatches.consume(server.ip) {
            return Self.identityChangedMessage
        }
        return "Server unreachable — has it moved networks? (\(fallback))"
    }

    // MARK: - Path A (operator PIN)

    /// Finish pairing with the operator's PIN: the satellite shows a PIN,
    /// the user types it here, the response carries the shared key.
    func pairWithPin(_ server: DiscoveredServer, pin: String) {
        let id = WifiConnection.idFor(server)
        cancelApprovalPoll(id)
        let conn = connections[id] ?? {
            let newConn = WifiConnection(id: id, server: server)
            register(newConn)
            return newConn
        }()
        conn.markConnecting()
        Task {
            beginPairing(conn.id)
            defer { endPairing(conn.id) }
            let pair = await pairing.pair(
                ip: server.ip,
                port: server.pairPort,
                deviceId: deviceId,
                deviceName: deviceName,
                pin: pin
            )
            switch PairingClient.classify(pair) {
            case let .success(sharedKey):
                store.setSharedKey(sharedKey, for: id)
                clearStale(id)
                await openSession(conn: conn, server: server, intent: .userInitiated)
            case .authRequired, .pendingApproval:
                conn.markDisconnected()
                events.send(.error(pair.error ?? "Pairing failed"))
            case .versionMismatch:
                conn.markDisconnected()
                events.send(.error(Self.protocolMismatchMessage))
            case let .unreachable(msg):
                conn.markDisconnected()
                events.send(.error(unreachableMessage(server, fallback: msg)))
            }
        }
    }

    // MARK: - Path B (client PIN + approval poll)

    /// Path B (gap G16): this dish shows `clientPin`; the operator accepts it
    /// on the satellite. Submit, then poll `/api/pair/status` until accept
    /// (→ open the session), decline, or timeout — the pairing key only
    /// arrives via the poll. An already-paired device never lands here:
    /// `connect(to:)` routes a keyed satellite straight to the session PUT.
    /// Ports dish-android `requestApproval`.
    func pairWithClientPin(_ server: DiscoveredServer, clientPin: String) {
        let id = WifiConnection.idFor(server)
        let conn = connections[id] ?? {
            let newConn = WifiConnection(id: id, server: server)
            register(newConn)
            return newConn
        }()
        conn.updateServer(server)
        conn.markConnecting()
        // A re-issued request supersedes any prior poll for this id; cancel
        // it so two polls can't race to openSession on the same satellite.
        cancelApprovalPoll(id)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runApprovalFlow(conn: conn, server: server, id: id, clientPin: clientPin)
        }
        approvalPolls[id] = task
    }

    private func runApprovalFlow(
        conn: WifiConnection,
        server: DiscoveredServer,
        id: String,
        clientPin: String
    ) async {
        beginPairing(id)
        defer { endPairing(id) }
        let submitted = await pairing.pair(
            ip: server.ip,
            port: server.pairPort,
            deviceId: deviceId,
            deviceName: deviceName,
            pin: "",
            clientPin: clientPin
        )
        switch PairingClient.classify(submitted) {
        case let .success(sharedKey):
            // Not the documented path-B shape, but a key is a key.
            store.setSharedKey(sharedKey, for: id)
            clearStale(id)
            await openSession(conn: conn, server: server, intent: .userInitiated)
            return
        case .pendingApproval:
            break // poll below
        case .versionMismatch:
            conn.markDisconnected()
            events.send(.error(Self.protocolMismatchMessage))
            return
        case .authRequired:
            conn.markDisconnected()
            events.send(.error(submitted.error ?? "Pairing failed"))
            return
        case let .unreachable(msg):
            conn.markDisconnected()
            events.send(.error(unreachableMessage(server, fallback: msg)))
            return
        }
        // Poll until accept / deny / timeout. pairWithPin shares this
        // connection: once it reaches .live, bail — the poll's terminal paths
        // must not tear down a session the PIN just established.
        var waitedMs = 0
        while waitedMs < Self.approvalTimeoutMs, !Task.isCancelled {
            if conn.state == .live { return }
            try? await Task.sleep(nanoseconds: UInt64(Self.approvalPollIntervalMs) * 1_000_000)
            if Task.isCancelled { return }
            waitedMs += Self.approvalPollIntervalMs
            let status = await pairing.pairStatus(
                ip: server.ip,
                port: server.httpPort,
                deviceId: deviceId
            )
            // A transient unreachable poll is still-pending, not a refusal.
            guard status.reachable else { continue }
            // Re-check: .live may have flipped during the poll round-trip.
            if conn.state == .live || Task.isCancelled { return }
            switch PairingClient.classifyStatus(status) {
            case let .approved(sharedKeyHex):
                store.setSharedKey(sharedKeyHex, for: id)
                clearStale(id)
                await openSession(conn: conn, server: server, intent: .userInitiated)
                return
            case .pending:
                continue
            case .declined:
                conn.markDisconnected()
                events.send(.error(Self.approvalDeclinedMessage))
                return
            }
        }
        if !Task.isCancelled, conn.state != .live {
            conn.markDisconnected()
            events.send(.error(Self.approvalTimeoutMessage))
        }
    }

    func cancelApprovalPoll(_ id: String) {
        approvalPolls.removeValue(forKey: id)?.cancel()
    }
}
