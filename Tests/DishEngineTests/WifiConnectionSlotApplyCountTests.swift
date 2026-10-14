// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import XCTest
@testable import DishEngine

/// The count of the satellite's confirmations that the slot is plugged: one
/// per confirmation, none without a bound slot, never rewound, and published
/// so the audio lanes can start over on each.
@MainActor
final class WifiConnectionSlotApplyCountTests: XCTestCase {

    private func connection() -> WifiConnection {
        let server = DiscoveredServer(name: "Desk", ip: "10.0.0.1", udpPort: 9876, pairPort: 9443, httpPort: 9443, machineId: "desk")
        return WifiConnection(id: "desk", server: server)
    }

    func testEveryConfirmationCountsAndNoneWithoutABoundSlot() {
        let conn = connection()
        conn.markSlotApplied()
        XCTAssertEqual(conn.slotApplyCount, 0, "nothing to plug")
        XCTAssertFalse(conn.slotApplied)

        conn.attachSlot("slot", controllerType: 0, capabilities: .none)
        conn.markSlotApplied()
        conn.markSlotApplied()
        XCTAssertEqual(conn.slotApplyCount, 2, "a re-PUT the satellite confirms is a fresh pad too")
        XCTAssertTrue(conn.slotApplied)
    }

    func testDetachingNeverRewindsTheCount() {
        let conn = connection()
        conn.attachSlot("slot", controllerType: 0, capabilities: .none)
        conn.markSlotApplied()
        conn.detachSlot()
        XCTAssertFalse(conn.slotApplied)
        XCTAssertEqual(conn.slotApplyCount, 1)
        conn.attachSlot("slot", controllerType: 0, capabilities: .none)
        conn.markSlotApplied()
        XCTAssertEqual(conn.slotApplyCount, 2)
    }

    func testTheCountIsPublishedOncePerConfirmation() {
        let conn = connection()
        conn.attachSlot("slot", controllerType: 0, capabilities: .none)
        var seen: [Int] = []
        let watch = conn.$slotApplyCount.dropFirst().sink { seen.append($0) }
        conn.markSlotApplied()
        conn.markSlotApplied()
        XCTAssertEqual(seen.count, 2)
        watch.cancel()
    }
}
