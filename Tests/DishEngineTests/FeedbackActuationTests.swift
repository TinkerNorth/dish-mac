// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import GameController
import XCTest
@testable import DishEngine

/// The pure halves of the feedback actuation: how long a rumble packet runs
/// the motors, which player index a LED pattern lights, and how a zone
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
}
