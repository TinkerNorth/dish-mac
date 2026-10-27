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
}
