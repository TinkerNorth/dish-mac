// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// Path B, the operator request: this dish shows a client PIN, files it with
/// the satellite, and polls until the operator answers there. The decisions
/// are `classifyApproval` and `nextReversePairingAction`; this performs them.
extension WifiConnectionManager {

    /// The Mac polls only once the submit has answered "pending", so that
    /// answer is the pending a later "none" is read against: a decline that
    /// lands before the first poll still reads as a decline.
    private static let submitAnsweredPending = true

    private enum PollStep {
        case keepPolling
        case finished
    }

    /// File `clientPin` and poll for the operator's answer. A re-issued
    /// request supersedes the prior poll so two polls cannot race to open
    /// one session.
    func pairWithClientPin(_ server: DiscoveredServer, clientPin: String) {
        let conn = pooledConnection(for: server)
        conn.updateServer(server)
        conn.markConnecting()
        cancelApprovalPoll(conn.id)
        pairingAttempts.awaitApproval(conn.id, clientPin: clientPin)
        approvalPolls[conn.id] = Task { [weak self] in
            await self?.runApprovalFlow(conn: conn, server: server, clientPin: clientPin)
        }
    }

    /// The user closed the card: the poll and the typed PIN stop, the phase
    /// goes back to nothing and the row rests. An approval that already
    /// handed off to the session is left to finish.
    func cancelApproval(_ id: String) {
        guard let attempt = pairingAttempts.state[id], attempt.phase != .approved else { return }
        dropPairing(id)
        if let conn = connections[id], !conn.hasLiveSession {
            conn.markDisconnected()
        }
    }

    /// Every trace of a pairing goes: the poll, the typed PIN, the attempt.
    func dropPairing(_ id: String) {
        cancelApprovalPoll(id)
        cancelPinSubmission(id)
        pairingAttempts.end(id)
    }

    func cancelApprovalPoll(_ id: String) {
        approvalPolls.removeValue(forKey: id)?.cancel()
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
            clientPin: clientPin,
            protocolVersion: conn.offeredProtocolVersion
        )
        if Task.isCancelled { return }
        guard await submissionNeedsPolling(submitted, conn: conn, server: server, clientPin: clientPin) else { return }
        await pollApproval(conn: conn, server: server)
    }

    /// Resolve the submit reply. True when the satellite parked the request
    /// for the operator and the poll must run. A 409 whose range still
    /// overlaps ours runs the whole flow again at the lower offer.
    private func submissionNeedsPolling(
        _ submitted: PairResponse,
        conn: WifiConnection,
        server: DiscoveredServer,
        clientPin: String
    ) async -> Bool {
        switch PairingClient.classify(submitted) {
        case .pendingApproval:
            return true
        case let .success(sharedKey):
            await adoptApproval(sharedKey, conn: conn, server: server)
        case let .versionMismatch(supported, supportedMin):
            await settleApprovalOffer(conn: conn, server: server, clientPin: clientPin, supported: supported, supportedMin: supportedMin)
        case .authRequired:
            endApproval(conn, phase: .timedOut, failure: .pairingRejected(detail: submitted.error))
        case let .unreachable(detail):
            endUnreachableApproval(conn, server: server, detail: detail)
        }
        return false
    }

    private func settleApprovalOffer(
        conn: WifiConnection,
        server: DiscoveredServer,
        clientPin: String,
        supported: Int,
        supportedMin: Int
    ) async {
        switch settleOffer(conn, supported: supported, supportedMin: supportedMin) {
        case .retryLower:
            await runApprovalFlow(conn: conn, server: server, clientPin: clientPin)
        case let .failed(failure):
            endApproval(conn, phase: .versionMismatch, failure: failure)
        }
    }

    /// A request that never landed can only be retried with a new code.
    private func endUnreachableApproval(_ conn: WifiConnection, server: DiscoveredServer, detail: String) {
        let failure = unreachableFailure(server, detail: detail)
        let phase: ReversePairingPhase = failure == .identityChanged ? .identityChanged : .timedOut
        endApproval(conn, phase: phase, failure: failure)
    }

    /// Poll `/api/pair/status` until the reducer says the request is over. A
    /// PIN pairing that wins first cancels this poll.
    private func pollApproval(conn: WifiConnection, server: DiscoveredServer) async {
        var elapsedMs = 0
        while await waitOneInterval() {
            elapsedMs += approvalPolling.intervalMs
            let status = await pairing.pairStatus(ip: server.ip, port: server.httpPort, deviceId: deviceId)
            let superseded = Task.isCancelled || conn.state == .live
            if superseded { return }
            let step = await applyApprovalReply(status, elapsedMs: elapsedMs, conn: conn, server: server)
            if step == .finished { return }
        }
    }

    private func waitOneInterval() async -> Bool {
        try? await Task.sleep(nanoseconds: UInt64(approvalPolling.intervalMs) * 1_000_000)
        return !Task.isCancelled
    }

    /// A handshake that aborts on a changed certificate ends the request
    /// before the reducer sees it as a blip worth waiting out.
    private func applyApprovalReply(
        _ status: PairStatusResponse,
        elapsedMs: Int,
        conn: WifiConnection,
        server: DiscoveredServer
    ) async -> PollStep {
        if !status.reachable, pinMismatches.consume(server.ip) {
            endApproval(conn, phase: .identityChanged, failure: .identityChanged)
            return .finished
        }
        let reply = PairingClient.approvalReply(status)
        let verdict = classifyApproval(reply, sawPending: Self.submitAnsweredPending)
        let action = nextReversePairingAction(verdict: verdict, elapsedMs: elapsedMs, deadlineMs: approvalPolling.timeoutMs)
        return await perform(action, conn: conn, server: server)
    }

    private func perform(_ action: ReversePairingAction, conn: WifiConnection, server: DiscoveredServer) async -> PollStep {
        switch action {
        case let .approve(sharedKeyHex):
            await adoptApproval(sharedKeyHex, conn: conn, server: server)
            return .finished
        case .decline:
            endApproval(conn, phase: .declined, failure: .approvalDeclined)
            return .finished
        case .timeOut:
            endApproval(conn, phase: .timedOut, failure: .approvalTimedOut)
            return .finished
        case .keepPolling:
            return .keepPolling
        }
    }

    /// The operator approved first: the typed PIN stops, the card reads
    /// "approved" while the session opens, and the session then takes over.
    private func adoptApproval(_ sharedKey: String, conn: WifiConnection, server: DiscoveredServer) async {
        approvalPolls.removeValue(forKey: conn.id)
        cancelPinSubmission(conn.id)
        pairingAttempts.finish(conn.id, phase: .approved)
        await adoptPairedKey(sharedKey, conn: conn, server: server)
        pairingAttempts.end(conn.id)
    }

    private func endApproval(_ conn: WifiConnection, phase: ReversePairingPhase, failure: ConnectionFailure) {
        approvalPolls.removeValue(forKey: conn.id)
        pairingAttempts.finish(conn.id, phase: phase)
        reportPairingFailure(conn, failure)
    }
}
