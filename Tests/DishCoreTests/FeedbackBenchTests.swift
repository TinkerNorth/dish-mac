// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// The bench's feedback tests are the contract's ("The bench"), with
/// dish-android's strengths and times: 48000 for 400 ms on a motor or a
/// trigger motor, the light bar through red, green and blue, the player
/// lights through their patterns, both triggers rigid for 2 s.
final class FeedbackBenchTests: XCTestCase {

    // MARK: - Rumble

    func testTheWeakTestBuzzRunsOnlyTheWeakMotor() {
        XCTAssertEqual(testBuzz(for: .weak), TestBuzz(strong: 0, weak: 48000, durationMs: 400))
    }

    func testTheStrongTestBuzzRunsOnlyTheStrongMotor() {
        XCTAssertEqual(testBuzz(for: .strong), TestBuzz(strong: 48000, weak: 0, durationMs: 400))
    }

    func testTheCombinedTestBuzzRunsBothMotorsAtOnce() {
        XCTAssertEqual(testBuzz(for: .both), TestBuzz(strong: 48000, weak: 48000, durationMs: 400))
    }

    func testATestBuzzIsDishAndroids() {
        XCTAssertEqual(TestBuzz.magnitude, 48000)
        XCTAssertEqual(TestBuzz.durationMs, 400)
        XCTAssertEqual(BuzzMotor.allCases, [.weak, .strong, .both])
    }

    // MARK: - Trigger rumble

    func testEachTriggerBuzzRunsItsTriggerMotorsAtTheRumblesStrengthAndTime() {
        XCTAssertEqual(testTriggerBuzz(for: .left), TestTriggerBuzz(left: 48000, right: 0, durationMs: 400))
        XCTAssertEqual(testTriggerBuzz(for: .right), TestTriggerBuzz(left: 0, right: 48000, durationMs: 400))
        XCTAssertEqual(testTriggerBuzz(for: .both), TestTriggerBuzz(left: 48000, right: 48000, durationMs: 400))
        XCTAssertEqual(TriggerMotor.allCases, [.left, .right, .both])
    }

    // MARK: - The programs

    func testARumbleTestTakesNoSurfaceAndEndsWithItsBuzz() {
        for motor in BuzzMotor.allCases {
            XCTAssertEqual(benchProgram(.rumble(motor)), BenchProgram(
                surface: nil,
                steps: [BenchStep(atMs: 0, action: .rumble(testBuzz(for: motor)))],
                durationMs: 400
            ))
        }
    }

    func testATriggerRumbleTestTakesNoSurfaceAndEndsWithItsBuzz() {
        for motor in TriggerMotor.allCases {
            XCTAssertEqual(benchProgram(.triggerRumble(motor)), BenchProgram(
                surface: nil,
                steps: [BenchStep(atMs: 0, action: .triggerRumble(testTriggerBuzz(for: motor)))],
                durationMs: 400
            ))
        }
    }

    func testTheLightBarCycleHoldsTheBarThroughRedGreenAndBlueFor400MsEach() {
        XCTAssertEqual(benchProgram(.lightbarCycle), BenchProgram(
            surface: .lightbar,
            steps: [
                BenchStep(atMs: 0, action: .lightbar(LightbarColor(r: 0xFF, g: 0, b: 0))),
                BenchStep(atMs: 400, action: .lightbar(LightbarColor(r: 0, g: 0xFF, b: 0))),
                BenchStep(atMs: 800, action: .lightbar(LightbarColor(r: 0, g: 0, b: 0xFF)))
            ],
            durationMs: 1200
        ))
    }

    func testThePlayerCycleHoldsTheLightsThroughTheFourPlayersFor400MsEach() {
        XCTAssertEqual(benchProgram(.playerCycle), BenchProgram(
            surface: .playerLeds,
            steps: [
                BenchStep(atMs: 0, action: .player(1)),
                BenchStep(atMs: 400, action: .player(2)),
                BenchStep(atMs: 800, action: .player(3)),
                BenchStep(atMs: 1200, action: .player(4))
            ],
            durationMs: 1600
        ))
    }

    /// Every path that lights a Mac pad's player LEDs takes a player number,
    /// the mask's lit count: the contract's single-LED masks would all read
    /// as player one, so the cycle walks the players instead.
    func testTheContractsSingleLedMasksWouldAllLightPlayerOne() {
        let masks: [UInt8] = [0x01, 0x02, 0x04, 0x08, 0x10]
        let players = masks.map { PlayerLedsCommand(controllerIndex: 0, ledMask: $0).playerNumber }
        XCTAssertEqual(players, [1, 1, 1, 1, 1])
        XCTAssertEqual(playerCycle, [1, 2, 3, 4])
    }

