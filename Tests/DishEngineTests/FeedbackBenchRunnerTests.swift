// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// The feedback bench on the pad's feedback record, with time moved by hand:
/// each test's writes land at their times, a state surface the test holds is
/// the test's alone while it runs (the game's values wait and are what goes
/// back), a surface the game never set goes back to what it showed, the
/// other surfaces keep following the game, and the page asks once the test
/// has ended (the contract's bench, rules 2 to 4).
@MainActor
final class FeedbackBenchRunnerTests: XCTestCase {

    private var wallMs: Int64 = 1_000_000
    private var log: BenchLog!
    private var feedback: PadFeedback!
    private var scheduler: ManualPathScheduler!
    private var outcomes: PadOutcomesStore!
    private var runner: FeedbackBenchRunner!

    override func setUp() {
        super.setUp()
        log = BenchLog()
        feedback = PadFeedback(actuators: log.actuators)
        scheduler = ManualPathScheduler()
        outcomes = PadOutcomesStore { [unowned self] in wallMs }
        runner = FeedbackBenchRunner(feedback: feedback, outcomes: outcomes, scheduler: scheduler)
    }

    /// Time moves on the bench's clock and the outcomes' together, and the
    /// feedback queue drains.
    private func advance(_ ms: Int) {
        wallMs += Int64(ms)
        scheduler.advance(ms: ms)
        feedback.queue.sync {}
    }

    private func gameLight(_ r: UInt8, _ g: UInt8, _ b: UInt8, pad: String = "pad") {
        feedback.pad(for: pad).post(lightbar: LightbarCommand(controllerIndex: 0, r: r, g: g, b: b))
        feedback.queue.sync {}
    }

    private func gamePlayer(_ player: Int) {
        feedback.pad(for: "pad").post(player: player)
        feedback.queue.sync {}
    }

    private func gameTriggers(_ mode: UInt8) {
        let block = [mode] + [UInt8](repeating: 0, count: ProtocolConstants.triggerEffectBlockBytes - 1)
        feedback.pad(for: "pad").post(triggerEffects: TriggerEffectsCommand(controllerIndex: 0, left: block, right: block))
        feedback.queue.sync {}
    }

    // MARK: - The light bar

    func testTheLightBarCycleShowsRedGreenAndBlueThenTheGamesColour() {
        gameLight(0x11, 0x22, 0x33)
        log.clear()
        runner.run(.lightbarCycle, slotId: "pad")
        advance(0)
        XCTAssertEqual(log.lines, ["lightbar ff0000"])
        advance(400)
        XCTAssertEqual(log.lines, ["lightbar ff0000", "lightbar 00ff00"])
        advance(400)
        XCTAssertEqual(log.lines.last, "lightbar 0000ff")
        advance(399)
        XCTAssertEqual(log.lines.count, 3, "the bar holds blue to the test's end")
        advance(1)
        XCTAssertEqual(log.lines, ["lightbar ff0000", "lightbar 00ff00", "lightbar 0000ff", "lightbar 112233"])
    }

    func testAColourTheGameSendsDuringTheCycleWaitsAndIsWhatGoesBack() {
        gameLight(0x11, 0x22, 0x33)
        log.clear()
        runner.run(.lightbarCycle, slotId: "pad")
        advance(500)
        gameLight(0x44, 0x55, 0x66)
        XCTAssertEqual(log.lines, ["lightbar ff0000", "lightbar 00ff00"], "the game's colour is remembered, not written")
        advance(700)
        XCTAssertEqual(log.lines.last, "lightbar 445566")
        gameLight(0x77, 0x88, 0x99)
        XCTAssertEqual(log.lines.last, "lightbar 778899", "once back, the game's colours are written again")
    }

    func testALightBarTheGameNeverSetGoesBackToWhatItShowed() {
        log.shownLight = LightbarColor(r: 0, g: 0, b: 0x40)
        runner.run(.lightbarCycle, slotId: "pad")
        advance(1200)
        XCTAssertEqual(log.lines.last, "lightbar 000040")
    }

    func testAPadThatShowsNoLightAndNeverHadOneIsGivenNothingBack() {
        runner.run(.lightbarCycle, slotId: "pad")
        advance(1200)
        XCTAssertEqual(log.lines, ["lightbar ff0000", "lightbar 00ff00", "lightbar 0000ff"])
    }

    // MARK: - The player lights and the triggers

    func testThePlayerCycleWalksTheFourPlayersThenPutsTheGamesPlayerBack() {
        gamePlayer(3)
        log.clear()
        runner.run(.playerCycle, slotId: "pad")
        advance(1600)
        XCTAssertEqual(log.lines, ["player 1", "player 2", "player 3", "player 4", "player 3"])
    }

    func testPlayerLightsTheGameNeverSetGoBackToThePatternTheyShowed() {
        log.shownPlayer = 0
        runner.run(.playerCycle, slotId: "pad")
        advance(1600)
        XCTAssertEqual(log.lines.last, "player 0")
    }

