// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore
@testable import DishEngine

/// A host's feedback landing on the pad bound to the number it names: body
/// and trigger rumble folded per motor behind the slot's Rumble switch, the
/// lamp behind the Light bar setting, a number no pad holds reaching nothing.
@MainActor
final class MoonlightFeedbackRouterTests: XCTestCase {

    private struct Rumble: Equatable {
        var deviceId: String
        var strong: UInt16
        var weak: UInt16
        var durationMs: UInt16
    }

    private struct Lamp: Equatable {
        var deviceId: String
        var r: UInt8
        var g: UInt8
        var b: UInt8
    }

    private let playStation = MoonlightAnnouncedPad(
        type: MoonlightControllerType.playStation,
        capabilities: 0xFF,
        supportedButtons: 0x10F7FF
    )
    private let table = RoutingTable()
    private let gate = ForwardingGate()
    private var rumbles: [Rumble] = []
    private var lamps: [Lamp] = []
    private var conn: MoonlightConnection!
    private var router: MoonlightFeedbackRouter!

    override func setUp() {
        super.setUp()
        conn = MoonlightConnection(id: "moonlight:10.0.0.5", host: MoonlightHost(name: "PC", address: "10.0.0.5"))
        _ = conn.acquirePad("ds", as: playStation)
        route(rumble: true)
        let actuators = MoonlightFeedbackActuators(
            rumble: { [weak self] deviceId, strong, weak, durationMs in
                self?.rumbles.append(Rumble(deviceId: deviceId, strong: strong, weak: weak, durationMs: durationMs))
            },
            lightbar: { [weak self] deviceId, r, g, b in self?.lamps.append(Lamp(deviceId: deviceId, r: r, g: g, b: b)) }
        )
        router = MoonlightFeedbackRouter(actuators: actuators, gate: gate, table: table)
        router.wire([conn.id: conn])
    }

    private func route(rumble: Bool) {
        var snapshot = RoutingSnapshot()
        snapshot.bySlot["ds"] = Route(sink: MoonlightPadSink(link: conn.link, slotId: "ds"), flags: ForwardingFlags(rumble: rumble))
        table.set(snapshot)
    }

    private func settle() async {
        for _ in 0 ..< 5 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            await Task.yield()
        }
    }

    func testBodyAndTriggerRumbleFoldPerMotorOntoTheBoundPad() async {
        conn.receive(.rumble(controller: 0, low: 1000, high: 2000))
        await settle()
        XCTAssertEqual(
            rumbles,
            [Rumble(deviceId: "ds", strong: 1000, weak: 2000, durationMs: 1500)],
            "low frequency is the large motor, held until the next"
        )
        conn.receive(.rumbleTriggers(controller: 0, left: 3000, right: 500))
        await settle()
        XCTAssertEqual(rumbles.last, Rumble(deviceId: "ds", strong: 3000, weak: 2000, durationMs: 1500), "per-motor maximum, never a sum")
        conn.receive(.rumble(controller: 0, low: 0, high: 0))
        await settle()
        XCTAssertEqual(
            rumbles.last,
            Rumble(deviceId: "ds", strong: 3000, weak: 500, durationMs: 1500),
            "the triggers still hold their motors"
        )
        XCTAssertEqual(rumbles.count, 3)
    }

    func testTheSlotsRumbleSwitchOffDropsItAndOnLetsItThrough() async {
        route(rumble: false)
        conn.receive(.rumble(controller: 0, low: 1000, high: 2000))
        await settle()
        XCTAssertEqual(rumbles, [])
        route(rumble: true)
        conn.receive(.rumble(controller: 0, low: 1000, high: 2000))
        await settle()
        XCTAssertEqual(rumbles.count, 1)
    }

    func testTheLampFollowsTheLightBarSetting() async {
        gate.update(ForwardingFlags(lightbar: false))
        conn.receive(.rgbLed(controller: 0, red: 1, green: 2, blue: 3))
        await settle()
        XCTAssertEqual(lamps, [])
        gate.update(ForwardingFlags(lightbar: true))
        conn.receive(.rgbLed(controller: 0, red: 1, green: 2, blue: 3))
        await settle()
        XCTAssertEqual(lamps, [Lamp(deviceId: "ds", r: 1, g: 2, b: 3)])
    }

    func testANumberNoPadHoldsReachesNothing() async {
        conn.receive(.rumble(controller: 3, low: 1000, high: 2000))
        conn.receive(.rumble(controller: 0x100, low: 1000, high: 2000))
        conn.receive(.rgbLed(controller: 1, red: 1, green: 2, blue: 3))
        conn.receive(.rumble(controller: 0, low: 7, high: 8))
        await settle()
        XCTAssertEqual(rumbles, [Rumble(deviceId: "ds", strong: 7, weak: 8, durationMs: 1500)])
        XCTAssertEqual(lamps, [])
    }

    func testAHostIsWiredOnceAndAgainAfterItLeftAndCameBack() async {
        router.wire([conn.id: conn])
        conn.receive(.rumble(controller: 0, low: 1, high: 1))
        await settle()
        XCTAssertEqual(rumbles.count, 1, "wired once, however often the pool is seen")
        router.wire([:])
        router.wire([conn.id: conn])
        conn.receive(.rumble(controller: 0, low: 2, high: 2))
        await settle()
        XCTAssertEqual(rumbles.count, 2)
    }
}