    func testTheTriggerPulseHoldsBothTriggersRigidAtFullForceForTwoSeconds() {
        let rigid: [UInt8] = [0x01, 0x00, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertEqual(benchProgram(.triggerPulse), BenchProgram(
            surface: .triggerEffects,
            steps: [BenchStep(atMs: 0, action: .triggerEffects(TriggerEffectsCommand(controllerIndex: 0, left: rigid, right: rigid)))],
            durationMs: 2000
        ))
        XCTAssertEqual(rigidTriggerBlock.count, ProtocolConstants.triggerEffectBlockBytes)
    }

    func testTheTriggersIdleWithNoEffectOnEitherSide() {
        let off = [UInt8](repeating: 0, count: ProtocolConstants.triggerEffectBlockBytes)
        XCTAssertEqual(idleTriggerEffects, TriggerEffectsCommand(controllerIndex: 0, left: off, right: off))
    }

    func testEachFeedbackTestCarriesTheContractsName() {
        let named: [(FeedbackTest, InspectorTest)] = [
            (.rumble(.weak), .rumbleWeak),
            (.rumble(.strong), .rumbleStrong),
            (.rumble(.both), .rumbleBoth),
            (.triggerRumble(.left), .triggerRumbleLeft),
            (.triggerRumble(.right), .triggerRumbleRight),
            (.triggerRumble(.both), .triggerRumbleBoth),
            (.lightbarCycle, .lightbarCycle),
            (.playerCycle, .playerLedsCycle),
            (.triggerPulse, .triggerPulse)
        ]
        for (test, name) in named {
            XCTAssertEqual(test.inspectorTest, name)
        }
    }

    // MARK: - Rules 2 and 3: the game's state goes back

    func testAGameValueOnAFreeSurfaceIsWrittenAtOnce() {
        var surface = BenchSurfaceState<Int>()
        XCTAssertEqual(surface.gameSent(2), 2)
        XCTAssertEqual(surface.game, 2)
        XCTAssertFalse(surface.held)
    }

    func testWhileATestHoldsTheSurfaceTheGamesValueIsRememberedNotWritten() {
        var surface = BenchSurfaceState<Int>()
        surface.take(idle: 0)
        XCTAssertNil(surface.gameSent(3))
        XCTAssertNil(surface.gameSent(4))
        XCTAssertEqual(surface.game, 4)
    }

    func testTheTestsEndWritesBackTheGamesNewestValueFromBeforeTheTest() {
        var surface = BenchSurfaceState<Int>()
        XCTAssertEqual(surface.gameSent(2), 2)
        surface.take(idle: 0)
        XCTAssertEqual(surface.release(), 2)
        XCTAssertFalse(surface.held)
    }

    func testTheTestsEndWritesBackTheValueTheGameSentDuringTheTest() {
        var surface = BenchSurfaceState<Int>()
        XCTAssertEqual(surface.gameSent(2), 2)
        surface.take(idle: 0)
        XCTAssertNil(surface.gameSent(5))
        XCTAssertEqual(surface.release(), 5)
    }

    func testASurfaceTheGameNeverSetGoesBackToItsIdleState() {
        var surface = BenchSurfaceState<Int>()
        surface.take(idle: 7)
        XCTAssertEqual(surface.release(), 7)
    }

    func testASurfaceWithNoGameValueAndNoIdleStateHasNothingToPutBack() {
        var surface = BenchSurfaceState<Int>()
        surface.take(idle: nil)
        XCTAssertNil(surface.release())
    }

    func testATakeOfAHeldSurfaceKeepsTheFirstIdleState() {
        var surface = BenchSurfaceState<Int>()
        surface.take(idle: 7)
        surface.take(idle: 9)
        XCTAssertTrue(surface.held)
        XCTAssertEqual(surface.release(), 7)
    }

    func testAnEndWithNoTestHoldingTheSurfaceWritesNothing() {
        var surface = BenchSurfaceState<Int>()
        XCTAssertEqual(surface.gameSent(2), 2)
        XCTAssertNil(surface.release())
    }

    func testOnceTheSurfaceIsBackTheGamesValuesAreWrittenAgain() {
        var surface = BenchSurfaceState<Int>()
        surface.take(idle: 0)
        XCTAssertEqual(surface.release(), 0)
        XCTAssertEqual(surface.gameSent(6), 6)
    }

    // MARK: - Rule 1: offered only where it can land

    func testAPathThatCarriesNothingOffersNoItem() {
        XCTAssertEqual(benchItems(BenchCarriage()), [])
    }

    func testAPathThatCarriesEverythingOffersEveryItemInThePagesOrder() {
        let everything = BenchCarriage(
            rumble: true,
            triggerRumble: true,
            lightbar: true,
            playerLeds: true,
            triggerEffects: true,
            speaker: true,
            hapticLanes: true,
            mic: true
        )
        XCTAssertEqual(benchItems(everything), BenchItem.allCases)
        XCTAssertEqual(
            BenchItem.allCases,
            [.rumble, .triggerRumble, .lightbar, .playerLeds, .adaptiveTriggers, .speaker, .haptics, .microphone]
        )
    }

    func testEachItemIsOfferedOnlyByItsOwnFact() {
        let alone: [(BenchCarriage, BenchItem)] = [
            (BenchCarriage(rumble: true), .rumble),
            (BenchCarriage(triggerRumble: true), .triggerRumble),
            (BenchCarriage(lightbar: true), .lightbar),
            (BenchCarriage(playerLeds: true), .playerLeds),
            (BenchCarriage(triggerEffects: true), .adaptiveTriggers),
            (BenchCarriage(speaker: true), .speaker),
            (BenchCarriage(hapticLanes: true), .haptics),
            (BenchCarriage(mic: true), .microphone)
        ]
        for (carriage, item) in alone {
            XCTAssertEqual(benchItems(carriage), [item])
        }
    }
}
