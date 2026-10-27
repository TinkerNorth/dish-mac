// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// One Direct lane fed through IOKit's own callback: the captured N64
/// reports reach the processor only while the lane is forwarded and only
/// when they change something, the first report is a baseline rather than
/// a change, and the battery goes out once per change.
final class HidPadLaneTests: XCTestCase {

    private let reports = LockedBox<[GamepadReport]>([])
    private let batteries = LockedBox<[PadBattery]>([])
    private let posts = LockedBox<[InputSource]>([])
    private let processor = GamepadInputProcessor()

    private func n64Lane() throws -> HidPadLane {
        let reports = reports
        let batteries = batteries
        let posts = posts
        processor.reportSender = { _, report in reports.set(reports.get() + [report]) }
        let wiring = HidPadWiring(
            processor: processor,
            notify: { _, source in posts.set(posts.get() + [source]) },
            battery: { _, battery in batteries.set(batteries.get() + [battery]) }
        )
        let candidate = try DirectFixtures.candidate(DirectFixtures.nintendoProperties(productId: 0x2019))
        return DirectFixtures.lane(candidate, slotId: "hid:057e:2019", wiring: wiring)
    }

    func testTheIdleAndPressedN64ReportsReachTheProcessorThroughTheCallback() throws {
        let lane = try n64Lane()
        lane.gate.route(.direct)
        feedReport(DirectFixtures.n64Idle, to: lane)
        feedReport(DirectFixtures.n64PressedA, to: lane)
        XCTAssertEqual(reports.get(), [.released, GamepadReport(buttons: WireButton.faceA.bit)])
        XCTAssertEqual(batteries.get(), [PadBattery(level: 100, status: .charging)], "the battery once, on its first sight")
    }

    func testAnUnchangedReportIsNotPublishedAgain() throws {
        let lane = try n64Lane()
        lane.gate.route(.direct)
        for _ in 0 ..< 80 {
            feedReport(DirectFixtures.n64Idle, to: lane)
        }
        XCTAssertEqual(reports.get(), [.released], "an idle pad streams 80 reports a second and publishes one")
        XCTAssertEqual(lane.tally.snapshot().reports, 80, "every report is still counted raw")
    }

    func testALaneNotForwardedPublishesNothingButStillTellsAChange() throws {
        let lane = try n64Lane()
        lane.gate.requestEvents()
        feedReport(DirectFixtures.n64Idle, to: lane)
        XCTAssertEqual(posts.get(), [], "the first report is the baseline, not a press")
        feedReport(DirectFixtures.n64PressedA, to: lane)
        feedReport(DirectFixtures.n64Idle, to: lane)
        XCTAssertEqual(posts.get(), [.direct], "one event for the source, however many changes")
        XCTAssertEqual(reports.get(), [])
        XCTAssertEqual(batteries.get(), [])
    }

    func testALaneForwardedAgainSendsItsStateWhole() throws {
        let lane = try n64Lane()
        lane.gate.route(.direct)
        feedReport(DirectFixtures.n64Idle, to: lane)
        lane.gate.route(.standard)
        feedReport(DirectFixtures.n64Idle, to: lane)
        lane.gate.route(.direct)
        feedReport(DirectFixtures.n64Idle, to: lane)
        XCTAssertEqual(reports.get(), [.released, .released], "the host hears the state again after a hand-back")
        XCTAssertEqual(batteries.get().count, 2)
        XCTAssertEqual(lane.latestBattery, PadBattery(level: 100, status: .charging))
    }

    func testAReportThatIsNotASwitchReportIsCountedAndDropped() throws {
        let lane = try n64Lane()
        lane.gate.route(.direct)
        feedReport([0x21, 0x00, 0x00], to: lane)
        XCTAssertEqual(reports.get(), [])
        XCTAssertEqual(lane.tally.snapshot().reports, 1)
    }

    func testTheTallyMeasuresTheFirstReportAndTheFirstSecond() {
        let tally = LaneTally(openedNs: 1_000_000_000)
        XCTAssertNil(tally.snapshot().firstReportMs)
        tally.count(nowNs: 1_012_000_000)
        tally.count(nowNs: 1_999_000_000)
        tally.count(nowNs: 2_000_000_000)
        let snapshot = tally.snapshot()
        XCTAssertEqual(snapshot.firstReportMs, 12)
        XCTAssertEqual(snapshot.reportsFirstSecond, 2, "a report at the one-second mark is past the window")
        XCTAssertEqual(snapshot.reports, 3)
    }

    // MARK: - A generic pad

    private static let gamepadRest: [UInt8] = [0x7F, 0x7F, 0x7F, 0x7F, 0x08, 0x00, 0x00]
    private static let gamepadButton9: [UInt8] = [0x7F, 0x7F, 0x7F, 0x7F, 0x08, 0x00, 0x02]

    private func gamepadLane(captures: LockedBox<[RawCapture]>) throws -> HidPadLane {
        let reports = reports
        processor.reportSender = { _, report in reports.set(reports.get() + [report]) }
        let wiring = HidPadWiring(
            processor: processor,
            notify: { _, _ in },
            battery: { _, _ in },
            captured: { _, capture in captures.set(captures.get() + [capture]) }
        )
        let candidate = try DirectFixtures.candidate(DirectFixtures.gamepadProperties())
        return DirectFixtures.lane(candidate, slotId: "hid:1234:5678", wiring: wiring)
    }

    func testAStoredRemapIsReadThroughItsTableFromTheNextReport() throws {
        let lane = try gamepadLane(captures: LockedBox([]))
        lane.gate.route(.direct)
        feedReport(Self.gamepadButton9, to: lane)
        var remap = defaultRemap(order: .western)
        remap.setButton(.rightThumb, -1)
        remap.setButton(.faceA, 9)
        lane.useRemap(HidRemapTable(remap: remap))
        feedReport(Self.gamepadRest, to: lane)
        feedReport(Self.gamepadButton9, to: lane)
        let buttons = reports.get().map(\.buttons)
        XCTAssertEqual(buttons, [WireButton.rightThumb.bit, 0, WireButton.faceA.bit], "R3 by the model's order, then A by the remap")
        lane.useRemap(nil)
        feedReport(Self.gamepadRest, to: lane)
        feedReport(Self.gamepadButton9, to: lane)
        XCTAssertEqual(reports.get().last?.buttons, WireButton.rightThumb.bit, "no table reads the model's order again")
    }

    func testAListeningWalkHearsTheNextRawChangeOncePerWish() throws {
        let captures = LockedBox<[RawCapture]>([])
        let lane = try gamepadLane(captures: captures)
        feedReport(Self.gamepadButton9, to: lane)
        XCTAssertEqual(captures.get(), [], "nobody listens")
        lane.gate.listenForCapture()
        feedReport(Self.gamepadRest, to: lane)
        XCTAssertEqual(captures.get(), [], "the first report is the walk's rest")
        feedReport(Self.gamepadButton9, to: lane)
        feedReport(Self.gamepadRest, to: lane)
        feedReport(Self.gamepadButton9, to: lane)
        XCTAssertEqual(captures.get(), [RawCapture(kind: .button, index: 9)], "one change per wish")
        lane.gate.listenForCapture()
        feedReport(Self.gamepadRest, to: lane)
        feedReport(Self.gamepadButton9, to: lane)
        XCTAssertEqual(captures.get().count, 2)
        lane.gate.closeCapture()
        feedReport(Self.gamepadRest, to: lane)
        feedReport(Self.gamepadButton9, to: lane)
        XCTAssertEqual(captures.get().count, 2, "a closed walk hears nothing")
    }
}
