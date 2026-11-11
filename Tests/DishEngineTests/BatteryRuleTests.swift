// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import GameController
import XCTest
@testable import DishEngine

/// The battery rule on both input paths: the wire hears the lower of the
/// pad's own battery and the Mac's, read off the main actor, while the card
/// keeps the pad's own reading.
@MainActor
final class BatteryRuleTests: XCTestCase {

    private static let n64 = "hid:057e:2019"
    private static let generic = "hid:1234:5678"

    private var suite: String!
    private var defaults: UserDefaults!
    private var reader: FakeHidPadReader!
    private var scheduler: ManualPathScheduler!
    private let mac = LockedBox(PadBattery(level: 30, status: .discharging))
    private let sent = LockedBox<[PadBattery]>([])

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

    private func bridge(_ connected: [GCController] = []) -> GameControllerInput {
        let paths = InputPaths(choices: UsbPathChoiceStore(defaults: defaults), reader: reader, scheduler: scheduler)
        let mac = mac
        let input = GameControllerInput(connected: connected, paths: paths, categoryOf: { _ in "MFi" }, hostBattery: { mac.get() })
        let sent = sent
        input.processor.send(batteries: { _, level, status in
            sent.mutate { $0.append(PadBattery(level: level, status: BatteryStatus(rawValue: status) ?? .unknown)) }
        })
        return input
    }

    private func arrive(_ input: GameControllerInput, _ properties: [String: Any], slotId: String, shows: Bool) throws -> HidPadLane {
        let wiring = try XCTUnwrap(reader.wiring)
        let lane = try DirectFixtures.lane(DirectFixtures.candidate(properties), slotId: slotId, wiring: wiring)
        input.paths.hidPadArrived(HidPadArrival(slotId: slotId, lane: lane, probe: GameControllerProbe { shows }))
        return lane
    }

    /// The N64's idle report with its battery byte replaced.
    private func n64Report(batCon: UInt8) -> [UInt8] {
        var bytes = DirectFixtures.n64Idle
        bytes[2] = batCon
        return bytes
    }

    // MARK: - The Direct path

    func testADirectPadAboveTheMacSendsTheMacsBatteryAndItsCardKeepsItsOwn() throws {
        let input = bridge()
        let lane = try arrive(input, DirectFixtures.nintendoProperties(productId: 0x2019), slotId: Self.n64, shows: true)
        feedReport(DirectFixtures.n64Idle, to: lane)
        spinMainUntil { !sent.get().isEmpty }
        XCTAssertEqual(sent.get().first, PadBattery(level: 30, status: .discharging), "the Mac's 30 % is lower than the pad's full charge")
        XCTAssertEqual(input.slots.first?.battery, BatteryReading(level: 100, state: .charging), "the card shows the pad's own")
    }

    func testADirectPadBelowTheMacSendsItsOwn() throws {
        mac.set(PadBattery(level: 80, status: .discharging))
        let input = bridge()
        let lane = try arrive(input, DirectFixtures.nintendoProperties(productId: 0x2019), slotId: Self.n64, shows: true)
        feedReport(n64Report(batCon: 0x50), to: lane)
        spinMainUntil { !sent.get().isEmpty }
        XCTAssertEqual(sent.get().first, PadBattery(level: 50, status: .charging), "the pad's half charge, with the pad's status")
    }

    func testTheHeartbeatSendsTheLowerOfTheLastPadReadingAndTheMacsNow() throws {
        let input = bridge()
        let lane = try arrive(input, DirectFixtures.nintendoProperties(productId: 0x2019), slotId: Self.n64, shows: true)
        feedReport(n64Report(batCon: 0x30), to: lane)
        spinMainUntil { !sent.get().isEmpty }
        mac.set(PadBattery(level: 10, status: .discharging))
        sent.set([])
        input.beatDirectBattery(Self.n64, lane: lane)
        spinMainUntil { !sent.get().isEmpty }
        XCTAssertEqual(sent.get(), [PadBattery(level: 10, status: .discharging)], "the Mac fell below the pad's 25 %")
    }

