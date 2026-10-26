// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI
import XCTest
@testable import Dish

/// The machine at the app layer: the rail's state and the welcome's survive
/// a relaunch under the desktops' keys, the window comes forward when the
/// menu bar asks, and the split view's and the stack's bindings speak in
/// events.
@MainActor
final class NavigationStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!
    private var activations = 0

    override func setUp() {
        super.setUp()
        suite = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        activations = 0
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func makeStore() -> NavigationStore {
        NavigationStore(
            preferences: UiPreferenceStore(defaults: defaults),
            onboarding: OnboardingPreferenceStore(defaults: defaults),
            activateWindow: countActivation
        )
    }

    private func countActivation() {
        activations += 1
    }

    func testTheRailStateSurvivesARelaunch() {
        XCTAssertFalse(makeStore().state.railCollapsed, "the rail starts labelled")
        makeStore().send(.toggleRail)
        XCTAssertTrue(defaults.bool(forKey: "ui_rail_collapsed"))
        XCTAssertTrue(makeStore().state.railCollapsed)
    }

    func testTheWelcomeShowsOnAFirstRunOnly() {
        XCTAssertTrue(makeStore().state.showingWelcome, "a first run opens on the welcome")
        makeStore().send(.welcome(.skip))
        XCTAssertTrue(defaults.bool(forKey: "onboarding_welcome_completed"), "Skip is a completion too")
        XCTAssertFalse(makeStore().state.showingWelcome)
    }

    func testFinishingTheWelcomeIsRememberedAndOpensTheWalk() {
        let store = makeStore()
        store.send(.welcome(.finish))
        XCTAssertEqual(store.state.path, [.setup(seedSlotId: nil)])
        XCTAssertTrue(OnboardingPreferenceStore(defaults: defaults).welcomeCompleted)
    }

    func testARequestFromTheMenuBarActivatesTheWindow() {
        let store = makeStore()
        store.send(.external(.showPage(.diagnostics)))
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(store.state.path, [.diagnostics])
        store.send(.select(.home))
        XCTAssertEqual(activations, 1, "a rail click is already in the window")
    }

    func testTheSplitViewsSidebarButtonCollapsesTheRailInsteadOfHidingIt() {
        let store = makeStore()
        let visibility = store.columnVisibility
        XCTAssertEqual(visibility.wrappedValue, .all)
        visibility.wrappedValue = .detailOnly
        XCTAssertTrue(store.state.railCollapsed)
        XCTAssertEqual(visibility.wrappedValue, .all, "the rail never hides")
        visibility.wrappedValue = .all
        XCTAssertTrue(store.state.railCollapsed, "showing what shows changes nothing")
    }

    func testTheStacksOwnPopsArriveAsEvents() {
        let store = makeStore()
        store.send(.push(.diagnostics))
        store.send(.push(.inspector(slotId: "pad")))
        let path = store.path
        XCTAssertEqual(path.wrappedValue, [.diagnostics, .inspector(slotId: "pad")])
        path.wrappedValue = [.diagnostics]
        XCTAssertEqual(store.state.path, [.diagnostics])
        path.wrappedValue = [.diagnostics, .licenses]
        XCTAssertEqual(store.state.path, [.diagnostics, .licenses])
        path.wrappedValue = []
        XCTAssertEqual(store.state.path, [])
    }
}
