// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import XCTest
@testable import Dish

/// What the shell draws around every page, from the navigation state and
/// the engine's facts.
final class ShellMappersTests: XCTestCase {

    private func inputs(
        wake: WakeState = WakeState(),
        update: UpdateStatus = UpdateStatus(currentVersion: "1.2.3"),
        connections: [ConnectionSummary] = [],
        mic: MicIndicatorState = .hidden
    ) -> ShellInputs {
        ShellInputs(facts: ShellFacts(wake: wake, update: update), connections: connections, mic: mic)
    }

    private func available(required: Bool) -> UpdateStatus {
        var update = UpdateStatus(phase: .available, currentVersion: "1.2.3")
        update.required = required
        return update
    }

    func testTheRailListsTheDesktopsDestinationsInOrder() {
        let state = shellState(NavigationState(), inputs())
        XCTAssertEqual(state.top.map(\.label), ["Home", "Controllers", "Connections"])
        XCTAssertEqual(state.footer.map(\.label), ["Support Dish", "Settings"])
        XCTAssertEqual(state.top.map(\.glyph) + state.footer.map(\.glyph), [.dish, .pad, .satellite, .heart, .gear])
        XCTAssertEqual(state.version, "Dish 1.2.3")
    }

    func testOnlyTheDestinationOnScreenIsActive() {
        let state = shellState(NavigationState(destination: .connections, path: [.diagnostics]), inputs())
        XCTAssertEqual((state.top + state.footer).filter(\.active).map(\.destination), [.connections])
    }

    func testTheTitleIsThePushedPagesOrElseTheDestinations() {
        XCTAssertEqual(pageTitle(NavigationState(destination: .support)), "Support Dish")
        XCTAssertEqual(pageTitle(NavigationState(destination: .settings, path: [.diagnostics])), "Diagnostics")
        XCTAssertEqual(
            pageTitle(NavigationState(destination: .settings, path: [.diagnostics, .inspector(slotId: "a")])),
            "Controller inspector"
        )
        XCTAssertEqual(pageTitle(NavigationState(destination: .settings, path: [.crashReport])), "Crash report")
        XCTAssertEqual(pageTitle(NavigationState(destination: .settings, path: [.licenses])), "Open source licenses")
        XCTAssertEqual(pageTitle(NavigationState(destination: .connections, path: [.moonlightHosts])), "Moonlight hosts")
        XCTAssertEqual(pageTitle(NavigationState(destination: .home, path: [.configureBinding(slotId: "a")])), "Configure binding")
        XCTAssertEqual(pageTitle(NavigationState(destination: .controllers, path: [.deadZones(slotId: "a")])), "Dead zones & motion")
    }

    func testTheSetupWalkAndHelpAreTitledAndCarryTheirOwnLines() {
        let walk = NavigationState(destination: .home, path: [.setup(seedSlotId: nil)])
        let help = NavigationState(destination: .settings, path: [.help])
        XCTAssertEqual(pageTitle(walk), "Set up Dish")
        XCTAssertEqual(pageTitle(help), "Help & FAQ")
        XCTAssertEqual(shellSubline(walk, connections: []), .note("Nothing is changed until the last step"))
        XCTAssertEqual(shellSubline(help, connections: []), .note("How Dish works, and what to try when it doesn’t"))
    }

    func testTheRailCarriesTheSetUpActionBetweenItsGroups() {
        XCTAssertEqual(shellState(NavigationState(), inputs()).setUp, "Set up")
    }

    func testTheBackChevronShowsOnlyOverAPushedPage() {
        XCTAssertFalse(shellState(NavigationState(), inputs()).showsBack)
        XCTAssertTrue(shellState(NavigationState(path: [.licenses]), inputs()).showsBack)
    }

    func testSettingsCarriesADotWhileAnUpdateWaits() {
        XCTAssertNil(updateBadge(UpdateStatus(phase: .upToDate)))
        XCTAssertNil(updateBadge(UpdateStatus(phase: .checking)), "checking is silent")
        XCTAssertNil(updateBadge(UpdateStatus(phase: .failed)), "a failure is a Settings matter")
        XCTAssertEqual(updateBadge(available(required: false)), DishTheme.primary)
        XCTAssertEqual(updateBadge(available(required: true)), DishTheme.warning)
        let footer = shellState(NavigationState(), inputs(update: available(required: false))).footer
        XCTAssertEqual(footer.map { $0.badge != nil }, [false, true], "only Settings wears it")
    }

    func testThePillNamesHowFarTheMachineIsHeld() {
        XCTAssertNil(streamingPill(WakeState(reach: .system, streamingSlotCount: 0)), "hidden while nothing streams")
        XCTAssertEqual(streamingPill(WakeState(reach: .system, streamingSlotCount: 1))?.text, "Streaming · computer kept awake")
        XCTAssertEqual(streamingPill(WakeState(reach: .systemAndDisplay, streamingSlotCount: 2))?.text, "Streaming · display kept awake")
        XCTAssertEqual(streamingPill(WakeState(reach: .none, streamingSlotCount: 1))?.text, "Streaming")
        let pill = streamingPill(WakeState(reach: .system, streamingSlotCount: 1))
        XCTAssertEqual(pill?.configure, "Configure")
        XCTAssertEqual(pill?.configureHelp, "Configure keep-awake")
    }

    func testTheMicChipFollowsTheAppWideWord() throws {
        XCTAssertNil(shellMicChip(.hidden))
        let live = try XCTUnwrap(shellMicChip(.live))
        XCTAssertEqual(live, MicChipState(text: "Mic live", live: true, help: "Microphone is live. Click to mute it."))
        let muted = try XCTUnwrap(shellMicChip(.muted))
        XCTAssertEqual(muted, MicChipState(text: "Mic muted", live: false, help: "Microphone muted. Click to unmute it."))
    }

    func testTheStatusLineIsTheDashboardsUnlessThePageHasItsOwn() {
        let live = ConnectionSummary(id: "a", name: "Den", live: .connected, boundSlotId: nil)
        XCTAssertEqual(
            shellSubline(NavigationState(), connections: [live]),
            .status(headline: "Den", summary: "1 of 1 online", accent: DishTheme.success)
        )
        XCTAssertEqual(
            shellSubline(NavigationState(), connections: []),
            .status(
                headline: "No connections yet",
                summary: "Plug in a controller and pair a Satellite to get started",
                accent: DishTheme.muted
            )
        )
        XCTAssertEqual(
            shellSubline(NavigationState(destination: .support), connections: []),
            .note("Dish is free and open source — donations keep it that way")
        )
        XCTAssertEqual(
            shellSubline(NavigationState(destination: .settings, path: [.licenses]), connections: []),
            .note("Acknowledgements for the libraries Dish is built on.")
        )
        if case .note = shellSubline(NavigationState(destination: .support, path: [.diagnostics]), connections: []) {
            XCTFail("a page pushed over Support Dish carries the dashboard's line")
        }
        if case .note = shellSubline(NavigationState(destination: .connections, path: [.moonlightHosts]), connections: []) {
            XCTFail("Moonlight hosts carries the dashboard's line")
        }
    }
}
