// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Session lifecycle POLICY for `WifiConnectionManager` (gaps G9/G14/G15):
// the `SessionHooks` installed at `markConnected`, the close-notify reason
// mapping (`DishCore.closeActionForReason`), heartbeat-death handling, the
// enriched-ack reconcile driver (GET then converge, single-flight), and the
// exponential reconnect backoff (`DishCore.backoffDelayMs`, 1 s → 60 s)
// that replaced the fixed 1.5 s retry. The connection itself decides
// nothing — it observes the wire and calls out through the hooks (dish-linux
// "humble object" style, PLAN D2). Split from the manager core the same way
// the pairing and session flows are.

import DishCore
import Foundation

extension WifiConnectionManager {

    /// Per-connection reconnect throttle (dish-linux `RetryState`).
    /// `suppressed` parks a connection out of every silent-retry path —
    /// close-notify(replaced) means a newer session owns the satellite and
    /// auto-reconnecting would kick it. User action clears everything.
    struct RetryState {
        var attempt = 0
        var nextRetryAtMs: Int64 = 0
        var suppressed = false
    }

    /// Wall-clock milliseconds for the retry deadlines (matches dish-linux
    /// `QDateTime::currentMSecsSinceEpoch`).
    static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    // MARK: - Hooks (installed at markConnected)

    /// The policy callbacks a live session calls out through. All decisions
    /// route back here so the per-connection state machine stays humble.
    func makeHooks(id: String) -> SessionHooks {
        var hooks = SessionHooks()
        hooks.onDead = { [weak self] in
            self?.handleDead(id)
        }
        hooks.onClose = { [weak self] reasonByte in
            self?.handleClose(id, reasonByte: reasonByte)
        }
        hooks.reconcile = { [weak self] in
            guard let self, let conn = self.connections[id] else { return }
            // The single-flight guard flips SYNCHRONOUSLY with the trigger
            // (both on the main actor) so the next alive tick can never
            // double-launch the GET while this one is still being scheduled.
            conn.setReconcileInFlight(true)
            Task { await self.runReconcile(conn) }
        }
        return hooks
    }

    // MARK: - Death / close policy (gaps G10/G15)

    /// Heartbeat death (contract §Liveness: 5 consecutive misses). Silent:
    /// the retry rides the backoff curve and the row chip parks on the
    /// `.stale` → "Unsteady" window; the user gets no banner for an attempt
    /// they didn't ask for.
    func handleDead(_ id: String) {
        guard let conn = connections[id] else { return }
        conn.parkStaleAwaitingRetry()
        scheduleRetry(id)
    }

    /// An authenticated MSG_SESSION_CLOSE reason, mapped through the pure
    /// reducer (`DishCore.closeAction(forReasonByte:)` — an unknown FUTURE
    /// byte degrades to the transient arm):
    ///   * `unpaired` → trust revoked: the terminal-auth funnel (drop key,
    ///     park "Needs pairing", stop retrying). Loud — the satellite
    ///     actively kicked this device out, which the user should hear about.
    ///   * `replaced` → a newer session (this device or another) owns the
    ///     satellite; auto-reconnecting would kick it. Park until user acts.
    ///   * `shutdown` / `kicked` → transient: re-enter the backoff curve.
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

    // MARK: - Reconcile driver (gap G9 policy side)

    /// The enriched ack said the server's applied topology drifted: GET the
    /// authoritative view, then converge. Benign drift (the applied view
    /// still matches what we want — e.g. the epoch bumped converging our own
    /// per-slot PUT) just adopts the epoch; real divergence re-PUTs the full
    /// desired state through the normal open path (the declarative PUT
    /// replaces the session and rotates the token, so the brief Connecting
    /// flip is honest). Self-heals within ~2 s of any server-side change.
    func runReconcile(_ conn: WifiConnection) async {
        guard conn.state == .live || conn.state == .faltering,
              let cid = conn.connectionId else
        {
            conn.setReconcileInFlight(false)
            return
        }
        let id = conn.id
        let server = conn.server
        let view = await http.getSession(
            ip: server.ip,
            port: server.httpPort,
            connectionId: cid,
            deviceId: deviceId,
            hmacProof: proofFor(id)
        )
        conn.setReconcileInFlight(false)
        if view.unauthorized || view.verdict == .unauthorized {
            // Centralised terminal-auth funnel; quiet — the user did not
            // initiate a reconcile (DishCore verdict; see `RestStamped`).
            handleTerminalAuth(id, loud: false)
            return
        }
        // Transient failure (or the session died while the GET was in
        // flight): drop this round — the next drift tick retries.
        guard view.reachable else { return }
        guard conn.state == .live || conn.state == .faltering else { return }

        let applied = view.controllers.map { dto in
            AppliedSlot(
                ctrlIdx: UInt8(truncatingIfNeeded: dto.ctrlIdx),
                appliedType: UInt8(truncatingIfNeeded: dto.appliedType),
                active: dto.active
            )
        }
        if appliedMatchesDesired(desired: conn.desiredSlots(), applied: applied) {
            conn.setLastAppliedEpoch(view.epoch)
            return
        }
        conn.markDisconnected()
        conn.markConnecting()
        await openSession(conn: conn, server: server, intent: .retryAfterDeath)
    }

    // MARK: - Backoff scheduling (gap G14)

    /// Arm the next silent retry on the exponential curve
    /// (`DishCore.backoffDelayMs`: 1 s, 2 s, 4 s … capped at 60 s). Each call
    /// grows the attempt; `clearRetry` (user action / session success) resets
    /// it. The armed one-shot fires `connect(intent: .retryAfterDeath)` —
    /// silent by intent — and is superseded by re-scheduling, suppression,
    /// or a user-initiated connect.
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
            self.retryTasks[id] = nil
            guard self.retry[id]?.suppressed != true else { return }
            guard let conn = self.connections[id],
                  conn.state == .idle || conn.state == .stale else { return }
            self.connect(to: conn.server, intent: .retryAfterDeath)
        }
    }

    /// Park a connection out of every silent-retry path (close-notify
    /// `replaced`). Only user action (`connect` with `.userInitiated`,
    /// `forget`) lifts it.
    func suppressRetry(_ id: String) {
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        retry[id] = RetryState(attempt: 0, nextRetryAtMs: 0, suppressed: true)
    }

    /// Drop all retry bookkeeping for `id`: cancels the armed task and resets
    /// the attempt curve + suppression.
    func clearRetry(_ id: String) {
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        retry[id] = nil
    }
}
