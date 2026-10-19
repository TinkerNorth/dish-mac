// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore
@testable import DishEngine

/// A Moonlight host's row in the Diagnostics source: resting on its probe
/// until a connection exists this run, then read off the connection.
@MainActor
final class MoonlightHostDiagnosticsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var store: ConnectionStore!
    private var wifi: WifiConnectionManager!
    private var moonlight: MoonlightConnectionManager!
    private var hub: ConnectionHub!
    private var source: DiagnosticsSource!
    private let host = MoonlightHost(name: "PC", address: "10.0.0.5", uniqueId: "abc")
    private let xbox = MoonlightAnnouncedPad(type: MoonlightControllerType.xbox, capabilities: 0x03, supportedButtons: 0xF7FF)

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
        source = DiagnosticsSource(wifi: wifi, hub: hub, moonlight: moonlight)
        var record = RememberedMoonlightHost(host: host, paired: true)
        record.uniqueId = "abc"
        moonlight.store.put(record)
        moonlight.publishRemembered()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func serverInfo(currentGame: Int) throws -> MoonlightServerInfo {
        try XCTUnwrap(MoonlightXml.serverInfo(
            "<root status_code=\"200\"><hostname>PC</hostname><uniqueid>abc</uniqueid><currentgame>\(currentGame)</currentgame></root>"
        ))
    }

    func testARememberedHostRestsOnItsProbeUntilAConnectionExists() throws {
        source.refresh()
        XCTAssertEqual(source.state.hosts.map(\.id), [host.id])
        XCTAssertEqual(source.state.hosts.first?.summary.kind, .moonlight)
        XCTAssertEqual(source.state.hosts.first?.moonlight, .resting(info: nil))
        XCTAssertEqual(source.state.hosts.first?.facts, .resting(id: host.id), "no satellite session behind a Moonlight row")

        let info = try serverInfo(currentGame: 3)
        moonlight.noteFacts(host.id, info)
        source.refresh()
        XCTAssertEqual(source.state.hosts.first?.moonlight, .resting(info: info), "what the probe said, with no session to read")
    }

    func testAConnectionsPhasePadsAndReportsAreReadOffIt() {
        let connection = moonlight.findOrCreate(host)
        XCTAssertNotNil(connection.acquirePad("a", as: xbox))
        source.refresh()
        let facts = source.state.hosts.first?.moonlight
        XCTAssertEqual(facts?.phase, .idle)
        XCTAssertNil(facts?.appName)
        XCTAssertNil(facts?.controlRoundTripMs, "no control link yet")
        XCTAssertEqual(facts?.pads, [MoonlightPadFacts(number: 0, slotId: "a", type: MoonlightControllerType.xbox, reports: 0)])
    }

    func testASatelliteRowCarriesNoMoonlightFacts() {
        let sat = DiscoveredServer(name: "Sat", ip: "192.0.2.10", udpPort: 9876, machineId: "sat-10")
        store.remember(sat)
        wifi.register(WifiConnection(id: sat.id, server: sat, tickIntervalNs: .max))
        source.refresh()
        let satellite = source.state.hosts.first { $0.summary.kind == .satellite }
        XCTAssertNotNil(satellite)
        XCTAssertNil(satellite?.moonlight)
    }
}
