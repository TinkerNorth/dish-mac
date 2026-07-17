// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Deterministic alive-tick + retry-policy coverage (gaps G9/G14/G15): drives
// `WifiConnection.aliveTick()` by hand with the loop parked
// (`tickIntervalNs: .max`), crafting the client's atomics directly — no
// sockets served, no sleeps, no live cadences. The FakeSatellite-driven
// state-entry proofs live in LifecyclePolicyLiveTests / ReconcileDriverLiveTests.

import CryptoKit
import DishCore
import XCTest
@testable import Dish

@MainActor
final class LifecyclePolicyTickTests: XCTestCase {

    private var conn: WifiConnection!
    private var client: SatelliteClient!

    private static let server = DiscoveredServer(
        name: "Tick",
        ip: "127.0.0.1",
        udpPort: 9,
        machineId: "tick-sat"
    )

    /// A connection promoted to `.live` with a real (but silent) client and
    /// custom hooks: the socket points at the discard port, the heartbeat
    /// timer is stopped right after start so `missedAcks`/`connectionAlive`
    /// stay exactly where the test puts them, and the alive loop is parked
    /// (`.max` cadence) so only manual `aliveTick()` calls evaluate policy.
    private func makeLive(
        epoch: Int = 1,
        hooks: SessionHooks
    ) throws -> (WifiConnection, SatelliteClient) {
        let conn = WifiConnection(id: Self.server.id, server: Self.server, tickIntervalNs: .max)
        let client = SatelliteClient()
        XCTAssertTrue(client.setConnectionParams(
            host: "127.0.0.1",
            udpPort: 9,
            token: 0x0102_0304,
            sessionKey: SymmetricKey(size: .bits256)
        ))
        conn.markConnecting()
        conn.markConnected(client: client, connectionId: "conn_t", epoch: epoch, hooks: hooks)
        // Freeze the wire inputs: no heartbeat bumps, no receive resets.
        client.stopHeartbeat()
        client.stopReceiveLoop()
        client.missedAcks.set(0)
        client.connectionAlive.set(true)
        return (conn, client)
    }

    override func tearDown() {
        conn?.markDisconnected()
        conn = nil
        client = nil
        super.tearDown()
    }

    // MARK: - Faltering (gap G15)

    func testTwoMissedHeartbeatsEnterFaltering() throws {
        (conn, client) = try makeLive(hooks: SessionHooks())
        XCTAssertEqual(conn.state, .live)

        client.missedAcks.set(ProtocolConstants.heartbeatMissNotResponding)
        XCTAssertEqual(conn.aliveTick(), .running)
        XCTAssertEqual(conn.state, .faltering, "2 consecutive misses must read Unsteady")
    }

    func testFalteringRecoversToLiveWhenAcksResume() throws {
        (conn, client) = try makeLive(hooks: SessionHooks())
        client.missedAcks.set(2)
        conn.aliveTick()
        XCTAssertEqual(conn.state, .faltering)

        // The receive path zeroes the miss counter on every ack.
        client.missedAcks.set(0)
        XCTAssertEqual(conn.aliveTick(), .running)
        XCTAssertEqual(conn.state, .live, "an ack ends the faltering window")
    }

    func testSingleMissStaysLive() throws {
        (conn, client) = try makeLive(hooks: SessionHooks())
        client.missedAcks.set(ProtocolConstants.heartbeatMissNotResponding - 1)
        conn.aliveTick()
        XCTAssertEqual(conn.state, .live, "the not-responding threshold is 2, not 1")
    }

    func testFalteringConnectionStillConvergesTopology() throws {
        (conn, client) = try makeLive(hooks: SessionHooks())
        client.missedAcks.set(2)
        conn.aliveTick()
        XCTAssertEqual(conn.state, .faltering)

        var converges = 0
        conn.onTopologyChanged = { converges += 1 }
        conn.attachSlot("slot-f", controllerType: 0, hasMotion: false, hasLight: false)
        XCTAssertEqual(converges, 1, "faltering is still a live session — REST converge must fire")
        conn.detachSlot()
        XCTAssertEqual(converges, 2)
    }

    func testMarkConnectingDoesNotDowngradeFaltering() throws {
        (conn, client) = try makeLive(hooks: SessionHooks())
        client.missedAcks.set(2)
        conn.aliveTick()

        conn.markConnecting()
        XCTAssertEqual(conn.state, .faltering, "a connect over a faltering session must not relink")
    }

    // MARK: - Death (gap G15 stale window)

    func testDeathThresholdFiresOnDeadOnceAndEndsTheTickLoop() throws {
        var deaths = 0
        var hooks = SessionHooks()
        hooks.onDead = { deaths += 1 }
        (conn, client) = try makeLive(hooks: hooks)

        client.connectionAlive.set(false)
        XCTAssertEqual(conn.aliveTick(), .sessionEnded, "death must stop the alive loop")
        XCTAssertEqual(deaths, 1)
    }

