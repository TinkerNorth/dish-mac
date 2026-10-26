// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

/// The shell's navigation rule, event by event: a rail selection replaces
/// the stack, a page pushes onto it, the rail's collapse is persisted, a
/// request from the menu bar brings the window forward, a guarded page gets
/// first refusal of every move that would take it off screen, the welcome
/// shows on a first run until it is skipped or finished, and the setup walk
/// opens on Home.
final class NavigationMachineTests: XCTestCase {

    private let root = NavigationState()
    private var pushed: NavigationState {
        NavigationState(destination: .settings, path: [.diagnostics, .inspector(slotId: "pad")])
    }

    private var guardedPage: NavigationState {
        var state = pushed
        state.leaveGuarded = true
        return state
    }

    private func step(_ state: NavigationState, _ event: NavigationEvent) -> NavigationStep {
        reduceNavigation(state, event)
    }

    // MARK: - Unguarded

    func testSelectingADestinationReplacesTheStack() {
        let next = step(pushed, .select(.connections))
        XCTAssertEqual(next.state.destination, .connections)
        XCTAssertEqual(next.state.path, [])
        XCTAssertEqual(next.effects, [])
    }

    func testSelectingTheDestinationOnScreenClearsItsPushedPages() {
        let next = step(pushed, .select(.settings))
        XCTAssertEqual(next.state, NavigationState(destination: .settings))
    }

    func testSelectingTheRootOnScreenChangesNothing() {
        XCTAssertEqual(step(root, .select(.home)), NavigationStep(state: root, effects: []))
    }

    func testPushingAPageStacksItOnTheDestination() {
        let next = step(root, .push(.licenses))
        XCTAssertEqual(next.state.destination, .home)
        XCTAssertEqual(next.state.path, [.licenses])
        XCTAssertEqual(next.effects, [])
    }

    func testPopRemovesTheTopPage() {
        XCTAssertEqual(step(pushed, .pop).state.path, [.diagnostics])
    }

    func testPopAtTheRootChangesNothing() {
        XCTAssertEqual(step(root, .pop), NavigationStep(state: root, effects: []))
    }

    func testPopToRootClearsTheStackAndKeepsTheDestination() {
        let next = step(pushed, .popToRoot)
        XCTAssertEqual(next.state, NavigationState(destination: .settings))
    }

    func testTogglingTheRailCollapsesItAndPersistsTheChoice() {
        let collapsed = step(root, .toggleRail)
        XCTAssertTrue(collapsed.state.railCollapsed)
        XCTAssertEqual(collapsed.effects, [.persistRail(collapsed: true)])
        let expanded = step(collapsed.state, .toggleRail)
        XCTAssertFalse(expanded.state.railCollapsed)
        XCTAssertEqual(expanded.effects, [.persistRail(collapsed: false)])
    }

    func testTogglingTheRailLeavesTheStackAlone() {
        let next = step(pushed, .toggleRail)
        XCTAssertEqual(next.state.path, pushed.path)
        XCTAssertEqual(next.state.destination, .settings)
    }

    func testTheMenuBarShowsADestinationAndBringsTheWindowForward() {
        let next = step(pushed, .external(.showDestination(.home)))
        XCTAssertEqual(next.state, NavigationState())
        XCTAssertEqual(next.effects, [.activateWindow])
    }

    func testTheMenuBarShowsAPageOnTheDestinationItLivesIn() {
        let next = step(root, .external(.showPage(.diagnostics)))
        XCTAssertEqual(next.state.destination, .settings)
        XCTAssertEqual(next.state.path, [.diagnostics])
        XCTAssertEqual(next.effects, [.activateWindow])
    }

    func testEveryPushedPageLivesUnderSettings() {
        let pages: [Page] = [.diagnostics, .inspector(slotId: "pad"), .crashReport, .licenses]
        XCTAssertEqual(pages.map(homeDestination), [.settings, .settings, .settings, .settings])
    }

    func testMoonlightHostsIsPushedOntoConnectionsAndShownThereFromOutside() {
        let onConnections = step(root, .select(.connections)).state
        let pushedHosts = step(onConnections, .push(.moonlightHosts)).state
        XCTAssertEqual(pushedHosts.destination, .connections)
        XCTAssertEqual(pushedHosts.path, [.moonlightHosts])
        XCTAssertEqual(homeDestination(of: .moonlightHosts), .connections)
        let shown = step(root, .external(.showPage(.moonlightHosts)))
        XCTAssertEqual(shown.state.destination, .connections, "a PIN minted elsewhere brings its page up")
        XCTAssertEqual(shown.state.path, [.moonlightHosts])
        XCTAssertEqual(shown.effects, [.activateWindow])
    }

