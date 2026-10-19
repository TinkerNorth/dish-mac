// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// The lifecycle, phase by phase: the happy path, every failure's name, a
/// stop from anywhere, and the stray completions that change nothing.
final class MoonlightSessionMachineTests: XCTestCase {

    private typealias State = MoonlightSessionMachineState

    private func reduce(_ state: State, _ event: MoonlightSessionEvent) -> MoonlightSessionReduction {
        reduceMoonlightSession(state, event)
    }

    func testTheHappyPathFromIdleToStreaming() {
        var state = State()
        var reduction = reduce(state, .startRequested)
        XCTAssertEqual(reduction, MoonlightSessionReduction(next: State(phase: .checkingInfo), effects: [.fetchServerInfo]))
        state = reduction.next ?? state
        reduction = reduce(state, .serverInfoOk(paired: true, remembered: true, identityChanged: false))
        XCTAssertEqual(reduction, MoonlightSessionReduction(next: State(phase: .launching), effects: [.sendLaunch]))
        state = reduction.next ?? state
        reduction = reduce(state, .launchOk)
        XCTAssertEqual(reduction, MoonlightSessionReduction(next: State(phase: .rtsp(.options)), effects: [.openRtsp]))
        state = reduction.next ?? state
        XCTAssertEqual(reduce(state, .rtspReady).effects, [.sendRtsp(.options)])
        for step in MoonlightRtspStep.allCases.dropLast() {
            XCTAssertEqual(state.phase, .rtsp(step))
            reduction = reduce(state, .rtspStepOk)
            XCTAssertEqual(reduction.effects, [.sendRtsp(step.next ?? .play)])
            state = reduction.next ?? state
        }
        reduction = reduce(state, .rtspStepOk)
        XCTAssertEqual(
            reduction,
            MoonlightSessionReduction(next: State(phase: .controlConnecting), effects: [.connectControl]),
            "play hands over"
        )
        state = reduction.next ?? state
        reduction = reduce(state, .controlConnected)
        XCTAssertEqual(reduction, MoonlightSessionReduction(next: State(phase: .streaming), effects: [.startStreaming]))
    }

    func testServerInfoLaunchesFirstAndNamesTheTrustFailures() {
        let checking = State(phase: .checkingInfo)
        XCTAssertEqual(
            reduce(State(phase: .checkingInfo, resuming: true), .serverInfoOk(paired: true, remembered: true, identityChanged: false)).next,
            State(phase: .launching, resuming: false),
            "a running app is asked for with a /launch first; the host says whether it is ours to resume"
        )
        XCTAssertEqual(
            reduce(checking, .serverInfoOk(paired: false, remembered: false, identityChanged: false)).next?.phase,
            .failed(.notPaired)
        )
        XCTAssertEqual(
            reduce(checking, .serverInfoOk(paired: false, remembered: true, identityChanged: false)).next?.phase,
            .failed(.trustLost)
        )
        XCTAssertEqual(
            reduce(checking, .serverInfoOk(paired: false, remembered: true, identityChanged: true)).next?.phase,
            .failed(.hostReplaced),
            "another identity is named before pairing is judged"
        )
        XCTAssertEqual(
            reduce(checking, .serverInfoFailed),
            MoonlightSessionReduction(next: State(phase: .failed(.unreachable)), effects: [.teardown, .notifyFailure])
        )
    }

    private func checkingState() -> State {
        State(phase: .checkingInfo)
    }

    func testLaunchBusyResumesOnceThenFails() {
        let launching = State(phase: .launching)
        let resume = reduce(launching, .launchBusy(resumable: true))
        XCTAssertEqual(resume, MoonlightSessionReduction(next: State(phase: .launching, resuming: true), effects: [.sendLaunch]))
        XCTAssertEqual(
            reduce(resume.next ?? launching, .launchBusy(resumable: true)).next?.phase,
            .failed(.appAlreadyRunning),
            "the host keeps the app"
        )
        XCTAssertEqual(reduce(launching, .launchBusy(resumable: false)).next?.phase, .failed(.appAlreadyRunning))
        XCTAssertEqual(reduce(launching, .launchFailed).next?.phase, .failed(.launchRejected))
        XCTAssertEqual(reduce(State(phase: .launching, resuming: true), .launchFailed).next?.phase, .failed(.resumeFailed))
        XCTAssertEqual(reduce(launching, .noAppsAvailable).next?.phase, .failed(.noApps))
        XCTAssertEqual(reduce(launching, .pickedAppRemoved).next?.phase, .failed(.appRemoved), "the pick is the user's to change")
        XCTAssertEqual(reduce(checkingState(), .pickedAppRemoved), .ignored, "only a launch knows the list")
    }

