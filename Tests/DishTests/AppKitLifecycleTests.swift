// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import AppKit
import Combine
import XCTest
@testable import Dish

final class AppKitLifecycleTests: XCTestCase {

    private var workspace: NotificationCenter!
    private var bag: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        workspace = NotificationCenter()
        bag = []
    }

    private func count(_ publisher: AnyPublisher<Void, Never>) -> () -> Int {
        var fired = 0
        publisher.sink { fired += 1 }.store(in: &bag)
        return { fired }
    }

    func testWorkspaceSleepFiresWillSleep() {
        let signals = appKitLifecycleSignals(workspace: workspace)
        let willSleep = count(signals.willSleep)
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(willSleep(), 1)
    }

    func testWorkspaceWakeFiresDidWake() {
        let signals = appKitLifecycleSignals(workspace: workspace)
        let didWake = count(signals.didWake)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(didWake(), 1)
    }

    func testEachSignalListensToItsOwnNotificationOnly() {
        let signals = appKitLifecycleSignals(workspace: workspace)
        let willSleep = count(signals.willSleep)
        let didWake = count(signals.didWake)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(willSleep(), 0)
        XCTAssertEqual(didWake(), 1)
    }

    func testAnotherAppComingToTheFrontIsNotASignal() {
        let signals = appKitLifecycleSignals(workspace: workspace)
        let willSleep = count(signals.willSleep)
        let didWake = count(signals.didWake)
        workspace.post(name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertEqual(willSleep(), 0, "input keeps flowing in the background, so nothing is released")
        XCTAssertEqual(didWake(), 0)
    }
}
