// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import XCTest
@testable import Dish

/// A Moonlight host's card in the Diagnostics window, from the facts the
/// engine reads off its connection.
final class MoonlightDiagnosticsMappersTests: XCTestCase {

    private let english = Locale(identifier: "en_US")
    private let hostId = "moonlight:10.0.0.5"

    private func summary(_ live: LinkState = .connected) -> ConnectionSummary {
        ConnectionSummary(id: hostId, label: "PC", detail: "10.0.0.5 • Moonlight", live: live, boundSlotId: nil, kind: .moonlight)
    }

    private func serverInfo(hostname: String, currentGame: Int, versions: String = "") throws -> MoonlightServerInfo {
        let xml = "<root status_code=\"200\"><hostname>\(hostname)</hostname><uniqueid>abc</uniqueid>\(versions)"
            + "<currentgame>\(currentGame)</currentgame></root>"
        return try XCTUnwrap(MoonlightXml.serverInfo(xml))
    }

    private func lines(_ facts: MoonlightHostDiagnostics?, live: LinkState = .connected) -> [FactLine] {
        hostLines(HostDiagnostics(summary: summary(live), facts: .resting(id: hostId), moonlight: facts), locale: english)
    }

    func testAHostNothingOpenedReadsIdleOnItsAddressAlone() {
        XCTAssertEqual(
            lines(nil, live: .saved),
            [
                FactLine(key: "Address", value: "10.0.0.5 • Moonlight"),
                FactLine(key: "Session", value: "Idle"),
                FactLine(key: "Control round trip", value: "unknown")
            ]
        )
    }

    func testAStreamingHostTellsItsSessionAppRoundTripAndPads() throws {
        let versions = "<appversion>2.0.0</appversion><GfeVersion>3.23.0.74</GfeVersion>"
        let info = try serverInfo(hostname: "Study PC", currentGame: 1, versions: versions)
        let pads = [
            MoonlightPadFacts(number: 0, slotId: "pad-a", type: MoonlightControllerType.xbox, reports: 1),
            MoonlightPadFacts(number: 1, slotId: "pad-b", type: MoonlightControllerType.playStation, reports: 250)
        ]
        let facts = MoonlightHostDiagnostics(phase: .streaming, appName: "Desktop", controlRoundTripMs: 12, info: info, pads: pads)
        XCTAssertEqual(
            lines(facts),
            [
                FactLine(key: "Address", value: "10.0.0.5 • Moonlight"),
                FactLine(key: "Session", value: "Live"),
                FactLine(key: "Host name", value: "Study PC"),
                FactLine(key: "Host app", value: "2.0.0"),
                FactLine(key: "GFE version", value: "3.23.0.74"),
                FactLine(key: "Running app", value: "Desktop"),
                FactLine(key: "Control round trip", value: "12 ms"),
                FactLine(key: "Pad 0", value: "pad-a · Xbox · 1 report"),
                FactLine(key: "Pad 1", value: "pad-b · PlayStation · 250 reports")
            ]
        )
    }

    func testTheHostsOwnGameAndAnEndedSessionReadInTheCardsWords() throws {
        let info = try serverInfo(hostname: "", currentGame: 7)
        let facts = MoonlightHostDiagnostics(phase: .failed(.appRemoved), appName: nil, controlRoundTripMs: nil, info: info, pads: [])
        XCTAssertEqual(
            lines(facts, live: .saved),
            [
                FactLine(key: "Address", value: "10.0.0.5 • Moonlight"),
                FactLine(key: "Session", value: "Ended"),
                FactLine(key: "Running app", value: "7"),
                FactLine(key: "Control round trip", value: "unknown")
            ],
            "no host name line for a host that gave none; the game by its id, since the host names no title"
        )
    }

    func testThePhaseWordsFollowTheSessionAndItsFailures() {
        XCTAssertEqual(moonlightPhaseText(.launching, summary: summary()), "Launching")
        XCTAssertEqual(moonlightPhaseText(.rtsp(.options), summary: summary()), "Launching")
        XCTAssertEqual(moonlightPhaseText(.controlConnecting, summary: summary()), "Launching")
        XCTAssertEqual(moonlightPhaseText(.failed(.notPaired), summary: summary()), "Not paired yet")
        XCTAssertEqual(moonlightPhaseText(.failed(.hostEnded), summary: summary()), "PC ended the session")
    }
}
