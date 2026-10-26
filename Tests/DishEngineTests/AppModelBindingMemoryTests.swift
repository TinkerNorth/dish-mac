// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// Bindings survive a restart: a binding remembered by an earlier run is
/// bound again without the user once its pad is attached and its
/// destination is known, whichever comes last, with the pick it carried; a
/// pad that leaves and returns is bound again; a forgotten satellite's
/// bindings never come back; and a Moonlight binding is restored the same way.
@MainActor
final class AppModelBindingMemoryTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!
    private var store: ConnectionStore!
    private var moonlight: MoonlightConnectionManager!
    private var model: AppModel!

    private let den = DiscoveredServer(name: "Den", ip: "192.0.2.10", machineId: "den")
    private let host = MoonlightHost(name: "PC", address: "10.0.0.5", uniqueId: "abc")
    private let pad = GameControllerInput.Slot(id: "pad", name: "DualSense", capabilities: .none, battery: nil, family: .dualSense)

    override func setUp() {
        super.setUp()
        suite = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        store = ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore())
    }

    override func tearDown() {
        model = nil
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// A launch over what the earlier run left in the defaults.
    private func launch() {
        moonlight = MoonlightConnectionManager(
            store: MoonlightHostStore(defaults: defaults),
            gateway: ScriptedMoonlightGateway(),
            identity: nil,
            edges: FakeMoonlightEdges(),
            discover: { [] }
        )
        model = AppModel(store: store, defaults: defaults, moonlight: moonlight)
    }

    private func rememberDenBinding(type: Int?) {
        BindingMemoryStore(defaults: defaults).remember(RememberedSatelliteBinding(slotId: pad.id, satelliteId: den.id, emulatedType: type))
    }

    /// The satellite joins the pool, as the launch's reconnect sweep puts it there.
    private func poolDen() {
        model.wifi.register(WifiConnection(id: den.id, server: den, tickIntervalNs: .max))
    }

    private func waitUntil(timeout: TimeInterval = 3, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    /// Long enough for every settled emission to have run.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    func testALaunchWithThePadPresentRestoresTheBindingAndItsPick() async {
        rememberDenBinding(type: 2)
        launch()
        poolDen()
        model.input.slots = [pad]
        let restored = await waitUntil { self.model.hub.bindings[self.pad.id] == self.den.id }
        XCTAssertTrue(restored, "bound again without the user")
        XCTAssertEqual(model.wifi.typeOverrides.typeFor(SlotKey(connectionId: den.id, slotId: pad.id)), 2)
        XCTAssertEqual(model.wifi.get(den.id)?.descriptor(for: pad.id)?.type, 2, "the satellite is asked for the pick")
    }

    func testThePadAttachingLaterIsBoundAgainAndSoIsItsReturn() async {
        rememberDenBinding(type: nil)
        launch()
        poolDen()
        await settle()
        XCTAssertNil(model.hub.bindings[pad.id], "no pad, nothing to bind")
        model.input.slots = [pad]
        let attached = await waitUntil { self.model.hub.bindings[self.pad.id] == self.den.id }
        XCTAssertTrue(attached)

        model.input.slots = []
        let left = await waitUntil { self.model.hub.bindings.isEmpty }
        XCTAssertTrue(left, "the pad left and its binding with it")
        model.input.slots = [pad]
        let returned = await waitUntil { self.model.hub.bindings[self.pad.id] == self.den.id }
        XCTAssertTrue(returned, "the memory outlived the pad's absence")
    }

    func testTheSatelliteAppearingLaterIsWhenThePadIsBound() async {
        rememberDenBinding(type: nil)
        launch()
        model.input.slots = [pad]
        await settle()
        XCTAssertNil(model.hub.bindings[pad.id], "the satellite is not in the pool yet")
        poolDen()
        let restored = await waitUntil { self.model.hub.bindings[self.pad.id] == self.den.id }
        XCTAssertTrue(restored)
    }

    func testAForgottenSatellitesBindingsNeverComeBack() async {
        rememberDenBinding(type: nil)
        launch()
        poolDen()
        model.forget(den.id)
        poolDen()
        model.input.slots = [pad]
        await settle()
        XCTAssertNil(model.hub.bindings[pad.id])
        XCTAssertEqual(BindingMemoryStore(defaults: defaults).bindings(), [])
    }

    func testARememberedMoonlightBindingIsRestoredWithItsPick() async {
        let hostStore = MoonlightHostStore(defaults: defaults)
        hostStore.put(RememberedMoonlightHost(host: host, paired: true))
        let pick = Int(MoonlightControllerType.nintendo)
        hostStore.putBinding(RememberedMoonlightBinding(slotId: pad.id, hostId: host.id, controllerType: pick))
        launch()
        model.input.slots = [pad]
        let restored = await waitUntil { self.model.hub.bindings[self.pad.id] == self.host.id }
        XCTAssertTrue(restored, "the Moonlight binding is read back and bound again")
        XCTAssertEqual(model.wifi.typeOverrides.typeFor(SlotKey(connectionId: host.id, slotId: pad.id)), pick)
    }

    func testTheForgetQuestionKnowsTheBindingsRememberedForPadsThatAreAway() async {
        rememberDenBinding(type: nil)
        launch()
        poolDen()
        let listed = await waitUntil { self.model.shellFacts.connections.rememberedPads[self.den.id] == ["pad"] }
        XCTAssertTrue(listed, "an id of another shape is named by itself")
        model.input.slots = [pad]
        let bound = await waitUntil { self.model.shellFacts.connections.rememberedPads.isEmpty }
        XCTAssertTrue(bound, "once bound again it is listed as bound, not remembered")
    }
}
