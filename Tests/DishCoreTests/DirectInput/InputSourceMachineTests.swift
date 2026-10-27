// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// One pad's input source: the decision at connect, proving by a real
/// change, the stickiness that stops flapping, the user's pick and the
/// "Not responding?" check. Effect lists are pinned in order.
final class InputSourceMachineTests: XCTestCase {

    private static let n64Facts = PadPathFacts(
        model: directModel(vendorId: 0x057E, productId: 0x2019), decodable: true, gameController: .shows, stored: nil
    )
    private static let shownFacts = PadPathFacts(model: nil, decodable: true, gameController: .shows, stored: nil)
    private static let pendingFacts = PadPathFacts(model: nil, decodable: true, gameController: .pending, stored: nil)
    private static let undecodableFacts = PadPathFacts(model: nil, decodable: false, gameController: .shows, stored: nil)
    private static let unreadableFacts = PadPathFacts(model: nil, decodable: false, gameController: .doesNotShow, stored: nil)

    private func run(_ events: [InputSourceEvent], from state: InputSourceState = .initial) -> InputSourceReduction {
        events.reduce(InputSourceReduction(next: state)) { reduceInputSource($0.next, $1) }
    }

    private func connected(_ facts: PadPathFacts) -> InputSourceState {
        reduceInputSource(.initial, .connected(facts)).next
    }

    private func checking(_ facts: PadPathFacts, at startMs: Int64 = 0) -> InputSourceState {
        reduceInputSource(connected(facts), .checkStarted(nowMs: startMs)).next
    }

    // MARK: - Connecting

    func testConnectingForwardsTheDecidedSourceUnproven() {
        let reduction = reduceInputSource(.initial, .connected(Self.n64Facts))
        XCTAssertEqual(reduction.next.phase, .forwarding(.direct))
        XCTAssertEqual(reduction.next.reason, .directByModel)
        XCTAssertFalse(reduction.next.proven, "the card asks for a press until a real change arrives")
        XCTAssertEqual(reduction.effects, [.forward(.direct)])
    }

    func testConnectingWhileGameControllerIsUnsettledForwardsNothingYet() {
        let reduction = reduceInputSource(.initial, .connected(Self.pendingFacts))
        XCTAssertEqual(reduction.next.phase, .awaitingGameController)
        XCTAssertEqual(reduction.effects, [])
    }

    func testTheSettledSupportDecidesTheSource() {
        let shown = run([.connected(Self.pendingFacts), .gameControllerResolved(shows: true)])
        XCTAssertEqual(shown.next.phase, .forwarding(.standard))
        XCTAssertEqual(shown.next.reason, .macOSReads)
        XCTAssertEqual(shown.effects, [.forward(.standard)])
        let unsupported = run([.connected(Self.pendingFacts), .gameControllerResolved(shows: false)])
        XCTAssertEqual(unsupported.next.phase, .forwarding(.direct))
        XCTAssertEqual(unsupported.next.reason, .macOSCannotRead)
        XCTAssertEqual(unsupported.effects, [.forward(.direct)])
    }

    func testAPadNeitherPathReadsForwardsNothing() {
        let reduction = reduceInputSource(.initial, .connected(Self.unreadableFacts))
        XCTAssertEqual(reduction.next.phase, .unreadable)
        XCTAssertEqual(reduction.effects, [])
    }

    // MARK: - Proving and stickiness

    func testAChangeOnTheForwardedSourceProvesIt() {
        let reduction = reduceInputSource(connected(Self.n64Facts), .directInputChanged(nowMs: 10))
        XCTAssertTrue(reduction.next.proven)
        XCTAssertEqual(reduction.effects, [])
    }

    func testAChangeOnTheOtherSourceNeitherProvesNorMovesIt() {
        let reduction = reduceInputSource(connected(Self.shownFacts), .directInputChanged(nowMs: 10))
        XCTAssertEqual(reduction.next.phase, .forwarding(.standard), "sticky: Dish's reader seeing input does not flip the path")
        XCTAssertFalse(reduction.next.proven)
        XCTAssertEqual(reduction.effects, [])
    }