    func testTheLaterFailuresKeepTheirNames() {
        XCTAssertEqual(reduce(State(phase: .rtsp(.setupControl)), .rtspFailed).next?.phase, .failed(.rtspRejected))
        XCTAssertEqual(reduce(State(phase: .controlConnecting), .controlLost).next?.phase, .failed(.controlLost))
        XCTAssertEqual(reduce(State(phase: .controlConnecting), .hostTerminated).next?.phase, .failed(.hostEnded))
        XCTAssertEqual(reduce(State(phase: .streaming), .controlLost).next?.phase, .failed(.dropped), "a live link that dies is a drop")
        XCTAssertEqual(reduce(State(phase: .streaming), .hostTerminated).next?.phase, .failed(.hostEnded))
    }

    func testStopWinsFromEveryPhaseAndOnlyALiveLinkIsToldItIsEnding() {
        XCTAssertEqual(
            reduce(State(phase: .streaming), .stopRequested),
            MoonlightSessionReduction(next: State(), effects: [.sendTermination, .teardown])
        )
        XCTAssertEqual(reduce(State(phase: .controlConnecting), .stopRequested).effects, [.sendTermination, .teardown])
        XCTAssertEqual(
            reduce(State(phase: .rtsp(.play), resuming: true), .stopRequested),
            MoonlightSessionReduction(next: State(), effects: [.teardown])
        )
        XCTAssertEqual(reduce(State(phase: .launching), .stopRequested).effects, [.teardown])
        XCTAssertEqual(reduce(State(phase: .failed(.dropped)), .stopRequested).effects, [.teardown])
        XCTAssertEqual(reduce(State(), .stopRequested), MoonlightSessionReduction(next: State(), effects: []))
    }

    func testStrayCompletionsChangeNothing() {
        XCTAssertEqual(reduce(State(), .launchOk), MoonlightSessionReduction(next: nil))
        XCTAssertEqual(reduce(State(phase: .checkingInfo), .rtspStepOk).next, nil)
        XCTAssertEqual(reduce(State(phase: .rtsp(.describe)), .rtspReady).next, nil, "ready is answered only before the first step")
        XCTAssertEqual(reduce(State(phase: .streaming), .startRequested).next, nil, "a second binding joins, it does not launch again")
        XCTAssertEqual(reduce(State(phase: .failed(.unreachable)), .startRequested).next?.phase, .checkingInfo, "a failed session restarts")
    }

    func testTheStartRuleAndTheHandBackRule() {
        XCTAssertTrue(moonlightSessionNeedsStart(.idle))
        XCTAssertTrue(moonlightSessionNeedsStart(.failed(.dropped)))
        XCTAssertFalse(moonlightSessionNeedsStart(.launching))
        XCTAssertFalse(moonlightSessionNeedsStart(.streaming))
        XCTAssertTrue(
            shouldHandBackApp(launched: true, wentLive: false, lastControllerLeft: false),
            "a launch that never went live left the host holding an app"
        )
        XCTAssertFalse(shouldHandBackApp(launched: true, wentLive: true, lastControllerLeft: false), "someone still rides it")
        XCTAssertTrue(shouldHandBackApp(launched: true, wentLive: true, lastControllerLeft: true))
        XCTAssertFalse(shouldHandBackApp(launched: false, wentLive: false, lastControllerLeft: true))
    }

    func testConvergeIsTheReferenceCountAsOneRule() {
        XCTAssertEqual(moonlightConverge(phase: .idle, wantedPads: 1), .open)
        XCTAssertEqual(moonlightConverge(phase: .failed(.dropped), wantedPads: 2), .open)
        XCTAssertEqual(moonlightConverge(phase: .launching, wantedPads: 2), .wait)
        XCTAssertEqual(moonlightConverge(phase: .rtsp(.announce), wantedPads: 1), .wait)
        XCTAssertEqual(moonlightConverge(phase: .streaming, wantedPads: 3), .announce)
        XCTAssertEqual(moonlightConverge(phase: .streaming, wantedPads: 0), .cancel)
        XCTAssertEqual(moonlightConverge(phase: .launching, wantedPads: 0), .release)
        XCTAssertEqual(moonlightConverge(phase: .idle, wantedPads: 0), .release)
    }
}
