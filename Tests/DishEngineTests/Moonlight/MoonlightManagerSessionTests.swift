// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore
@testable import DishEngine

/// The session belongs to the bindings pointing at the host, not to any one
/// of them: two bindings mean one launch, later ones only announce a pad,
/// the last leaving cancels a live session and nothing else, and every
/// refusal is reported as what it is. A MOONLIGHT HOST REFUSES IN THE BODY,
/// NOT IN THE STATUS LINE, so most cases here answer HTTP 200 and disagree inside it.
@MainActor
final class MoonlightManagerSessionTests: MoonlightManagerTestCase {

    private func refuseLaunch() {
        gateway.answerSecure("/launch", .init(status: 200, body: Self.refusedLaunch))
    }

    private func liveSession() throws -> RecordingLiveSession {
        try XCTUnwrap(edges.liveSessions.last, "no control link came up")
    }

    func testTwoBindingsOnOneHostLaunchOneSessionAndAThirdJoinsIt() async throws {
        await bind("a", "b")
        XCTAssertEqual(launches(), 1)
        XCTAssertEqual(connection()?.phase, .streaming)
        XCTAssertEqual(connection()?.pads.map(\.number), [0, 1])
        XCTAssertEqual(manager.sessionHostIds, [host.id])
        let live = try liveSession()
        XCTAssertEqual(live.sent.count, 4, "both pads announced at rest on the live link")
        await bind("a", "b", "c")
        XCTAssertEqual(launches(), 1, "a later binding is a controller arrival and nothing else")
        XCTAssertEqual(resumes(), 0)
        XCTAssertEqual(connection()?.padCount, 3)
        XCTAssertEqual(live.sent.count, 6, "the third pad announced on the same link")
        XCTAssertEqual(store.host(id: host.id)?.lastAppId, "1", "the session recorded the app it settled on")
    }

    func testDroppingOneOfTwoBindingsFreesItsNumberAndCancelsNothing() async throws {
        await bind("a", "b")
        let live = try liveSession()
        _ = live.take()
        await bind("a")
        XCTAssertEqual(connection()?.padCount, 1)
        XCTAssertNil(connection()?.pad(for: "b"))
        XCTAssertEqual(cancels(), 0)
        XCTAssertEqual(
            live.take(),
            [.state(MoonlightInput.PadFrame(controller: 1, activeMask: 0b0001))],
            "the unplug names the pad that left"
        )
        XCTAssertEqual(connection()?.phase, .streaming)
    }

    func testTheLastUnbindCancelsALiveSessionAndNotOneThatNeverCameUp() async throws {
        await bind("a")
        let live = try liveSession()
        manager.applyDesired([:])
        await manager.awaitQuiet()
        XCTAssertEqual(cancels(), 1, "the host started the app for us; the last binding takes it back down")
        XCTAssertTrue(live.stopped)
        XCTAssertEqual(connection()?.padCount, 0)
        XCTAssertEqual(connection()?.phase, .idle)
        XCTAssertEqual(manager.sessionHostIds, [])
        refuseLaunch()
        await bind("a")
        XCTAssertEqual(connection()?.phase, .failed(.launchRejected))
        manager.applyDesired([:])
        await manager.awaitQuiet()
        XCTAssertEqual(cancels(), 1, "a session that never came up is not cancelled")
    }

    func testANewPickOnAHeldPadReachesThePadTheReopenedSessionAnnounces() async {
        refuseLaunch()
        await bind("a")
        manager.applyDesired([host.id: [pad("a", playStation)]])
        await manager.awaitQuiet()
        XCTAssertEqual(connection()?.pad(for: "a")?.announced, playStation)
        XCTAssertEqual(connection()?.pad(for: "a")?.number, 0)
        XCTAssertEqual(launches(), 2, "the retry is the same session reopened, never one attempt per binding")
    }

    func testTheSessionIsReprobedBeforeItOpensAndAReplacedHostIsNotLaunched() async {
        gateway.answerPlain("/serverinfo", .init(status: 200, body: Self.pairedInfo.replacingOccurrences(of: "abc", with: "zzz")))
        await bind("a")
        XCTAssertEqual(launches(), 0)
        XCTAssertEqual(connection()?.phase, .failed(.hostReplaced))
        XCTAssertEqual(seen, [.hostReplaced(host)])
        XCTAssertEqual(connection()?.padCount, 1, "the binding is durable intent")
    }

    func testAHostThatStoppedTrustingThisDeviceIsNotLaunched() async {
        gateway.answerSecure("/serverinfo", .init(status: 401, body: ""))
        await bind("a")
        XCTAssertEqual(launches(), 0)
        XCTAssertEqual(connection()?.phase, .failed(.trustLost))
        XCTAssertEqual(seen, [], "the row shows the verdict; nothing more is said")
    }

