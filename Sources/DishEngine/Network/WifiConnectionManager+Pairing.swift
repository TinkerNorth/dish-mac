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
    /// probe and open the pairing card.
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
    /// "PIN required" and the pairing card opens.
    private func probeAndOpen(conn: WifiConnection, server: DiscoveredServer) async {
        beginPairing(conn.id)
        defer { endPairing(conn.id) }
        let pair = await pairing.pair(
            ip: server.ip,
            port: server.pairPort,
            deviceId: deviceId,
            deviceName: deviceName,
            pin: "",
            protocolVersion: conn.offeredProtocolVersion
        )
        switch PairingClient.classify(pair) {
        case let .success(sharedKey):
            await adoptPairedKey(sharedKey, conn: conn, server: server)
        case .authRequired, .pendingApproval:
            conn.markDisconnected()
            events.send(.pairingRequired(server))
        case let .versionMismatch(supported, supportedMin):
            if lowerOfferOrFail(conn, intent: .userInitiated, supported: supported, supportedMin: supportedMin) {
                await probeAndOpen(conn: conn, server: server)
            }
        case let .unreachable(detail):
            failPairing(conn, unreachableFailure(server, detail: detail))
        }
    }

    /// Store the key the satellite handed back and open the session.
    func adoptPairedKey(_ sharedKey: String, conn: WifiConnection, server: DiscoveredServer) async {
        store.setSharedKey(sharedKey, for: conn.id)
        clearStale(conn.id)
        await openSession(conn: conn, server: server, intent: .userInitiated)
    }

    private func failPairing(_ conn: WifiConnection, _ failure: ConnectionFailure) {
        conn.markDisconnected()
        events.send(.failure(failure))
    }

    /// A failure the pairing card shows, keyed to its satellite.
    func reportPairingFailure(_ conn: WifiConnection, _ failure: ConnectionFailure) {
        conn.markDisconnected()
        events.send(.pairingFailed(serverId: conn.id, failure: failure))
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
    /// carries the shared key. It runs beside an operator request on the
    /// same satellite; whichever lands first stops the other.
    func pairWithPin(_ server: DiscoveredServer, pin: String) {
        let conn = pooledConnection(for: server)
        conn.markConnecting()
        cancelPinSubmission(conn.id)
        pairingAttempts.startSubmission(conn.id)
        pinSubmissions[conn.id] = Task { [weak self] in
            await self?.submitPin(conn: conn, server: server, pin: pin)
        }
    }

    /// One PIN submission. A 409 whose range still overlaps ours submits
    /// again at the lower offer; every other answer ends the attempt.
    private func submitPin(conn: WifiConnection, server: DiscoveredServer, pin: String) async {
        beginPairing(conn.id)
        defer { endPairing(conn.id) }
        let pair = await pairing.pair(
            ip: server.ip,
            port: server.pairPort,
            deviceId: deviceId,
            deviceName: deviceName,
            pin: pin,
            protocolVersion: conn.offeredProtocolVersion
        )
        if Task.isCancelled { return }
        switch PairingClient.classify(pair) {
        case let .success(sharedKey):
            await adoptPinPairing(sharedKey, conn: conn, server: server)
        case .authRequired:
            rejectPin(conn, .wrongPin, failure: .pairingRejected(detail: pair.error))
        case .pendingApproval:
            rejectPin(conn, .pending, failure: .pairingRejected(detail: pair.error))
        case let .versionMismatch(supported, supportedMin):
            await settlePinOffer(conn: conn, server: server, pin: pin, supported: supported, supportedMin: supportedMin)
        case let .unreachable(detail):
            rejectUnreachablePin(conn, server: server, detail: detail)
        }
    }

    private func settlePinOffer(conn: WifiConnection, server: DiscoveredServer, pin: String, supported: Int, supportedMin: Int) async {
        switch settleOffer(conn, supported: supported, supportedMin: supportedMin) {
        case .retryLower:
            await submitPin(conn: conn, server: server, pin: pin)
        case let .failed(failure):
            rejectPin(conn, .versionMismatch, failure: failure)
        }
    }

    private func rejectUnreachablePin(_ conn: WifiConnection, server: DiscoveredServer, detail: String) {
        let failure = unreachableFailure(server, detail: detail)
        let rejection: PinRejection = failure == .identityChanged ? .identityChanged : .unreachable
        rejectPin(conn, rejection, failure: failure)
    }

    private func rejectPin(_ conn: WifiConnection, _ rejection: PinRejection, failure: ConnectionFailure) {
        pinSubmissions.removeValue(forKey: conn.id)
        pairingAttempts.reject(conn.id, rejection)
        reportPairingFailure(conn, failure)
    }

    /// The typed PIN landed first: the operator request stops and the
    /// session takes over from the card.
    private func adoptPinPairing(_ sharedKey: String, conn: WifiConnection, server: DiscoveredServer) async {
        pinSubmissions.removeValue(forKey: conn.id)
        cancelApprovalPoll(conn.id)
        pairingAttempts.end(conn.id)
        await adoptPairedKey(sharedKey, conn: conn, server: server)
    }

    func cancelPinSubmission(_ id: String) {
        pinSubmissions.removeValue(forKey: id)?.cancel()
    }
}
