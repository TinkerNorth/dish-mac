// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore
@testable import DishEngine

/// The hot path over a recording sender: what the table's changes put on a
/// live link and in what order, what the input becomes, and what a cleared
/// link forgets.
final class MoonlightPadLinkTests: XCTestCase {

    private let xbox = MoonlightAnnouncedPad(type: MoonlightControllerType.xbox, capabilities: 0x03, supportedButtons: 0xF7FF)
    private let playStation = MoonlightAnnouncedPad(
        type: MoonlightControllerType.playStation,
        capabilities: 0xFF,
        supportedButtons: 0x10F7FF
    )
    private let sender = RecordingPadSender()
    private var clockNs: Int64 = 0
    private lazy var link = MoonlightPadLink(nowNs: { self.clockNs })

    private func arrival(_ number: UInt8, _ pad: MoonlightAnnouncedPad) -> MoonlightInput.PadArrival {
        MoonlightInput.PadArrival(
            controller: number,
            type: pad.type,
            capabilities: pad.capabilities,
            supportedButtons: pad.supportedButtons
        )
    }

    private func rest(_ number: UInt8, mask: UInt16) -> MoonlightInput.PadFrame {
        MoonlightInput.PadFrame(controller: number, activeMask: mask)
    }

    private func click(_ pressed: Bool) -> TouchpadSample {
        TouchpadSample(finger0: .none, finger1: .none, buttonPressed: pressed)
    }

    func testInstallAnnouncesEveryHeldPadAtRestInNumberOrder() {
        _ = link.acquire("a", as: xbox)
        _ = link.acquire("b", as: playStation)
        XCTAssertEqual(sender.sent, [], "nothing is on the wire before the link is live")
        XCTAssertFalse(link.isLive)
        link.install(sender)
        XCTAssertTrue(link.isLive)
        XCTAssertEqual(
            sender.sent,
            [.arrival(arrival(0, xbox)), .state(rest(0, mask: 0b0011)), .arrival(arrival(1, playStation)), .state(rest(1, mask: 0b0011))]
        )
    }

    func testAPadAcquiredOnALiveLinkIsAnnouncedAndAHeldOneIsNot() {
        link.install(sender)
        let pad = link.acquire("a", as: xbox)
        XCTAssertEqual(pad?.number, 0)
        XCTAssertEqual(sender.take(), [.arrival(arrival(0, xbox)), .state(rest(0, mask: 0b0001))])
        XCTAssertEqual(link.acquire("a", as: playStation), pad, "the host skips an arrival for a number it has seen")
        XCTAssertEqual(sender.take(), [])
        for slot in ["b", "c", "d"] {
            _ = link.acquire(slot, as: xbox)
        }
        _ = sender.take()
        XCTAssertNil(link.acquire("e", as: xbox))
        XCTAssertEqual(sender.take(), [], "a fifth pad is refused and nothing goes out")
        XCTAssertTrue(link.isFull)
    }

    func testReleasingAPadUnplugsItsOwnNumberWhileTheOthersStay() {
        _ = link.acquire("a", as: xbox)
        _ = link.acquire("b", as: xbox)
        link.install(sender)
        _ = sender.take()
        XCTAssertEqual(link.release("b"), 1)
        XCTAssertEqual(sender.take(), [.state(rest(1, mask: 0b0001))], "the frame that names pad 1 with its bit cleared")
        XCTAssertEqual(link.release("a"), 0)
        XCTAssertEqual(sender.take(), [.state(rest(0, mask: 0))], "no survivor to name: pad 0's own number, mask empty")
        XCTAssertEqual(link.release("nobody"), 0)
        XCTAssertEqual(sender.take(), [])
    }

