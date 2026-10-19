// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishEngine

/// The routing table's two views are built together from the bindings, the
/// pool and the switches in force per satellite.
@MainActor
final class RoutingSnapshotTests: XCTestCase {

    private func server(_ name: String) -> DiscoveredServer {
        DiscoveredServer(name: name, ip: "10.0.0.1", udpPort: 9876, pairPort: 9443, httpPort: 9443, machineId: name)
    }

    func testTheSwitchesPerSatelliteFoldTheBoundControllersOwn() {
        let flags = connectionFlags(
            bindings: ["ds": "desk"],
            connectionIds: ["desk", "den"],
            global: ForwardingFlags(motion: true, touchpad: true, rumble: true, lightbar: false),
            preferences: ["ds": SlotPreferences(motion: false)]
        )
        XCTAssertEqual(flags["desk"], ForwardingFlags(motion: false, touchpad: true, rumble: true, lightbar: false))
        XCTAssertEqual(
            flags["den"],
            ForwardingFlags(motion: true, touchpad: true, rumble: true, lightbar: false),
            "nothing bound: the global switches"
        )
    }

    func testTheSnapshotCarriesTheSameFlagsOnBothSides() {
        let desk = WifiConnection(id: "desk", server: server("Desk"))
        let den = WifiConnection(id: "den", server: server("Den"))
        let flags = ["desk": ForwardingFlags(motion: false), "den": ForwardingFlags()]
        let snapshot = routeSnapshot(
            bindings: ["ds": "desk", "ghost": "gone"],
            pool: ["desk": desk, "den": den],
            flags: flags,
            global: ForwardingFlags()
        )
        XCTAssertEqual(snapshot.bySlot.keys.sorted(), ["ds"], "a binding to a connection outside the pool routes nowhere")
        XCTAssertTrue((snapshot.bySlot["ds"]?.sink as? WifiConnection) === desk)
        XCTAssertEqual(snapshot.bySlot["ds"]?.flags, ForwardingFlags(motion: false))
        XCTAssertEqual(snapshot.byConnection["desk"]?.slotId, "ds")
        XCTAssertEqual(snapshot.byConnection["desk"]?.flags, ForwardingFlags(motion: false))
        XCTAssertNil(snapshot.byConnection["den"], "nothing bound to it")
    }

    func testTheTableServesBothViewsUnderItsLock() {
        let desk = WifiConnection(id: "desk", server: server("Desk"))
        let table = RoutingTable()
        XCTAssertNil(table.get("ds"))
        table.set(routeSnapshot(bindings: ["ds": "desk"], pool: ["desk": desk], flags: [:], global: ForwardingFlags(rumble: false)))
        XCTAssertEqual(table.get("ds")?.flags.rumble, false, "a missing entry falls back to the global switches")
        XCTAssertEqual(table.boundSlot(of: "desk")?.slotId, "ds")
        table.set(RoutingSnapshot())
        XCTAssertNil(table.boundSlot(of: "desk"))
    }

    func testASlotBoundToAMoonlightHostRoutesToItsPadUnderItsOwnSwitches() {
        let desk = WifiConnection(id: "desk", server: server("Desk"))
        let host = MoonlightConnection(id: "moonlight:10.0.0.5", host: MoonlightHost(name: "PC", address: "10.0.0.5"))
        let snapshot = routeSnapshot(
            bindings: ["ds": host.id, "xb": "desk"],
            pool: ["desk": desk],
            flags: ["desk": ForwardingFlags()],
            global: ForwardingFlags(motion: false),
            moonlight: [host.id: host],
            preferences: ["ds": SlotPreferences(rumble: false)]
        )
        let sink = snapshot.bySlot["ds"]?.sink as? MoonlightPadSink
        XCTAssertEqual(sink?.slotId, "ds")
        XCTAssertTrue(sink?.link === host.link)
        XCTAssertEqual(
            snapshot.bySlot["ds"]?.flags,
            ForwardingFlags(motion: false, rumble: false),
            "the slot's own switches under the global ones"
        )
        XCTAssertNil(snapshot.byConnection[host.id], "a host carries up to four pads: its feedback finds the slot by number")
        XCTAssertEqual(snapshot.byConnection["desk"]?.slotId, "xb")
    }
}