    func testAHostThatAnswersNothingKeepsItsBindingsAndOpensNoSession() async {
        gateway.answerPlain("/serverinfo", .unreachable)
        await bind("a")
        XCTAssertEqual(connection()?.padCount, 1)
        XCTAssertEqual(launches(), 0)
        XCTAssertEqual(gateway.count(.secure, "/serverinfo"), 0, "a host that will not answer plaintext is never asked over mutual TLS")
        XCTAssertEqual(connection()?.phase, .failed(.unreachable))
    }

    func testASessionAnotherDeviceHoldsIsReportedBusyAndNeverResumed() async {
        gateway.answerSecure("/launch", .init(
            status: 200,
            body: "<root status_code=\"400\" status_message=\"An app is already running on this host\"><resume>0</resume></root>"
        ))
        await bind("a")
        XCTAssertEqual(seen, [.appAlreadyRunning(host: host, resumable: false)])
        XCTAssertEqual(resumes(), 0)
        XCTAssertEqual(connection()?.padCount, 1, "the pad stays claimed; the offer to close that app is the way out")
        XCTAssertEqual(cancels(), 0)
    }

    func testAResumeTheHostOffersIsTakenSilentlyAndOneItRefusesIsARejoinFailure() async {
        let busy = "<root status_code=\"400\" status_message=\"An app is already running on this host\"><resume>1</resume></root>"
        gateway.answerSecure("/launch", .init(status: 200, body: busy))
        gateway.answerSecure("/resume", .init(status: 200, body: Self.launchOk))
        await bind("a")
        XCTAssertEqual(resumes(), 1)
        XCTAssertEqual(connection()?.phase, .streaming)
        XCTAssertEqual(seen, [], "resume=1 means the running session is ours; nothing is asked")
        let resume = gateway.queries("/resume").first ?? ""
        XCTAssertTrue(resume.contains("rikey=42424242"), "the same key the launch minted")
        XCTAssertFalse(resume.contains("appid="))
        gateway.answerSecure("/resume", .init(status: 200, body: "<root status_code=\"400\" status_message=\"no session\"/>"))
        manager.applyDesired([:])
        await manager.awaitQuiet()
        seen.removeAll()
        await bind("a")
        XCTAssertEqual(seen, [.rejoinRefused(host)])
        XCTAssertEqual(connection()?.phase, .failed(.resumeFailed))
    }

    func testAnyOtherRefusalCarriesTheHostsOwnWording() async {
        refuseLaunch()
        await bind("a")
        XCTAssertEqual(seen, [.launchRefused(host: host, message: "Unauthorized")])
        XCTAssertEqual(cancels(), 0)
        XCTAssertEqual(connection()?.phase, .failed(.launchRejected))
    }

    func testALaunchRefusedInTheStatusLineIsARefusalNotAStream() async {
        gateway.answerSecure("/launch", .init(status: 400, body: "<root status_code=\"400\"/>"))
        await bind("a")
        XCTAssertEqual(seen, [.launchRefused(host: host, message: "")], "Wolf refuses in the status line with no wording of its own")
        XCTAssertEqual(cancels(), 0)
    }

    func testALaunchThatSucceedsAndAStreamThatDoesNotIsCancelledAgain() async {
        edges.rtspOk = false
        await bind("a")
        XCTAssertEqual(seen, [.setupFailed(host)])
        XCTAssertEqual(cancels(), 1, "the host started an app on our behalf, so it is taken back down")
        XCTAssertEqual(connection()?.phase, .failed(.rtspRejected))
        XCTAssertEqual(edges.rtspClients.first?.steps, [.options], "it stopped at the first refused step")
        edges.rtspOk = true
        edges.controlConnects = false
        seen.removeAll()
        manager.retrySessions()
        await manager.awaitQuiet()
        XCTAssertEqual(seen, [.setupFailed(host)])
        XCTAssertEqual(cancels(), 2)
        XCTAssertEqual(connection()?.phase, .failed(.controlLost))
        XCTAssertEqual(edges.rtspClients.last?.steps, MoonlightRtspStep.allCases, "every step, in order")
    }

    func testAFifthPadIsReportedFullRatherThanSilentlyDropped() async {
        await bind("a", "b", "c", "d", "e")
        XCTAssertEqual(connection()?.padCount, 4)
        XCTAssertTrue(seen.contains(.hostFull(host)))
    }

