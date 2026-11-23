// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import Foundation

// MARK: - Live input

private let readoutSeparator = " · "

func wireButtonText(_ button: WireButton, words: L10n = .app) -> String {
    switch button {
    case .dpadUp: words.buttonDpadUp
    case .dpadDown: words.buttonDpadDown
    case .dpadLeft: words.buttonDpadLeft
    case .dpadRight: words.buttonDpadRight
    case .start: words.buttonStart
    case .back: words.buttonBack
    case .leftThumb: words.buttonL3
    case .rightThumb: words.buttonR3
    case .leftShoulder: words.buttonLB
    case .rightShoulder: words.buttonRB
    case .guide: words.buttonGuide
    case .micMute: words.buttonMute
    case .faceA: words.buttonA
    case .faceB: words.buttonB
    case .faceX: words.buttonX
    case .faceY: words.buttonY
    }
}

func extendedButtonText(_ button: ExtendedButton, words: L10n = .app) -> String {
    switch button {
    case .rightPaddle1: words.buttonRightPaddle1
    case .leftPaddle1: words.buttonLeftPaddle1
    case .rightPaddle2: words.buttonRightPaddle2
    case .leftPaddle2: words.buttonLeftPaddle2
    case .misc1: words.buttonMisc1
    case .leftPadClick: words.buttonLeftPadClick
    case .rightPadClick: words.buttonRightPadClick
    case .leftTriggerClick: words.buttonLeftTriggerClick
    case .rightTriggerClick: words.buttonRightTriggerClick
    case .leftStickTouch: words.buttonLeftStickTouch
    case .rightStickTouch: words.buttonRightStickTouch
    case .leftGripTouch: words.buttonLeftGripTouch
    case .rightGripTouch: words.buttonRightGripTouch
    }
}

/// The buttons the host sees held down, in wire order, or the word for none.
func pressedText(_ snapshot: InputSnapshot, words: L10n = .app) -> String {
    let wire = pressedButtons(snapshot.buttons).map { wireButtonText($0, words: words) }
    let extended = pressedExtendedButtons(snapshot.extButtons).map { extendedButtonText($0, words: words) }
    let names = wire + extended
    return words.pressed(names.isEmpty ? words.noneWord : names.joined(separator: readoutSeparator))
}

/// A fraction as whole percent, the sign kept.
func percentText(_ fraction: Float, words: L10n = .app) -> String {
    words.percentOf(Int((fraction * 100).rounded()))
}

func stickText(_ sample: StickSample, words: L10n = .app) -> String {
    words.stickXY(percentText(sample.x, words: words), percentText(sample.y, words: words))
}

func inputRateText(_ hz: Int, words: L10n = .app) -> String {
    words.inputRate(hz)
}

// MARK: - Motion and touch

/// Whole degrees per second; the sensor's noise floor is wider than a degree.
func gyroText(_ motion: MotionReadout?, locale: Locale = .current, words: L10n = .app) -> String {
    guard let motion else { return words.noMotionData }
    return words.gyroLine(
        wholeNumber(motion.gyroX, locale: locale),
        wholeNumber(motion.gyroY, locale: locale),
        wholeNumber(motion.gyroZ, locale: locale)
    )
}

/// Hundredths of a g; gravity reads 1.00 on the axis that points down.
func accelText(_ motion: MotionReadout?, locale: Locale = .current, words: L10n = .app) -> String {
    guard let motion else { return words.noMotionData }
    return words.accelLine(
        hundredths(motion.accelX, locale: locale),
        hundredths(motion.accelY, locale: locale),
        hundredths(motion.accelZ, locale: locale)
    )
}

func touchText(_ touch: TouchReadout?, words: L10n = .app) -> String {
    guard let touch else { return words.noTouchData }
    let click = touch.click ? words.pressedWord : words.releasedWord
    return words.fingersLine(fingerText(touch.finger1, words: words), fingerText(touch.finger2, words: words), click)
}