    func testADirectPadWithNoBatteryBeatsTheMacsAndShowsNoChip() throws {
        let input = bridge()
        _ = try arrive(input, DirectFixtures.gamepadProperties(), slotId: Self.generic, shows: false)
        scheduler.advance(ms: 100)
        XCTAssertEqual(input.slots.map(\.id), [Self.generic])
        XCTAssertNotNil(input.batteryTimers[Self.generic], "every Direct pad beats a battery, its own or the Mac's")
        input.beatDirectBattery(Self.generic, lane: nil)
        spinMainUntil { !sent.get().isEmpty }
        XCTAssertEqual(sent.get(), [PadBattery(level: 30, status: .discharging)])
        XCTAssertNil(input.slots.first?.battery, "a pad that reports none keeps a card with no battery")
    }

    func testTheLaneLeavesTheWireToTheMainActor() throws {
        let input = bridge()
        let lane = try arrive(input, DirectFixtures.nintendoProperties(productId: 0x2019), slotId: Self.n64, shows: true)
        feedReport(DirectFixtures.n64Idle, to: lane)
        XCTAssertEqual(sent.get(), [], "the reader's thread sends no battery: the Mac's must be read first")
        settleBattery(input)
        XCTAssertEqual(sent.get().count, 1, "the main actor sends it once the Mac's is read")
    }

    // MARK: - The GameController path

    func testAControllerWithNoBatterySendsTheMacsAndShowsIt() throws {
        let controller = GCController.withExtendedGamepad()
        let input = bridge([controller])
        let id = try XCTUnwrap(input.slots.first?.id)
        input.emitBattery(deviceId: id, controller: controller, force: true)
        spinMainUntil { !sent.get().isEmpty }
        XCTAssertEqual(sent.get().first, PadBattery(level: 30, status: .discharging))
        XCTAssertEqual(input.slots.first?.battery, BatteryReading(level: 30, state: .discharging))
    }

    func testTheStateWatchSendsOnlyWhenTheSentStatusMoves() throws {
        let controller = GCController.withExtendedGamepad()
        let input = bridge([controller])
        let id = try XCTUnwrap(input.slots.first?.id)
        input.emitBattery(deviceId: id, controller: controller, force: true)
        settleBattery(input)
        input.emitBattery(deviceId: id, controller: controller, force: false)
        settleBattery(input)
        XCTAssertEqual(sent.get().count, 1, "nothing moved: the watch stays quiet")
        mac.set(PadBattery(level: 30, status: .charging))
        input.emitBattery(deviceId: id, controller: controller, force: false)
        settleBattery(input)
        XCTAssertEqual(sent.get(), [PadBattery(level: 30, status: .discharging), PadBattery(level: 30, status: .charging)])
    }

    /// The Mac's read has run on its queue and its answer has landed on the
    /// main actor.
    private func settleBattery(_ input: GameControllerInput) {
        drainMain()
        input.batteryWorkQueue.sync {}
        drainMain()
    }

    // MARK: - A controller's own battery

    func testAControllersBatteryReadsAsAPercentWithItsStatus() {
        let mostly = GameControllerInput.controllerBattery(level: 0.734, state: .discharging)
        XCTAssertEqual(mostly, PadBattery(level: 73, status: .discharging))
        XCTAssertEqual(GameControllerInput.controllerBattery(level: 1.5, state: .full), PadBattery(level: 100, status: .full))
        XCTAssertEqual(GameControllerInput.controllerBattery(level: 0, state: .charging), PadBattery(level: 0, status: .charging))
        XCTAssertEqual(GameControllerInput.controllerBattery(level: 0.5, state: .unknown), PadBattery(level: 50, status: .unknown))
    }

    func testAControllerWhoseLevelReadsUnknownHasNoBatteryOfItsOwn() {
        XCTAssertNil(GameControllerInput.controllerBattery(level: -1, state: .unknown), "the Mac's stands in")
    }
}