    func testALateSupportAnswerIsKeptButNeverMovesTheSource() {
        let proPending = PadPathFacts(
            model: directModel(vendorId: 0x057E, productId: 0x2009),
            decodable: true,
            gameController: .pending,
            stored: nil
        )
        let before = connected(proPending)
        XCTAssertFalse(before.canPick(.standard))
        let reduction = reduceInputSource(before, .gameControllerResolved(shows: true))
        XCTAssertEqual(reduction.next.phase, .forwarding(.direct))
        XCTAssertEqual(reduction.effects, [])
        XCTAssertTrue(reduction.next.canPick(.standard), "now the Switch Pro may be sent back to macOS")
    }

    func testAConnectDuringAConnectionChangesNothing() {
        for state in [connected(Self.pendingFacts), connected(Self.shownFacts), connected(Self.unreadableFacts)] {
            XCTAssertEqual(reduceInputSource(state, .connected(Self.n64Facts)), InputSourceReduction(next: state))
        }
    }

    // MARK: - Picking

    func testAPickMovesTheSourceRemembersItAndMustBeProvenAgain() {
        let proven = reduceInputSource(connected(Self.shownFacts), .standardInputChanged(nowMs: 10)).next
        let reduction = reduceInputSource(proven, .userPicked(.direct))
        XCTAssertEqual(reduction.next.phase, .forwarding(.direct))
        XCTAssertEqual(reduction.next.reason, .userPicked)
        XCTAssertFalse(reduction.next.proven)
        XCTAssertEqual(reduction.effects, [.forward(.direct), .remember(.direct)])
    }

    func testAPickOfTheCurrentSourceOrOfAPathThatCannotReadIsIgnored() {
        let standard = connected(Self.shownFacts)
        XCTAssertEqual(reduceInputSource(standard, .userPicked(.standard)), InputSourceReduction(next: standard))
        let undecodable = connected(Self.undecodableFacts)
        XCTAssertEqual(reduceInputSource(undecodable, .userPicked(.direct)), InputSourceReduction(next: undecodable))
        let n64 = connected(Self.n64Facts)
        XCTAssertEqual(reduceInputSource(n64, .userPicked(.standard)), InputSourceReduction(next: n64), "never the N64")
    }

    func testAPickCancelsARunningCheck() {
        let reduction = reduceInputSource(checking(Self.shownFacts), .userPicked(.direct))
        XCTAssertNil(reduction.next.check)
        XCTAssertEqual(reduction.effects, [.forward(.direct), .remember(.direct)], "no verdict for a check the pick ended")
    }

    // MARK: - Disconnecting

    func testADisconnectStopsForwardingAndForgetsThePad() {
        let proven = reduceInputSource(checking(Self.n64Facts), .tick(nowMs: 1)).next
        let reduction = reduceInputSource(proven, .disconnected)
        XCTAssertEqual(reduction.next, .initial)
        XCTAssertEqual(reduction.effects, [.stopForwarding])
    }

    func testADisconnectBeforeAnythingWasForwardedHasNothingToStop() {
        for state in [connected(Self.pendingFacts), connected(Self.unreadableFacts)] {
            XCTAssertEqual(reduceInputSource(state, .disconnected), InputSourceReduction(next: .initial))
        }
    }

    func testTheNextConnectionDecidesAfresh() {
        let picked = run([.connected(Self.shownFacts), .userPicked(.direct), .disconnected, .connected(Self.shownFacts)])
        XCTAssertEqual(picked.next.phase, .forwarding(.standard), "the stored pick arrives in the facts, not from the last connection")
    }

    // MARK: - The check

    func testACheckThatSeesTheForwardedSourceSettlesAtOnce() {
        let standard = reduceInputSource(checking(Self.shownFacts), .standardInputChanged(nowMs: 1200))
        XCTAssertEqual(standard.effects, [.verdict(.standardWorks, offer: .none)])
        XCTAssertNil(standard.next.check)
        XCTAssertTrue(standard.next.proven)
        let direct = reduceInputSource(checking(Self.n64Facts), .directInputChanged(nowMs: 1200))
        XCTAssertEqual(direct.effects, [.verdict(.dishReadsIt, offer: .none)])
    }

