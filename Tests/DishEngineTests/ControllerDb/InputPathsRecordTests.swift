// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import IOKit.hid
import XCTest
@testable import DishEngine

/// The record at attach on the Direct path: the reader hears new data, a
/// pad's hardware is checked against its record's `expect`, and its last
/// write is kept on its facts.
@MainActor
final class InputPathsRecordTests: XCTestCase {

    private var suite: String!
    private var defaults: UserDefaults!
    private var reader: FakeHidPadReader!
    private var scheduler: ManualPathScheduler!
    private var host: FakePathHost!
    private let processor = GamepadInputProcessor()

    override func setUp() {
        super.setUp()
        suite = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        reader = FakeHidPadReader()
        scheduler = ManualPathScheduler()
        host = FakePathHost()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// The bundled data: the N64 pad expects an OUT endpoint.
    private func paths(index: ControllerIndex? = nil) throws -> InputPaths {
        let bundled = try XCTUnwrap(BundledControllerDb.load())
        let paths = InputPaths(
            choices: UsbPathChoiceStore(defaults: defaults),
            reader: reader,
            scheduler: scheduler,
            controllerIndex: index ?? ControllerIndex(bundled, source: .bundled)
        )
        paths.host = host
        paths.start(processor: processor)
        return paths
    }

    private func arriveN64(_ paths: InputPaths, outputReportSize: Int?) throws -> HidPadLane {
        var properties = DirectFixtures.nintendoProperties(productId: 0x2019)
        properties[kIOHIDMaxOutputReportSizeKey] = outputReportSize
        let wiring = try XCTUnwrap(reader.wiring)
        let lane = try DirectFixtures.lane(DirectFixtures.candidate(properties), slotId: "hid:057e:2019", wiring: wiring)
        paths.hidPadArrived(HidPadArrival(slotId: "hid:057e:2019", lane: lane, probe: GameControllerProbe { true }))
        scheduler.advance(ms: 100)
        return lane
    }

    func testTheReaderStartsWithWhatTheDataAddsToTheTable() throws {
        _ = try paths()
        XCTAssertEqual(
            reader.wiring?.served,
            try ServedDirectModels(index: ControllerIndex(XCTUnwrap(BundledControllerDb.load()), source: .bundled))
        )
    }

    func testNewDataReachesTheReaderOnceAndTheSameDataNotAgain() throws {
        let paths = try paths()
        let served = try XCTUnwrap(try ServedVersion(dbVersion: 2).set)
        let newer = ControllerIndex(served, source: .cache)
        paths.useControllerIndex(newer)
        paths.useControllerIndex(newer)
        XCTAssertEqual(reader.servedUpdates, [ServedDirectModels(index: newer)])
        XCTAssertEqual(paths.controllerIndex, newer)
    }

    func testAPadWhoseOutputPathIsMissingIsAMismatch() throws {
        let paths = try paths()
        _ = try arriveN64(paths, outputReportSize: 0)
        XCTAssertEqual(paths.state["hid:057e:2019"]?.expectMismatches, ["endpoints.out: expected true, found false"])
    }

    func testAPadThatMeetsItsRecordHasNoMismatch() throws {
        let paths = try paths()
        _ = try arriveN64(paths, outputReportSize: 64)
        XCTAssertEqual(paths.state["hid:057e:2019"]?.expectMismatches, [])
    }

    func testAPadTheDataDoesNotKnowHasNoMismatch() throws {
        let empty = ControllerIndex(BundledControllerDb.empty, source: .bundled)
        let paths = try paths(index: empty)
        _ = try arriveN64(paths, outputReportSize: 0)
        XCTAssertEqual(paths.state["hid:057e:2019"]?.expectMismatches, [])
    }

    func testTheLastWriteIsTakenOnTheTickAndKeptUntilThePadLeaves() throws {
        let paths = try paths()
        let lane = try arriveN64(paths, outputReportSize: 64)
        XCTAssertNil(paths.state["hid:057e:2019"]?.lastWrite)
        lane.writes.record(route: .setReport, reportId: 0x80, status: kIOReturnNotResponding)
        paths.sampleRawRates(nowUs: 1_000_000)
        XCTAssertEqual(paths.state["hid:057e:2019"]?.lastWrite?.error, "kIOReturnNotResponding")
        paths.sampleRawRates(nowUs: 2_000_000)
        XCTAssertEqual(paths.state["hid:057e:2019"]?.lastWrite?.reportId, 0x80, "kept across ticks with nothing new")
        paths.hidPadRemoved(slotId: "hid:057e:2019")
        XCTAssertTrue(paths.lastWrites.isEmpty)
    }

    func testEachTransportHasItsDataWord() {
        XCTAssertEqual(controllerTransport(.usb), .usb)
        XCTAssertEqual(controllerTransport(.bluetooth(.classic)), .bluetooth)
        XCTAssertNil(controllerTransport(.other("SPI")))
        XCTAssertNil(controllerTransport(.unknown))
        XCTAssertNil(controllerTransport(nil))
    }
}
