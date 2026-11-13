// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// An XUSB pad's rumble on its OUT pipe: each host command at once, and the
/// stop Dish owes once the command's hold ends, on a release and at quit,
/// since the pad holds a level until it is sent another.
final class XusbOutputTests: XCTestCase {

    private static let level = xusbRumbleReport(strong: 0x8000, weak: 0x1000)

    private let pipe = FakeUsbOutputPipe()
    private let ticker = ManualQueueTicker()

    private func output() -> XusbOutput {
        XusbOutput(slotId: "hid:2dc8:310b", pipe: pipe, holdTicker: ticker)
    }

    func testAHostCommandGoesOutAtOnceAndHoldsForItsDuration() {
        let output = output()
        output.rumble(strong: 0x8000, weak: 0x1000, durationMs: 500)
        output.drain()
        XCTAssertEqual(pipe.writes, [Self.level])
        XCTAssertEqual(ticker.periodMs, 500)
    }

    func testTheStopFollowsOnceTheHoldEnds() {
        let output = output()
        output.rumble(strong: 0x8000, weak: 0x1000, durationMs: 500)
        output.drain()
        ticker.tick()
        XCTAssertEqual(pipe.writes, [Self.level, xusbRumbleStop])
        XCTAssertFalse(ticker.running)
    }

    func testAContinuousCommandHoldsForTheSafetyNet() {
        let output = output()
        output.rumble(strong: 0x8000, weak: 0x1000, durationMs: 0)
        output.drain()
        XCTAssertEqual(ticker.periodMs, TritonRumbleRule.maxHoldMs)
    }

    func testANewerCommandRestartsTheHold() {
        let output = output()
        output.rumble(strong: 0x8000, weak: 0x1000, durationMs: 500)
        output.rumble(strong: 0x4000, weak: 0, durationMs: 200)
        output.drain()
        XCTAssertEqual(pipe.writes, [Self.level, xusbRumbleReport(strong: 0x4000, weak: 0)])
        XCTAssertEqual(ticker.starts, 2)
        XCTAssertEqual(ticker.periodMs, 200)
    }

    func testAStillCommandStopsTheMotorsAndEndsTheHold() {
        let output = output()
        output.rumble(strong: 0x8000, weak: 0x1000, durationMs: 500)
        output.rumble(strong: 0, weak: 0, durationMs: 500)
        output.drain()
        XCTAssertEqual(pipe.writes, [Self.level, xusbRumbleStop])
        XCTAssertFalse(ticker.running)
        ticker.tick()
        XCTAssertEqual(pipe.writes.count, 2, "a hold that ended sends no second stop")
    }

    func testAReleaseStillsARunningPadAndQuittingDoesSoBeforeItReturns() {
        let released = output()
        released.rumble(strong: 0x8000, weak: 0x1000, durationMs: 500)
        released.release()
        released.drain()
        XCTAssertEqual(pipe.writes, [Self.level, xusbRumbleStop])
        let quitting = output()
        quitting.rumble(strong: 0x8000, weak: 0x1000, durationMs: 500)
        quitting.releaseNow()
        XCTAssertEqual(pipe.writes, [Self.level, xusbRumbleStop, Self.level, xusbRumbleStop])
    }

    func testAStillPadIsSentNothingOnReleaseOrAtQuit() {
        let output = output()
        output.release()
        output.releaseNow()
        XCTAssertEqual(pipe.writes, [])
    }

    func testAPadThatLeftIsSentNothingMore() {
        let output = output()
        output.rumble(strong: 0x8000, weak: 0x1000, durationMs: 500)
        output.deviceGone()
        output.rumble(strong: 0x8000, weak: 0x1000, durationMs: 500)
        output.releaseNow()
        XCTAssertEqual(pipe.writes, [Self.level])
        XCTAssertFalse(ticker.running)
    }

    func testAWiredPadThatNeedsNoConfigurationIsSentNoneOnAClaimOrALink() {
        let output = output()
        output.claimed()
        output.controllerConnected()
        output.controllerLeft()
        output.drain()
        XCTAssertEqual(pipe.writes, [])
    }
}