    func testRetryingAndQuittingTheApp() async {
        refuseLaunch()
        await bind("a")
        manager.retrySessions()
        await manager.awaitQuiet()
        XCTAssertEqual(launches(), 2, "a retry re-attempts what the bindings already asked for")
        XCTAssertEqual(cancels(), 0)
        seen.removeAll()
        manager.quitHostApp(host)
        await manager.awaitQuiet()
        XCTAssertEqual(connection()?.padCount, 0)
        XCTAssertEqual(cancels(), 1)
        XCTAssertEqual(seen, [.appCloseRequested(host)])
    }

    func testTheAppPickedForTheHostIsLaunchedAndARemovedPickLaunchesNothing() async {
        gateway.answerSecure("/applist", .init(status: 200, body: Self.twoApps))
        rememberPaired(appId: "2", appName: "Steam")
        await bind("a")
        XCTAssertTrue(gateway.queries("/launch").first?.contains("appid=2") ?? false)
        manager.applyDesired([:])
        await manager.awaitQuiet()
        rememberPaired(appId: "9", appName: "Removed")
        seen.removeAll()
        await bind("a")
        XCTAssertEqual(launches(), 1, "nothing launched for a pick the host no longer lists")
        XCTAssertEqual(seen, [.appRemoved(host: host, appName: "Removed")])
        XCTAssertEqual(store.host(id: host.id)?.lastAppId, "9", "the pick is the user's to change, not the probe's")
        XCTAssertEqual(connection()?.phase, .failed(.appRemoved))
    }

    func testAPickIsLaunchedWhenTheListCannotBeReadAndTheFirstAppWhenNonePickedAndNoneIsReported() async {
        gateway.answerSecure("/applist", .init(status: 401, body: ""))
        rememberPaired(appId: "9", appName: "Kept")
        await bind("a")
        XCTAssertTrue(gateway.queries("/launch").first?.contains("appid=9") ?? false, "an unreadable list says nothing about the pick")
        manager.applyDesired([:])
        await manager.awaitQuiet()
        gateway.answerSecure("/applist", .init(status: 200, body: Self.twoApps))
        rememberPaired(appId: "", appName: "")
        await bind("a")
        XCTAssertTrue(gateway.queries("/launch").last?.contains("appid=1") ?? false, "no pick: the first app the host lists")
        manager.applyDesired([:])
        await manager.awaitQuiet()
        XCTAssertEqual(store.host(id: host.id)?.lastAppId, "1", "the session recorded the app it settled on")
        gateway.answerSecure("/applist", .init(status: 200, body: "<root status_code=\"200\"></root>"))
        rememberPaired(appId: "", appName: "")
        seen.removeAll()
        await bind("a")
        XCTAssertEqual(seen, [.noAppsAvailable(host)])
        XCTAssertEqual(launches(), 2)
    }

    func testAControlLinkThatDropsLeavesTheAppRunningAndKeepsThePad() async {
        await bind("a")
        edges.onClosed?()
        let dropped = await waitUntil { [weak self] in self?.connection()?.phase == .failed(.dropped) }
        XCTAssertTrue(dropped)
        XCTAssertEqual(cancels(), 0, "a drop is as likely a blip as an end")
        XCTAssertEqual(connection()?.padCount, 1)
        XCTAssertFalse(seen.contains(.endedByHost(host)))
        XCTAssertEqual(manager.sessionHostIds, [host.id], "the binding still holds the host")
    }

    func testAHostEndedSessionIsReportedAndTheNextUseStartsANewOne() async {
        await bind("a")
        edges.onEvent?(.termination(reason: 0x8003_0023))
        let ended = await waitUntil { [weak self] in self?.connection()?.phase == .failed(.hostEnded) }
        XCTAssertTrue(ended)
        XCTAssertEqual(seen, [.endedByHost(host)])
        XCTAssertEqual(cancels(), 0)
        XCTAssertEqual(connection()?.padCount, 1)
        manager.retrySessions()
        await manager.awaitQuiet()
        XCTAssertEqual(launches(), 2, "a new session, not a resume")
        XCTAssertEqual(resumes(), 0)
        XCTAssertEqual(connection()?.phase, .streaming)
    }

    func testTheLiveLinksEventsReachTheConnection() async {
        await bind("a")
        let heard = LockedBox<[MoonlightEvent]>([])
        connection()?.setFeedbackHandler { event in heard.mutate { $0.append(event) } }
        edges.onEvent?(.rumble(controller: 0, low: 1, high: 2))
        edges.onEvent?(.motionRequest(controller: 0, rateHz: 100, type: MoonlightMotionType.gyro))
        XCTAssertEqual(heard.get(), [.rumble(controller: 0, low: 1, high: 2)])
        XCTAssertEqual(connection()?.link.motionWanted("a"), true)
    }
}
