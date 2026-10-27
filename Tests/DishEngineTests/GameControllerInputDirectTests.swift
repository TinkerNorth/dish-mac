// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import GameController
import XCTest
@testable import DishEngine

/// R7 in the bridge: a controller GameController lists under a Direct-by-
/// model Nintendo category gets no input slot and publishes nothing, stays
/// the carrier of its pad's rumble and lights, and gets its slot back when
/// the user picks Standard for the model.
@MainActor
final class GameControllerInputDirectTests: XCTestCase {

    private static let pro = "hid:057e:2009"

    private var suite: String!
    private var defaults: UserDefaults!
    private var reader: FakeHidPadReader!
    private let published = LockedBox<[String]>([])

    override func setUp() {
        super.setUp()
        GCController.shouldMonitorBackgroundEvents = false
        suite = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        reader = FakeHidPadReader()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func bridge(_ connected: [GCController], category: String) -> GameControllerInput {
        let paths = InputPaths(choices: UsbPathChoiceStore(defaults: defaults), reader: reader, scheduler: ManualPathScheduler())
        let input = GameControllerInput(connected: connected, paths: paths) { _ in category }
        let published = published
        input.processor.reportSender = { deviceId, _ in published.set(published.get() + [deviceId]) }
        return input
    }

    private func arrive(_ input: GameControllerInput, productId: Int, slotId: String) throws -> HidPadLane {
        let wiring = try XCTUnwrap(reader.wiring)
        let lane = try DirectFixtures.lane(
            DirectFixtures.candidate(DirectFixtures.nintendoProperties(productId: productId)),
            slotId: slotId,
            wiring: wiring
        )
        input.paths.hidPadArrived(HidPadArrival(slotId: slotId, lane: lane, probe: GameControllerProbe { true }))
        return lane
    }

    /// The framework's own call, from the queue the pad was handed.
    private func press(_ pad: GCExtendedGamepad, on input: GameControllerInput) {
        pad.buttonA.setValue(1)
        let call = HandlerCall(pad: pad)
        input.inputQueue.sync { call.fire() }
    }

    func testANintendoCategoryControllerGetsNoInputSlotAndPublishesNothing() throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try XCTUnwrap(controller.extendedGamepad)
        let input = bridge([controller], category: "Switch N64 Controller")
        XCTAssertEqual(input.slots, [])
        XCTAssertNotNil(pad.valueChangedHandler, "kept as a carrier: its handlers still hear for a check")
        press(pad, on: input)
        XCTAssertEqual(published.get(), [])
        XCTAssertTrue(input.batteryTimers.isEmpty, "no battery of its own while hidden")
    }

    func testAnOrdinaryControllerIsStandardAndPublishesAsBefore() throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try XCTUnwrap(controller.extendedGamepad)
        let input = bridge([controller], category: "MFi")
        let id = try XCTUnwrap(input.slots.first?.id)
        XCTAssertEqual(input.paths.state[id]?.source, .standard)
        press(pad, on: input)
        XCTAssertEqual(published.get(), [id])
    }

    func testTheDirectProsRumbleAndLightsRideItsCarrier() throws {
        let controller = GCController.withExtendedGamepad()
        let input = bridge([controller], category: "Switch Pro Controller")
        _ = try arrive(input, productId: 0x2009, slotId: Self.pro) // The lane is not under test here.
        XCTAssertEqual(input.slots.map(\.id), [Self.pro])
        XCTAssertTrue(input.controllersById[Self.pro] === controller, "the return paths reach the carrier under the pad's id")
        XCTAssertEqual(input.slots.first?.family, .nintendo)
    }

    func testAStandardPickRestoresTheCarriersSlotAndADirectPickHidesItAgain() throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try XCTUnwrap(controller.extendedGamepad)
        let input = bridge([controller], category: "Switch Pro Controller")
        let carrierId = input.slotId(for: controller)
        _ = try arrive(input, productId: 0x2009, slotId: Self.pro) // The lane is not under test here.

        XCTAssertTrue(input.paths.pick(slotId: Self.pro, .standard))
        XCTAssertEqual(input.slots.map(\.id), [carrierId])
        XCTAssertNil(input.controllersById[Self.pro], "no Direct slot, no alias")
        press(pad, on: input)
        XCTAssertEqual(published.get(), [carrierId])

        XCTAssertTrue(input.paths.pick(slotId: carrierId, .direct))
        XCTAssertEqual(input.slots.map(\.id), [Self.pro])
        published.set([])
        press(pad, on: input)
        XCTAssertEqual(published.get(), [], "the carrier publishes nothing again")
    }

    func testADirectPadsBatteryReachesItsSlotCard() throws {
        let input = bridge([], category: "MFi")
        let lane = try arrive(input, productId: 0x2019, slotId: "hid:057e:2019")
        feedReport(DirectFixtures.n64Idle, to: lane)
        spinMainUntil { input.slots.first?.battery != nil }
        XCTAssertEqual(input.slots.first?.battery, BatteryReading(level: 100, state: .charging))
        XCTAssertNotNil(input.batteryTimers["hid:057e:2019"], "the 30 s heartbeat")
        input.paths.hidPadRemoved(slotId: "hid:057e:2019")
        XCTAssertEqual(input.slots, [])
        XCTAssertNil(input.batteryTimers["hid:057e:2019"])
    }

    func testAReportFromTheN64ReachesTheProcessorUnderItsSlot() throws {
        let input = bridge([], category: "MFi")
        let lane = try arrive(input, productId: 0x2019, slotId: "hid:057e:2019")
        feedReport(DirectFixtures.n64Idle, to: lane)
        feedReport(DirectFixtures.n64PressedA, to: lane)
        XCTAssertEqual(published.get(), ["hid:057e:2019", "hid:057e:2019"])
    }
}

/// The framework's objects are not `Sendable`; the test owns them and
/// touches them on one queue at a time.
private struct HandlerCall: @unchecked Sendable {
    let pad: GCExtendedGamepad

    func fire() {
        pad.valueChangedHandler?(pad, pad.buttonA)
    }
}
