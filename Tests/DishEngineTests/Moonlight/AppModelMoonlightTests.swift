// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import XCTest
@testable import DishCore
@testable import DishEngine

/// The composition root's Moonlight half: a binding to a host becomes the
/// pad its session is asked to carry, the pad's slot routes to the host's
/// link, the PIN prompt follows the pairing, and the intents reach the manager.
@MainActor
final class AppModelMoonlightTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!
    private var gateway: ScriptedMoonlightGateway!
    private var edges: FakeMoonlightEdges!
    private var moonlight: MoonlightConnectionManager!
    private var model: AppModel!
    private let host = MoonlightHost(name: "PC", address: "10.0.0.5", uniqueId: "abc")
    private let dualSense = GameControllerInput.Slot(
        id: "ds",
        name: "DualSense",
        capabilities: ControllerCapabilities(hasMotion: true, hasTouchpad: true, hasRumble: true, hasLightbar: true, hasBattery: true),
        battery: nil,
        family: .dualSense
    )

    override func setUp() {
        super.setUp()
        suite = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        gateway = ScriptedMoonlightGateway()
        edges = FakeMoonlightEdges()
        moonlight = MoonlightConnectionManager(
            store: MoonlightHostStore(defaults: defaults),
            gateway: gateway,
            identity: nil,
            edges: edges,
            discover: { [] }
        )
        var record = RememberedMoonlightHost(host: host, paired: true)
        record.uniqueId = "abc"
        moonlight.store.put(record)
        moonlight.publishRemembered()
        model = AppModel(store: ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore()), defaults: defaults, moonlight: moonlight)
    }

    override func tearDown() {
        model = nil
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testABindingBecomesThePadTheHostIsAskedToCarryAndTheSlotRoutesToItsLink() async {
        model.input.slots = [dualSense]
        model.bind(slotId: "ds", connectionId: host.id)
        XCTAssertEqual(moonlight.desired[host.id]?.map(\.slotId), ["ds"])
        XCTAssertEqual(moonlight.desired[host.id]?.first?.announced.type, MoonlightControllerType.playStation, "Auto with motion")
        await moonlight.awaitQuiet()
        XCTAssertEqual(moonlight.get(host.id)?.pads.map(\.slotId), ["ds"], "the pad is claimed whatever the host answered")
        XCTAssertEqual(model.connections.first?.boundSlotIds, ["ds"])
        XCTAssertEqual(
            model.slots.first?.emulation?.type,
            Int(MoonlightControllerType.auto),
            "the host's own pick, in the protocol's numbering"
        )
        XCTAssertEqual(model.slots.first?.emulation?.offered, [], "the types are the app's to offer")
        model.setSlotSwitch(.motion, on: false, slotId: "ds")
        XCTAssertEqual(moonlight.desired[host.id]?.first?.announced.type, MoonlightControllerType.xbox, "the switch re-resolves the pad")
        model.setEmulatedType(slotId: "ds", type: Int(MoonlightControllerType.nintendo))
        XCTAssertEqual(moonlight.desired[host.id]?.first?.announced.type, MoonlightControllerType.nintendo)
        XCTAssertEqual(model.slots.first?.emulation?.isOverride, true)
        model.unbind(slotId: "ds")
        XCTAssertEqual(moonlight.desired, [:])
        await moonlight.awaitQuiet()
        XCTAssertEqual(moonlight.get(host.id)?.padCount, 0)
    }

    func testThePinPromptFollowsThePairingAndTheIntentsReachTheManager() async {
        moonlight.events.send(.pairingPinReady(host: host, pin: "0451"))
        XCTAssertEqual(model.moonlightPin, MoonlightPinPrompt(host: host, pin: "0451"))
        XCTAssertEqual(model.moonlightPin?.id, host.id)
        moonlight.events.send(.paired(host))
        XCTAssertNil(model.moonlightPin)
        moonlight.events.send(.pairingPinReady(host: host, pin: "0452"))
        model.cancelMoonlightPairing(host.id)
        XCTAssertNil(model.moonlightPin)
        XCTAssertEqual(moonlight.pairingGenerations[host.id], 1)
        moonlight.events.send(.pairingPinReady(host: host, pin: "0453"))
        moonlight.events.send(.pairingFailed(
            host: host,
            reason: MoonlightPairingFailure(phase: 1, kind: .noCertificate, httpStatus: 0, hostSaid: "")
        ))
        XCTAssertNil(model.moonlightPin)
        model.setMoonlightApp(host.id, appId: "7", appName: "Steam")
        XCTAssertEqual(moonlight.rememberedAppId(hostId: host.id), "7")
        model.forget(host.id)
        await moonlight.awaitQuiet()
        XCTAssertNil(moonlight.store.host(id: host.id))
        XCTAssertEqual(model.connections, [])
    }

    func testForgettingAHostUnbindsItsSlotsFirst() async {
        model.input.slots = [dualSense]
        model.bind(slotId: "ds", connectionId: host.id)
        model.forget(host.id)
        XCTAssertEqual(model.hub.bindings, [:])
        await moonlight.awaitQuiet()
        XCTAssertEqual(moonlight.desired, [:])
        XCTAssertNil(moonlight.get(host.id))
    }

    func testAScanBrowsesForBothKindsAndDisconnectReachesTheHost() async {
        model.startScan()
        XCTAssertTrue(moonlight.isScanning || model.wifi.isScanning)
        model.disconnect(host.id)
        await moonlight.awaitQuiet()
        XCTAssertNil(moonlight.get(host.id), "a host with no session has nothing to stop")
    }
}