func fingerText(_ finger: TouchFinger?, words: L10n = .app) -> String {
    guard let finger else { return words.liftedWord }
    return words.fingerAt(percentText(finger.x, words: words), percentText(finger.y, words: words))
}

func pointerText(_ touch: TouchReadout?, words: L10n = .app) -> String? {
    guard let touch else { return nil }
    let rightClick = touch.rightClick ? [words.rightClick] : []
    let wheel = touch.wheel == 0 ? [] : [words.wheelStep(signedStep(touch.wheel))]
    let parts = rightClick + wheel
    return parts.isEmpty ? nil : parts.joined(separator: readoutSeparator)
}

private func signedStep(_ step: Int16) -> String {
    String(format: "%+lld", Int64(step))
}

func wholeNumber(_ value: Float, locale: Locale) -> String {
    String(format: "%.0f", locale: locale, value)
}

func hundredths(_ value: Float, locale: Locale) -> String {
    String(format: "%.2f", locale: locale, value)
}

// MARK: - The stick tests

/// The line under the test buttons: nothing before a test, the countdown
/// while one runs, the last result after.
func stickTestText(_ inspection: InputInspection, words: L10n = .app) -> String? {
    switch inspection.bench.phase {
    case .idle: nil
    case .running: words.capturingSeconds(inspection.secondsLeft)
    case .done: inspection.bench.result.map { stickTestResultText($0, words: words) }
    }
}

func stickTestResultText(_ result: StickTestResult, words: L10n = .app) -> String {
    guard result.samples > 0 else { return words.testSawNothing }
    switch result.kind {
    case .drift:
        return words.driftResult(
            percentText(result.driftLeft, words: words),
            percentText(result.driftRight, words: words),
            percentText(result.suggestedDeadzone, words: words)
        )
    case .range:
        return words.rangeResult(
            percentText(result.reachLeft, words: words),
            percentText(result.reachRight, words: words),
            circularityText(result.circularityLeft, words: words),
            circularityText(result.circularityRight, words: words)
        )
    }
}

/// Nil when the sweep never covered enough of the circle for a verdict.
func circularityText(_ error: Float?, words: L10n = .app) -> String {
    error.map { percentText($0, words: words) } ?? words.notApplicable
}

// MARK: - The benches

func buzzMotorText(_ motor: BuzzMotor, words: L10n = .app) -> String {
    switch motor {
    case .weak: words.weakMotor
    case .strong: words.strongMotor
    case .both: words.bothMotors
    }
}

func triggerMotorText(_ motor: TriggerMotor, words: L10n = .app) -> String {
    switch motor {
    case .left: words.leftTriggerMotor
    case .right: words.rightTriggerMotor
    case .both: words.bothMotors
    }
}

/// An item's row of feedback tests; nil for an audio item, which the audio
/// card draws.
func feedbackRow(_ item: BenchItem, words: L10n = .app) -> BenchRowState? {
    switch item {
    case .rumble:
        BenchRowState(id: item, label: words.rumble, tests: BuzzMotor.allCases.map { motor in
            BenchTestButton(test: .rumble(motor), title: buzzMotorText(motor, words: words))
        })
    case .triggerRumble:
        BenchRowState(id: item, label: words.triggerRumble, tests: TriggerMotor.allCases.map { motor in
            BenchTestButton(test: .triggerRumble(motor), title: triggerMotorText(motor, words: words))
        })
    case .lightbar: BenchRowState(id: item, label: words.lightBar, tests: [BenchTestButton(test: .lightbarCycle, title: words.cycleWord)])
    case .playerLeds: BenchRowState(id: item, label: words.playerLeds, tests: [BenchTestButton(test: .playerCycle, title: words.cycleWord)])
    case .adaptiveTriggers:
        BenchRowState(id: item, label: words.adaptiveTriggers, tests: [BenchTestButton(test: .triggerPulse, title: words.pulseResistance)])
    case .speaker, .haptics, .microphone: nil
    }
}

