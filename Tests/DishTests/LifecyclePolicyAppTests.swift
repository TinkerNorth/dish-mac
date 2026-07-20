// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// App-side G19 coverage: the focus-loss release-all wiring
// (NSApplication.didResignActive → zeroAndSendAll), the return-path
// wired-set prune on forget/re-add, and the `afterMutationSettles`
// willSet-deferral helper the three ad-hoc DispatchQueue.main.async blocks
// were consolidated into.

import AppKit
import Combine
import XCTest
@testable import Dish

@MainActor
final class LifecyclePolicyAppTests: XCTestCase {

    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var center: NotificationCenter!
    private var workspaceCenter: NotificationCenter!
    private var model: AppModel!

    override func setUp() {
        super.setUp()
        defaultsName = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
        center = NotificationCenter()
        workspaceCenter = NotificationCenter()
        model = AppModel(
            store: ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore()),
            notificationCenter: center,
            workspaceNotificationCenter: workspaceCenter
        )
    }

    override func tearDown() {
        model = nil
        defaults.removePersistentDomain(forName: defaultsName)
        super.tearDown()
    }

    /// Spin the main run loop until `predicate` holds (bounded) — the async
    /// deliveries under test are one main-queue hop away.
    private func spinUntil(
        _ predicate: () -> Bool,
        timeout: TimeInterval = 1.0,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(predicate(), message, file: file, line: line)
    }

    // MARK: - Focus-loss release-all (gap G19)

    func testAppResignActiveZeroesAndSendsAllKnownDevices() {
        // Capture what the processor emits (replaces AppModel's router —
        // this test pins the notification → zeroAndSendAll linkage, not the
        // per-connection routing, which has its own coverage).
        var reports: [(id: String, buttons: UInt16, lt: UInt8, lx: Int16)] = []
        model.input.processor.reportSender = { id, buttons, lt, _, lx, _, _, _ in
            reports.append((id, buttons, lt, lx))
        }

        // Two controllers mid-press.
        var held = GamepadInputProcessor.DeviceState()
        held.wButtons = 0x1000
        held.lt = 200
        held.lx = 5000
        model.input.processor.publish(deviceId: "pad-a", state: held)
        model.input.processor.publish(deviceId: "pad-b", state: held)
        XCTAssertEqual(reports.count, 2)
        XCTAssertTrue(reports.allSatisfy { $0.buttons == 0x1000 })

        // The app loses focus: GameController callbacks stop reaching us, so
        // whatever was held would stay pressed server-side without this.
        center.post(name: NSApplication.didResignActiveNotification, object: nil)

        spinUntil({ reports.count >= 4 }, message: "focus loss must emit a release-all per device")
        let releases = reports.dropFirst(2)
        XCTAssertEqual(Set(releases.map(\.id)), ["pad-a", "pad-b"])
        XCTAssertTrue(
            releases.allSatisfy { $0.buttons == 0 && $0.lt == 0 && $0.lx == 0 },
            "every axis and button must read released"
        )
    }

    // MARK: - Manual add-by-address seeds the normal connect flow

    func testConnectManualSeedsPoolRowUnderLegacyIdentity() {
        XCTAssertTrue(model.connectManual("192.0.2.50"))
        XCTAssertNotNil(
            model.wifi.connections["wifi:192.0.2.50:9876"],
            "a manual add must register a pool row under the legacy wifi: identity"
        )

        XCTAssertFalse(model.connectManual("not-an-address"))
        XCTAssertEqual(model.wifi.connections.count, 1, "a rejected address must not seed anything")
    }

    // MARK: - Sleep/wake (forced sleep may never deliver didResignActive)

    func testSystemWillSleepZeroesAndSendsAllKnownDevices() {
        var reports: [(id: String, buttons: UInt16)] = []
        model.input.processor.reportSender = { id, buttons, _, _, _, _, _, _ in
            reports.append((id, buttons))
        }
        var held = GamepadInputProcessor.DeviceState()
        held.wButtons = 0x1000
        model.input.processor.publish(deviceId: "pad-a", state: held)
        XCTAssertEqual(reports.count, 1)

        // Lid closes: the release-all must fire without a didResignActive.
        workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)

        spinUntil({ reports.count >= 2 }, message: "willSleep must emit a release-all per device")
        XCTAssertEqual(reports.last?.id, "pad-a")
        XCTAssertEqual(reports.last?.buttons, 0, "the held button must read released")
    }

    func testSystemDidWakeReconnectsWithoutWaitingOutBackoff() {
        // A remembered satellite parked deep in the backoff curve.
        let server = DiscoveredServer(
            name: "Napper",
            ip: "192.0.2.77",
            udpPort: 9876,
            machineId: "nap-sat"
        )
        model.store.remember(server)
        model.wifi.retry[server.id] = WifiConnectionManager.RetryState(
            attempt: 5,
            nextRetryAtMs: WifiConnectionManager.nowMs() + 60_000,
            suppressed: false
        )

        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        spinUntil(
            { self.model.wifi.connections[server.id] != nil },
            message: "wake must reconnect the resting row immediately, not in 60 s"
        )
        XCTAssertNil(model.wifi.retry[server.id], "the wake clears the stale time throttle")
    }

    func testSystemDidWakeKeepsReplacedSessionsSuppressed() {
        // close-notify(replaced) parks a row until the USER acts — a wake
        // must not resurrect a session that would kick the newer owner.
        let server = DiscoveredServer(
            name: "Replaced",
            ip: "192.0.2.78",
            udpPort: 9876,
            machineId: "replaced-sat"
        )
        model.store.remember(server)
        model.wifi.retry[server.id] = WifiConnectionManager.RetryState(
            attempt: 1,
            nextRetryAtMs: 0,
            suppressed: true
        )

        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        // Bounded negative observation: the suppressed row must stay parked.
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.2))
        XCTAssertNil(model.wifi.connections[server.id], "suppressed rows stay parked through a wake")
        XCTAssertEqual(model.wifi.retry[server.id]?.suppressed, true)
    }

    // MARK: - Return-path wiring prune (gap G19)

    private static let server = DiscoveredServer(
        name: "Prune",
        ip: "192.0.2.60",
        udpPort: 9876,
        machineId: "prune-sat"
    )

    func testForgetThenReAddReinstallsReturnPathHandlers() {
        let id = Self.server.id
        let first = WifiConnection(id: id, server: Self.server, tickIntervalNs: .max)
        model.wifi.register(first)
        XCTAssertTrue(first.hasRumbleHandler, "a newly pooled connection gets the rumble handler")
        XCTAssertTrue(first.hasLightbarHandler, "…and the light-bar handler")

        model.wifi.forget(id: id)

        // The same satellite id re-appears (re-discovered after a forget):
        // the fresh WifiConnection must be wired again. Before the prune fix
        // the grow-only set skipped this install and the new session had no
        // rumble/light-bar return path.
        let second = WifiConnection(id: id, server: Self.server, tickIntervalNs: .max)
        model.wifi.register(second)
        XCTAssertTrue(second.hasRumbleHandler, "re-added id must be re-wired (grow-only set bug)")
        XCTAssertTrue(second.hasLightbarHandler)
    }

    func testNewlyRegisteredConnectionIsWiredImmediately() {
        // The install walk must use the EMITTED pool: `@Published` delivers
        // in willSet, so re-reading the manager property during delivery
        // misses the entry that just registered.
        let conn = WifiConnection(id: Self.server.id, server: Self.server, tickIntervalNs: .max)
        model.wifi.register(conn)
        XCTAssertTrue(
            conn.hasRumbleHandler,
            "the connection that triggered the pool change must be wired in the same pass"
        )
    }

    // MARK: - afterMutationSettles (gap G19 helper)

    private final class Box: ObservableObject {
        @Published var value = 0
    }

    func testAfterMutationSettlesDeliversPostMutationState() {
        let box = Box()
        var observedDirect = [Int]()
        var observedSettled = [Int]()
        var bag = Set<AnyCancellable>()

        // Control: a raw sink on objectWillChange reads the PRIOR value —
        // that is the trap the helper exists to close.
        box.objectWillChange
            .sink { _ in observedDirect.append(box.value) }
            .store(in: &bag)
        box.objectWillChange
            .afterMutationSettles()
            .sink { _ in observedSettled.append(box.value) }
            .store(in: &bag)

        box.value = 7
        XCTAssertEqual(observedDirect, [0], "willSet timing: the raw sink sees the stale value")
        spinUntil({ observedSettled == [7] }, message: "the helper must deliver post-mutation state")
    }
}
