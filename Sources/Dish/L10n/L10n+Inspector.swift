// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

extension L10n {

    // MARK: - The inspector

    var inspectorTitle: String {
        catalog.text("Controller inspector")
    }

    var inspectInput: String {
        catalog.text("Inspect input")
    }

    var liveInput: String {
        catalog.text("Live input")
    }

    var waitingForFirstReport: String {
        catalog.text("Waiting for this controller's first report. Move a stick or press a button.")
    }

    func pressed(_ names: String) -> String {
        catalog.format("Pressed: %@", names)
    }

    var noneWord: String {
        catalog.text("none")
    }

    var leftStick: String {
        catalog.text("Left stick")
    }

    var rightStick: String {
        catalog.text("Right stick")
    }

    var leftTrigger: String {
        catalog.text("Left trigger")
    }

    var rightTrigger: String {
        catalog.text("Right trigger")
    }

    func percentOf(_ value: Int) -> String {
        catalog.format("%lld%%", value)
    }

    func stickXY(_ x: String, _ y: String) -> String {
        catalog.format("X %@ · Y %@", x, y)
    }

    func inputRate(_ hz: Int) -> String {
        catalog.format("Input rate: %lld Hz", hz)
    }

    var inputAfterDeadZones: String {
        catalog.text("This is the input as it goes to the host, after the dead zones.")
    }

    // MARK: - Motion and touch

    var motionAndTouch: String {
        catalog.text("Motion and touch")
    }

    func gyroLine(_ x: String, _ y: String, _ z: String) -> String {
        catalog.format("Gyro: %@ · %@ · %@ deg/s", x, y, z)
    }

    func accelLine(_ x: String, _ y: String, _ z: String) -> String {
        catalog.format("Accel: %@ · %@ · %@ g", x, y, z)
    }

    var noMotionData: String {
        catalog.text("No motion data from this controller.")
    }

    func fingersLine(_ first: String, _ second: String, _ click: String) -> String {
        catalog.format("Finger 1: %@ · Finger 2: %@ · Click: %@", first, second, click)
    }

    func fingerAt(_ x: String, _ y: String) -> String {
        catalog.format("%@ across, %@ down", x, y)
    }

    var liftedWord: String {
        catalog.text("lifted")
    }

    var pressedWord: String {
        catalog.text("pressed")
    }

    var releasedWord: String {
        catalog.text("released")
    }

    var noTouchData: String {
        catalog.text("No touch data from this controller.")
    }

    // MARK: - Stick tests

    var stickTests: String {
        catalog.text("Stick tests")
    }

    var stickTestsReadRaw: String {
        catalog.text("The tests read the sticks as the controller sends them, before the dead zones.")
    }

    var driftTestButton: String {
        catalog.text("Drift test (hands off the sticks)")
    }

    var rangeTestButton: String {
        catalog.text("Range test (sweep full circles)")
    }

    func capturingSeconds(_ seconds: Int) -> String {
        catalog.format("Capturing… %lld s", seconds)
    }

    var testSawNothing: String {
        catalog.text("The controller sent nothing during the test.")
    }

    func driftResult(_ left: String, _ right: String, _ deadzone: String) -> String {
        catalog.format("Resting drift: L %@ · R %@. Suggested dead zone: %@.", left, right, deadzone)
    }

    func rangeResult(_ left: String, _ right: String, _ circularityLeft: String, _ circularityRight: String) -> String {
        catalog.format("Reach: L %@ · R %@. Circularity error: L %@ · R %@.", left, right, circularityLeft, circularityRight)
    }

    var notApplicable: String {
        catalog.text("n/a")
    }

    // MARK: - The rumble bench

    var rumbleTest: String {
        catalog.text("Rumble test")
    }

    var rumbleTestNote: String {
        catalog.text("A short buzz straight to the controller, whatever its rumble switch says.")
    }

    var noRumbleOnThisPath: String {
        catalog.text("This controller has no rumble motors on the path it is on now.")
    }

    var weakMotor: String {
        catalog.text("Weak")
    }

    var strongMotor: String {
        catalog.text("Strong")
    }

    var bothMotors: String {
        catalog.text("Both")
    }

    // MARK: - The audio tests

    var audioTests: String {
        catalog.text("Audio tests")
    }

    var playTone: String {
        catalog.text("Play tone")
    }

    var tonePlayingWord: String {
        catalog.text("Playing…")
    }

    var noAudioOutput: String {
        catalog.text("No audio output for this controller.")
    }

    var testMicrophone: String {
        catalog.text("Test microphone")
    }

    var stopWord: String {
        catalog.text("Stop")
    }

    var micListening: String {
        catalog.text("Listening… speak into the microphone.")
    }

    func micLevel(_ level: Int, _ peak: Int) -> String {
        catalog.format("Level %lld%% · peak %lld%%", level, peak)
    }

    var micCouldNotOpen: String {
        catalog.text("The microphone could not be opened.")
    }

    var noAudioEndpoints: String {
        catalog.text("No audio endpoints on this path.")
    }

    // MARK: - The buttons

    var buttonDpadUp: String {
        catalog.text("D-pad up")
    }

    var buttonDpadDown: String {
        catalog.text("D-pad down")
    }

    var buttonDpadLeft: String {
        catalog.text("D-pad left")
    }

    var buttonDpadRight: String {
        catalog.text("D-pad right")
    }

    var buttonStart: String {
        catalog.text("Start")
    }

    var buttonBack: String {
        catalog.text("Back")
    }

    var buttonGuide: String {
        catalog.text("Guide")
    }

    var buttonMute: String {
        catalog.text("Mute")
    }

    var buttonL3: String {
        catalog.text("L3")
    }

    var buttonR3: String {
        catalog.text("R3")
    }

    var buttonLB: String {
        catalog.text("LB")
    }

    var buttonRB: String {
        catalog.text("RB")
    }

    var buttonA: String {
        catalog.text("A")
    }

    var buttonB: String {
        catalog.text("B")
    }

    var buttonX: String {
        catalog.text("X")
    }

    var buttonY: String {
        catalog.text("Y")
    }
}
