// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import XCTest
@testable import Dish

/// The inspector's lines, from the engine's snapshot and the core's tests.
final class InspectorMappersTests: XCTestCase {

    private let english = Locale(identifier: "en_US")

    private func snapshot(buttons: UInt16 = 0, motion: MotionReadout? = nil, touch: TouchReadout? = nil) -> InputSnapshot {
        InputSnapshot(
            buttons: buttons,
            leftStick: StickSample(x: 0.5, y: -0.25),
            rightStick: .centre,
            leftTrigger: 1,
            rightTrigger: 0.5,
            rawLeft: StickSample(x: 0.52, y: -0.25),
            rawRight: .centre,
            motion: motion,
            touch: touch
        )
    }

    func testThePressedLineNamesEveryButtonInWireOrderOrNone() {
        XCTAssertEqual(pressedText(snapshot()), "Pressed: none")
        XCTAssertEqual(pressedText(snapshot(buttons: 0x1000 | 0x0001 | 0x0800 | 0x0040)), "Pressed: D-pad up · L3 · Mute · A")
        XCTAssertEqual(WireButton.allCases.map { wireButtonText($0) }, [
            "D-pad up", "D-pad down", "D-pad left", "D-pad right", "Start", "Back", "L3", "R3", "LB", "RB", "Guide", "Mute", "A", "B", "X",
            "Y"
        ])
    }

    func testSticksTriggersAndTheRateReadInPercentAndHertz() {
        XCTAssertEqual(stickText(StickSample(x: 0.5, y: -0.25)), "X 50% · Y -25%")
        XCTAssertEqual(percentText(0.999), "100%")
        XCTAssertEqual(percentText(0), "0%")
        XCTAssertEqual(inputRateText(250), "Input rate: 250 Hz")
    }

    func testMotionAndTouchReadInHumanUnitsOrSayTheyAreAbsent() {
        XCTAssertEqual(gyroText(nil), "No motion data from this controller.")
        XCTAssertEqual(accelText(nil), "No motion data from this controller.")
        let motion = MotionReadout(gyroX: 12.4, gyroY: -300, gyroZ: 0.4, accelX: 0, accelY: 1.004, accelZ: -0.5)
        XCTAssertEqual(gyroText(motion, locale: english), "Gyro: 12 · -300 · 0 deg/s")
        XCTAssertEqual(accelText(motion, locale: english), "Accel: 0.00 · 1.00 · -0.50 g")
        XCTAssertEqual(touchText(nil), "No touch data from this controller.")
        let touch = TouchReadout(finger1: TouchFinger(x: 0.25, y: 1), finger2: nil, click: true)
        XCTAssertEqual(touchText(touch), "Finger 1: 25% across, 100% down · Finger 2: lifted · Click: pressed")
    }

    func testTheStickTestLineFollowsTheBench() {
        var inspection = InputInspection(slotId: "pad")
        XCTAssertNil(stickTestText(inspection), "nothing before a test")
        var bench = StickBench()
        bench.start(.drift, nowMs: 0)
        inspection.bench = bench
        inspection.secondsLeft = 4
        XCTAssertEqual(stickTestText(inspection), "Capturing… 4 s")
        bench.sample(left: StickSample(x: 0.06, y: 0.08), right: .centre)
        bench.advance(nowMs: StickHealth.driftCaptureMs)
        inspection.bench = bench
        XCTAssertEqual(stickTestText(inspection), "Resting drift: L 10% · R 0%. Suggested dead zone: 15%.")
        var range = StickTestResult(kind: .range, samples: 12)
        range.reachLeft = 0.98
        range.reachRight = 0.7071
        range.circularityLeft = 0.004
        XCTAssertEqual(stickTestResultText(range), "Reach: L 98% · R 71%. Circularity error: L 0% · R n/a.")
        XCTAssertEqual(stickTestResultText(StickTestResult(kind: .range, samples: 0)), "The controller sent nothing during the test.")
    }

    func testTheBenchesSayWhatCanRunAndWhatIsRunning() {
        let bare = ControllerSlot(id: "pad", name: "Pad")
        XCTAssertEqual(rumbleBenchNote(bare), "This controller has no rumble motors on the path it is on now.")
        XCTAssertEqual(toneNote(bare), "No audio output for this controller.")
        XCTAssertEqual(micMeterNote(bare, micPermitted: true), "No audio endpoints on this path.")
        var full = ControllerSlot(
            id: "pad",
            name: "DualSense",
            capabilities: ControllerCapabilities(hasRumble: true, hasMic: true, hasSpeaker: true)
        )
        XCTAssertEqual(rumbleBenchNote(full), "A short buzz straight to the controller, whatever its rumble switch says.")
        XCTAssertNil(toneNote(full), "ready says nothing")
        XCTAssertNil(micMeterNote(full, micPermitted: true))
        XCTAssertEqual(
            micMeterNote(full, micPermitted: false),
            "Microphone permission is off for Dish. Turn it on in system settings to use the controller microphone."
        )
        full.audio = ControllerAudioState(tonePlaying: true, micMeter: MicLevel(levelPercent: 0, peakPercent: 0))
        XCTAssertEqual(toneNote(full), "Playing…")
        XCTAssertEqual(micMeterNote(full, micPermitted: true), "Listening… speak into the microphone.")
        full.audio = ControllerAudioState(micMeter: MicLevel(levelPercent: 21, peakPercent: 30))
        XCTAssertEqual(micMeterNote(full, micPermitted: true), "Level 21% · peak 30%")
        XCTAssertEqual(BuzzMotor.allCases.map { buzzMotorText($0) }, ["Weak", "Strong", "Both"])
    }
}

