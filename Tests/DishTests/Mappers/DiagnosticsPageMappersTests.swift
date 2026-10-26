// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import XCTest
@testable import Dish

/// The Diagnostics page as one state from the model's facts: a card per
/// host and per pad or the word for none, the newest lines of the recorder,
/// and Copy only once there is something to copy.
final class DiagnosticsPageMappersTests: XCTestCase {

    private let english = Locale(identifier: "en_US")

    private func utc() throws -> TimeZone {
        try XCTUnwrap(TimeZone(identifier: "UTC"))
    }

    private func host() -> HostDiagnostics {
        let summary = ConnectionSummary(id: "sat", name: "Desk", address: "10.0.0.2", udpPort: 9876, live: .saved, boundSlotId: nil)
        return HostDiagnostics(summary: summary, facts: .resting(id: "sat"))
    }

    private func pad() -> PadDiagnostics {
        PadDiagnostics(slot: ControllerSlot(id: "pad", name: "DualSense"), wire: nil)
    }

    func testNothingSeenSaysSoAndCopyWaits() throws {
        let state = try diagnosticsPageState(facts: ShellFacts(), locale: english, timeZone: utc())
        XCTAssertEqual(state.hosts, .empty("No satellites yet. Pair one on the Connections page and its session shows here."))
        XCTAssertEqual(state.pads, .empty(L10n.app.noControllersConnected))
        XCTAssertEqual(state.events, [])
        XCTAssertFalse(state.canCopy)
    }

    func testAHostsCardCarriesItsDotItsChipAndItsLines() throws {
        var facts = ShellFacts()
        facts.diagnostics = DiagnosticsSnapshot(hosts: [host()])
        let state = try diagnosticsPageState(facts: facts, locale: english, timeZone: utc())
        guard case let .cards(cards) = state.hosts else { return XCTFail("a host is a card") }
        let card = try XCTUnwrap(cards.first)
        XCTAssertEqual(card.title, connectionTitle(host().summary))
        XCTAssertEqual(card.dot, linkDotColor(.saved))
        XCTAssertEqual(card.chip, linkStateText(.saved))
        XCTAssertEqual(card.lines, hostLines(host(), locale: english))
        XCTAssertNil(card.inspects, "a host has nothing to inspect")
    }

    func testAPadsCardOpensTheInspectorOnThatPad() throws {
        var facts = ShellFacts()
        facts.diagnostics = DiagnosticsSnapshot(pads: [pad()])
        guard case let .cards(cards) = diagnosticsPageState(facts: facts).pads else { return XCTFail("a pad is a card") }
        let card = try XCTUnwrap(cards.first)
        XCTAssertEqual(card.title, "DualSense")
        XCTAssertNil(card.dot)
        XCTAssertNil(card.chip)
        XCTAssertEqual(card.lines, padLines(pad()))
        XCTAssertEqual(card.inspects, "pad")
    }

    func testTheRecorderShowsNewestFirstAndCopiesOldestFirst() throws {
        var facts = ShellFacts()
        facts.diagnosticsEvents = [
            DiagnosticsEvent(sequence: 1, atMs: 3_600_000, kind: .linkRemoved, subject: "Desk"),
            DiagnosticsEvent(sequence: 2, atMs: 3_661_000, kind: .padDetached, subject: "Pad")
        ]
        let british = Locale(identifier: "en_GB")
        let state = try diagnosticsPageState(facts: facts, locale: british, timeZone: utc())
        XCTAssertEqual(state.events.map(\.id), [2, 1])
        XCTAssertEqual(state.events.first?.text, "01:01:01  Pad: detached")
        XCTAssertTrue(state.canCopy)
        XCTAssertEqual(
            try diagnosticsTranscript(facts: facts, locale: british, timeZone: utc()),
            "01:00:00  Desk: removed\n01:01:01  Pad: detached"
        )
    }
}
