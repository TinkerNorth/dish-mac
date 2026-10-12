// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

extension WifiConnectionManager {

    /// Path-B poll cadence. The timeout matches the satellite's pairing-request
    /// TTL: once the request can no longer be accepted there, waiting ends.
    struct ApprovalPolling {
        let intervalMs: Int
        let timeoutMs: Int

        static let standard = ApprovalPolling(intervalMs: 2000, timeoutMs: 120_000)
    }

    // MARK: - Connect-time pairing

    /// A stored key skips the handshake and opens the session directly, so a
    /// moved or offline satellite fails fast instead of trapping the user
    /// behind a PIN prompt. Without a key, only a user-initiated connect may
    /// probe and pop the PIN sheet.
    func pairAndConnect(conn: WifiConnection, server: DiscoveredServer, intent: ConnectIntent) async {
        let id = WifiConnection.idFor(server)
        let hasStoredKey = store.sharedKey(for: id)?.count == 64
        if hasStoredKey {
            await openSession(conn: conn, server: server, intent: intent)
            return
        }
        if intent != .userInitiated {
            conn.markDisconnected()
            markStale(id)
            return
        }
        await probeAndOpen(conn: conn, server: server)
    }

    /// An empty-PIN pair is the reachability and version probe: the
    /// protocol has no PIN-free path, so a reachable satellite answers
    /// "PIN required" and the sheet opens.
    private func probeAndOpen(conn: WifiConnection, server: DiscoveredServer) async {
        beginPairing(conn.id)
        defer { endPairing(conn.id) }
        let pair = await pairing.pair(
            ip: server.ip,
            port: server.pairPort,
            deviceId: deviceId,
            deviceName: deviceName,
            pin: ""
        )
        switch PairingClient.classify(pair) {
        case let .success(sharedKey):
            await adoptPairedKey(sharedKey, conn: conn, server: server)
        case .authRequired, .pendingApproval:
            conn.markDisconnected()
            events.send(.pairingRequired(server))
        case .versionMismatch:
            failPairing(conn, .protocolMismatch)
        case let .unreachable(detail):
            failPairing(conn, unreachableFailure(server, detail: detail))
        }
    }

    /// Store the key the satellite handed back and open the session.
    private func adoptPairedKey(_ sharedKey: String, conn: WifiConnection, server: DiscoveredServer) async {
        store.setSharedKey(sharedKey, for: conn.id)
        clearStale(conn.id)
        await openSession(conn: conn, server: server, intent: .userInitiated)
    }

    private func failPairing(_ conn: WifiConnection, _ failure: ConnectionFailure) {
        conn.markDisconnected()
        events.send(.failure(failure))
    }

    /// A transport abort after a TOFU mismatch is an identity problem, not a
    /// connectivity one.
    func unreachableFailure(_ server: DiscoveredServer, detail: String) -> ConnectionFailure {
        if pinMismatches.consume(server.ip) {
            return .identityChanged
        }
        return .unreachable(detail: detail)
    }

    // MARK: - Path A (operator PIN)

    /// The satellite shows a PIN, the user types it here, and the response
    /// carries the shared key.
    func pairWithPin(_ server: DiscoveredServer, pin: String) {
        let conn = pooledConnection(for: server)
        cancelApprovalPoll(conn.id)
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
            await handlePinResponse(pair, conn: conn, server: server)
        }
    }

    private func handlePinResponse(_ pair: PairResponse, conn: WifiConnection, server: DiscoveredServer) async {
        switch PairingClient.classify(pair) {
        case let .success(sharedKey):
            await adoptPairedKey(sharedKey, conn: conn, server: server)
        case .authRequired, .pendingApproval:
            failPairing(conn, .pairingRejected(detail: pair.error))
        case .versionMismatch:
            failPairing(conn, .protocolMismatch)
        case let .unreachable(detail):
            failPairing(conn, unreachableFailure(server, detail: detail))
        }
    }

    // MARK: - Path B (client PIN + approval poll)

    /// This dish shows `clientPin`; the operator accepts it on the satellite.
    /// Submit, then poll until approved, declined or timed out: the key only
    /// arrives through the poll. A re-issued request supersedes the prior
    /// poll so two polls cannot race to open one session.
    func pairWithClientPin(_ server: DiscoveredServer, clientPin: String) {
        let conn = pooledConnection(for: server)
        conn.updateServer(server)
        conn.markConnecting()
        cancelApprovalPoll(conn.id)
        approvalPolls[conn.id] = Task { [weak self] in
            await self?.runApprovalFlow(conn: conn, server: server, clientPin: clientPin)
        }
    }

    private func runApprovalFlow(conn: WifiConnection, server: DiscoveredServer, clientPin: String) async {
        beginPairing(conn.id)
        defer { endPairing(conn.id) }
        let submitted = await pairing.pair(
            ip: server.ip,
            port: server.pairPort,
            deviceId: deviceId,
            deviceName: deviceName,
            pin: "",
            clientPin: clientPin
        )
        if Task.isCancelled { return }
        guard await submissionNeedsPolling(submitted, conn: conn, server: server) else { return }
        await pollApproval(conn: conn, server: server)
    }

    /// Resolve the submit reply. True when the satellite parked the request
    /// for the operator and the poll must run.
    private func submissionNeedsPolling(_ submitted: PairResponse, conn: WifiConnection, server: DiscoveredServer) async -> Bool {
        switch PairingClient.classify(submitted) {
        case .pendingApproval:
            return true
        case let .success(sharedKey):
            await adoptPairedKey(sharedKey, conn: conn, server: server)
        case .versionMismatch:
            failPairing(conn, .protocolMismatch)
        case .authRequired:
            failPairing(conn, .pairingRejected(detail: submitted.error))
        case let .unreachable(detail):
            failPairing(conn, unreachableFailure(server, detail: detail))
        }
        return false
    }

    /// Poll `/api/pair/status` until a terminal answer or the timeout. A PIN
    /// pairing on the same connection may win first, in which case the poll
    /// must leave the live session alone.
    private func pollApproval(conn: WifiConnection, server: DiscoveredServer) async {
        var waitedMs = 0
        while waitedMs < approvalPolling.timeoutMs, !Task.isCancelled {
            if conn.state == .live { return }
            try? await Task.sleep(nanoseconds: UInt64(approvalPolling.intervalMs) * 1_000_000)
            if Task.isCancelled { return }
            waitedMs += approvalPolling.intervalMs
            let status = await pairing.pairStatus(ip: server.ip, port: server.httpPort, deviceId: deviceId)
            if !status.reachable { continue }
            if conn.state == .live || Task.isCancelled { return }
            if await handleApprovalStatus(status, conn: conn, server: server) == .finished { return }
        }
        if !Task.isCancelled, conn.state != .live {
            failPairing(conn, .approvalTimedOut)
        }
    }

    private enum PollStep {
        case keepPolling
        case finished
    }

    private func handleApprovalStatus(_ status: PairStatusResponse, conn: WifiConnection, server: DiscoveredServer) async -> PollStep {
        switch PairingClient.classifyStatus(status) {
        case let .approved(sharedKeyHex):
            await adoptPairedKey(sharedKeyHex, conn: conn, server: server)
            return .finished
        case .pending:
            return .keepPolling
        case .declined:
            failPairing(conn, .approvalDeclined)
            return .finished
        }
    }

    func cancelApprovalPoll(_ id: String) {
        approvalPolls.removeValue(forKey: id)?.cancel()
    }
}
