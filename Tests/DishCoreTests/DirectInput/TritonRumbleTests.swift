// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The 2026 pad's rumble between host commands: SDL re-sends the level every
/// 40 ms, inside the firmware's ~50 ms safety stop, and the host's hold (its
/// duration, capped as the GameController path caps it) ends the level.
final class TritonRumbleTests: XCTestCase {

    private let still = tritonRumbleReport(left: 0, right: 0)

    func testACommandSendsItsLevelAtOnce() {
        var rumble = TritonRumble()
        XCTAssertEqual(
            rumble.command(strong: 0x8000, weak: 0x4000, durationMs: 500, nowMs: 1000),
            tritonRumbleReport(left: 0x8000, right: 0x4000)
        )
        XCTAssertTrue(rumble.running)
    }

    func testTheLevelIsSentAgainEveryFortyMilliseconds() {
        var rumble = TritonRumble()
        let level = rumble.command(strong: 0x8000, weak: 0x4000, durationMs: 500, nowMs: 1000)
        XCTAssertNil(rumble.tick(nowMs: 1039))
        XCTAssertEqual(rumble.tick(nowMs: 1040), level)
        XCTAssertNil(rumble.tick(nowMs: 1079), "counted from the last send")
        XCTAssertEqual(rumble.tick(nowMs: 1080), level)
    }

    func testTheLevelStopsOnceItsHoldEnds() {
        var rumble = TritonRumble()
        _ = rumble.command(strong: 0x8000, weak: 0, durationMs: 500, nowMs: 1000) // Its own send is not under test.
        XCTAssertEqual(rumble.tick(nowMs: 1500), still, "the stop goes out once")
        XCTAssertFalse(rumble.running)
        XCTAssertNil(rumble.tick(nowMs: 1540))
    }

    func testAZeroCommandStopsTheMotorsAtOnce() {
        var rumble = TritonRumble()
        _ = rumble.command(strong: 0x8000, weak: 0x8000, durationMs: 500, nowMs: 1000) // Its own send is not under test.
        XCTAssertEqual(rumble.command(strong: 0, weak: 0, durationMs: 500, nowMs: 1010), still)
        XCTAssertFalse(rumble.running)
        XCTAssertNil(rumble.tick(nowMs: 1050))
    }

    func testAContinuousCommandHoldsForTheSafetyNet() {
        var rumble = TritonRumble()
        _ = rumble.command(strong: 1, weak: 1, durationMs: 0, nowMs: 0) // Its own send is not under test.
        XCTAssertNotEqual(rumble.tick(nowMs: 1480), still)
        XCTAssertEqual(rumble.tick(nowMs: 1500), still, "a dead host never leaves the motors running")
    }

    func testAHoldIsCappedAtTheSafetyNet() {
        var rumble = TritonRumble()
        _ = rumble.command(strong: 1, weak: 1, durationMs: 9000, nowMs: 0) // Its own send is not under test.
        XCTAssertEqual(rumble.tick(nowMs: 1500), still)
    }

    func testANewCommandExtendsTheHold() {
        var rumble = TritonRumble()
        _ = rumble.command(strong: 9, weak: 9, durationMs: 500, nowMs: 0) // Its own send is not under test.
        _ = rumble.command(strong: 9, weak: 9, durationMs: 500, nowMs: 200) // The satellite's 200 ms repeat.
        XCTAssertEqual(rumble.tick(nowMs: 500), tritonRumbleReport(left: 9, right: 9))
        XCTAssertEqual(rumble.tick(nowMs: 700), still)
    }

    func testAStillPadTicksNothing() {
        var rumble = TritonRumble()
        XCTAssertNil(rumble.tick(nowMs: 5000))
        XCTAssertFalse(rumble.running)
    }
}
