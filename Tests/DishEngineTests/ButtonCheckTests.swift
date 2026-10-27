// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import XCTest
@testable import DishEngine

/// "Check the buttons" through the paths: a generic Direct pad's walk
/// listens on its lane, a press lands as the control asked for, is stored
/// under `joystick_remaps` and swaps the lane's table; a pad read by a fixed
/// decoder or by macOS gets no walk, and a pad that leaves ends it.
@MainActor
final class ButtonCheckTests: XCTestCase {

    private static let generic = "hid:1234:5678"
    private static let rest: [UInt8] = [0x7F, 0x7F, 0x7F, 0x7F, 0x08, 0x00, 0x00]
    private static let button9: [UInt8] = [0x7F, 0x7F, 0x7F, 0x7F, 0x08, 0x00, 0x02]

    private var suite: String!
    private var defaults: UserDefaults!
    private var reader: FakeHidPadReader!
    private var scheduler: ManualPathScheduler!
    private var remaps: JoystickRemapStore!
    private var paths: InputPaths!
    private let host = FakePathHost()
    private let processor = GamepadInputProcessor()

    override func setUp() {
        super.setUp()
        suite = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        reader = FakeHidPadReader()
        scheduler = ManualPathScheduler()
        remaps = JoystickRemapStore(defaults: defaults)
        paths = InputPaths(choices: UsbPathChoiceStore(defaults: defaults), remaps: remaps, reader: reader, scheduler: scheduler) { 0 }
        paths.host = host
        paths.start(processor: processor)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// A generic pad GameController does not show, on the reader's own wiring.
    private func arriveGeneric() throws -> HidPadLane {
        let wiring = try XCTUnwrap(reader.wiring)
        let lane = try DirectFixtures.lane(
            DirectFixtures.candidate(DirectFixtures.gamepadProperties()),
            slotId: Self.generic,
            wiring: wiring
        )
        paths.hidPadArrived(HidPadArrival(slotId: Self.generic, lane: lane, probe: GameControllerProbe { false }))
        scheduler.advance(ms: 100)
        return lane
    }

    private var walk: RemapAssignState? {
        guard case let .walking(walk) = paths.buttonCheck.state?.phase else { return nil }
        return walk
    }

    func testAGenericPadsWalkStartsFromItsModelsOrderAndListens() throws {
        let lane = try arriveGeneric()
        XCTAssertEqual(paths.state[Self.generic]?.remappable, true)
        paths.beginButtonCheck(slotId: Self.generic)
        XCTAssertEqual(paths.buttonCheck.state?.name, "Generic Pad")
        XCTAssertEqual(walk?.remap, defaultRemap(order: .western))
        XCTAssertEqual(walk?.step, .assign(.button(.faceA)))
        XCTAssertTrue(lane.gate.capturing)
    }

    func testAPressBecomesTheControlIsStoredAndSwapsTheLanesTable() throws {
        let lane = try arriveGeneric()
        paths.beginButtonCheck(slotId: Self.generic)
        feedReport(Self.rest, to: lane)
        feedReport(Self.button9, to: lane)
        drainMain()
        XCTAssertEqual(walk?.remap.button(.faceA), 9)
        XCTAssertEqual(walk?.step, .assign(.button(.faceB)))
        XCTAssertEqual(remaps.remap(vendorId: 0x1234, productId: 0x5678)?.button(.faceA), 9)
        XCTAssertEqual(lane.remapTable, walk.map { HidRemapTable(remap: $0.remap) })
        XCTAssertTrue(lane.gate.takeCaptureWish(), "the walk asks for the next change at once")
    }

    func testResetDropsTheStoredRemapAndTheLaneReadsItsModelsOrderAgain() throws {
        let lane = try arriveGeneric()
        paths.beginButtonCheck(slotId: Self.generic)
        paths.buttonCheck.send(.captured(RawCapture(kind: .button, index: 9)))
        XCTAssertNotNil(lane.remapTable)
        paths.buttonCheck.send(.reset)
        XCTAssertNil(remaps.remap(vendorId: 0x1234, productId: 0x5678))
        XCTAssertNil(lane.remapTable)
        XCTAssertEqual(walk?.stepIndex, 0)
    }

    func testAStoredRemapIsTheLanesTableFromItsArrival() throws {
        var remap = defaultRemap(order: .western)
        remap.setButton(.faceB, 3)
        remaps.setRemap(remap, vendorId: 0x1234, productId: 0x5678)
        let lane = try arriveGeneric()
        XCTAssertEqual(lane.remapTable, HidRemapTable(remap: remap))
        paths.beginButtonCheck(slotId: Self.generic)
        XCTAssertEqual(walk?.remap, remap, "the walk starts from what is stored")
    }

    func testAPadReadByAFixedDecoderOrByMacOSGetsNoWalk() throws {
        let wiring = try XCTUnwrap(reader.wiring)
        let n64 = try DirectFixtures.lane(
            DirectFixtures.candidate(DirectFixtures.nintendoProperties(productId: 0x2019)),
            slotId: "hid:057e:2019",
            wiring: wiring
        )
        paths.hidPadArrived(HidPadArrival(slotId: "hid:057e:2019", lane: n64, probe: GameControllerProbe { true }))
        paths.beginButtonCheck(slotId: "hid:057e:2019")
        XCTAssertEqual(paths.buttonCheck.state?.phase, .notRemappable)
        XCTAssertFalse(n64.gate.capturing)
        _ = paths.gameControllerAttached(id: "gc:pad", name: "Pad", category: "MFi", hasRumble: false) // The gate is not under test here.
        paths.beginButtonCheck(slotId: "gc:pad")
        XCTAssertEqual(paths.buttonCheck.state, ButtonCheckFacts(slotId: "gc:pad", name: "Pad", phase: .notRemappable))
        paths.beginButtonCheck(slotId: "gone")
        XCTAssertEqual(paths.buttonCheck.state?.phase, .missing)
    }

    func testThePadLeavingEndsTheWalkAndLeavingThePageClosesIt() throws {
        let lane = try arriveGeneric()
        paths.beginButtonCheck(slotId: Self.generic)
        paths.hidPadRemoved(slotId: Self.generic)
        XCTAssertEqual(paths.buttonCheck.state?.phase, .missing)
        XCTAssertFalse(lane.gate.capturing)
        let again = try arriveGeneric()
        paths.beginButtonCheck(slotId: Self.generic)
        paths.buttonCheck.end()
        XCTAssertNil(paths.buttonCheck.state)
        XCTAssertFalse(again.gate.capturing)
        paths.buttonCheck.captured(slotId: Self.generic, RawCapture(kind: .button, index: 1))
        XCTAssertNil(paths.buttonCheck.state, "a change after the walk ended lands nowhere")
    }
}
