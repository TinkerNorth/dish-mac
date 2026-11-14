// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import IOKit.hid
import XCTest
@testable import DishEngine

/// The output's clock as the tests start it, in milliseconds.
private let clockStartMs: Int64 = 1000

/// One Steam Controller's writes on the output's own queue: the plan at a
/// claim, a connect and a release, the 2026 pad's lizard-mode refresh and
/// rumble re-sends on tickers the test fires by hand, and a refused feature
/// write retried.
final class SteamOutputTests: XCTestCase {

    private let writer = FakeReportWriter()
    private let clock = LockedBox<Int64>(clockStartMs)
    private let refreshTicker = ManualQueueTicker()
    private let rumbleTicker = ManualQueueTicker()

    private func output(_ generation: SteamGeneration, receiver: Bool = false) -> SteamOutput {
        SteamOutput(
            slotId: "hid:28de:1102",
            plan: SteamPlan(generation: generation, receiver: receiver),
            writer: writer,
            clockMs: clock.get,
            refreshTicker: refreshTicker,
            rumbleTicker: rumbleTicker
        )
    }

    private var rumbleWrites: [SteamWrite] {
        writer.writes.filter { $0.kind == .output }
    }

    private func rumble(_ left: UInt16, _ right: UInt16) -> SteamWrite {
        SteamWrite(kind: .output, reportId: 0x80, bytes: tritonRumbleReport(left: left, right: right))
    }

    /// The resend ticker fires with the clock `elapsedMs` past the start.
    private func tickRumble(afterMs elapsedMs: Int64) {
        clock.set(clockStartMs + elapsedMs)
        rumbleTicker.tick()
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

    func testA2015PadOverBluetoothIsQuietedInSegmentsWhenClaimedAndRestoredOnReleaseWithNoRumbleBetween() {
        let pad = output(.originalOverBluetooth)
        let plan = SteamPlan(generation: .originalOverBluetooth, receiver: false)
        pad.claimed()
        pad.rumble(strong: 0xFFFF, weak: 0xFFFF, durationMs: 100)
        pad.drain()
        XCTAssertEqual(writer.writes, plan.onConnect)
        XCTAssertEqual(writer.writes.map(\.reportId), [3, 3, 3, 3], "report 3, as SDL's segments go")
        XCTAssertFalse(refreshTicker.running, "its settings hold")
        pad.release()
        pad.drain()
        XCTAssertEqual(writer.writes, plan.onConnect + plan.onRelease)
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

    // MARK: - The 2026 pad's lizard-mode refresh

    func testThe2026PadRefreshesLizardModeOnSdlsPeriodWhileItIsRead() {
        let pad = output(.triton)
        let plan = SteamPlan(generation: .triton, receiver: false)
        pad.claimed()
        pad.drain()
        XCTAssertEqual(refreshTicker.periodMs, TritonRumbleRule.lizardRefreshMs)
        refreshTicker.tick()
        refreshTicker.tick()
        XCTAssertEqual(writer.writes, plan.onConnect + plan.refresh + plan.refresh, "the configure's own, then one per tick")
        pad.release()
        pad.drain()
        XCTAssertFalse(refreshTicker.running, "the watchdog restores lizard mode once the refresh stops")
    }

    func testThe2015PadIsNeverRefreshed() {
        let pad = output(.original)
        pad.claimed()
        pad.drain()
        XCTAssertFalse(refreshTicker.running, "its quiet settings persist until it reboots")
    }

    func testAReceiversSlotIsRefreshedOnlyWhileItHoldsAController() {
        let slot = output(.triton, receiver: true)
        slot.claimed()
        slot.drain()
        XCTAssertFalse(refreshTicker.running, "an empty slot has nothing to refresh")
        slot.controllerConnected()
        slot.drain()
        XCTAssertEqual(refreshTicker.periodMs, TritonRumbleRule.lizardRefreshMs)
        slot.controllerLeft()
        slot.drain()
        XCTAssertFalse(refreshTicker.running)
    }

    // MARK: - The 2026 pad's rumble

    func testTheRumbleIsSentAtOnceResentEveryFortyMillisecondsAndStoppedWhenItsHoldEnds() {
        let pad = output(.triton)
        pad.claimed()
        pad.rumble(strong: 0x8000, weak: 0x2000, durationMs: 150)
        pad.drain()
        let level = rumble(0x8000, 0x2000)
        XCTAssertEqual(rumbleWrites, [level])
        XCTAssertEqual(rumbleTicker.periodMs, TritonRumbleRule.resendMs)
        tickRumble(afterMs: 40)
        tickRumble(afterMs: 80)
        tickRumble(afterMs: 120)
        XCTAssertEqual(rumbleWrites, [level, level, level, level], "re-sent inside the firmware's 50 ms stop")
        tickRumble(afterMs: 160)
        XCTAssertEqual(rumbleWrites, [level, level, level, level, rumble(0, 0)], "the hold ends the level")
        XCTAssertFalse(rumbleTicker.running)
    }

    func testEachCommandRestartsTheResendSoItIsCountedFromTheLastSend() {
        let pad = output(.triton)
        pad.claimed()
        pad.rumble(strong: 1, weak: 1, durationMs: 500)
        pad.drain()
        clock.set(clockStartMs + 30)
        pad.rumble(strong: 1, weak: 1, durationMs: 500)
        pad.drain()
        XCTAssertEqual(rumbleWrites, [rumble(1, 1), rumble(1, 1)])
        XCTAssertEqual(rumbleTicker.starts, 2, "the next resend is 40 ms after the command, not after the tick before it")
    }

    func testAZeroRumbleStopsAtOnceAndIsNotResent() {
        let pad = output(.triton)
        pad.claimed()
        pad.rumble(strong: 0x8000, weak: 0, durationMs: 500)
        pad.rumble(strong: 0, weak: 0, durationMs: 500)
        pad.drain()
        XCTAssertEqual(rumbleWrites, [rumble(0x8000, 0), rumble(0, 0)])
        XCTAssertFalse(rumbleTicker.running)
    }

    func testAReleaseMidHoldStopsTheResendAndStillsTheMotors() {
        let pad = output(.triton)
        pad.claimed()
        pad.rumble(strong: 5, weak: 5, durationMs: 500)
        pad.release()
        pad.drain()
        XCTAssertEqual(rumbleWrites, [rumble(5, 5), rumble(0, 0)])
        XCTAssertFalse(rumbleTicker.running)
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
        XCTAssertFalse(rumbleTicker.running)
    }

    func testADeviceThatLeftIsSentNothingMore() {
        let pad = output(.triton)
        pad.claimed()
        pad.deviceGone()
        pad.rumble(strong: 1, weak: 1, durationMs: 500)
        pad.release()
        pad.drain()
        XCTAssertEqual(writer.writes, SteamPlan(generation: .triton, receiver: false).onConnect, "the configure, then nothing")
        XCTAssertFalse(refreshTicker.running)
        XCTAssertFalse(rumbleTicker.running)
    }

    func testTheHoldIsCappedWhereTheGameControllerPathCapsIt() {
        XCTAssertEqual(TritonRumbleRule.maxHoldMs, Int64(RumbleActuator.maxHoldMs))
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
