// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// The pads one session carries and the host-side state the hot path reads:
/// numbers and masks, the frame's buttons, the click's replay, touches
/// diffed, motion gated, the battery's words, and what a replug or a drop
/// forgets.
final class MoonlightPadTableTests: XCTestCase {

    private let xbox = MoonlightAnnouncedPad(type: MoonlightControllerType.xbox, capabilities: 0x03, supportedButtons: 0xF7FF)
    private let playStation = MoonlightAnnouncedPad(
        type: MoonlightControllerType.playStation,
        capabilities: 0xFF,
        supportedButtons: 0x10F7FF
    )
    private let allPads: UInt16 = 0b1111

    private func report(_ seed: Int16) -> GamepadReport {
        GamepadReport(
            buttons: UInt16(MoonlightButton.buttonA) | UInt16(seed),
            lt: UInt8(seed + 1),
            rt: UInt8(seed + 2),
            lx: seed + 3,
            ly: -(seed + 4),
            rx: seed + 5,
            ry: -(seed + 6)
        )
    }

    private func frame(_ number: UInt8, mask: UInt16, seed: Int16, extra: UInt32 = 0) -> MoonlightInput.PadFrame {
        MoonlightInput.PadFrame(
            controller: number,
            activeMask: mask,
            buttons: MoonlightButton.buttonA | UInt32(seed) | extra,
            leftTrigger: UInt8(seed + 1),
            rightTrigger: UInt8(seed + 2),
            leftX: seed + 3,
            leftY: -(seed + 4),
            rightX: seed + 5,
            rightY: -(seed + 6)
        )
    }

    private func click(_ pressed: Bool) -> TouchpadSample {
        TouchpadSample(finger0: .none, finger1: .none, buttonPressed: pressed)
    }

    private func full() -> MoonlightPadTable {
        var table = MoonlightPadTable()
        for number in 0 ..< MoonlightProtocol.maxPads {
            _ = table.acquire("slot-\(number)", as: playStation)
        }
        return table
    }

    func testPadsTakeTheLowestFreeNumberFourAtMostAndAHeldSlotKeepsIts() {
        var table = MoonlightPadTable()
        let first = table.acquire("a", as: xbox)
        XCTAssertEqual(first, MoonlightPadTable.Pad(slotId: "a", number: 0, announced: xbox))
        XCTAssertEqual(table.acquire("b", as: playStation)?.number, 1)
        XCTAssertEqual(table.acquire("c", as: xbox)?.number, 2)
        XCTAssertEqual(table.acquire("d", as: xbox)?.number, 3)
        XCTAssertTrue(table.isFull)
        XCTAssertNil(table.acquire("e", as: xbox), "a session carries four pads and no more")
        XCTAssertEqual(table.acquire("a", as: playStation), first, "a held slot keeps its pad, whatever it asks for now")
        XCTAssertEqual(table.count, 4)
        XCTAssertEqual(table.pads.map(\.number), [0, 1, 2, 3])
        XCTAssertEqual(table.pad(for: "b")?.announced, playStation, "a pad carries what its own binding asked for")
        XCTAssertEqual(table.slot(for: 2), "c")
        XCTAssertNil(table.slot(for: 4))
    }

    func testAReleasedNumberGoesToTheNextPadAndTheMaskFollows() {
        var table = MoonlightPadTable()
        _ = table.acquire("a", as: xbox)
        _ = table.acquire("b", as: xbox)
        _ = table.acquire("c", as: xbox)
        XCTAssertEqual(table.activeMask, 0b0111)
        XCTAssertEqual(table.release("b"), 1)
        XCTAssertNil(table.pad(for: "b"))
        XCTAssertEqual(table.activeMask, 0b0101)
        XCTAssertNil(table.release("nobody"))
        XCTAssertEqual(table.count, 2)
        XCTAssertEqual(table.acquire("d", as: xbox)?.number, 1, "the freed number, and only then")
        _ = table.release("a")
        _ = table.release("c")
        _ = table.release("d")
        XCTAssertEqual(table.activeMask, 0)
        XCTAssertTrue(table.isEmpty)
    }

    func testAFrameCarriesXusbLessTheMicMuteBitAndTheClickWhileHeld() {
        var table = MoonlightPadTable()
        _ = table.acquire("a", as: playStation)
        let muted = GamepadReport(
            buttons: UInt16(MoonlightButton.reservedMicMute | MoonlightButton.buttonA),
            lt: 9,
            rt: 8,
            lx: 1,
            ly: 2,
            rx: 3,
            ry: 4
        )
        XCTAssertEqual(
            table.frame("a", report: muted),
            MoonlightInput.PadFrame(
                controller: 0,
                activeMask: 0b0001,
                buttons: MoonlightButton.buttonA,
                leftTrigger: 9,
                rightTrigger: 8,
                leftX: 1,
                leftY: 2,
                rightX: 3,
                rightY: 4
            ),
            "the DualSense mic-mute bit never reaches a Moonlight host"
        )
        XCTAssertNil(table.frame("zz", report: muted), "a slot with no pad sends nothing")
        _ = table.touch("a", sample: click(true))
        XCTAssertEqual(
            table.frame("a", report: GamepadReport())?.buttons,
            MoonlightButton.touchpad,
            "the click keeps riding later frames until released"
        )
        XCTAssertEqual(MoonlightPadTable.buttons(GamepadReport(buttons: 0xFFFF), clickHeld: true), 0xF7FF | MoonlightButton.touchpad)
    }