    func testThePulseHoldsBothTriggersRigidForTwoSecondsThenPutsTheGamesEffectBack() {
        gameTriggers(0x21)
        log.clear()
        runner.run(.triggerPulse, slotId: "pad")
        advance(1999)
        XCTAssertEqual(log.lines, ["triggers 01/ff 01/ff"])
        advance(1)
        XCTAssertEqual(log.lines, ["triggers 01/ff 01/ff", "triggers 21/00 21/00"])
    }

    func testTriggersTheGameNeverSetGoBackToNoEffect() {
        runner.run(.triggerPulse, slotId: "pad")
        advance(2000)
        XCTAssertEqual(log.lines, ["triggers 01/ff 01/ff", "triggers 00/00 00/00"])
    }

    func testTheOtherSurfacesKeepFollowingTheGameWhileATestHoldsOne() {
        runner.run(.triggerPulse, slotId: "pad")
        advance(100)
        gameLight(0x01, 0x02, 0x03)
        gamePlayer(2)
        XCTAssertEqual(log.lines, ["triggers 01/ff 01/ff", "lightbar 010203", "player 2"])
    }

    // MARK: - Rumble and trigger rumble

    func testARumbleTestBuzzesOnceAndTakesNothingFromTheGame() {
        runner.run(.rumble(.strong), slotId: "pad")
        advance(0)
        gameLight(0x01, 0x02, 0x03)
        advance(400)
        XCTAssertEqual(log.lines, ["rumble 48000/0/400", "lightbar 010203"])
    }

    func testATriggerRumbleTestDrivesTheTriggerMotors() {
        runner.run(.triggerRumble(.left), slotId: "pad")
        advance(400)
        XCTAssertEqual(log.lines, ["trigger-rumble 48000/0/400"])
    }

    func testTheBenchsWritesAreNotTheGamesAndNoLaneCountsThem() {
        runner.run(.lightbarCycle, slotId: "pad")
        advance(1200)
        XCTAssertEqual(feedback.outputCounts(slotId: "pad"), PadOutputCounts())
    }

    // MARK: - One test at a time, one answer per run

    func testAPadRunsOneFeedbackTestAtATimeAndAnotherPadRunsItsOwn() {
        runner.run(.lightbarCycle, slotId: "pad")
        runner.run(.rumble(.weak), slotId: "pad")
        runner.run(.rumble(.weak), slotId: "other")
        XCTAssertEqual(runner.state, ["pad": .lightbarCycle, "other": .rumble(.weak)])
        advance(1200)
        XCTAssertEqual(log.lines.filter { $0.hasPrefix("rumble") }, ["rumble 0/48000/400"], "only the other pad buzzed")
        XCTAssertEqual(runner.state, [:])
    }

    func testThePageAsksOnceTheTestHasEndedWithTheTimeItEnded() {
        runner.run(.playerCycle, slotId: "pad")
        XCTAssertEqual(outcomes.state.ledgers["pad"]?.running, .playerLedsCycle)
        advance(1599)
        XCTAssertNil(outcomes.state.asking("pad"))
        advance(1)
        XCTAssertEqual(outcomes.state.asking("pad"), EndedTest(test: .playerLedsCycle, atMs: 1_001_600))
    }
}

/// What the feedback queue was asked to do, as text a test can compare, and
/// what the pad shows when a test takes its light or its player lights.
private final class BenchLog: @unchecked Sendable {
    private let log = LockedBox<[String]>([])
    private let light = LockedBox<LightbarColor?>(nil)
    private let player = LockedBox<Int?>(nil)

    var lines: [String] {
        log.get()
    }

    var shownLight: LightbarColor? {
        get { light.get() }
        set { light.set(newValue) }
    }

    var shownPlayer: Int? {
        get { player.get() }
        set { player.set(newValue) }
    }

    func clear() {
        log.set([])
    }

    private func record(_ line: String) {
        log.mutate { $0.append(line) }
    }

    var actuators: FeedbackActuators {
        FeedbackActuators(
            rumble: { [self] _, strong, weak, durationMs in record("rumble \(strong)/\(weak)/\(durationMs)") },
            lightbar: { [self] _, red, green, blue in record("lightbar " + String(format: "%02x%02x%02x", red, green, blue)) },
            triggerEffects: { [self] _, command in record("triggers \(blockText(command.left)) \(blockText(command.right))") },
            playerLeds: { [self] _, player in record("player \(player)") },
            triggerRumble: { [self] _, left, right, durationMs in record("trigger-rumble \(left)/\(right)/\(durationMs)") },
            lightbarShown: { [self] _ in shownLight },
            playerShown: { [self] _ in shownPlayer }
        )
    }

    /// A block's mode and force bytes.
    private func blockText(_ block: [UInt8]) -> String {
        String(format: "%02x/%02x", block[0], block[2])
    }
}
