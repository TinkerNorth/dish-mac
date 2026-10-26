// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishEngine

/// The routing table's two views are built together from the bindings, the
/// pool and the switches in force per bound slot: a slot routes to its pad
/// on its satellite under the controller index it holds there, and each of
/// a satellite's pads is found again by that index for the return paths.
@MainActor
final class RoutingSnapshotTests: XCTestCase {

    private func server(_ name: String) -> DiscoveredServer {
        DiscoveredServer(name: name, ip: "10.0.0.1", udpPort: 9876, pairPort: 9443, httpPort: 9443, machineId: name)
    }

    private func satellite(_ id: String, carrying slotIds: [String]) -> WifiConnection {
        let conn = WifiConnection(id: id, server: server(id))
        for slotId in slotIds {
            conn.attachSlot(slotId, controllerType: 0, capabilities: .none)
        }
        return conn
    }

    func testTheSwitchesPerSlotFoldEachControllersOwn() {
        let flags = slotFlags(
            bindings: ["ds": "desk", "xb": "desk"],
            global: ForwardingFlags(motion: true, touchpad: true, rumble: true, lightbar: false),
            preferences: ["ds": SlotPreferences(motion: false)]
        )
        XCTAssertEqual(flags["ds"], ForwardingFlags(motion: false, touchpad: true, rumble: true, lightbar: false))
        XCTAssertEqual(
            flags["xb"],
            ForwardingFlags(motion: true, touchpad: true, rumble: true, lightbar: false),
            "two pads on one satellite keep their own switches"
        )
        XCTAssertEqual(flags.count, 2, "an unbound slot has no entry")
    }

    func testTheSnapshotCarriesTheSameFlagsOnBothSides() {
        let desk = satellite("desk", carrying: ["ds"])
        let den = WifiConnection(id: "den", server: server("Den"))
        let snapshot = routeSnapshot(
            bindings: ["ds": "desk", "ghost": "gone"],
            pool: ["desk": desk, "den": den],
            flags: ["ds": ForwardingFlags(motion: false)],
            global: ForwardingFlags()
        )
        XCTAssertEqual(snapshot.bySlot.keys.sorted(), ["ds"], "a binding to a connection outside the pool routes nowhere")
        let sink = snapshot.bySlot["ds"]?.sink as? SatellitePadSink
        XCTAssertTrue(sink?.connection === desk)
        XCTAssertEqual(sink?.controllerIndex, 0)
        XCTAssertEqual(snapshot.bySlot["ds"]?.flags, ForwardingFlags(motion: false))
        let pad = SatellitePadKey(connectionId: "desk", controllerIndex: 0)
        XCTAssertEqual(snapshot.bySatellitePad[pad]?.slotId, "ds")
        XCTAssertEqual(snapshot.bySatellitePad[pad]?.flags, ForwardingFlags(motion: false))
        XCTAssertNil(snapshot.bySatellitePad[SatellitePadKey(connectionId: "den", controllerIndex: 0)], "nothing bound to it")
    }

    func testTwoPadsOnOneSatelliteRouteToTheirOwnIndices() {
        let desk = satellite("desk", carrying: ["ds", "xb"])
        let snapshot = routeSnapshot(
            bindings: ["ds": "desk", "xb": "desk"],
            pool: ["desk": desk],
            flags: ["ds": ForwardingFlags(rumble: false), "xb": ForwardingFlags()],
            global: ForwardingFlags()
        )
        XCTAssertEqual((snapshot.bySlot["ds"]?.sink as? SatellitePadSink)?.controllerIndex, 0)
        XCTAssertEqual((snapshot.bySlot["xb"]?.sink as? SatellitePadSink)?.controllerIndex, 1)
        let first = snapshot.bySatellitePad[SatellitePadKey(connectionId: "desk", controllerIndex: 0)]
        let second = snapshot.bySatellitePad[SatellitePadKey(connectionId: "desk", controllerIndex: 1)]
        XCTAssertEqual(first?.slotId, "ds")
        XCTAssertEqual(first?.flags.rumble, false)
        XCTAssertEqual(second?.slotId, "xb")
        XCTAssertEqual(second?.flags.rumble, true, "each pad's return path reads its own switches")
    }

    func testASlotItsSatelliteDoesNotCarryYetHasNoRoute() {
        let desk = WifiConnection(id: "desk", server: server("Desk"))
        let snapshot = routeSnapshot(bindings: ["ds": "desk"], pool: ["desk": desk], flags: [:], global: ForwardingFlags())
        XCTAssertNil(snapshot.bySlot["ds"])
        XCTAssertTrue(snapshot.bySatellitePad.isEmpty)
    }

    func testTheTableServesBothViewsUnderItsLock() {
        let desk = satellite("desk", carrying: ["ds"])
        let table = RoutingTable()
        let pad = SatellitePadKey(connectionId: "desk", controllerIndex: 0)
        XCTAssertNil(table.get("ds"))
        table.set(routeSnapshot(bindings: ["ds": "desk"], pool: ["desk": desk], flags: [:], global: ForwardingFlags(rumble: false)))
        XCTAssertEqual(table.get("ds")?.flags.rumble, false, "a missing entry falls back to the global switches")
        XCTAssertEqual(table.boundSlot(of: pad)?.slotId, "ds")
        table.set(RoutingSnapshot())
        XCTAssertNil(table.boundSlot(of: pad))
    }

    func testASlotBoundToAMoonlightHostRoutesToItsPadUnderItsOwnSwitches() {
        let desk = satellite("desk", carrying: ["xb"])
        let host = MoonlightConnection(id: "moonlight:10.0.0.5", host: MoonlightHost(name: "PC", address: "10.0.0.5"))
        let snapshot = routeSnapshot(
            bindings: ["ds": host.id, "xb": "desk"],
            pool: ["desk": desk],
            flags: ["ds": ForwardingFlags(motion: false, rumble: false)],
            global: ForwardingFlags(motion: false),
            moonlight: [host.id: host]
        )
        let sink = snapshot.bySlot["ds"]?.sink as? MoonlightPadSink
        XCTAssertEqual(sink?.slotId, "ds")
        XCTAssertTrue(sink?.link === host.link)
        XCTAssertEqual(snapshot.bySlot["ds"]?.flags, ForwardingFlags(motion: false, rumble: false), "the slot's own switches")
        XCTAssertEqual(snapshot.bySatellitePad.count, 1, "a host's feedback finds the slot by its pad number instead")
        XCTAssertEqual(snapshot.bySatellitePad[SatellitePadKey(connectionId: "desk", controllerIndex: 0)]?.slotId, "xb")
    }
}