    func testAClickEdgeReplaysThePadsLastFrameWithTheClickMerged() {
        var table = full()
        _ = table.frame("slot-0", report: report(10))
        _ = table.frame("slot-3", report: report(40))
        let firstDown = table.touch("slot-0", sample: click(true))
        XCTAssertEqual(firstDown?.replay, frame(0, mask: allPads, seed: 10, extra: MoonlightButton.touchpad))
        XCTAssertEqual(firstDown?.emissions, [])
        XCTAssertEqual(
            table.touch("slot-3", sample: click(true))?.replay,
            frame(3, mask: allPads, seed: 40, extra: MoonlightButton.touchpad)
        )
        XCTAssertEqual(
            table.touch("slot-0", sample: click(false))?.replay,
            frame(0, mask: allPads, seed: 10),
            "a release replays without the click"
        )
        XCTAssertNil(table.touch("slot-0", sample: click(false))?.replay, "no edge, no replay")
        XCTAssertNil(table.touch("slot-3", sample: click(true))?.replay, "a held click replays nothing more")
        XCTAssertNil(table.touch("nobody", sample: click(true)))
    }

    func testTheFirstReportIsHeardWhicheverWayItSaysAndAClickBeforeAnyFrameIsAPadAtRest() {
        var table = MoonlightPadTable()
        _ = table.acquire("a", as: playStation)
        XCTAssertEqual(
            table.touch("a", sample: click(true))?.replay,
            MoonlightInput.PadFrame(controller: 0, activeMask: 0b0001, buttons: MoonlightButton.touchpad),
            "at rest before it has sent a frame"
        )
        var fresh = MoonlightPadTable()
        _ = fresh.acquire("a", as: playStation)
        _ = fresh.frame("a", report: report(10))
        XCTAssertEqual(
            fresh.touch("a", sample: click(false))?.replay,
            frame(0, mask: 0b0001, seed: 10),
            "the click state starts unknown, not up"
        )
        XCTAssertNil(fresh.touch("a", sample: click(false))?.replay)
    }

    func testAReleasedPadsFrameAndClickAreNotReplayedForThePadThatTakesItsNumber() {
        var table = MoonlightPadTable()
        _ = table.acquire("a", as: playStation)
        _ = table.frame("a", report: report(10))
        _ = table.touch("a", sample: click(true))
        XCTAssertEqual(table.release("a"), 0)
        XCTAssertEqual(table.acquire("next", as: playStation)?.number, 0)
        XCTAssertEqual(
            table.touch("next", sample: click(false))?.replay,
            MoonlightInput.PadFrame(controller: 0, activeMask: 0b0001),
            "the next pad at that number starts from nothing"
        )
    }

