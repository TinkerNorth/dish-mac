// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// The fleet's keys: hosts by address, bindings by slot, one client id.
final class MoonlightHostStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!
    private var store: MoonlightHostStore!

    override func setUp() {
        super.setUp()
        suite = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        store = MoonlightHostStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testTheIdIsTheAddressAndRecordsReplaceByIt() {
        XCTAssertEqual(MoonlightHostStore.hostId(address: "192.168.1.20"), "moonlight:192.168.1.20")
        let host = MoonlightHost(name: "Desk", address: "192.168.1.20")
        XCTAssertEqual(host.id, "moonlight:192.168.1.20")
        XCTAssertEqual(host.endpoint, MoonlightEndpoint(address: "192.168.1.20", httpPort: 47989, httpsPort: 47984))
        store.put(RememberedMoonlightHost(host: host, paired: false))
        var renamed = RememberedMoonlightHost(host: host, paired: true)
        renamed.name = "Desk PC"
        renamed.lastAppId = "881448767"
        store.put(renamed)
        XCTAssertEqual(store.hosts().count, 1)
        XCTAssertEqual(store.host(id: host.id)?.name, "Desk PC")
        XCTAssertEqual(store.host(id: host.id)?.paired, true)
        XCTAssertEqual(MoonlightHostStore(defaults: defaults).host(id: host.id)?.lastAppId, "881448767", "persisted under the fleet's key")
        XCTAssertNotNil(defaults.data(forKey: "moonlight_host_list"))
        store.removeHost(id: host.id)
        XCTAssertEqual(store.hosts(), [])
    }

    func testARecordWrittenBeforeAFieldExistedReadsWithTheDefaults() throws {
        let legacy = Data("[{\"id\":\"moonlight:10.0.0.9\",\"address\":\"10.0.0.9\"}]".utf8)
        defaults.set(legacy, forKey: "moonlight_host_list")
        let host = try XCTUnwrap(store.host(id: "moonlight:10.0.0.9"))
        XCTAssertEqual(host.httpPort, 47989)
        XCTAssertEqual(host.httpsPort, 47984)
        XCTAssertEqual(host.emulatedType, Int(MoonlightControllerType.auto))
        XCTAssertTrue(host.paired, "every record written before the field was written by a completed pairing")
        XCTAssertEqual(host.host.name, "")
        defaults.set(Data("not json".utf8), forKey: "moonlight_host_list")
        XCTAssertEqual(store.hosts(), [], "a garbled list reads as empty, never as a crash")
    }

    func testBindingsBySlotAndByHost() {
        store.putBinding(RememberedMoonlightBinding(slotId: "slot-a", hostId: "moonlight:h1", controllerType: 2))
        store.putBinding(RememberedMoonlightBinding(slotId: "slot-b", hostId: "moonlight:h1", controllerType: 1))
        store.putBinding(RememberedMoonlightBinding(slotId: "slot-a", hostId: "moonlight:h2", controllerType: 255)) // a slot has one host
        XCTAssertEqual(store.bindings().count, 2)
        XCTAssertEqual(store.bindings(forHost: "moonlight:h1").map(\.slotId), ["slot-b"])
        XCTAssertEqual(store.bindings(forHost: "moonlight:h2").first?.controllerType, 255)
        store.removeBinding(slotId: "slot-b")
        XCTAssertEqual(store.bindings().map(\.slotId), ["slot-a"])
        XCTAssertNotNil(defaults.data(forKey: "moonlight_binding_list"))
    }

    func testTheClientIdIsSixteenHexCharactersMintedOnce() {
        let id = store.uniqueId()
        XCTAssertEqual(id.count, 16)
        XCTAssertTrue(id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertEqual(MoonlightHostStore(defaults: defaults).uniqueId(), id, "kept across launches")
        XCTAssertEqual(defaults.string(forKey: "moonlight_uniqueid"), id)
    }
}
