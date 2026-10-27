// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import XCTest
@testable import DishEngine

/// The input paths through the composition root: a Direct pad joins the
/// slot list the UI reads, its path facts reach the shell, a pick the model
/// cannot take is refused and stores nothing, a check's verdict lands in
/// the facts and the flight recorder, and Diagnostics reads the path and
/// the raw rate on its own tick.
@MainActor
final class AppModelInputPathTests: XCTestCase {

    private static let n64 = "hid:057e:2019"

    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var reader: FakeHidPadReader!
    private var model: AppModel!

    override func setUp() {
        super.setUp()
        defaultsName = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
        reader = FakeHidPadReader()
        model = AppModel(
            store: ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore()),
            defaults: defaults,
            hidPads: reader,
            discovery: WifiConnectionManager.DiscoveryPaths { WifiConnectionManager.ScanResult(broadcast: [], mdns: []) }
        )
    }

    override func tearDown() {
        model = nil
        defaults.removePersistentDomain(forName: defaultsName)
        super.tearDown()
    }

    private func arriveN64() throws -> HidPadLane {
        let wiring = try XCTUnwrap(reader.wiring, "the root starts the reader")
        let candidate = try DirectFixtures.candidate(DirectFixtures.nintendoProperties(productId: 0x2019))
        let lane = DirectFixtures.lane(candidate, slotId: Self.n64, wiring: wiring)
        model.input.paths.hidPadArrived(HidPadArrival(slotId: Self.n64, lane: lane, probe: GameControllerProbe { true }))
        return lane
    }

    func testADirectPadJoinsTheSlotListWithItsPathAndPlayerNumber() throws {
        _ = try arriveN64() // The lane is not under test here.
        let slot = try XCTUnwrap(model.slots.first { $0.id == Self.n64 })
        XCTAssertEqual(slot.name, "Nintendo N64 Online Controller")
        XCTAssertEqual(slot.family, .nintendo)
        let path = try XCTUnwrap(model.shellFacts.inputPaths[Self.n64])
        XCTAssertEqual(path.source, .direct)
        XCTAssertEqual(path.reason, .directByModel)
        XCTAssertEqual(path.playerNumber, 1)
        XCTAssertTrue(model.diagnosticsLog.state.contains { $0.kind == .padPathChosen && $0.path == .chosen(.direct, .directByModel) })
    }

    func testAPickTheModelCannotTakeIsRefusedAndStoresNothing() throws {
        _ = try arriveN64() // The lane is not under test here.
        XCTAssertFalse(model.pickInputPath(slotId: Self.n64, .standard))
        XCTAssertNil(defaults.dictionary(forKey: "usb_path_choices"))
        XCTAssertEqual(model.shellFacts.inputPaths[Self.n64]?.source, .direct)
    }

    func testTheCheckYieldsItsVerdictInTheFactsAndTheFlightRecorder() throws {
        let lane = try arriveN64()
        model.startInputCheck(slotId: Self.n64)
        guard case .running = model.shellFacts.inputPaths[Self.n64]?.check else { return XCTFail("the check runs") }
        feedReport(DirectFixtures.n64Idle, to: lane)
        feedReport(DirectFixtures.n64PressedA, to: lane)
        spinMainUntil { model.shellFacts.inputPaths[Self.n64]?.check == .concluded(.dishReadsIt, offer: CheckOffer.none) }
        XCTAssertEqual(model.shellFacts.inputPaths[Self.n64]?.check, .concluded(.dishReadsIt, offer: CheckOffer.none))
        XCTAssertTrue(model.diagnosticsLog.state.contains { $0.kind == .padCheckConcluded && $0.path == .verdict(.dishReadsIt) })
    }

    func testDiagnosticsReadsThePathTheUsbIdAndTheRawRateOnItsTick() throws {
        let lane = try arriveN64()
        model.pageAppeared(.diagnostics)
        for _ in 0 ..< 40 {
            feedReport(DirectFixtures.n64Idle, to: lane)
        }
        model.diagnostics.refresh()
        let pad = try XCTUnwrap(model.diagnostics.state.pads.first { $0.id == Self.n64 })
        XCTAssertEqual(pad.inputPath?.source, .direct)
        XCTAssertEqual(pad.hardwareId, HidHardwareId(vendorId: 0x057E, productId: 0x2019), "a Direct pad names its own USB ID")
        XCTAssertNotNil(pad.inputPath?.rawReportHz, "sampled on the Diagnostics tick")
        model.pageDisappeared(.diagnostics)
    }

    func testAPadThatKeepsDroppingReachesTheAppOncePerBurstByName() throws {
        var names: [String] = []
        let subscription = model.padKeepsDisconnecting.sink { names.append($0) }
        for _ in 0 ..< 4 {
            _ = try arriveN64() // The lane is not under test here.
            model.input.paths.hidPadRemoved(slotId: Self.n64)
        }
        XCTAssertEqual(names, ["Nintendo N64 Online Controller"], "the fourth drop is the same burst")
        subscription.cancel()
    }

    func testTheControllerSupportPagesOpenTheirWorkAsTheyShowAndEndItAsTheyGo() throws {
        _ = try arriveN64() // The lane is not under test here.
        model.pageAppeared(.checkButtons(slotId: Self.n64))
        XCTAssertEqual(model.shellFacts.buttonCheck?.phase, .notRemappable, "the N64 is read by its fixed decoder")
        model.skipButtonCheckStep()
        model.resetButtonCheck()
        model.restartButtonCheck()
        XCTAssertEqual(model.shellFacts.buttonCheck?.phase, .notRemappable, "a pad with no walk ignores the walk's intents")
        model.pageDisappeared(.checkButtons(slotId: Self.n64))
        XCTAssertNil(model.shellFacts.buttonCheck)
        model.pageAppeared(.helpSupport(deviceKey: "057e:2019"))
        XCTAssertEqual(model.shellFacts.supportCapture?.known, true)
        model.nextSupportStep()
        model.skipSupportStep()
        XCTAssertEqual(model.shellFacts.supportCapture?.capture.records, [], "no device found, no step taken")
        model.pageDisappeared(.helpSupport(deviceKey: "057e:2019"))
        XCTAssertNil(model.shellFacts.supportCapture)
    }
}