    func testTouchesBecomeDownMoveAndUpPerFingerFirstFingerFirst() {
        var table = MoonlightPadTable()
        _ = table.acquire("a", as: playStation)
        _ = table.acquire("b", as: playStation)
        let landing = TouchpadSample(
            finger0: TouchpadFinger(active: true, id: 4, x: 0, y: Int16.max),
            finger1: TouchpadFinger(active: true, id: 5, x: -1000, y: 0),
            buttonPressed: false
        )
        let out = table.touch("b", sample: landing)
        XCTAssertEqual(out?.controller, 1)
        XCTAssertEqual(out?.emissions.map(\.event), [MoonlightTouchEvent.down, MoonlightTouchEvent.down])
        XCTAssertEqual(out?.emissions.map(\.pointerId), [4, 5])
        XCTAssertEqual(out?.emissions.first?.x ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(out?.emissions.first?.y ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(out?.emissions.first?.pressure, 1)
        let moving = TouchpadSample(
            finger0: TouchpadFinger(active: true, id: 4, x: 1000, y: Int16.max),
            finger1: TouchpadFinger(active: true, id: 5, x: -1000, y: 0),
            buttonPressed: false
        )
        XCTAssertEqual(table.touch("b", sample: moving)?.emissions.map(\.event), [MoonlightTouchEvent.move])
        let lifting = TouchpadSample(finger0: .none, finger1: .none, buttonPressed: false)
        let lifted = table.touch("b", sample: lifting)
        XCTAssertEqual(lifted?.emissions.map(\.event), [MoonlightTouchEvent.up, MoonlightTouchEvent.up])
        XCTAssertEqual(lifted?.emissions.map(\.pointerId), [4, 5], "a lift names the contact that was there")
        XCTAssertEqual(lifted?.emissions.map(\.pressure), [0, 0])
    }

    func testMotionIsDroppedUntilTheHostAsksThenSplitPerTypeAndStoppedAtRateZero() {
        var table = MoonlightPadTable()
        _ = table.acquire("a", as: playStation)
        let sample = MotionSample(gyroX: 16384, gyroY: 0, gyroZ: 0, accelX: 0, accelY: 0, accelZ: 8192)
        XCTAssertEqual(table.motion("a", sample: sample, nowNs: 0), [])
        XCTAssertFalse(table.motionWanted("a"))
        table.onMotionRequest(controller: 0, rateHz: 100, type: MoonlightMotionType.gyro)
        XCTAssertTrue(table.motionWanted("a"))
        let packets = table.motion("a", sample: sample, nowNs: 0)
        XCTAssertEqual(packets.count, 1, "only the gyro subscription fires; accel was never requested")
        XCTAssertEqual(packets.first?.controller, 0)
        XCTAssertEqual(packets.first?.type, MoonlightMotionType.gyro)
        XCTAssertEqual(packets.first?.x ?? 0, 1000.03, accuracy: 0.5, "16384 on the wire is half scale: a thousand degrees a second")
        XCTAssertEqual(table.motion("a", sample: sample, nowNs: 5_000_000), [], "a hundred hertz: nothing five milliseconds later")
        XCTAssertEqual(table.motion("a", sample: sample, nowNs: 10_000_000).count, 1)
        table.onMotionRequest(controller: 0, rateHz: 50, type: MoonlightMotionType.accelerometer)
        let both = table.motion("a", sample: sample, nowNs: 20_000_000)
        XCTAssertEqual(both.map(\.type), [MoonlightMotionType.gyro, MoonlightMotionType.accelerometer])
        XCTAssertEqual(both.last?.z ?? 0, 9.80665, accuracy: 0.01, "one g")
        table.onMotionRequest(controller: 0, rateHz: 0, type: MoonlightMotionType.gyro)
        table.onMotionRequest(controller: 0, rateHz: 0, type: MoonlightMotionType.accelerometer)
        XCTAssertFalse(table.motionWanted("a"), "rate 0 stops the stream again")
        XCTAssertEqual(table.motion("zz", sample: sample, nowNs: 0), [])
    }

    func testBatteryTranslatesToTheHostsVocabulary() {
        var table = MoonlightPadTable()
        _ = table.acquire("a", as: xbox)
        XCTAssertEqual(
            table.battery("a", level: 73, status: .charging),
            MoonlightPadTable.BatteryOut(controller: 0, state: MoonlightBatteryState.charging, percentage: 73)
        )
        XCTAssertEqual(
            table.battery("a", level: 0xFF, status: .unknown),
            MoonlightPadTable.BatteryOut(
                controller: 0,
                state: MoonlightBatteryState.unknown,
                percentage: MoonlightBatteryState.percentageUnknown
            )
        )
        XCTAssertEqual(table.battery("a", level: 100, status: .wired)?.state, MoonlightBatteryState.notPresent)
        XCTAssertNil(table.battery("zz", level: 50, status: .discharging), "an unknown slot sends nothing")
    }

    func testAReannouncedPadKeepsItsNumberAndForgetsWhatTheHostAskedOfTheOld() {
        var table = MoonlightPadTable()
        _ = table.acquire("a", as: playStation)
        _ = table.acquire("b", as: playStation)
        table.onMotionRequest(controller: 0, rateHz: 100, type: MoonlightMotionType.gyro)
        _ = table.frame("a", report: report(10))
        _ = table.touch("a", sample: click(true))
        XCTAssertEqual(table.reannounce("a", as: xbox), MoonlightPadTable.Pad(slotId: "a", number: 0, announced: xbox))
        XCTAssertEqual(table.pad(for: "a")?.announced, xbox)
        XCTAssertFalse(table.motionWanted("a"), "the host's new pad has asked for nothing yet")
        XCTAssertEqual(
            table.touch("a", sample: click(true))?.replay,
            MoonlightInput.PadFrame(controller: 0, activeMask: 0b0011, buttons: MoonlightButton.touchpad),
            "the old pad's frame and click are gone"
        )
        XCTAssertNil(table.reannounce("nobody", as: xbox))
        XCTAssertEqual(table.count, 2)
    }

    func testASessionThatGoesDownForgetsTheHostStateAndKeepsThePads() {
        var table = full()
        _ = table.frame("slot-0", report: report(10))
        _ = table.touch("slot-0", sample: click(true))
        table.onMotionRequest(controller: 2, rateHz: 100, type: MoonlightMotionType.accelerometer)
        table.forgetHostState()
        XCTAssertEqual(table.count, 4, "the pads stay claimed by their bindings")
        XCTAssertFalse(table.motionWanted("slot-2"))
        XCTAssertEqual(
            table.touch("slot-0", sample: click(true))?.replay,
            MoonlightInput.PadFrame(controller: 0, activeMask: allPads, buttons: MoonlightButton.touchpad)
        )
    }
}
