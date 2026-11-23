// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import XCTest
@testable import Dish

/// The inspector's lines, from the engine's snapshot and the core's tests.
final class InspectorMappersTests: XCTestCase {

    private let english = Locale(identifier: "en_US")

    private func snapshot(buttons: UInt16 = 0, extButtons: UInt32 = 0, motion: MotionReadout? = nil, touch: TouchReadout? = nil)
        -> InputSnapshot
    {
        InputSnapshot(
            buttons: buttons,
            extButtons: extButtons,
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

    func testThePressedLineNamesTheExtendedButtonsAfterTheWireButtonsInWireOrder() {
        let paddleAndMisc = ProtocolConstants.extButtonLeftPaddle1 | ProtocolConstants.extButtonMisc1
        let aWithPaddleAndMisc = snapshot(buttons: WireButton.faceA.bit, extButtons: paddleAndMisc)
        XCTAssertEqual(pressedText(aWithPaddleAndMisc), "Pressed: A · Left paddle 1 · Misc 1")
        XCTAssertEqual(pressedText(snapshot(extButtons: ProtocolConstants.extButtonRightGripTouch)), "Pressed: Right grip touch")
        XCTAssertEqual(ExtendedButton.allCases.map { extendedButtonText($0) }, [
            "Right paddle 1", "Left paddle 1", "Right paddle 2", "Left paddle 2", "Misc 1", "Left trackpad click", "Right trackpad click",
            "Left trigger click", "Right trigger click", "Left stick touch", "Right stick touch", "Left grip touch", "Right grip touch"
        ])
    }

    private func pointer(rightClick: Bool = false, wheel: Int16 = 0) -> TouchReadout {
        TouchReadout(finger1: nil, finger2: nil, click: false, rightClick: rightClick, wheel: wheel)
    }

    func testThePointerLineShowsTheRightClickAndAWheelTurnAndHidesWithNeither() {
        let notch = ProtocolConstants.scrollUnitsPerNotch
        XCTAssertNil(pointerText(nil), "no touch data, no pointer line")
        XCTAssertNil(pointerText(pointer()), "an idle pointer hides the line")
        XCTAssertEqual(pointerText(pointer(rightClick: true)), "Right click")
        XCTAssertEqual(pointerText(pointer(wheel: notch)), "Wheel +120")
        XCTAssertEqual(pointerText(pointer(rightClick: true, wheel: -notch)), "Right click · Wheel -120")
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
        let touch = TouchReadout(finger1: TouchFinger(x: 0.25, y: 1), finger2: nil, click: true, rightClick: false, wheel: 0)
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

    func testTheMicrophoneLineSaysWhyItCannotListenOrWhatItHears() {
        var full = ControllerSlot(id: "pad", name: "DualSense", capabilities: ControllerCapabilities(hasMic: true))
        XCTAssertNil(micMeterNote(full, micPermitted: true), "ready says nothing")
        XCTAssertEqual(
            micMeterNote(full, micPermitted: false),
            "Microphone permission is off for Dish. Turn it on in system settings to use the controller microphone."
        )
        full.audio = ControllerAudioState(micMeter: MicLevel(levelPercent: 0, peakPercent: 0))
        XCTAssertEqual(micMeterNote(full, micPermitted: true), "Listening… speak into the microphone.")
        full.audio = ControllerAudioState(micMeter: MicLevel(levelPercent: 21, peakPercent: 30))
        XCTAssertEqual(micMeterNote(full, micPermitted: true), "Level 21% · peak 30%")
    }

    func testEachFeedbackItemHasItsRowAndItsTests() {
        XCTAssertEqual(BuzzMotor.allCases.map { buzzMotorText($0) }, ["Weak", "Strong", "Both"])
        XCTAssertEqual(TriggerMotor.allCases.map { triggerMotorText($0) }, ["Left", "Right", "Both"])
        let rows = BenchItem.allCases.compactMap { feedbackRow($0) }
        XCTAssertEqual(rows.map(\.label), ["Rumble", "Trigger rumble", "Light bar", "Player LEDs", "Adaptive triggers"])
        XCTAssertEqual(rows.map { $0.tests.map(\.test) }, [
            [.rumble(.weak), .rumble(.strong), .rumble(.both)],
            [.triggerRumble(.left), .triggerRumble(.right), .triggerRumble(.both)],
            [.lightbarCycle],
            [.playerCycle],
            [.triggerPulse]
        ])
        XCTAssertEqual(rows.map { $0.tests.map(\.title) }, [
            ["Weak", "Strong", "Both"], ["Left", "Right", "Both"], ["Cycle"], ["Cycle"], ["Pulse resistance"]
        ])
    }

    func testTheAudioItemsHaveNoFeedbackRow() {
        XCTAssertNil(feedbackRow(.speaker))
        XCTAssertNil(feedbackRow(.haptics))
        XCTAssertNil(feedbackRow(.microphone))
    }

    func testTheFeedbackCardSaysWhatItsTestsDoOrThatThePathTakesNone() {
        XCTAssertEqual(
            feedbackBench([.rumble], running: nil).note,
            "Each test goes straight to the controller, whatever its switches say, and what the game set comes back when it ends."
        )
        let none = feedbackBench([.speaker, .microphone], running: nil)
        XCTAssertEqual(none.rows, [])
        XCTAssertEqual(none.note, "This controller takes no feedback on the path it is on now.")
    }

    func testTheFeedbackTestsWaitWhileOneRunsOnThePad() {
        XCTAssertTrue(feedbackBench([.rumble, .lightbar], running: nil).enabled)
        XCTAssertFalse(feedbackBench([.rumble, .lightbar], running: .lightbarCycle).enabled)
    }

    func testAToneWaitsWhileEitherPlaysAndTheOnePlayingSaysSo() {
        XCTAssertEqual(toneRow("Speaker", lane: .speaker, playing: nil), ToneRowState(label: "Speaker", enabled: true, note: nil))
        XCTAssertEqual(
            toneRow("Speaker", lane: .speaker, playing: .speaker),
            ToneRowState(label: "Speaker", enabled: false, note: "Playing…")
        )
        XCTAssertEqual(toneRow("Haptics", lane: .haptics, playing: .speaker), ToneRowState(label: "Haptics", enabled: false, note: nil))
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

    func testTheInspectorOffersThePadsCheckFromItsPathFacts() {
        var facts = ShellFacts()
        facts.inputPaths["pad"] = SlotInputPath(source: .standard, reason: .macOSReads)
        let page = inspectorPageState(slotId: "pad", slots: [full], facts: facts, micPermitted: true, locale: english)
        XCTAssertEqual(page.path?.check.link, "Not responding?")
        XCTAssertEqual(page.path?.reason, "macOS reads it")
        XCTAssertNil(state([full]).path, "no facts yet, no section")
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
        XCTAssertNil(page.pointer)
    }

    func testAReportReadsAsLiveLines() throws {
        let snapshot = InputSnapshot(
            buttons: 0x1000,
            extButtons: ProtocolConstants.extButtonMisc1,
            leftStick: StickSample(x: 0.5, y: -0.25),
            rightStick: .centre,
            leftTrigger: 1,
            rightTrigger: 0.5,
            rawLeft: .centre,
            rawRight: .centre,
            motion: nil,
            touch: TouchReadout(finger1: nil, finger2: nil, click: false, rightClick: true, wheel: 0)
        )
        let page = state([full], inspection: InputInspection(slotId: "pad", snapshot: snapshot, reportsHz: 250))
        let live = try XCTUnwrap(page.live)
        XCTAssertEqual(live.pressed, "Pressed: A · Misc 1")
        XCTAssertEqual(page.pointer, "Right click", "under the touch line")
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

    /// A USB DualSense on GameController: everything but trigger rumble.
    private let dualSense = ControllerSlot(
        id: "pad",
        name: "DualSense",
        capabilities: ControllerCapabilities(
            hasRumble: true,
            hasLightbar: true,
            hasTriggerEffects: true,
            hasPlayerLeds: true,
            hasMic: true,
            hasSpeaker: true,
            hasHapticLanes: true
        )
    )

    func testAPadOffersEveryItemItsPathCarriesAndNoOther() throws {
        let benches = try XCTUnwrap(state([dualSense]).benches)
        XCTAssertEqual(benches.feedback.rows.map(\.id), [.rumble, .lightbar, .playerLeds, .adaptiveTriggers], "no trigger motors, no row")
        XCTAssertTrue(benches.feedback.enabled)
        XCTAssertEqual(benches.audio.speaker, ToneRowState(label: "Speaker", enabled: true, note: nil))
        XCTAssertEqual(benches.audio.haptics, ToneRowState(label: "Haptics", enabled: true, note: nil))
        XCTAssertEqual(benches.audio.mic, MicRowState(label: "Microphone", button: .start(enabled: true), note: nil, level: nil))
        XCTAssertNil(benches.audio.emptyNote)
    }

    func testAnXboxPadOffersItsTriggerMotors() throws {
        let xbox = ControllerSlot(id: "pad", name: "Xbox", capabilities: ControllerCapabilities(hasRumble: true, hasTriggerRumble: true))
        let benches = try XCTUnwrap(state([xbox]).benches)
        XCTAssertEqual(benches.feedback.rows.map(\.id), [.rumble, .triggerRumble])
    }

    func testABarePadOffersNoItemAndSaysSo() throws {
        let benches = try XCTUnwrap(state([ControllerSlot(id: "pad", name: "Pad")]).benches)
        XCTAssertEqual(benches.feedback.rows, [])
        XCTAssertEqual(benches.feedback.note, "This controller takes no feedback on the path it is on now.")
        XCTAssertNil(benches.audio.speaker)
        XCTAssertNil(benches.audio.haptics)
        XCTAssertNil(benches.audio.mic)
        XCTAssertEqual(benches.audio.emptyNote, "No audio endpoints on this path.")
    }

    func testAMicrophoneTheSystemWithholdsCannotStart() throws {
        let benches = try XCTUnwrap(state([dualSense], micPermitted: false).benches)
        XCTAssertEqual(benches.audio.mic?.button, .start(enabled: false))
        XCTAssertEqual(benches.audio.mic?.note, micMeterNote(dualSense, micPermitted: false))
    }

    func testAPlayingToneWaitsAndAListeningMeterStops() throws {
        var busy = dualSense
        busy.audio = ControllerAudioState(tone: .haptics, micMeter: MicLevel(levelPercent: 40, peakPercent: 60))
        let benches = try XCTUnwrap(state([busy]).benches)
        XCTAssertEqual(benches.audio.speaker?.enabled, false)
        XCTAssertEqual(benches.audio.haptics?.note, "Playing…")
        XCTAssertEqual(benches.audio.mic?.button, .stop)
        XCTAssertEqual(benches.audio.mic?.level, 0.4)
    }

    func testTheFeedbackTestsWaitWhileTheBenchRunsOneOnThisPad() {
        var facts = ShellFacts()
        facts.inspection = InputInspection(slotId: "pad")
        facts.benchRuns = ["pad": .triggerPulse]
        let busy = inspectorPageState(slotId: "pad", slots: [dualSense], facts: facts, micPermitted: true, locale: english)
        XCTAssertEqual(busy.benches?.feedback.enabled, false)
        facts.benchRuns = ["other": .triggerPulse]
        let free = inspectorPageState(slotId: "pad", slots: [dualSense], facts: facts, micPermitted: true, locale: english)
        XCTAssertEqual(free.benches?.feedback.enabled, true, "another pad's test is its own")
    }
}