/// A row per feedback item the path carries, or the word for none; every
/// test waits while one runs on the pad.
func feedbackBench(_ items: [BenchItem], running: FeedbackTest?, words: L10n = .app) -> FeedbackBenchState {
    let rows = items.compactMap { feedbackRow($0, words: words) }
    let note = rows.isEmpty ? words.noFeedbackOnThisPath : words.feedbackTestsNote
    return FeedbackBenchState(rows: rows, note: note, enabled: running == nil)
}

/// A tone waits while one plays on either lane; the lane it plays on says so.
func toneRow(_ label: String, lane: ToneLane, playing: ToneLane?, words: L10n = .app) -> ToneRowState {
    ToneRowState(label: label, enabled: playing == nil, note: playing == lane ? words.tonePlayingWord : nil)
}

/// What the microphone meter's line says: why it cannot listen, the level
/// while it listens, or nothing while it is ready.
func micMeterNote(_ slot: ControllerSlot, micPermitted: Bool, words: L10n = .app) -> String? {
    guard micPermitted else { return words.micPermissionOff }
    guard let meter = slot.audio?.micMeter else { return nil }
    return meter.peakPercent == 0 ? words.micListening : words.micLevel(meter.levelPercent, meter.peakPercent)
}

/// A meter starts only on a microphone the system lets Dish hear, and a
/// listening one stops.
func micRow(_ slot: ControllerSlot, micPermitted: Bool, words: L10n = .app) -> MicRowState {
    let meter = slot.audio?.micMeter
    return MicRowState(
        label: words.microphone,
        button: meter == nil ? .start(enabled: micPermitted) : .stop,
        note: micMeterNote(slot, micPermitted: micPermitted, words: words),
        level: meter.map { Double($0.levelPercent) / 100 }
    )
}

/// The tone on the speaker and on the haptics lanes and the meter, each
/// where the pad's route reaches it, or the word for none.
func audioBench(_ items: [BenchItem], slot: ControllerSlot, micPermitted: Bool, words: L10n = .app) -> AudioBenchState {
    let playing = slot.audio?.tone
    let speaker = items.contains(.speaker) ? toneRow(words.speaker, lane: .speaker, playing: playing, words: words) : nil
    let haptics = items.contains(.haptics) ? toneRow(words.haptics, lane: .haptics, playing: playing, words: words) : nil
    let mic = items.contains(.microphone) ? micRow(slot, micPermitted: micPermitted, words: words) : nil
    let carriesNone = speaker == nil && haptics == nil && mic == nil
    return AudioBenchState(speaker: speaker, haptics: haptics, mic: mic, emptyNote: carriesNone ? words.noAudioEndpoints : nil)
}

// MARK: - The page

/// Everything the inspector draws for one controller: its name, the live
/// input once the first report arrives, motion and touch, the stick tests
/// and, while the pad is attached, the benches.
struct InspectorPageState: Equatable {
    let title: String
    /// Nil until the pad's first report.
    let live: LiveInputState?
    let gyro: String
    let accel: String
    let touch: String
    let pointer: String?
    /// The test buttons wait while a test runs.
    let stickTestsEnabled: Bool
    let stickTestStatus: String?
    /// Nil while the pad is not attached.
    let benches: InspectorBenchState?
    /// The pad's input path and its "Not responding?" check.
    var path: PadPathState?
    /// "Did it work?" after the test the pad ran last, and the answers.
    var outcomes = OutcomesState(question: nil, answers: [], hint: nil)
}

struct LiveInputState: Equatable {
    let pressed: String
    let leftStick: String
    let rightStick: String
    let leftTrigger: TriggerReadoutState
    let rightTrigger: TriggerReadoutState
    let rate: String
}

struct TriggerReadoutState: Equatable {
    let fraction: Double
    let text: String
}

