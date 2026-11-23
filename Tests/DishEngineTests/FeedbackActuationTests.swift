// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import GameController
import XCTest
@testable import DishEngine

/// The pure halves of the feedback actuation: how long a rumble packet runs
/// the motors, which player index a LED pattern lights and which player a
/// pattern reads back as, which pads have trigger motors, how a framework
/// colour reads as bytes, what the bench reads of a path, and how a zone
/// array fills the framework's positional structs.
final class FeedbackActuationTests: XCTestCase {

    func testARumblePacketNeverRunsPastTheCap() {
        XCTAssertEqual(RumbleActuator.holdSeconds(durationMs: 300), 0.3)
        XCTAssertEqual(RumbleActuator.holdSeconds(durationMs: 1500), 1.5)
        XCTAssertEqual(RumbleActuator.holdSeconds(durationMs: 5000), 1.5, "a dead host cannot leave the motors running")
    }

    func testAContinuousPacketHoldsForTheCap() {
        XCTAssertEqual(RumbleActuator.holdSeconds(durationMs: 0), 1.5)
    }

    @MainActor
    func testPlayersOneToFourLightTheirIndexAndAnythingElseClears() {
        XCTAssertEqual(GameControllerInput.playerIndex(for: 1), .index1)
        XCTAssertEqual(GameControllerInput.playerIndex(for: 2), .index2)
        XCTAssertEqual(GameControllerInput.playerIndex(for: 3), .index3)
        XCTAssertEqual(GameControllerInput.playerIndex(for: 4), .index4)
        XCTAssertEqual(GameControllerInput.playerIndex(for: 0), .indexUnset)
        XCTAssertEqual(GameControllerInput.playerIndex(for: 9), .indexUnset)
    }

    @MainActor
    func testEachPatternReadsBackAsThePlayerItLights() {
        let indices: [GCControllerPlayerIndex] = [.index1, .index2, .index3, .index4, .indexUnset]
        XCTAssertEqual(indices.map { GameControllerInput.player(for: $0) }, [1, 2, 3, 4, 0])
        for player in 0 ... 4 {
            XCTAssertEqual(GameControllerInput.player(for: GameControllerInput.playerIndex(for: player)), player)
        }
    }

    /// An Xbox Wireless Controller's impulse triggers: both localities, or
    /// there is no trigger test to run.
    @MainActor
    func testAPadHasTriggerMotorsOnlyWhenItsHapticsNameBothTriggers() {
        let handles: Set<GCHapticsLocality> = [.default, .all, .handles, .leftHandle, .rightHandle]
        XCTAssertTrue(GameControllerInput.hasTriggerMotors(handles.union([.triggers, .leftTrigger, .rightTrigger])))
        XCTAssertFalse(GameControllerInput.hasTriggerMotors(handles), "a DualSense's")
        XCTAssertFalse(GameControllerInput.hasTriggerMotors([.leftTrigger]))
        XCTAssertFalse(GameControllerInput.hasTriggerMotors([.triggers]), "the pair alone names no side to test")
        XCTAssertFalse(GameControllerInput.hasTriggerMotors([]))
    }

    func testTheHandlesAndTheTriggersEachDriveTheirOwnPair() {
        XCTAssertEqual(HapticPair.handles, HapticPair(left: .leftHandle, right: .rightHandle))
        XCTAssertEqual(HapticPair.triggers, HapticPair(left: .leftTrigger, right: .rightTrigger))
    }

    func testAFrameworkColourReadsAsTheLightBarsBytes() {
        XCTAssertEqual(lightbarColor(GCColor(red: 1, green: 0, blue: 0.5)), LightbarColor(r: 0xFF, g: 0, b: 0x80))
        XCTAssertEqual(lightbarColor(GCColor(red: 2, green: -1, blue: 0.2)), LightbarColor(r: 0xFF, g: 0, b: 0x33), "out of range clamps")
    }

    func testThePathsCapabilitiesAreWhatTheBenchReads() {
        let caps = ControllerCapabilities(
            hasRumble: true,
            hasTriggerRumble: true,
            hasLightbar: true,
            hasTriggerEffects: true,
            hasPlayerLeds: true,
            hasMic: true,
            hasSpeaker: true,
            hasHapticLanes: true
        )
        XCTAssertEqual(caps.benchCarriage, BenchCarriage(
            rumble: true,
            triggerRumble: true,
            lightbar: true,
            playerLeds: true,
            triggerEffects: true,
            speaker: true,
            hapticLanes: true,
            mic: true
        ))
        XCTAssertEqual(ControllerCapabilities(hasMotion: true, hasTouchpad: true, hasBattery: true).benchCarriage, BenchCarriage())
    }

    @MainActor
    func testPositionalStructsTakeTenZonesAndLeaveTheRestAtZero() {
        var zones = [Float](repeating: 0, count: 10)
        zones[0] = 0.25
        zones[9] = 1
        let strengths = GameControllerInput.positionalStrengths(zones)
        XCTAssertEqual(strengths.values.0, 0.25)
        XCTAssertEqual(strengths.values.9, 1)
        XCTAssertEqual(strengths.values.4, 0)
        let amplitudes = GameControllerInput.positionalAmplitudes([0.5])
        XCTAssertEqual(amplitudes.values.0, 0.5)
        XCTAssertEqual(amplitudes.values.1, 0)
    }

    /// SDL's rule: a repeated rumble restarts the player a motor has; only a
    /// new level, its magnitude or its hold, builds a new one, and zero stops.
    func testAMotorReusesItsPlayerWhileTheLevelRepeats() {
        let playing = MotorLevel(magnitude: 30000, duration: 0.5)
        XCTAssertEqual(motorStep(playing: playing, magnitude: 30000, duration: 0.5), .restart)
        XCTAssertEqual(motorStep(playing: playing, magnitude: 30001, duration: 0.5), .replace(MotorLevel(magnitude: 30001, duration: 0.5)))
        XCTAssertEqual(motorStep(playing: playing, magnitude: 30000, duration: 1.5), .replace(MotorLevel(magnitude: 30000, duration: 1.5)))
        XCTAssertEqual(motorStep(playing: nil, magnitude: 30000, duration: 0.5), .replace(playing))
        XCTAssertEqual(motorStep(playing: playing, magnitude: 0, duration: 0.5), .stop)
        XCTAssertEqual(motorStep(playing: nil, magnitude: 0, duration: 0.5), .stop)
    }
}