    func testACheckThatSeesOnlyDishsReaderOffersUseDirect() {
        let watched = run([.directInputChanged(nowMs: 800), .tick(nowMs: 4999)], from: checking(Self.shownFacts))
        XCTAssertEqual(watched.effects, [], "the window is still open")
        XCTAssertEqual(watched.next.check?.sawDirect, true)
        let closed = reduceInputSource(watched.next, .tick(nowMs: 5000))
        XCTAssertEqual(closed.effects, [.verdict(.dishReadsIt, offer: .useDirect)])
        XCTAssertNil(closed.next.check)
        XCTAssertEqual(reduceInputSource(closed.next, .userPicked(.direct)).effects, [.forward(.direct), .remember(.direct)])
    }

    func testACheckThatSeesOnlyMacOSOnADirectPadSaysStandardWorks() {
        let watched = run([.standardInputChanged(nowMs: 800), .tick(nowMs: 5000)], from: checking(Self.n64Facts))
        XCTAssertEqual(watched.effects, [.verdict(.standardWorks, offer: .none)])
    }

    func testASilentCheckIsAConnectionHintWhenDishCouldDecodeThePad() {
        let closed = reduceInputSource(checking(Self.shownFacts), .tick(nowMs: 5000))
        XCTAssertEqual(closed.effects, [.verdict(.nothingAtAll, offer: .connectionHint)])
    }

    func testASilentCheckAsksForHelpWhenDishHasNoDecoder() {
        let closed = reduceInputSource(checking(Self.undecodableFacts), .tick(nowMs: 5000))
        XCTAssertEqual(closed.effects, [.verdict(.noDecoder, offer: .helpSupport)])
    }

    func testTheCheckWatchesForFiveSeconds() {
        XCTAssertEqual(InputCheckWindow.durationMs, 5000)
        let running = checking(Self.shownFacts, at: 10000)
        XCTAssertEqual(reduceInputSource(running, .tick(nowMs: 14999)), InputSourceReduction(next: running))
        XCTAssertEqual(reduceInputSource(running, .tick(nowMs: 15000)).effects.count, 1)
    }

    func testAChangeAfterTheWindowClosesTheCheckOnWhatItHadSeenAndStillProves() {
        let late = reduceInputSource(checking(Self.shownFacts), .standardInputChanged(nowMs: 6000))
        XCTAssertEqual(late.effects, [.verdict(.nothingAtAll, offer: .connectionHint)], "the press came after the window")
        XCTAssertNil(late.next.check)
        XCTAssertTrue(late.next.proven)
        let lateOther = reduceInputSource(checking(Self.shownFacts), .directInputChanged(nowMs: 6000))
        XCTAssertEqual(lateOther.effects, [.verdict(.nothingAtAll, offer: .connectionHint)])
        XCTAssertFalse(lateOther.next.proven)
    }

    func testASecondCheckStartKeepsTheFirstStart() {
        let running = checking(Self.shownFacts, at: 0)
        let restarted = reduceInputSource(running, .checkStarted(nowMs: 4000))
        XCTAssertEqual(restarted.next.check?.startedAtMs, 0)
        XCTAssertEqual(reduceInputSource(restarted.next, .tick(nowMs: 5000)).effects.count, 1)
    }

    func testAClockThatStepsBackDoesNotCloseTheCheck() {
        let running = checking(Self.shownFacts, at: 10000)
        XCTAssertEqual(reduceInputSource(running, .tick(nowMs: 0)), InputSourceReduction(next: running))
    }

    func testTheVerdictPrefersTheForwardedPathWhenBothSawThePress() {
        var both = PadCheck(startedAtMs: 0)
        both.sawStandard = true
        both.sawDirect = true
        XCTAssertEqual(checkVerdict(both, forwarded: .standard, decodable: true).0, .standardWorks)
        XCTAssertEqual(checkVerdict(both, forwarded: .direct, decodable: true).0, .dishReadsIt)
    }
}
