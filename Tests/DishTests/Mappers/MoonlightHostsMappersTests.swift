// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import XCTest
@testable import Dish
@testable import DishCore

/// The Moonlight hosts page as data: its empty states, a known host's row
/// with its chips, status, app picker, actions and menu, a discovered host's
/// row, the PIN card in the row that asked for it, and the inline add form.
final class MoonlightHostsMappersTests: XCTestCase {

    private let pc = MoonlightHost(name: "PC", address: "10.0.0.5", uniqueId: "abc")

    private func summary(_ live: LinkState, bound: [String] = []) -> ConnectionSummary {
        ConnectionSummary(
            id: pc.id,
            name: "PC",
            address: "10.0.0.5",
            live: live,
            boundSlotId: bound.first,
            kind: .moonlight,
            boundSlotIds: bound
        )
    }

    private func inputs(
        _ connections: [ConnectionSummary] = [],
        moonlight: MoonlightFacts = MoonlightFacts(),
        pin: MoonlightPinPrompt? = nil
    ) -> MoonlightHostsInputs {
        var facts = ConnectionsFacts()
        facts.moonlight = moonlight
        return MoonlightHostsInputs(connections: connections, slots: [], facts: facts, pin: pin)
    }

    private func onlyRow(_ inputs: MoonlightHostsInputs) throws -> MoonlightHostRowState {
        guard case let .rows(rows) = moonlightList(inputs), rows.count == 1 else { throw NotOneRow() }
        return rows[0]
    }

    private struct NotOneRow: Error {}

    // MARK: - Empty

    func testAnEmptyListLooksWhileTheSweepRuns() {
        var scanning = MoonlightFacts()
        scanning.scanning = true
        XCTAssertEqual(moonlightList(inputs(moonlight: scanning)), .looking(EmptyStateModel(
            title: "Looking for Moonlight hosts",
            message: "Scanning your network for hosts advertising GameStream. They appear here as they answer."
        )))
    }

    func testAnEmptyListAfterTheSweepOffersSunshineAndAnAddress() {
        guard case let .nothing(nothing) = moonlightList(inputs()) else { return XCTFail("nothing found") }
        XCTAssertEqual(nothing.card.title, "No Moonlight hosts found")
        XCTAssertEqual(nothing.getApp, "Get Sunshine ↗")
        XCTAssertEqual(nothing.getAppURL, URL(string: "https://github.com/LizardByte/Sunshine"))
        XCTAssertEqual(nothing.secondary, "Add by address…")
    }

    // MARK: - A known host

    func testAKnownHostsRowSaysItsKindTrustTierAndControllers() throws {
        let row = try onlyRow(inputs([summary(.saved, bound: ["a", "b"])]))
        XCTAssertEqual(row.title, "PC")
        XCTAssertEqual(row.kindLine, "Moonlight host (Sunshine, Apollo or Wolf)")
        XCTAssertEqual(row.address, "10.0.0.5")
        XCTAssertEqual(row.dot, DishTheme.muted)
        XCTAssertEqual(row.chips.map(\.text), [linkTierText(.moonlight), "Remembered", "2 controllers"])
        XCTAssertEqual(row.menu, RowMenuState(label: "More actions for PC", forget: "Forget"))
        XCTAssertNil(row.app, "no probe has listed apps yet")
        XCTAssertNil(row.pin)
    }

    func testAKnownHostsActionsFollowItsSessionAndWaitOutAPairing() throws {
        var facts = MoonlightFacts()
        facts.phases = [pc.id: .failed(.appAlreadyRunning)]
        let row = try onlyRow(inputs([summary(.ready)], moonlight: facts))
        XCTAssertEqual(row.actions.map(\.kind), [.quitApp, .retry])
        XCTAssertEqual(row.actions.map(\.title), ["Close the app on PC", "Retry"])
        XCTAssertEqual(row.statusLine, "Another device is using PC")
        facts.pairingInFlight = [pc.id]
        XCTAssertEqual(try onlyRow(inputs([summary(.ready)], moonlight: facts)).actions.map(\.enabled), [false, false])
    }

    func testANeverPairedHostOffersPairNow() throws {
        let row = try onlyRow(inputs([summary(.stale)]))
        XCTAssertEqual(row.actions, [MoonlightActionState(kind: .pair, title: "Pair now", enabled: true)])
        XCTAssertEqual(row.statusLine, "Not paired yet")
    }

