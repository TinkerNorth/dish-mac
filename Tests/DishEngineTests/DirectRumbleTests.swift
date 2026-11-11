// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import GameController
import XCTest
@testable import DishEngine

/// The host's rumble onto a Direct pad that drives its own rumble report:
/// the feedback queue hands it to the pad's output rather than to
/// GameController's engines, and only while the pad's slot shows.
@MainActor
final class DirectRumbleTests: XCTestCase {

    private static let triton = "hid:28de:1302"
    private static let original = "hid:28de:1102"

    private var suite: String!
    private var defaults: UserDefaults!
    private var reader: FakeHidPadReader!
    private var scheduler: ManualPathScheduler!

    override func setUp() {
        super.setUp()
        GCController.shouldMonitorBackgroundEvents = false
        suite = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        reader = FakeHidPadReader()
        scheduler = ManualPathScheduler()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func bridge() -> GameControllerInput {
        let choices = UsbPathChoiceStore(defaults: defaults)
        choices.setChoice(.direct, vendorId: 0x28DE, productId: 0x1302)
        choices.setChoice(.direct, vendorId: 0x28DE, productId: 0x1102)
        let paths = InputPaths(choices: choices, reader: reader, scheduler: scheduler)
        return GameControllerInput(
            connected: [],
            paths: paths,
            categoryOf: { _ in "MFi" },
            hostBattery: { PadBattery(level: 50, status: .discharging) }
        )
    }

    private func arrive(_ input: GameControllerInput, productId: Int, slotId: String, output: DirectOutput) throws {
        let wiring = try XCTUnwrap(reader.wiring)
        let properties = DirectFixtures.valveProperties(productId: productId, interfaceNumber: 2)
        let lane = try DirectFixtures.lane(DirectFixtures.candidate(properties), slotId: slotId, wiring: wiring, output: output)
        input.paths.hidPadArrived(HidPadArrival(slotId: slotId, lane: lane, probe: GameControllerProbe { false }))
        scheduler.advance(ms: 100)
    }

    /// The feedback queue has run what the post scheduled.
    private func settleFeedback(_ input: GameControllerInput) {
        input.padActuators.queue.sync {}
        input.padActuators.queue.sync {}
    }

    func testAHostRumbleReachesThe2026PadsOwnReport() throws {
        let input = bridge()
        let output = FakeDirectOutput()
        try arrive(input, productId: 0x1302, slotId: Self.triton, output: output)
        XCTAssertEqual(input.slots.map(\.id), [Self.triton])
        input.applyRumble(deviceId: Self.triton, strongMagnitude: 0x8000, weakMagnitude: 0x1000, durationMs: 500)
        settleFeedback(input)
        XCTAssertEqual(output.calls, [.rumble(strong: 0x8000, weak: 0x1000, durationMs: 500)])
    }

    func testThe2015PadsOutputTakesNoRumble() throws {
        let input = bridge()
        let output = FakeDirectOutput()
        try arrive(input, productId: 0x1102, slotId: Self.original, output: output)
        input.applyRumble(deviceId: Self.original, strongMagnitude: 0x8000, weakMagnitude: 0x8000, durationMs: 500)
        settleFeedback(input)
        XCTAssertEqual(output.calls, [], "no motors: the rumble is dropped with no carrier behind it")
    }

    func testAPadWhoseSlotGoesTakesNoMoreRumble() throws {
        let input = bridge()
        let output = FakeDirectOutput()
        try arrive(input, productId: 0x1302, slotId: Self.triton, output: output)
        input.paths.hidPadRemoved(slotId: Self.triton)
        input.applyRumble(deviceId: Self.triton, strongMagnitude: 1, weakMagnitude: 1, durationMs: 500)
        settleFeedback(input)
        XCTAssertEqual(output.calls, [])
    }

    func testTheActuatorsHandAFiledOutputTheRumbleAndForgetItWhenUnfiled() {
        let actuators = PadActuators(queue: DispatchQueue(label: "test.feedback"))
        let output = FakeDirectOutput()
        actuators.fileOutput(output, for: Self.triton)
        actuators.queue.sync { actuators.actuators.rumble(Self.triton, 3, 4, 50) }
        actuators.fileOutput(nil, for: Self.triton)
        actuators.queue.sync { actuators.actuators.rumble(Self.triton, 5, 6, 50) }
        XCTAssertEqual(output.calls, [.rumble(strong: 3, weak: 4, durationMs: 50)])
    }
}