    func testParkStaleAwaitingRetryParksWireStateOnStale() throws {
        (conn, client) = try makeLive(hooks: SessionHooks())
        conn.parkStaleAwaitingRetry()
        XCTAssertEqual(conn.state, .stale, "the silent-retry window reads .stale, not .idle")
        XCTAssertNil(conn.client, "the dead client is torn down")
        XCTAssertNil(conn.connectionId)

        // A user tap (or the armed retry) relinks from .stale.
        conn.markConnecting()
        XCTAssertEqual(conn.state, .linking)
    }

    // MARK: - Close-notify dispatch (gap G10 policy path)

    func testLatchedCloseReasonDispatchesOnCloseNotOnDead() throws {
        var deaths = 0
        var closes: [UInt8] = []
        var hooks = SessionHooks()
        hooks.onDead = { deaths += 1 }
        hooks.onClose = { closes.append($0) }
        (conn, client) = try makeLive(hooks: hooks)

        // The receive path latches the reason AND drops liveness; the close
        // branch must win (terminal-now, not a death retry).
        client.sessionCloseReason.set(Int(CloseReason.replaced.rawValue))
        client.connectionAlive.set(false)
        XCTAssertEqual(conn.aliveTick(), .sessionEnded)
        XCTAssertEqual(closes, [CloseReason.replaced.rawValue])
        XCTAssertEqual(deaths, 0, "a latched close is not a heartbeat death")
    }

    func testUnknownFutureCloseReasonStillRoutesRawByte() throws {
        var closes: [UInt8] = []
        var hooks = SessionHooks()
        hooks.onClose = { closes.append($0) }
        (conn, client) = try makeLive(hooks: hooks)

        client.sessionCloseReason.set(200)
        conn.aliveTick()
        XCTAssertEqual(closes, [200], "policy mapping owns the unknown-byte degrade, not the tick")
        XCTAssertEqual(closeAction(forReasonByte: 200), .backoffRetry)
    }

    // MARK: - Reconcile trigger (gap G9 policy side)

    /// Seed the client's enriched-ack snapshot; the next tick copies it into
    /// `lastHeartbeatAck` and evaluates drift.
    private func seedAck(epoch: UInt16, bitmap: UInt16) {
        client.storeHeartbeatAck(HeartbeatAck(
            backendAvailable: true,
            activeCount: 0,
            epoch: epoch,
            bitmap: bitmap
        ))
    }

    func testEpochDriftFiresReconcileOnce() throws {
        var reconciles = 0
        var hooks = SessionHooks()
        hooks.reconcile = { [weak self] in
            reconciles += 1
            // The manager's hook flips the guard synchronously — mimic it.
            self?.conn.setReconcileInFlight(true)
        }
        (conn, client) = try makeLive(epoch: 1, hooks: hooks)

        seedAck(epoch: 9, bitmap: 0)
        conn.aliveTick()
        XCTAssertEqual(reconciles, 1, "epoch 9 vs applied 1 is drift")

        conn.aliveTick()
        conn.aliveTick()
        XCTAssertEqual(reconciles, 1, "single-flight: no re-trigger while the GET is out")

        // The manager's GET landed benign: adopt the epoch, clear the guard.
        conn.setReconcileInFlight(false)
        conn.setLastAppliedEpoch(9)
        conn.aliveTick()
        XCTAssertEqual(reconciles, 1, "adopted epoch means no drift — the loop is closed")
    }

    func testBitmapDriftAloneFiresReconcile() throws {
        var reconciles = 0
        var hooks = SessionHooks()
        hooks.reconcile = { reconciles += 1 }
        (conn, client) = try makeLive(epoch: 3, hooks: hooks)

        // Epoch matches, but the server claims an active slot we never
        // applied (expected bitmap is empty — no slot bound).
        seedAck(epoch: 3, bitmap: 0b1)
        conn.aliveTick()
        XCTAssertEqual(reconciles, 1)
    }

    func testMatchingAckDoesNotReconcile() throws {
        var reconciles = 0
        var hooks = SessionHooks()
        hooks.reconcile = { reconciles += 1 }
        (conn, client) = try makeLive(epoch: 3, hooks: hooks)

        seedAck(epoch: 3, bitmap: 0)
        conn.aliveTick()
        XCTAssertEqual(reconciles, 0)
    }

    func testNoEnrichedAckYetMeansNoReconcile() throws {
        var reconciles = 0
        var hooks = SessionHooks()
        hooks.reconcile = { reconciles += 1 }
        (conn, client) = try makeLive(epoch: 1, hooks: hooks)

        conn.aliveTick() // snapshot is still nil — a short ack never parsed
        XCTAssertEqual(reconciles, 0, "reconcile needs an enriched ack to compare against")
    }