    // MARK: - The app picker

    func testTheAppPickerListsAutoThenEachAppAndNotesWhatAutoStarts() throws {
        var facts = MoonlightFacts()
        facts.apps = [pc.id: [
            MoonlightApp(id: "1", title: "Desktop", hdrSupported: false),
            MoonlightApp(id: "2", title: "", hdrSupported: false)
        ]]
        let picker = try XCTUnwrap(try onlyRow(inputs([summary(.ready)], moonlight: facts)).app)
        XCTAssertEqual(picker.label, "App")
        XCTAssertEqual(
            picker.options,
            [AppOption(id: "", title: "Auto"), AppOption(id: "1", title: "Desktop"), AppOption(id: "2", title: "2")]
        )
        XCTAssertEqual(picker.selection, "")
        XCTAssertEqual(picker.note, "Without a pick, Dish starts whatever PC lists first.")
        facts.pickedApps = [pc.id: "1"]
        let picked = try XCTUnwrap(try onlyRow(inputs([summary(.ready)], moonlight: facts)).app)
        XCTAssertEqual(picked.selection, "1")
        XCTAssertNil(picked.note)
    }

    func testAHostWhoseProbeListedNoAppsHasNoPicker() {
        var facts = MoonlightFacts()
        facts.apps = [pc.id: []]
        XCTAssertNil(appPicker(pc.id, host: "PC", facts: facts))
    }

    // MARK: - A discovered host

    func testAHostOnlyAScanKnowsIsNotPairedAndHasNothingToForget() throws {
        var facts = MoonlightFacts()
        facts.discovered = [pc]
        let row = try onlyRow(inputs(moonlight: facts))
        XCTAssertEqual(row.chips.map(\.text), [linkTierText(.moonlight), "Not paired"])
        XCTAssertEqual(row.actions, [MoonlightActionState(kind: .pair, title: "Pair now", enabled: true)])
        XCTAssertNil(row.menu)
        facts.pairingInFlight = [pc.id]
        XCTAssertEqual(
            try onlyRow(inputs(moonlight: facts)).actions,
            [MoonlightActionState(kind: .pair, title: "Pairing…", enabled: false)]
        )
    }

    // MARK: - The PIN card

    func testThePinShowsInTheRowOfTheHostThatMintedIt() throws {
        let prompt = MoonlightPinPrompt(host: pc, pin: "0451")
        let row = try onlyRow(inputs([summary(.stale)], pin: prompt))
        XCTAssertEqual(row.pin, MoonlightPinCardState(
            title: "Pair with PC",
            cells: ["0", "4", "5", "1"],
            prompt: "Type 0451 into the Moonlight or Sunshine page on PC.",
            waiting: "Waiting for the host to accept the PIN…",
            cancel: "Cancel",
            newCode: "New code"
        ))
        XCTAssertNil(pinCard(on: "moonlight:other", prompt), "another host's row shows no card")
    }

    // MARK: - The page

    func testTheAddFormAsksForAnAddressAndSaysWhenNoneWasTyped() {
        let state = moonlightHostsPageState(inputs(), draft: "")
        XCTAssertEqual(state.addTitle, "Add by address…")
        XCTAssertEqual(state.addForm.heading, "Add a host by address")
        XCTAssertEqual(state.addForm.message, "Enter the host IP address or hostname. Dish uses the standard Moonlight ports.")
        XCTAssertEqual(state.addForm.cancel, "Cancel")
        XCTAssertFalse(state.addForm.field.canAdd)
        XCTAssertNil(state.addForm.field.error)
        var rejected = inputs()
        var facts = rejected.facts
        facts.rejectedAddress = .moonlight
        rejected = MoonlightHostsInputs(connections: [], slots: [], facts: facts, pin: nil)
        XCTAssertEqual(moonlightHostsPageState(rejected, draft: "").addForm.field.error, "Enter the host address")
        XCTAssertTrue(moonlightHostsPageState(inputs(), draft: "pc.local").addForm.field.canAdd)
    }

    func testThePageScansItsOwnHosts() {
        var facts = MoonlightFacts()
        facts.scanning = true
        XCTAssertEqual(moonlightHostsPageState(inputs(moonlight: facts), draft: "").scan, scanControl(scanning: true))
        XCTAssertEqual(moonlightHostsPageState(inputs(), draft: "").scan, scanControl(scanning: false))
    }
}