/// The feedback and audio benches of an attached pad: only the items its
/// path carries (the contract's bench, rule 1).
struct InspectorBenchState: Equatable {
    let feedback: FeedbackBenchState
    let audio: AudioBenchState
}

struct FeedbackBenchState: Equatable {
    let rows: [BenchRowState]
    /// What the tests do, or that the path takes no feedback.
    let note: String
    /// False while a feedback test runs on the pad.
    let enabled: Bool
}

struct BenchRowState: Equatable, Identifiable {
    let id: BenchItem
    let label: String
    let tests: [BenchTestButton]
}

struct BenchTestButton: Equatable, Identifiable {
    let test: FeedbackTest
    let title: String

    var id: FeedbackTest {
        test
    }
}

struct AudioBenchState: Equatable {
    /// Nil where the pad's route has no speaker pair.
    let speaker: ToneRowState?
    /// Nil where it has no haptics lanes.
    let haptics: ToneRowState?
    /// Nil where it has no microphone.
    let mic: MicRowState?
    /// Shown when the route reaches none of the three.
    let emptyNote: String?
}

struct ToneRowState: Equatable {
    let label: String
    let enabled: Bool
    /// "Playing…" while the tone plays on this lane.
    let note: String?
}

struct MicRowState: Equatable {
    let label: String
    let button: MicTestButton
    let note: String?
    /// The meter's level as a fraction while it listens.
    let level: Double?
}

/// The microphone bench's one button: stop a meter that listens, or start one.
enum MicTestButton: Equatable {
    case stop
    case start(enabled: Bool)
}

func inspectorPageState(
    slotId: String,
    slots: [ControllerSlot],
    facts: ShellFacts,
    micPermitted: Bool,
    locale: Locale = .current,
    words: L10n = .app
) -> InspectorPageState {
    let slot = slots.first { $0.id == slotId }
    let inspection = facts.inspection
    let snapshot = inspection.snapshot
    return InspectorPageState(
        title: slot?.name ?? slotId,
        live: snapshot.map { liveInput($0, reportsHz: inspection.reportsHz, words: words) },
        gyro: gyroText(snapshot?.motion, locale: locale, words: words),
        accel: accelText(snapshot?.motion, locale: locale, words: words),
        touch: touchText(snapshot?.touch, words: words),
        pointer: pointerText(snapshot?.touch, words: words),
        stickTestsEnabled: inspection.bench.phase != .running,
        stickTestStatus: stickTestText(inspection, words: words),
        benches: slot.map { inspectorBenches($0, running: facts.benchRuns[slotId], micPermitted: micPermitted, words: words) },
        path: padPathState(facts.inputPaths[slotId], words: words),
        outcomes: outcomesState(slotId: slotId, outcomes: facts.outcomes, words: words)
    )
}

func liveInput(_ snapshot: InputSnapshot, reportsHz: Int, words: L10n = .app) -> LiveInputState {
    LiveInputState(
        pressed: pressedText(snapshot, words: words),
        leftStick: stickText(snapshot.leftStick, words: words),
        rightStick: stickText(snapshot.rightStick, words: words),
        leftTrigger: TriggerReadoutState(fraction: Double(snapshot.leftTrigger), text: percentText(snapshot.leftTrigger, words: words)),
        rightTrigger: TriggerReadoutState(fraction: Double(snapshot.rightTrigger), text: percentText(snapshot.rightTrigger, words: words)),
        rate: inputRateText(reportsHz, words: words)
    )
}

/// The items the pad's path carries, from its capabilities; the feedback
/// tests wait while one runs on the pad.
func inspectorBenches(_ slot: ControllerSlot, running: FeedbackTest?, micPermitted: Bool, words: L10n = .app) -> InspectorBenchState {
    let items = benchItems(slot.capabilities.benchCarriage)
    return InspectorBenchState(
        feedback: feedbackBench(items, running: running, words: words),
        audio: audioBench(items, slot: slot, micPermitted: micPermitted, words: words)
    )
}
