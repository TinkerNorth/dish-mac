// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore
@testable import DishEngine

/// The hub with Moonlight hosts beside the satellites: a row per host the
/// records or the pool know, up to four slots bound to one host without
/// eviction, a slot's prior owner of either kind letting go, and the pick
/// kept with the remembered binding.
@MainActor
final class ConnectionHubMoonlightTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!
    private var store: ConnectionStore!
    private var wifi: WifiConnectionManager!
    private var moonlight: MoonlightConnectionManager!
    private var hub: ConnectionHub!
    private let host = MoonlightHost(name: "PC", address: "10.0.0.5", uniqueId: "abc")

    override func setUp() {
        super.setUp()
        suite = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        store = ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore())
        wifi = WifiConnectionManager(store: store)
        moonlight = MoonlightConnectionManager(
            store: MoonlightHostStore(defaults: defaults),
            gateway: ScriptedMoonlightGateway(),
            identity: nil,
            edges: FakeMoonlightEdges(),
            discover: { [] }
        )
        hub = ConnectionHub(wifi: wifi, store: store, moonlight: moonlight)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func remember(paired: Bool) {
        var record = RememberedMoonlightHost(host: host, paired: paired)
        record.uniqueId = "abc"
        moonlight.store.put(record)
        moonlight.publishRemembered()
    }

    private func satellite(_ suffix: String) -> DiscoveredServer {
        DiscoveredServer(name: "Sat-\(suffix)", ip: "192.0.2.\(suffix)", udpPort: 9876, machineId: "sat-\(suffix)")
    }

    func testARememberedHostIsARowWhoseChipReadsItsTrustAndPresence() {
        XCTAssertEqual(hub.connections, [])
        remember(paired: false)
        XCTAssertEqual(hub.connections.map(\.id), [host.id])
        XCTAssertEqual(hub.connections.first?.kind, .moonlight)
        XCTAssertEqual(hub.connections.first?.live, .stale, "no pairing: Needs pairing")
        XCTAssertEqual(hub.connections.first?.name, "PC")
        remember(paired: true)
        XCTAssertEqual(hub.connections.first?.live, .saved, "paired and out of sight")
        moonlight.mergeDiscovered(host)
        XCTAssertEqual(hub.connections.first?.live, .ready)
        let sat = satellite("10")
        store.remember(sat)
        wifi.register(WifiConnection(id: sat.id, server: sat, tickIntervalNs: .max))
        XCTAssertEqual(hub.connections.map(\.name), ["PC", "Sat-10"], "both kinds, name-sorted")
    }

    func testFourSlotsBindToOneHostWithoutEvictionAndTheRowNamesThemAll() {
        remember(paired: true)
        for slotId in ["a", "b", "c", "d"] {
            hub.bind(slotId: slotId, connectionId: host.id, capabilities: .none, family: .other)
        }
        XCTAssertEqual(hub.bindings, ["a": host.id, "b": host.id, "c": host.id, "d": host.id])
        let row = hub.summary(host.id)
        XCTAssertEqual(row?.boundSlotIds, ["a", "b", "c", "d"])
        XCTAssertEqual(row?.boundSlotId, "a")
        XCTAssertFalse(row?.hasRoomForAnotherSlot ?? true)
        XCTAssertEqual(moonlight.rememberedBindings.map(\.slotId).sorted(), ["a", "b", "c", "d"], "kept across restarts")
        XCTAssertEqual(moonlight.rememberedBindings.first?.controllerType, Int(MoonlightControllerType.auto), "the host's own pick, Auto")
        hub.unbind(slotId: "b")
        XCTAssertEqual(hub.summary(host.id)?.boundSlotIds, ["a", "c", "d"])
        XCTAssertEqual(moonlight.rememberedBindings.map(\.slotId).sorted(), ["a", "c", "d"], "an unbound pad's binding is forgotten")
    }

    func testBindingToAHostTheRecordsDoNotHoldRemembersInterest() {
        moonlight.mergeDiscovered(host)
        hub.bind(slotId: "a", connectionId: host.id, capabilities: .none, family: .other)
        XCTAssertEqual(moonlight.store.host(id: host.id)?.paired, false, "binding is durable interest, not trust")
        XCTAssertEqual(hub.summary(host.id)?.boundSlotIds, ["a"])
    }

    func testASlotsPriorOwnerOfEitherKindLetsGo() {
        remember(paired: true)
        let sat = satellite("20")
        let conn = WifiConnection(id: sat.id, server: sat, tickIntervalNs: .max)
        wifi.register(conn)
        hub.bind(slotId: "a", connectionId: sat.id, capabilities: .none, family: .other)
        XCTAssertEqual(conn.boundSlotIds, ["a"])
        hub.bind(slotId: "a", connectionId: host.id, capabilities: .none, family: .other)
        XCTAssertEqual(conn.boundSlotIds, [], "the satellite detached when its slot moved to the host")
        XCTAssertEqual(hub.bindings, ["a": host.id])
        hub.bind(slotId: "a", connectionId: sat.id, capabilities: .none, family: .other)
        XCTAssertEqual(conn.boundSlotIds, ["a"])
        XCTAssertEqual(moonlight.rememberedBindings, [], "the host's remembered binding went when the slot moved back")
        XCTAssertEqual(hub.summary(host.id)?.boundSlotIds, [])
    }

    func testThePickForAMoonlightBindingIsKeptWithItAndNilReturnsToTheHosts() {
        remember(paired: true)
        moonlight.setEmulatedType(hostId: host.id, type: MoonlightControllerType.playStation)
        hub.bind(slotId: "a", connectionId: host.id, capabilities: .none, family: .other)
        XCTAssertEqual(moonlight.rememberedBindings.first?.controllerType, Int(MoonlightControllerType.playStation), "the host's pick")
        hub.setEmulatedType(slotId: "a", type: Int(MoonlightControllerType.nintendo), family: .other)
        XCTAssertEqual(wifi.typeOverrides.typeFor(SlotKey(connectionId: host.id, slotId: "a")), Int(MoonlightControllerType.nintendo))
        XCTAssertEqual(moonlight.rememberedBindings.first?.controllerType, Int(MoonlightControllerType.nintendo))
        hub.setEmulatedType(slotId: "a", type: nil, family: .other)
        XCTAssertNil(wifi.typeOverrides.typeFor(SlotKey(connectionId: host.id, slotId: "a")))
        XCTAssertEqual(
            moonlight.rememberedBindings.first?.controllerType,
            Int(MoonlightControllerType.playStation),
            "back to the host's own"
        )
    }

    func testAHostInThePoolIsARowThatFollowsItsPhase() async {
        remember(paired: true)
        let gateway = ScriptedMoonlightGateway()
        gateway.answerPlain("/serverinfo", .unreachable)
        hub.bind(slotId: "a", connectionId: host.id, capabilities: .none, family: .other)
        moonlight.applyDesired([host.id: [MoonlightPadRequest(
            slotId: "a",
            announced: MoonlightAnnouncedPad(type: 1, capabilities: 1, supportedButtons: 0xF7FF)
        )]])
        await moonlight.awaitQuiet()
        XCTAssertEqual(moonlight.get(host.id)?.phase, .failed(.unreachable))
        XCTAssertEqual(hub.summary(host.id)?.live, .saved, "unreachable this time, remembered as paired")
        XCTAssertEqual(hub.summary(host.id)?.boundSlotIds, ["a"])
        moonlight.forget(hostId: host.id)
        await moonlight.awaitQuiet()
        XCTAssertEqual(hub.connections, [], "a forgotten host leaves no row")
    }
}