    func testAHeldPadReannouncedLiveIsReplugedUnderItsNumberThenHeardAtRest() {
        _ = link.acquire("a", as: xbox)
        _ = link.acquire("b", as: xbox)
        link.install(sender)
        _ = sender.take()
        let pad = link.reannounce("b", as: playStation)
        XCTAssertEqual(pad, MoonlightPadTable.Pad(slotId: "b", number: 1, announced: playStation))
        XCTAssertEqual(link.pad(for: "b"), pad)
        XCTAssertEqual(sender.take(), [.replug(1, 0b0001, arrival(1, playStation)), .state(rest(1, mask: 0b0011))], "no plain arrival")
        XCTAssertNil(link.reannounce("nobody", as: playStation))
        XCTAssertEqual(sender.take(), [])
        XCTAssertEqual(link.count, 2)
    }

    func testAPadReannouncedBeforeTheLinkIsLiveOnlyChangesWhatInstallAnnounces() {
        _ = link.acquire("a", as: xbox)
        _ = link.reannounce("a", as: playStation)
        XCTAssertEqual(sender.sent, [])
        link.install(sender)
        XCTAssertEqual(sender.sent, [.arrival(arrival(0, playStation)), .state(rest(0, mask: 0b0001))])
    }

    func testReportsGoOutAsFramesUnderTheMaskAndAreCounted() {
        link.sendReport("a", GamepadReport(buttons: 1))
        XCTAssertEqual(sender.sent, [], "dropped before the link is live")
        _ = link.acquire("a", as: xbox)
        _ = link.acquire("b", as: xbox)
        link.install(sender)
        _ = sender.take()
        link.sendReport("b", GamepadReport(buttons: UInt16(MoonlightButton.buttonA), lt: 5, lx: -7))
        XCTAssertEqual(
            sender.take(),
            [.state(MoonlightInput.PadFrame(
                controller: 1,
                activeMask: 0b0011,
                buttons: MoonlightButton.buttonA,
                leftTrigger: 5,
                leftX: -7
            ))]
        )
        link.sendReport("zz", GamepadReport(buttons: 1))
        XCTAssertEqual(sender.take(), [], "a slot with no pad sends nothing")
        XCTAssertEqual(link.reportsSent(for: 1), 1)
        XCTAssertEqual(link.reportsSent(for: 0), 0)
        XCTAssertEqual(link.reportsSent(for: 9), 0)
    }

    func testAClickEdgeReplaysThroughTheLinkAndCounts() {
        _ = link.acquire("a", as: playStation)
        link.install(sender)
        link.sendReport("a", GamepadReport(buttons: UInt16(MoonlightButton.buttonA)))
        _ = sender.take()
        link.sendTouchpad("a", sample: click(true))
        XCTAssertEqual(
            sender.take(),
            [.state(MoonlightInput.PadFrame(
                controller: 0,
                activeMask: 0b0001,
                buttons: MoonlightButton.buttonA | MoonlightButton.touchpad
            ))]
        )
        XCTAssertEqual(link.reportsSent(for: 0), 2)
        link.sendTouchpad("a", sample: click(true))
        XCTAssertEqual(sender.take(), [], "a held click replays nothing more")
    }