    func testAppliedSlotBeliefFeedsExpectedBitmap() throws {
        var reconciles = 0
        var hooks = SessionHooks()
        hooks.reconcile = { reconciles += 1 }
        (conn, client) = try makeLive(epoch: 5, hooks: hooks)

        // Bound + server-confirmed slot 0: expected bitmap 0b1 matches.
        conn.attachSlot("slot-a", controllerType: 0, hasMotion: false, hasLight: false)
        conn.markSlotApplied()
        seedAck(epoch: 5, bitmap: 0b1)
        conn.aliveTick()
        XCTAssertEqual(reconciles, 0, "applied belief matches the ack — no drift")

        // The server unplugged it (admin action): bitmap empties.
        seedAck(epoch: 5, bitmap: 0)
        conn.aliveTick()
        XCTAssertEqual(reconciles, 1, "belief says applied, ack says gone — drift")
    }

    func testConvergeInFlightDoesNotReadAsDrift() throws {
        var reconciles = 0
        var hooks = SessionHooks()
        hooks.reconcile = { reconciles += 1 }
        (conn, client) = try makeLive(epoch: 5, hooks: hooks)

        // Desire exists but the per-slot PUT hasn't landed: the expected
        // bitmap must come from the applied BELIEF (empty), not the want —
        // otherwise every converge flight would false-positive.
        conn.attachSlot("slot-a", controllerType: 0, hasMotion: false, hasLight: false)
        seedAck(epoch: 5, bitmap: 0)
        conn.aliveTick()
        XCTAssertEqual(reconciles, 0)
    }

    func testDesiredSlotsReflectBindingForTheGetCompare() throws {
        (conn, client) = try makeLive(hooks: SessionHooks())
        XCTAssertEqual(conn.desiredSlots(), [])
        conn.attachSlot("slot-a", controllerType: 0, hasMotion: true, hasLight: true)
        XCTAssertEqual(conn.desiredSlots(), [DesiredSlot(ctrlIdx: 0, type: 0)])
        conn.detachSlot()
        XCTAssertEqual(conn.desiredSlots(), [])
    }

    // MARK: - Teardown resets reconcile state

    func testTeardownResetsReconcileAndTelemetryState() throws {
        var hooks = SessionHooks()
        hooks.reconcile = {}
        (conn, client) = try makeLive(epoch: 7, hooks: hooks)
        conn.setReconcileInFlight(true)
        conn.attachSlot("slot-a", controllerType: 0, hasMotion: false, hasLight: false)
        conn.markSlotApplied()

        conn.markDisconnected()
        XCTAssertEqual(conn.lastAppliedEpoch, -1)
        XCTAssertFalse(conn.reconcileInFlight)
        XCTAssertFalse(conn.slotApplied)
        XCTAssertNil(conn.latencyOneWayMs)
        XCTAssertEqual(conn.latencySamples, 0)
    }
}

// MARK: - Manager retry policy (gap G14) — no live sockets

@MainActor
final class LifecycleRetryPolicyTests: XCTestCase {

    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var store: ConnectionStore!
    private var manager: WifiConnectionManager!

    private static let server = DiscoveredServer(
        name: "Retry",
        ip: "192.0.2.99",
        udpPort: 9876,
        machineId: "retry-sat"
    )

    private var id: String {
        Self.server.id
    }