    func testConfigureBindingIsPushedOntoThePageThatAskedAndLivesUnderHome() {
        let onControllers = step(root, .select(.controllers)).state
        let editing = step(onControllers, .push(.configureBinding(slotId: "pad"))).state
        XCTAssertEqual(editing.destination, .controllers, "the card's hand-off stays on Controllers")
        XCTAssertEqual(editing.path, [.configureBinding(slotId: "pad")])
        XCTAssertEqual(homeDestination(of: .configureBinding(slotId: "pad")), .home)
        let shown = step(onControllers, .external(.showPage(.configureBinding(slotId: "pad"))))
        XCTAssertEqual(shown.state.destination, .home)
    }

    func testDeadZonesIsPushedOntoControllersAndShownThereFromOutside() {
        let onControllers = step(root, .select(.controllers)).state
        let tuning = step(onControllers, .push(.deadZones(slotId: "pad"))).state
        XCTAssertEqual(tuning.path, [.deadZones(slotId: "pad")])
        XCTAssertEqual(homeDestination(of: .deadZones(slotId: "pad")), .controllers)
        let shown = step(root, .external(.showPage(.deadZones(slotId: "pad"))))
        XCTAssertEqual(shown.state.destination, .controllers)
        XCTAssertEqual(shown.state.path, [.deadZones(slotId: "pad")])
    }

    func testADirtyBindingHoldsTheRailUntilThePageAnswers() {
        var editing = NavigationState(destination: .home, path: [.configureBinding(slotId: "pad")])
        editing = step(editing, .guardLeave(true)).state
        let held = step(editing, .select(.connections)).state
        XCTAssertEqual(held.pendingLeaveGuard, .select(.connections))
        XCTAssertEqual(held.path, [.configureBinding(slotId: "pad")], "the page stays while it asks")
        XCTAssertEqual(step(held, .leaveGuard(.stay)).state.path, [.configureBinding(slotId: "pad")])
        let left = step(held, .leaveGuard(.leave)).state
        XCTAssertEqual(left.destination, .connections)
        XCTAssertEqual(left.path, [])
    }

    func testAnAnswerWithNothingHeldChangesNothing() {
        XCTAssertEqual(step(pushed, .leaveGuard(.leave)), NavigationStep(state: pushed, effects: []))
        XCTAssertEqual(step(pushed, .leaveGuard(.stay)), NavigationStep(state: pushed, effects: []))
    }

    // MARK: - The welcome and the setup walk

    private var firstRun: NavigationState {
        NavigationState(showingWelcome: true)
    }

    func testSkippingTheWelcomeLandsOnHomeAndRemembersIt() {
        let next = step(firstRun, .welcome(.skip))
        XCTAssertEqual(next.state, root)
        XCTAssertEqual(next.effects, [.markWelcomeComplete])
    }

    func testFinishingTheWelcomeRemembersItAndOpensSetup() {
        let next = step(firstRun, .welcome(.finish))
        XCTAssertFalse(next.state.showingWelcome)
        XCTAssertEqual(next.state.destination, .home)
        XCTAssertEqual(next.state.path, [.setup(seedSlotId: nil)])
        XCTAssertEqual(next.effects, [.markWelcomeComplete])
    }

    func testAWelcomeAnswerWithNoWelcomeUpChangesNothing() {
        XCTAssertEqual(step(pushed, .welcome(.finish)), NavigationStep(state: pushed, effects: []))
        XCTAssertEqual(step(pushed, .welcome(.skip)), NavigationStep(state: pushed, effects: []))
    }

    func testOpeningSetupSelectsHomeFirstThenPushesTheWalk() {
        let next = step(pushed, .openSetup(seedSlotId: "pad"))
        XCTAssertEqual(next.state.destination, .home, "the walk's result is a Home row")
        XCTAssertEqual(next.state.path, [.setup(seedSlotId: "pad")])
        XCTAssertEqual(next.effects, [])
        XCTAssertEqual(homeDestination(of: .setup(seedSlotId: nil)), .home)
    }

    func testOpeningSetupAsksAGuardedPageFirst() {
        let held = step(guardedPage, .openSetup(seedSlotId: nil)).state
        XCTAssertEqual(held.pendingLeaveGuard, .openSetup(seedSlotId: nil))
        XCTAssertEqual(held.path, guardedPage.path)
        let left = step(held, .leaveGuard(.leave)).state
        XCTAssertEqual(left.path, [.setup(seedSlotId: nil)])
    }

    func testTheWalkPastItsFirstPageHoldsTheRail() {
        let walking = step(step(root, .openSetup(seedSlotId: nil)).state, .guardLeave(true)).state
        let held = step(walking, .select(.settings)).state
        XCTAssertEqual(held.pendingLeaveGuard, .select(.settings), "Leave setup? is asked first")
        XCTAssertEqual(held.path, [.setup(seedSlotId: nil)])
        XCTAssertEqual(step(held, .leaveGuard(.stay)).state.path, [.setup(seedSlotId: nil)])
    }