    func testTouchesMotionAndBatteryReachTheSenderForTheRightNumber() {
        _ = link.acquire("a", as: playStation)
        _ = link.acquire("b", as: playStation)
        link.install(sender)
        _ = sender.take()
        let landing = TouchpadSample(finger0: TouchpadFinger(active: true, id: 4, x: 0, y: 0), finger1: .none, buttonPressed: false)
        let centre = MoonlightTelemetry.touchNormalized(0)
        link.sendTouchpad("b", sample: landing)
        XCTAssertEqual(
            sender.take(),
            [
                .state(rest(1, mask: 0b0011)),
                .touch(1, MoonlightTouchEmission(event: MoonlightTouchEvent.down, pointerId: 4, x: centre, y: centre, pressure: 1))
            ],
            "the first report settles the click (up) with a replay at rest, then the contact lands"
        )
        let sample = MotionSample(gyroX: 0, gyroY: 0, gyroZ: 0, accelX: 0, accelY: 0, accelZ: 8192)
        link.sendMotion("b", sample)
        XCTAssertEqual(sender.take(), [], "dropped until the host asks")
        link.onMotionRequest(controller: 1, rateHz: 100, type: MoonlightMotionType.accelerometer)
        XCTAssertTrue(link.motionWanted("b"))
        link.sendMotion("b", sample)
        guard case let .motion(controller, type, _, _, z)? = sender.take().first else { return XCTFail("no motion packet") }
        XCTAssertEqual(controller, 1)
        XCTAssertEqual(type, MoonlightMotionType.accelerometer)
        XCTAssertEqual(z, 9.80665, accuracy: 0.01)
        link.sendBattery("b", level: 50, status: .discharging)
        XCTAssertEqual(sender.take(), [.battery(1, MoonlightBatteryState.discharging, 50)])
        XCTAssertEqual(link.slot(forController: 1), "b")
        XCTAssertNil(link.slot(forController: 4), "a number no session carries names no slot")
        XCTAssertNil(link.slot(forController: 0x100))
        link.onMotionRequest(controller: 9, rateHz: 100, type: MoonlightMotionType.gyro)
        XCTAssertFalse(link.motionWanted("a"))
    }

    func testClearForgetsTheHostStateAndTheCountsAndKeepsThePads() {
        _ = link.acquire("a", as: playStation)
        link.install(sender)
        link.sendReport("a", GamepadReport(buttons: UInt16(MoonlightButton.buttonA)))
        link.sendTouchpad("a", sample: click(true))
        link.clear()
        XCTAssertFalse(link.isLive)
        XCTAssertEqual(link.reportsSent(for: 0), 0)
        XCTAssertEqual(link.count, 1, "the pads stay claimed by their bindings")
        _ = sender.take()
        link.sendReport("a", GamepadReport(buttons: 1))
        XCTAssertEqual(sender.take(), [], "not live: dropped")
        link.install(sender)
        _ = sender.take()
        link.sendTouchpad("a", sample: click(true))
        XCTAssertEqual(
            sender.take(),
            [.state(MoonlightInput.PadFrame(controller: 0, activeMask: 0b0001, buttons: MoonlightButton.touchpad))],
            "the old frame and click are gone: a pad at rest with the click merged"
        )
    }

    func testThePadSinkForwardsTheSlotsInput() {
        _ = link.acquire("a", as: playStation)
        link.install(sender)
        _ = sender.take()
        let sink: InputSink = MoonlightPadSink(link: link, slotId: "a")
        sink.sendReport(GamepadReport(buttons: UInt16(MoonlightButton.buttonB)))
        sink.sendBattery(level: 20, status: .full)
        sink.sendTouchpad(sample: click(false), eventTimeMs: 99)
        link.onMotionRequest(controller: 0, rateHz: 200, type: MoonlightMotionType.gyro)
        sink.sendMotion(MotionSample(gyroX: 100, gyroY: 0, gyroZ: 0, accelX: 0, accelY: 0, accelZ: 0), timestampDeltaUs: 1000)
        let sent = sender.take()
        XCTAssertEqual(sent.count, 4)
        XCTAssertEqual(sent[0], .state(MoonlightInput.PadFrame(controller: 0, activeMask: 0b0001, buttons: MoonlightButton.buttonB)))
        XCTAssertEqual(sent[1], .battery(0, MoonlightBatteryState.full, 20))
        XCTAssertEqual(
            sent[2],
            .state(MoonlightInput.PadFrame(controller: 0, activeMask: 0b0001, buttons: MoonlightButton.buttonB)),
            "the first touch report settles the click with a replay of the last frame"
        )
        guard case let .motion(controller, type, _, _, _) = sent[3] else { return XCTFail("no motion packet") }
        XCTAssertEqual(controller, 0)
        XCTAssertEqual(type, MoonlightMotionType.gyro)
    }
}