    override func setUp() {
        super.setUp()
        defaultsName = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
        store = ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore())
        manager = WifiConnectionManager(store: store)
    }

    override func tearDown() {
        manager.clearRetry(id)
        defaults.removePersistentDomain(forName: defaultsName)
        super.tearDown()
    }

    func testScheduleRetryWalksTheBackoffCurve() {
        let before = WifiConnectionManager.nowMs()
        for attempt in 1 ... 8 {
            manager.scheduleRetry(id)
            let state = manager.retry[id]
            XCTAssertEqual(state?.attempt, attempt)
            let delay = Int64(backoffDelayMs(attempt: attempt))
            XCTAssertGreaterThanOrEqual(
                state?.nextRetryAtMs ?? 0,
                before + delay,
                "deadline must sit at least backoffDelayMs(\(attempt)) out"
            )
        }
        // The curve is the DishCore schedule: 1 s, 2 s, … capped at 60 s.
        XCTAssertEqual(backoffDelayMs(attempt: 1), 1000)
        XCTAssertEqual(backoffDelayMs(attempt: 7), 60000)
        XCTAssertEqual(backoffDelayMs(attempt: 8), 60000)
    }

    func testSuppressRetryParksAndScheduleBecomesNoOp() {
        manager.suppressRetry(id)
        XCTAssertEqual(manager.retry[id]?.suppressed, true)

        manager.scheduleRetry(id)
        XCTAssertEqual(manager.retry[id]?.attempt, 0, "suppressed rows never re-enter the curve")
        XCTAssertNil(manager.retryTasks[id])
    }

    func testUserInitiatedConnectClearsSuppressionAndCurve() {
        manager.scheduleRetry(id)
        manager.suppressRetry(id)

        // The endpoint is unroutable — the connect itself will fail silently
        // later; what's pinned here is the synchronous bookkeeping reset.
        manager.connect(to: Self.server, intent: .userInitiated)
        XCTAssertNil(manager.retry[id], "user intent outranks the throttle")
    }

    func testAutoReconnectConnectDoesNotClearTheCurve() {
        manager.scheduleRetry(id)
        manager.scheduleRetry(id)
        manager.connect(to: Self.server, intent: .autoReconnect)
        XCTAssertEqual(manager.retry[id]?.attempt, 2, "only user action resets the curve")
    }

    func testAutoReconnectAllSkipsSuppressedAndNotDueRows() {
        store.remember(Self.server)
        manager.suppressRetry(id)
        manager.autoReconnectAll()
        XCTAssertNil(manager.connections[id], "suppressed row must not reconnect")

        manager.clearRetry(id)
        manager.scheduleRetry(id) // deadline ~1 s out — not due yet
        manager.autoReconnectAll()
        XCTAssertNil(manager.connections[id], "row with a future deadline must not reconnect")

        manager.clearRetry(id)
        manager.autoReconnectAll()
        XCTAssertNotNil(manager.connections[id], "an unthrottled remembered row reconnects")
    }

    func testTerminalAuthStopsTheRetryCurve() {
        store.setSharedKey(String(repeating: "1f", count: 32), for: id)
        manager.scheduleRetry(id)
        XCTAssertNotNil(manager.retryTasks[id])

        manager.handleTerminalAuth(id, loud: false)
        XCTAssertNil(manager.retry[id], "trust revoked — silent retries must stop")
        XCTAssertNil(manager.retryTasks[id])
        XCTAssertNil(store.sharedKey(for: id), "the key is dropped")
        XCTAssertTrue(manager.staleSatelliteIds.contains(id), "the row parks on Needs pairing")
    }

    func testForgetCancelsArmedRetrySoItCannotResurrectTheRow() {
        store.remember(Self.server)
        manager.connect(to: Self.server, intent: .autoReconnect)
        manager.scheduleRetry(id)
        XCTAssertNotNil(manager.retryTasks[id])

        manager.forget(id: id)
        XCTAssertNil(manager.retryTasks[id])
        XCTAssertNil(manager.retry[id])
        XCTAssertNil(manager.connections[id])
    }

    // MARK: - handleClose mapping (gap G10 policy)

    private func pooledConnection() -> WifiConnection {
        let conn = WifiConnection(id: id, server: Self.server, tickIntervalNs: .max)
        manager.register(conn)
        return conn
    }

    func testCloseReplacedParksSuppressed() {
        let conn = pooledConnection()
        manager.handleClose(id, reasonByte: CloseReason.replaced.rawValue)
        XCTAssertEqual(conn.state, .idle)
        XCTAssertEqual(manager.retry[id]?.suppressed, true, "a newer session owns the satellite")
    }

    func testCloseShutdownParksStaleAndEntersBackoff() {
        let conn = pooledConnection()
        conn.markConnecting()
        manager.handleClose(id, reasonByte: CloseReason.shutdown.rawValue)
        XCTAssertEqual(conn.state, .stale, "transient close rides the Unsteady retry window")
        XCTAssertEqual(manager.retry[id]?.attempt, 1)
    }

    func testCloseUnpairedFunnelsToTerminalAuth() {
        store.setSharedKey(String(repeating: "1f", count: 32), for: id)
        let conn = pooledConnection()
        manager.handleClose(id, reasonByte: CloseReason.unpaired.rawValue)
        XCTAssertEqual(conn.state, .idle)
        XCTAssertNil(store.sharedKey(for: id), "unpaired close revokes trust — key dropped")
        XCTAssertTrue(manager.staleSatelliteIds.contains(id))
        XCTAssertNil(manager.retry[id], "no silent retry against a server that revoked us")
    }

    func testCloseUnknownByteDegradesToBackoffRetry() {
        let conn = pooledConnection()
        conn.markConnecting()
        manager.handleClose(id, reasonByte: 250)
        XCTAssertEqual(conn.state, .stale)
        XCTAssertEqual(manager.retry[id]?.attempt, 1, "unknown FUTURE reasons are transient")
    }
}
