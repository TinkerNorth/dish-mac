// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import Foundation

// MARK: - Live input

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

/// The buttons the host sees held down, in wire order, or the word for none.
func pressedText(_ snapshot: InputSnapshot, words: L10n = .app) -> String {
    let names = pressedButtons(snapshot.buttons).map { wireButtonText($0, words: words) }
    return words.pressed(names.isEmpty ? words.noneWord : names.joined(separator: " · "))
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

func rumbleBenchNote(_ slot: ControllerSlot, words: L10n = .app) -> String {
    slot.capabilities.hasRumble ? words.rumbleTestNote : words.noRumbleOnThisPath
}

/// What the tone button's line says: why it cannot play, that it plays, or
/// nothing while it is ready.
func toneNote(_ slot: ControllerSlot, words: L10n = .app) -> String? {
    guard slot.capabilities.hasSpeaker else { return words.noAudioOutput }
    return slot.audio?.tonePlaying == true ? words.tonePlayingWord : nil
}

/// What the microphone meter's line says: why it cannot listen, the level
/// while it listens, or nothing while it is ready.
func micMeterNote(_ slot: ControllerSlot, micPermitted: Bool, words: L10n = .app) -> String? {
    guard slot.capabilities.hasMic else { return words.noAudioEndpoints }
    guard micPermitted else { return words.micPermissionOff }
    guard let meter = slot.audio?.micMeter else { return nil }
    return meter.peakPercent == 0 ? words.micListening : words.micLevel(meter.levelPercent, meter.peakPercent)
}
