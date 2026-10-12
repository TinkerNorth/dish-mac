// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import AppKit
import Combine
import XCTest
@testable import Dish

final class AppKitLifecycleTests: XCTestCase {

    private var application: NotificationCenter!
    private var workspace: NotificationCenter!
    private var bag: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        application = NotificationCenter()
        workspace = NotificationCenter()
        bag = []
    }

    private func count(_ publisher: AnyPublisher<Void, Never>) -> () -> Int {
        var fired = 0
        publisher.sink { fired += 1 }.store(in: &bag)
        return { fired }
    }

    func testResigningActiveFiresFocusLost() {
        let signals = appKitLifecycleSignals(application: application, workspace: workspace)
        let focusLost = count(signals.focusLost)
        application.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertEqual(focusLost(), 1)
    }

    func testWorkspaceSleepFiresWillSleep() {
        let signals = appKitLifecycleSignals(application: application, workspace: workspace)
        let willSleep = count(signals.willSleep)
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(willSleep(), 1)
    }

    func testWorkspaceWakeFiresDidWake() {
        let signals = appKitLifecycleSignals(application: application, workspace: workspace)
        let didWake = count(signals.didWake)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(didWake(), 1)
    }

    func testEachSignalListensToItsOwnNotificationOnly() {
        let signals = appKitLifecycleSignals(application: application, workspace: workspace)
        let focusLost = count(signals.focusLost)
        let willSleep = count(signals.willSleep)
        let didWake = count(signals.didWake)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(focusLost(), 0)
        XCTAssertEqual(willSleep(), 0)
        XCTAssertEqual(didWake(), 1)
    }

    func testTheApplicationNotificationIsNotReadFromTheWorkspaceCenter() {
        let signals = appKitLifecycleSignals(application: application, workspace: workspace)
        let focusLost = count(signals.focusLost)
        workspace.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertEqual(focusLost(), 0)
    }
}
