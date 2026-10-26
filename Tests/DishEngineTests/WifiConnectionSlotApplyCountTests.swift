// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import XCTest
@testable import DishEngine

/// The count of the satellite's confirmations that a slot is plugged, kept
/// per slot: one per confirmation, none without a bound slot, never rewound,
/// another pad's confirmation never counted, and published so that pad's
/// audio lanes can start over on each.
@MainActor
final class WifiConnectionSlotApplyCountTests: XCTestCase {

    private func connection() -> WifiConnection {
        let server = DiscoveredServer(name: "Desk", ip: "10.0.0.1", udpPort: 9876, pairPort: 9443, httpPort: 9443, machineId: "desk")
        return WifiConnection(id: "desk", server: server)
    }

    func testEveryConfirmationCountsAndNoneWithoutABoundSlot() {
        let conn = connection()
        conn.markSlotApplied("slot")
        XCTAssertEqual(conn.slotTable.applyCount(of: "slot"), 0, "nothing to plug")
        XCTAssertFalse(conn.isSlotApplied("slot"))

        conn.attachSlot("slot", controllerType: 0, capabilities: .none)
        conn.markSlotApplied("slot")
        conn.markSlotApplied("slot")
        XCTAssertEqual(conn.slotTable.applyCount(of: "slot"), 2, "a re-PUT the satellite confirms is a fresh pad too")
        XCTAssertTrue(conn.isSlotApplied("slot"))
    }

    func testDetachingNeverRewindsTheCount() {
        let conn = connection()
        conn.attachSlot("slot", controllerType: 0, capabilities: .none)
        conn.markSlotApplied("slot")
        conn.detachSlot("slot")
        XCTAssertFalse(conn.isSlotApplied("slot"))
        XCTAssertEqual(conn.slotTable.applyCount(of: "slot"), 1)
        conn.attachSlot("slot", controllerType: 0, capabilities: .none)
        conn.markSlotApplied("slot")
        XCTAssertEqual(conn.slotTable.applyCount(of: "slot"), 2)
    }

    func testTheCountIsPublishedOncePerConfirmationOfThatSlotAlone() {
        let conn = connection()
        conn.attachSlot("slot", controllerType: 0, capabilities: .none)
        conn.attachSlot("other", controllerType: 0, capabilities: .none)
        var seen: [Int] = []
        let watch = conn.applyCountPublisher(of: "slot").dropFirst().sink { seen.append($0) }
        conn.markSlotApplied("slot")
        conn.markSlotApplied("other")
        conn.markSlotApplied("slot")
        XCTAssertEqual(seen, [1, 2], "the other pad's confirmation is not this one's")
        watch.cancel()
    }
}
