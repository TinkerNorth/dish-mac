// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import IOKit.hid
import XCTest
@testable import DishEngine

/// One Steam Controller's writes on the output's own queue: the plan at a
/// claim, a connect and a release, the 2026 pad's lizard-mode refresh and
/// rumble re-sends on their timers, and a refused feature write retried.
final class SteamOutputTests: XCTestCase {

    private let writer = FakeReportWriter()

    private func output(_ generation: SteamGeneration, receiver: Bool = false, refreshMs: Int64 = 60000) -> SteamOutput {
        SteamOutput(
            slotId: "hid:28de:1102",
            plan: SteamPlan(generation: generation, receiver: receiver),
            writer: writer,
            refreshMs: refreshMs
        )
    }

    private var rumbleWrites: [SteamWrite] {
        writer.writes.filter { $0.kind == .output }
    }

    private func rumble(_ left: UInt16, _ right: UInt16) -> SteamWrite {
        SteamWrite(kind: .output, reportId: 0x80, bytes: tritonRumbleReport(left: left, right: right))
    }

    // MARK: - The plan

    func testAWired2015PadIsQuietedWhenClaimedAndRestoredOnRelease() {
        let pad = output(.original)
        let plan = SteamPlan(generation: .original, receiver: false)
        pad.claimed()
        pad.drain()
        XCTAssertEqual(writer.writes, plan.onConnect)
        pad.release()
        pad.release()
        pad.drain()
        XCTAssertEqual(writer.writes, plan.onConnect + plan.onRelease, "a second release has nothing left to give back")
    }

    func testA2015ReceiverAsksItsSlotAndQuietsTheControllerThatConnects() {
        let slot = output(.original, receiver: true)
        let plan = SteamPlan(generation: .original, receiver: true)
        slot.claimed()
        slot.drain()
        XCTAssertEqual(writer.writes, plan.onClaim)
        slot.controllerConnected()
        slot.drain()
        XCTAssertEqual(writer.writes, plan.onClaim + plan.onConnect)
    }

    func testAControllerThatConnectsBeforeTheClaimIsConfiguredAtTheClaim() {
        let slot = output(.triton, receiver: true)
        slot.controllerConnected()
        slot.drain()
        XCTAssertEqual(writer.writes, [], "a pad Dish does not read is sent nothing")
        slot.claimed()
        slot.drain()
        XCTAssertEqual(writer.writes, SteamPlan(generation: .triton, receiver: true).onConnect)
    }

    func testAnEmptySlotHasNothingToRestore() {
        let slot = output(.original, receiver: true)
        slot.claimed()
        slot.release()
        slot.drain()
        XCTAssertEqual(writer.writes, SteamPlan(generation: .original, receiver: true).onClaim)
    }

    func testReleaseNowHasRunWhenItReturns() {
        let pad = output(.original)
        pad.claimed()
        pad.releaseNow()
        XCTAssertEqual(
            Array(writer.writes.suffix(3)),
            SteamPlan(generation: .original, receiver: false).onRelease,
            "the app quits right after"
        )
    }

    // MARK: - The 2026 pad's timers

    func testThe2026PadRefreshesLizardModeWhileItIsRead() {
        let pad = output(.triton, refreshMs: 20)
        pad.claimed()
        let lizardOff = SteamWrite(kind: .feature, reportId: 1, bytes: tritonLizardOffReport())
        pollUntil { writer.writes.filter { $0 == lizardOff }.count >= 3 }
        XCTAssertGreaterThanOrEqual(writer.writes.filter { $0 == lizardOff }.count, 3, "the configure's own, then the refreshes")
        pad.release()
        pad.drain()
        let afterRelease = writer.writes.count
        Thread.sleep(forTimeInterval: 0.08)
        XCTAssertEqual(writer.writes.count, afterRelease, "the watchdog restores lizard mode once the refresh stops")
    }

    func testAControllerThatLeavesStopsTheRefresh() {
        let slot = output(.triton, receiver: true, refreshMs: 20)
        slot.claimed()
        slot.controllerConnected()
        slot.controllerLeft()
        slot.drain()
        let written = writer.writes.count
        Thread.sleep(forTimeInterval: 0.08)
        XCTAssertEqual(writer.writes.count, written)
    }

    func testTheRumbleIsSentAtOnceResentAndStoppedWhenItsHoldEnds() {
        let pad = output(.triton)
        pad.claimed()
        pad.rumble(strong: 0x8000, weak: 0x2000, durationMs: 150)
        pad.drain()
        XCTAssertEqual(rumbleWrites.first, rumble(0x8000, 0x2000))
        pollUntil { rumbleWrites.last == rumble(0, 0) }
        let levels = rumbleWrites.filter { $0 == rumble(0x8000, 0x2000) }.count
        XCTAssertGreaterThanOrEqual(levels, 2, "re-sent inside the firmware's 50 ms stop")
        XCTAssertEqual(rumbleWrites.last, rumble(0, 0), "the hold ends the level")
    }

    func testAZeroRumbleStopsAtOnceAndIsNotResent() {
        let pad = output(.triton)
        pad.claimed()
        pad.rumble(strong: 0x8000, weak: 0, durationMs: 500)
        pad.rumble(strong: 0, weak: 0, durationMs: 500)
        pad.drain()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(rumbleWrites, [rumble(0x8000, 0), rumble(0, 0)])
    }

    func testThe2015PadAndAPadNotReadTakeNoRumble() {
        let original = output(.original)
        original.claimed()
        original.rumble(strong: 0x8000, weak: 0x8000, durationMs: 500)
        let unclaimed = output(.triton)
        unclaimed.rumble(strong: 0x8000, weak: 0x8000, durationMs: 500)
        original.drain()
        unclaimed.drain()
        XCTAssertEqual(rumbleWrites, [], "no motors on the 2015 pad, and nothing to a pad Dish does not read")
    }

    func testADeviceThatLeftIsSentNothingMore() {
        let pad = output(.triton, refreshMs: 20)
        pad.claimed()
        pad.deviceGone()
        pad.rumble(strong: 1, weak: 1, durationMs: 500)
        pad.release()
        pad.drain()
        let written = writer.writes.count
        Thread.sleep(forTimeInterval: 0.08)
        XCTAssertEqual(writer.writes.count, written)
        XCTAssertEqual(rumbleWrites, [])
    }

    // MARK: - A receiver under load

    func testARefusedFeatureWriteIsRetriedUntilItLands() {
        let pad = output(.original)
        writer.refuse(next: 2)
        pad.claimed()
        pad.drain()
        let quiet = SteamPlan(generation: .original, receiver: false).onConnect
        XCTAssertEqual(writer.writes, [quiet[0], quiet[0], quiet[0], quiet[1]], "the first packet lands on its third try")
    }

    func testAFeatureWriteThatNeverLandsIsGivenUpOnAndTheNextStillGoes() {
        let pad = output(.original)
        writer.refuse(next: SteamOutput.featureAttempts)
        pad.claimed()
        pad.drain()
        let quiet = SteamPlan(generation: .original, receiver: false).onConnect
        XCTAssertEqual(writer.writes.filter { $0 == quiet[0] }.count, SteamOutput.featureAttempts)
        XCTAssertEqual(writer.writes.last, quiet[1])
    }
}
