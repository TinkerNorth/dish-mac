// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore
@testable import DishEngine

/// The hub keeps every binding across restarts: written on bind and on a
/// type change, kept when the pad leaves or its satellite refuses it,
/// dropped when the user unbinds or forgets the satellite, one record per
/// pad of one kind; and it hands each remembered binding back once per
/// attachment of its pad, when its destination is known here.
@MainActor
final class ConnectionHubMemoryTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!
    private var store: ConnectionStore!
    private var wifi: WifiConnectionManager!
    private var moonlight: MoonlightConnectionManager!
    private var hub: ConnectionHub!
    private let den = DiscoveredServer(name: "Den", ip: "192.0.2.10", udpPort: 9876, machineId: "den")
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
        wifi.register(WifiConnection(id: den.id, server: den, tickIntervalNs: .max))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private var memory: [RememberedSatelliteBinding] {
        BindingMemoryStore(defaults: defaults).bindings()
    }

    private func rememberHost() {
        moonlight.store.put(RememberedMoonlightHost(host: host, paired: true))
        moonlight.publishRemembered()
    }

    private func bind(_ slotId: String, to connectionId: String) {
        hub.bind(slotId: slotId, connectionId: connectionId, capabilities: .none, family: .other)
    }

    private func due(present: Set<String>) -> [StandingBinding] {
        hub.takeDueStandingBindings(
            present: present,
            satellites: Set(wifi.connections.keys),
            hosts: Set(moonlight.rememberedHosts.map(\.id))
        )
    }

    // MARK: - What is written

    func testABindAndATypeChangeAreRemembered() {
        bind("pad", to: den.id)
        XCTAssertEqual(memory, [RememberedSatelliteBinding(slotId: "pad", satelliteId: den.id, emulatedType: nil)])
        hub.setEmulatedType(slotId: "pad", type: 2, family: .other)
        XCTAssertEqual(memory.first?.emulatedType, 2)
        hub.setEmulatedType(slotId: "pad", type: nil, family: .other)
        XCTAssertNil(memory.first?.emulatedType, "back to the pad's own type")
    }

    func testAPadThatLeftOrWasRefusedKeepsItsMemory() {
        bind("pad", to: den.id)
        bind("other", to: den.id)
        hub.release(slotId: "pad")
        wifi.slotRegistrationFailed.send("other")
        XCTAssertEqual(hub.bindings, [:])
        XCTAssertEqual(memory.map(\.slotId), ["pad", "other"])
    }

    func testUnbindingForgetsTheMemory() {
        bind("pad", to: den.id)
        hub.unbind(slotId: "pad")
        XCTAssertEqual(memory, [])
    }

    func testForgettingASatelliteDropsTheBindingsOfPadsPresentAndAbsent() {
        bind("pad", to: den.id)
        bind("gone", to: den.id)
        hub.release(slotId: "gone")
        hub.forgetBindings(of: den.id)
        XCTAssertEqual(hub.bindings, [:])
        XCTAssertEqual(memory, [])
    }

    func testAPadThatMovedBetweenKindsIsRememberedOnlyWhereItIsNow() {
        rememberHost()
        bind("pad", to: den.id)
        bind("pad", to: host.id)
        XCTAssertEqual(memory, [], "the satellite record went")
        XCTAssertEqual(moonlight.rememberedBindings.map(\.slotId), ["pad"])
        bind("pad", to: den.id)
        XCTAssertEqual(moonlight.rememberedBindings, [], "the host record went")
        XCTAssertEqual(memory.map(\.slotId), ["pad"])
    }

    // MARK: - What is handed back

    func testAStandingBindingIsDueOncePerAttachmentOfItsPad() {
        bind("pad", to: den.id)
        hub.setEmulatedType(slotId: "pad", type: 3, family: .other)
        hub.release(slotId: "pad")
        XCTAssertEqual(due(present: []), [], "the pad is not here")
        XCTAssertEqual(due(present: ["pad"]), [StandingBinding(slotId: "pad", connectionId: den.id, emulatedType: 3)])
        XCTAssertEqual(due(present: ["pad"]), [], "tried once while it stays attached")
        XCTAssertEqual(due(present: []), [])
        XCTAssertEqual(due(present: ["pad"]).map(\.slotId), ["pad"], "due again once it returns")
    }

    func testABoundPadIsNeverDue() {
        bind("pad", to: den.id)
        XCTAssertEqual(due(present: ["pad"]), [])
    }

    func testABindingWaitsUntilItsDestinationIsKnown() {
        BindingMemoryStore(defaults: defaults).remember(RememberedSatelliteBinding(
            slotId: "pad",
            satelliteId: "mid:loft",
            emulatedType: nil
        ))
        XCTAssertEqual(due(present: ["pad"]), [], "no such satellite in the pool yet")
        let loft = DiscoveredServer(name: "Loft", ip: "192.0.2.11", udpPort: 9876, machineId: "loft")
        wifi.register(WifiConnection(id: loft.id, server: loft, tickIntervalNs: .max))
        XCTAssertEqual(due(present: ["pad"]).map(\.connectionId), [loft.id], "an unknown destination was not counted as tried")
    }

    func testAMoonlightBindingNamesItsOwnPickOnlyWhereItDiffersFromTheHosts() {
        rememberHost()
        moonlight.setEmulatedType(hostId: host.id, type: MoonlightControllerType.playStation)
        bind("own", to: host.id)
        bind("picked", to: host.id)
        hub.setEmulatedType(slotId: "picked", type: Int(MoonlightControllerType.nintendo), family: .other)
        hub.release(slotId: "own")
        hub.release(slotId: "picked")
        let standing = Dictionary(uniqueKeysWithValues: due(present: ["own", "picked"]).map { ($0.slotId, $0) })
        XCTAssertEqual(standing["own"], StandingBinding(slotId: "own", connectionId: host.id, emulatedType: nil))
        XCTAssertEqual(standing["picked"]?.emulatedType, Int(MoonlightControllerType.nintendo))
    }
}
