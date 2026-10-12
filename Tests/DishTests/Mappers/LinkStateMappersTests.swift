// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI
import XCTest
@testable import Dish

final class LinkStateMappersTests: XCTestCase {

    private static let allStates: [LinkState] = [.found, .stale, .saved, .ready, .connecting, .connected, .unstable]

    private func summary(_ live: LinkState, latencyMs: Double? = nil) -> ConnectionSummary {
        ConnectionSummary(id: "c", label: "Desk PC", detail: "", live: live, boundSlotId: nil, latencyMs: latencyMs)
    }

    func testEveryStateHasItsChipWord() {
        let expected: [LinkState: String] = [
            .found: "Found", .stale: "Needs pairing", .saved: "Offline", .ready: "Ready",
            .connecting: "Connecting…", .connected: "Online", .unstable: "Unsteady"
        ]
        for state in Self.allStates {
            XCTAssertEqual(linkStateText(state), expected[state], "\(state)")
        }
    }

    func testOnlyALiveSessionShowsLatency() {
        XCTAssertEqual(Self.allStates.filter(showsLatency), [.connected, .unstable])
    }

    func testLatencySuffixUsesTheLocalesDecimalMark() {
        XCTAssertEqual(latencySuffix(3.44, locale: Locale(identifier: "en_US")), " · 3.4 ms")
        XCTAssertEqual(latencySuffix(3.44, locale: Locale(identifier: "de_DE")), " · 3,4 ms")
    }

    func testStatusLineAppendsLatencyWhileLive() {
        XCTAssertEqual(statusLine(for: summary(.connected, latencyMs: 2.06)), "Online · 2.1 ms")
        XCTAssertEqual(statusLine(for: summary(.unstable, latencyMs: 40)), "Unsteady · 40.0 ms")
    }

    func testStatusLineSkipsLatencyAtRestOrWhenUnknown() {
        XCTAssertEqual(statusLine(for: summary(.ready, latencyMs: 2.0)), "Ready")
        XCTAssertEqual(statusLine(for: summary(.connected)), "Online")
    }

    func testDotColourByState() {
        let expected: [LinkState: Color] = [
            .connected: DishTheme.success, .connecting: DishTheme.primary, .unstable: DishTheme.primary,
            .found: DishTheme.muted, .stale: DishTheme.muted, .saved: DishTheme.muted, .ready: DishTheme.muted
        ]
        for state in Self.allStates {
            XCTAssertEqual(linkDotColor(state), expected[state], "\(state)")
        }
    }

    func testGlyphStateByLinkState() {
        let expected: [LinkState: BrandIconState] = [
            .connected: .connected, .saved: .off, .stale: .off,
            .found: .default, .ready: .default, .connecting: .default, .unstable: .default
        ]
        for state in Self.allStates {
            XCTAssertEqual(brandIconState(for: state), expected[state], "\(state)")
        }
    }
}