/// The inspector page as one state: the pad's name or its id once it has
/// gone, the live lines after the first report, the test buttons waiting
/// on a running test, and benches only for an attached pad.
final class InspectorPageMappersTests: XCTestCase {

    private let english = Locale(identifier: "en_US")
    private let full = ControllerSlot(
        id: "pad",
        name: "DualSense",
        capabilities: ControllerCapabilities(hasRumble: true, hasMic: true, hasSpeaker: true)
    )

    private func state(_ slots: [ControllerSlot], inspection: InputInspection = InputInspection(slotId: "pad"), micPermitted: Bool = true)
        -> InspectorPageState
    {
        var facts = ShellFacts()
        facts.inspection = inspection
        return inspectorPageState(slotId: "pad", slots: slots, facts: facts, micPermitted: micPermitted, locale: english)
    }

    func testAPadThatLeftIsNamedByItsIdAndHasNoBenches() {
        let page = state([])
        XCTAssertEqual(page.title, "pad")
        XCTAssertNil(page.benches)
    }

    func testBeforeTheFirstReportThereAreNoLiveLines() {
        let page = state([full])
        XCTAssertEqual(page.title, "DualSense")
        XCTAssertNil(page.live)
        XCTAssertEqual(page.gyro, "No motion data from this controller.")
        XCTAssertEqual(page.touch, touchText(nil))
    }

    func testAReportReadsAsLiveLines() throws {
        let snapshot = InputSnapshot(
            buttons: 0x1000,
            leftStick: StickSample(x: 0.5, y: -0.25),
            rightStick: .centre,
            leftTrigger: 1,
            rightTrigger: 0.5,
            rawLeft: .centre,
            rawRight: .centre,
            motion: nil,
            touch: nil
        )
        let live = try XCTUnwrap(state([full], inspection: InputInspection(slotId: "pad", snapshot: snapshot, reportsHz: 250)).live)
        XCTAssertEqual(live.pressed, "Pressed: A")
        XCTAssertEqual(live.leftStick, stickText(StickSample(x: 0.5, y: -0.25)))
        XCTAssertEqual(live.leftTrigger, TriggerReadoutState(fraction: 1, text: "100%"))
        XCTAssertEqual(live.rightTrigger, TriggerReadoutState(fraction: 0.5, text: "50%"))
        XCTAssertEqual(live.rate, inputRateText(250))
    }

    func testTheStickTestsWaitWhileOneRuns() {
        var bench = StickBench()
        XCTAssertTrue(state([full], inspection: InputInspection(slotId: "pad", bench: bench)).stickTestsEnabled)
        bench.start(.drift, nowMs: 0)
        let running = state([full], inspection: InputInspection(slotId: "pad", bench: bench, secondsLeft: 3))
        XCTAssertFalse(running.stickTestsEnabled)
        XCTAssertEqual(running.stickTestStatus, stickTestText(InputInspection(slotId: "pad", bench: bench, secondsLeft: 3)))
    }

    func testAReadyPadOffersEveryBench() throws {
        let benches = try XCTUnwrap(state([full]).benches)
        XCTAssertTrue(benches.rumbleEnabled)
        XCTAssertTrue(benches.toneEnabled)
        XCTAssertEqual(benches.mic, .start(enabled: true))
        XCTAssertNil(benches.micLevel)
    }

    func testABarePadOffersNoBench() throws {
        let benches = try XCTUnwrap(state([ControllerSlot(id: "pad", name: "Pad")]).benches)
        XCTAssertFalse(benches.rumbleEnabled)
        XCTAssertFalse(benches.toneEnabled)
        XCTAssertEqual(benches.mic, .start(enabled: false))
        XCTAssertEqual(benches.rumbleNote, rumbleBenchNote(ControllerSlot(id: "pad", name: "Pad")))
    }

    func testAMicrophoneTheSystemWithholdsCannotStart() throws {
        let benches = try XCTUnwrap(state([full], micPermitted: false).benches)
        XCTAssertEqual(benches.mic, .start(enabled: false))
        XCTAssertEqual(benches.micNote, micMeterNote(full, micPermitted: false))
    }

    func testAPlayingToneWaitsAndAListeningMeterStops() throws {
        var busy = full
        busy.audio = ControllerAudioState(tonePlaying: true, micMeter: MicLevel(levelPercent: 40, peakPercent: 60))
        let benches = try XCTUnwrap(state([busy]).benches)
        XCTAssertFalse(benches.toneEnabled)
        XCTAssertEqual(benches.toneNote, "Playing…")
        XCTAssertEqual(benches.mic, .stop)
        XCTAssertEqual(benches.micLevel, 0.4)
    }
}
