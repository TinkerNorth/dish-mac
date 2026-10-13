// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import XCTest
@testable import DishEngine

/// The flight recorder: onsets only, the first snapshot as the opening
/// inventory, a bounded store that numbers every line, and a recorder that
/// diffs what the UI renders.
@MainActor
final class DiagnosticsLogTests: XCTestCase {

    private func link(_ id: String, _ state: LinkState) -> LinkSnapshot {
        LinkSnapshot(id: id, label: id.capitalized, state: state)
    }

    private func pad(_ id: String, bound: String = "") -> PadSnapshot {
        PadSnapshot(id: id, name: id.capitalized, boundId: bound, boundLabel: bound.capitalized)
    }

    private func summary(_ id: String, _ live: LinkState, boundTo slot: String? = nil) -> ConnectionSummary {
        ConnectionSummary(id: id, label: id.capitalized, detail: "", live: live, boundSlotId: slot)
    }

    // MARK: - Links

    func testTheFirstSnapshotIsTheOpeningInventory() {
        let events = linkEvents(before: [], after: [link("desk", .saved), link("den", .connected)], atMs: 5)
        XCTAssertEqual(events, [
            DiagnosticsEvent(atMs: 5, kind: .linkAppeared, subject: "Desk", to: .saved),
            DiagnosticsEvent(atMs: 5, kind: .linkAppeared, subject: "Den", to: .connected)
        ])
    }

    func testALinkLogsOnlyWhenItsStateMovesOrItGoes() {
        let before = [link("desk", .connecting), link("den", .connected)]
        let after = [link("desk", .connected)]
        XCTAssertEqual(linkEvents(before: before, after: after, atMs: 9), [
            DiagnosticsEvent(atMs: 9, kind: .linkChanged, subject: "Desk", from: .connecting, to: .connected),
            DiagnosticsEvent(atMs: 9, kind: .linkRemoved, subject: "Den", to: .connected)
        ])
        XCTAssertEqual(linkEvents(before: after, after: after, atMs: 10), [], "a quiet tick logs nothing")
    }

    // MARK: - Pads

    func testAPadLogsItsArrivalItsBindingsAndItsDeparture() {
        XCTAssertEqual(padEvents(before: [], after: [pad("ds")], atMs: 1), [DiagnosticsEvent(atMs: 1, kind: .padAttached, subject: "Ds")])
        XCTAssertEqual(
            padEvents(before: [pad("ds")], after: [pad("ds", bound: "desk")], atMs: 2),
            [DiagnosticsEvent(atMs: 2, kind: .padBound, subject: "Ds", host: "Desk")]
        )
        XCTAssertEqual(
            padEvents(before: [pad("ds", bound: "desk")], after: [pad("ds", bound: "den")], atMs: 3),
            [DiagnosticsEvent(atMs: 3, kind: .padBound, subject: "Ds", host: "Den")],
            "a move is a bind to the new host"
        )
        XCTAssertEqual(
            padEvents(before: [pad("ds", bound: "den")], after: [pad("ds")], atMs: 4),
            [DiagnosticsEvent(atMs: 4, kind: .padUnbound, subject: "Ds", host: "Den")],
            "only losing the host is an unbind, naming the host left"
        )
        XCTAssertEqual(
            padEvents(before: [pad("ds", bound: "den")], after: [], atMs: 5),
            [DiagnosticsEvent(atMs: 5, kind: .padDetached, subject: "Ds", host: "Den")]
        )
    }

    func testTheSnapshotsReadTheShapesTheUIRenders() {
        XCTAssertEqual(linkSnapshot(of: summary("desk", .unstable)), link("desk", .unstable))
        var slot = ControllerSlot(id: "ds", name: "Ds")
        XCTAssertEqual(padSnapshot(of: slot), pad("ds"))
        slot.boundConnectionId = "desk"
        slot.boundStatus = summary("desk", .connected, boundTo: "ds")
        XCTAssertEqual(padSnapshot(of: slot), pad("ds", bound: "desk"))
        slot.boundStatus = nil
        XCTAssertEqual(padSnapshot(of: slot).boundLabel, "desk", "the id stands in once the row is gone")
    }

    // MARK: - The store

    func testTheStoreNumbersEveryLineAndKeepsTheNewest() {
        let store = DiagnosticsLogStore()
        var emissions = 0
        var bag = Set<AnyCancellable>()
        store.statePublisher.dropFirst().sink { _ in emissions += 1 }.store(in: &bag)
        store.record([])
        XCTAssertEqual(emissions, 0, "nothing to record is no change")
        store.record([
            DiagnosticsEvent(atMs: 1, kind: .padAttached, subject: "A"),
            DiagnosticsEvent(atMs: 1, kind: .padAttached, subject: "B")
        ])
        store.record([DiagnosticsEvent(atMs: 2, kind: .padDetached, subject: "A")])
        XCTAssertEqual(store.state.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(store.state.map(\.subject), ["A", "B", "A"])
        let flood = (0 ..< DiagnosticsLog.capacity).map { DiagnosticsEvent(atMs: Int64($0), kind: .linkRemoved, subject: "x") }
        store.record(flood)
        XCTAssertEqual(store.state.count, DiagnosticsLog.capacity)
        XCTAssertEqual(store.state.first?.subject, "x", "the oldest lines fall off")
        XCTAssertEqual(store.state.last?.sequence, 3 + DiagnosticsLog.capacity)
    }

    // MARK: - The recorder

    func testTheRecorderDiffsTheRowsAndTheSlotsOnItsOwnClock() {
        let store = DiagnosticsLogStore()
        var now: Int64 = 100
        let recorder = DiagnosticsRecorder(store: store, clock: { now })
        recorder.observeLinks([summary("desk", .saved)])
        recorder.observeSlots([ControllerSlot(id: "ds", name: "Ds")])
        now = 200
        recorder.observeLinks([summary("desk", .connected, boundTo: "ds")])
        var bound = ControllerSlot(id: "ds", name: "Ds")
        bound.boundConnectionId = "desk"
        bound.boundStatus = summary("desk", .connected, boundTo: "ds")
        recorder.observeSlots([bound])
        recorder.observeSlots([bound])
        XCTAssertEqual(store.state.map(\.kind), [.linkAppeared, .padAttached, .linkChanged, .padBound])
        XCTAssertEqual(store.state.map(\.atMs), [100, 100, 200, 200])
        XCTAssertEqual(store.state.last?.host, "Desk")
    }
}
