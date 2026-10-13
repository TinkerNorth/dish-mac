// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

extension WifiConnectionManager {

    /// Per-connection reconnect throttle. `suppressed` parks a connection out
    /// of every silent retry: a session the satellite replaced belongs to a
    /// newer owner, and only the user lifts that.
    struct RetryState {
        var attempt = 0
        var nextRetryAtMs: Int64 = 0
        var suppressed = false
    }

    static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    // MARK: - Hooks a live session calls out through

    func makeHooks(id: String) -> SessionHooks {
        var hooks = SessionHooks()
        hooks.onDead = { [weak self] in
            self?.handleDead(id)
        }
        hooks.onClose = { [weak self] reasonByte in
            self?.handleClose(id, reasonByte: reasonByte)
        }
        hooks.reconcile = { [weak self] in
            self?.startReconcile(id)
        }
        return hooks
    }

    // MARK: - Death and close

    /// Heartbeat death is silent: the row parks on the "Unsteady" window and
    /// the retry rides the backoff curve.
    func handleDead(_ id: String) {
        guard let conn = connections[id] else { return }
        conn.parkStaleAwaitingRetry()
        scheduleRetry(id)
    }

    /// An authenticated close-notify, mapped through the pure reducer: trust
    /// revoked drops the key and tells the user; a replaced session stays
    /// down until the user acts; a shutdown or kick re-enters the backoff.
    func handleClose(_ id: String, reasonByte: UInt8) {
        guard let conn = connections[id] else { return }
        switch closeAction(forReasonByte: reasonByte) {
        case .dropKeyAndStale:
            handleTerminalAuth(id, loud: true)
        case .stayDown:
            conn.markDisconnected()
            suppressRetry(id)
        case .backoffRetry:
            conn.parkStaleAwaitingRetry()
            scheduleRetry(id)
        }
    }

    // MARK: - Reconcile

    /// The single-flight guard flips with the trigger, on the main actor, so
    /// the next alive tick cannot launch a second GET.
    private func startReconcile(_ id: String) {
        guard let conn = connections[id] else { return }
        conn.setReconcileInFlight(true)
        Task { await runReconcile(conn) }
    }

    /// The enriched ack said the applied topology drifted: GET the
    /// authoritative view, adopt the epoch when it still matches what we
    /// want, else re-PUT the whole desired state through the normal open.
    func runReconcile(_ conn: WifiConnection) async {
        guard conn.hasLiveSession, let connectionId = conn.connectionId else {
            conn.setReconcileInFlight(false)
            return
        }
        let server = conn.server
        let view = await http.getSession(
            ip: server.ip,
            port: server.httpPort,
            connectionId: connectionId,
            deviceId: deviceId,
            hmacProof: proofFor(conn.id)
        )
        conn.setReconcileInFlight(false)
        if view.unauthorized || view.verdict == .unauthorized {
            handleTerminalAuth(conn.id, loud: false)
            return
        }
        guard view.reachable, conn.hasLiveSession else { return }
        await converge(conn, to: view, server: server)
    }

    /// The host-feature grant is applied state too: a slot picked as the
    /// mouse mid-session leaves wants ≠ granted, and a whole PUT heals it
    /// without tearing the session down.
    private func converge(_ conn: WifiConnection, to view: SessionViewDto, server: DiscoveredServer) async {
        let applied = view.controllers.map(appliedSlot)
        let benignDrift = appliedMatchesDesired(desired: conn.desiredSlots(), applied: applied)
        if benignDrift {
            conn.setLastAppliedEpoch(view.epoch)
            if view.mouseControl.granted != conn.wantsMouseControl { await rekeySession(conn) }
            return
        }
        conn.markDisconnected()
        conn.markConnecting()
        await openSession(conn: conn, server: server, intent: .retryAfterDeath)
    }

    private func appliedSlot(_ dto: SessionViewControllerDto) -> AppliedSlot {
        AppliedSlot(
            ctrlIdx: UInt8(truncatingIfNeeded: dto.ctrlIdx),
            appliedType: UInt8(truncatingIfNeeded: dto.appliedType),
            active: dto.active
        )
    }

    // MARK: - Backoff

    /// Arm the next silent retry on the exponential curve. Re-scheduling,
    /// suppression and a user connect each supersede the armed task.
    func scheduleRetry(_ id: String) {
        var state = retry[id] ?? RetryState()
        if state.suppressed { return }
        state.attempt += 1
        let delayMs = backoffDelayMs(attempt: state.attempt)
        state.nextRetryAtMs = Self.nowMs() + Int64(delayMs)
        retry[id] = state
        retryTasks[id]?.cancel()
        retryTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            guard !Task.isCancelled, let self else { return }
            self.fireRetry(id)
        }
    }

    private func fireRetry(_ id: String) {
        retryTasks[id] = nil
        guard retry[id]?.suppressed != true else { return }
        guard let conn = connections[id], conn.state == .idle || conn.state == .stale else { return }
        connect(to: conn.server, intent: .retryAfterDeath)
    }

    func suppressRetry(_ id: String) {
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        retry[id] = RetryState(attempt: 0, nextRetryAtMs: 0, suppressed: true)
    }

    func clearRetry(_ id: String) {
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        retry[id] = nil
    }
}