    func testAWalkThatAppliedLandsOnHomeAndRemembersTheWelcome() {
        let walking = step(step(root, .openSetup(seedSlotId: nil)).state, .guardLeave(true)).state
        let ended = step(walking, .setupEnded(.applied))
        XCTAssertEqual(ended.state, root, "the guard goes with the walk")
        XCTAssertEqual(ended.effects, [.markWelcomeComplete])
    }

    func testAWalkLeftFromABlockerLandsOnHomeWithoutAsking() {
        let walking = step(step(root, .openSetup(seedSlotId: nil)).state, .guardLeave(true)).state
        let ended = step(walking, .setupEnded(.exited))
        XCTAssertEqual(ended.state, root)
        XCTAssertEqual(ended.effects, [])
    }

    func testAPairingCardBringsConnectionsUpUnlessTheWalkHoldsIt() {
        XCTAssertEqual(step(pushed, .pairingCardOpened).state.destination, .connections)
        let walking = step(root, .openSetup(seedSlotId: nil)).state
        XCTAssertEqual(step(walking, .pairingCardOpened), NavigationStep(state: walking, effects: []), "the walk draws the card itself")
    }

    func testHelpIsPushedOntoSettings() {
        XCTAssertEqual(homeDestination(of: .help), .settings)
        let shown = step(root, .external(.showPage(.help)))
        XCTAssertEqual(shown.state.path, [.help])
    }

    // MARK: - The leave guard

    func testAPageArmsAndReleasesItsGuard() {
        let armed = step(pushed, .guardLeave(true))
        XCTAssertTrue(armed.state.leaveGuarded)
        XCTAssertEqual(armed.effects, [])
        XCTAssertFalse(step(armed.state, .guardLeave(false)).state.leaveGuarded)
    }

    func testAGuardHoldsEveryMoveThatTakesThePageOffScreen() {
        let moves: [(NavigationEvent, NavigationMove)] = [
            (.select(.home), .select(.home)),
            (.pop, .pop),
            (.popToRoot, .popToRoot),
            (.external(.showDestination(.connections)), .external(.showDestination(.connections))),
            (.external(.showPage(.licenses)), .external(.showPage(.licenses)))
        ]
        for (event, move) in moves {
            let held = step(guardedPage, event)
            XCTAssertEqual(held.state.path, guardedPage.path, "\(event) waits for the page")
            XCTAssertEqual(held.state.destination, .settings, "\(event) waits for the page")
            XCTAssertEqual(held.state.pendingLeaveGuard, move)
        }
    }

    func testAHeldRequestFromTheMenuBarStillBringsTheWindowForward() {
        XCTAssertEqual(step(guardedPage, .external(.showDestination(.home))).effects, [.activateWindow])
        XCTAssertEqual(step(guardedPage, .select(.home)).effects, [])
    }

    func testStayingDropsTheHeldMoveAndKeepsTheGuard() {
        let held = step(guardedPage, .select(.home)).state
        let stayed = step(held, .leaveGuard(.stay)).state
        XCTAssertNil(stayed.pendingLeaveGuard)
        XCTAssertTrue(stayed.leaveGuarded)
        XCTAssertEqual(stayed.path, guardedPage.path)
    }

    func testLeavingRunsTheHeldMoveAndReleasesTheGuard() {
        let held = step(guardedPage, .select(.home)).state
        let left = step(held, .leaveGuard(.leave)).state
        XCTAssertEqual(left, NavigationState())
    }

    func testLeavingOnAHeldPopPopsOnePage() {
        let held = step(guardedPage, .pop).state
        let left = step(held, .leaveGuard(.leave)).state
        XCTAssertEqual(left.path, [.diagnostics])
        XCTAssertFalse(left.leaveGuarded)
    }

    func testReleasingTheGuardDropsWhatItHeld() {
        let held = step(guardedPage, .popToRoot).state
        let released = step(held, .guardLeave(false)).state
        XCTAssertNil(released.pendingLeaveGuard)
        XCTAssertEqual(released.path, guardedPage.path)
    }

    func testAGuardDoesNotStopThePageFromPushingOrTheRailFromCollapsing() {
        let next = step(guardedPage, .push(.crashReport))
        XCTAssertEqual(next.state.path.last, .crashReport)
        XCTAssertFalse(next.state.leaveGuarded, "the guard belonged to the page now covered")
        XCTAssertTrue(step(guardedPage, .toggleRail).state.railCollapsed)
    }
}
