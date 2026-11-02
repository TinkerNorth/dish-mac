// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation
import XCTest
@testable import DishEngine

/// A pad's switches and a Direct lane's counts as atomic words: the main
/// actor and the pad's thread meet on them without a lock and lose nothing.
final class LaneStateTests: XCTestCase {

    private static let threads = 4

    /// One raised bit, many reporters at once: exactly one of them spends it.
    func testARaisedBitPostsOnceWhenReportersRace() {
        let posted = AtomicInt(0)
        let gate = PadGate(key: "pad") { _, _ in _ = posted.incrementAndGet() }
        gate.route(.standard)
        for round in 1 ... 200 {
            gate.requestEvents()
            race { _ in _ = gate.pass(.standard, changed: true) }
            XCTAssertEqual(posted.get(), round, "round \(round) posted once")
            XCTAssertFalse(gate.awaitsEvent(.standard))
            XCTAssertTrue(gate.awaitsEvent(.direct), "the other source's bit is untouched")
        }
    }

    /// The main actor routes while the pad's thread reads: every read sees one
    /// of the two sources, never a torn word, and the tell bits survive.
    func testRoutingWhileReportsArriveKeepsTheOtherSwitches() {
        let gate = PadGate(key: "pad") { _, _ in }
        gate.route(.standard)
        gate.listenForCapture()
        let torn = AtomicInt(0)
        race { thread in
            for step in 0 ..< 2000 {
                if thread == 0 {
                    gate.route(step % 2 == 0 ? .standard : .direct)
                } else if gate.routed == nil {
                    _ = torn.incrementAndGet()
                }
            }
        }
        XCTAssertEqual(torn.get(), 0)
        XCTAssertTrue(gate.capturing, "routing never lowers the walk")
        XCTAssertTrue(gate.takeCaptureWish())
        XCTAssertFalse(gate.takeCaptureWish())
    }

    /// The reader's thread counts while the main actor reads: the last read
    /// after the counting stops has every report.
    func testALaneTallyCountedOnOneThreadReadsWholeOnAnother() {
        let tally = LaneTally(openedNs: 1000)
        let counted = DispatchSemaphore(value: 0)
        Thread {
            for report in 0 ..< 5000 {
                tally.count(nowNs: 2000 + UInt64(report))
            }
            counted.signal()
        }.start()
        while counted.wait(timeout: .now()) == .timedOut {
            XCTAssertLessThanOrEqual(tally.snapshot().reports, 5000)
        }
        let snapshot = tally.snapshot()
        XCTAssertEqual(snapshot.reports, 5000)
        XCTAssertEqual(snapshot.reportsFirstSecond, 5000)
        XCTAssertEqual(snapshot.firstReportMs, 0)
    }

    func testAPackedBatteryReadsBackAndTheEmptyWordReadsNone() {
        for battery in [
            PadBattery(level: 100, status: .charging),
            PadBattery(level: 0, status: .discharging),
            PadBattery(level: 37, status: .full)
        ] {
            XCTAssertEqual(PadBattery(packed: battery.packed), battery)
        }
        XCTAssertNil(PadBattery(packed: 0))
    }

    private func race(_ body: @escaping (Int) -> Void) {
        let group = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        for thread in 0 ..< Self.threads {
            group.enter()
            Thread {
                start.wait()
                body(thread)
                group.leave()
            }.start()
        }
        for _ in 0 ..< Self.threads {
            start.signal()
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
    }
}
