// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import IOKit
import XCTest
@testable import DishEngine

/// The last write's verdict, posted by whichever writer wrote and taken by
/// the main actor's tick.
final class DirectWritesTests: XCTestCase {

    func testTheNewestVerdictIsTakenOnce() {
        let writes = DirectWrites { 7 }
        XCTAssertNil(writes.take())
        writes.record(route: .setReport, reportId: 0x80, status: 0)
        writes.record(route: .setReport, reportId: 0x81, status: kIOReturnNotResponding)
        let taken = writes.take()
        XCTAssertEqual(taken, DirectWriteVerdict(route: .setReport, reportId: 0x81, status: kIOReturnNotResponding, atMs: 7))
        XCTAssertEqual(taken?.error, "kIOReturnNotResponding")
        XCTAssertNil(writes.take(), "taken once")
    }

    func testAnXusbRumbleWriteLeavesItsVerdictOnTheInterruptOutRoute() throws {
        let pipe = FakeUsbOutputPipe()
        let writes = DirectWrites { 9 }
        let output = XusbOutput(slotId: "hid:2dc8:310b", pipe: pipe, quitBoundMs: 1000, holdTicker: ManualQueueTicker(), writes: writes)
        output.rumble(strong: 0x8000, weak: 0x1000, durationMs: 500)
        output.drain()
        let verdict = try XCTUnwrap(writes.take())
        XCTAssertEqual(verdict.route, .interruptOut)
        XCTAssertEqual(verdict.reportId, pipe.writes.first?.first)
        XCTAssertTrue(verdict.ok)
    }

    func testARefusedSteamWriteLeavesItsErrorOnTheSetReportRoute() throws {
        let writer = FakeReportWriter()
        let writes = DirectWrites { 3 }
        let output = SteamOutput(
            slotId: "hid:28de:1302",
            plan: SteamPlan(generation: .triton, receiver: false),
            writer: writer,
            refreshTicker: ManualQueueTicker(),
            rumbleTicker: ManualQueueTicker(),
            writes: writes
        )
        output.claimed()
        output.drain()
        XCTAssertEqual(writes.take()?.ok, true, "the claim's writes went")
        writer.refuse(next: 1)
        output.rumble(strong: 0x8000, weak: 0x8000, durationMs: 100)
        output.drain()
        let verdict = try XCTUnwrap(writes.take())
        XCTAssertEqual(verdict.route, .setReport)
        XCTAssertEqual(verdict.reportId, TritonReportId.hapticRumble)
        XCTAssertFalse(verdict.ok)
        XCTAssertEqual(verdict.error, "kIOReturnError")
    }
}
