// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore
@testable import DishEngine

/// The connection object: the reducer's steps and their effects, the pads
/// published as they come and go, a session adopted with its clock and torn
/// down, and the link's own events (the host's goodbye, a dead link) raised
/// into the lifecycle while feedback goes to its handler.
@MainActor
final class MoonlightConnectionTests: XCTestCase {

    private let xbox = MoonlightAnnouncedPad(type: MoonlightControllerType.xbox, capabilities: 0x03, supportedButtons: 0xF7FF)
    private let playStation = MoonlightAnnouncedPad(
        type: MoonlightControllerType.playStation,
        capabilities: 0xFF,
        supportedButtons: 0x10F7FF
    )

    private func connection() -> MoonlightConnection {
        MoonlightConnection(id: "moonlight:10.0.0.5", host: MoonlightHost(name: "PC", address: "10.0.0.5"))
    }

    /// Every step from idle to the live stream, as the manager would drive it.
    private func stream(_ conn: MoonlightConnection) {
        _ = conn.apply(.startRequested)
        _ = conn.apply(.serverInfoOk(paired: true, currentGame: 0, remembered: false, identityChanged: false))
        _ = conn.apply(.launchOk)
        _ = conn.apply(.rtspReady)
        for _ in MoonlightRtspStep.allCases {
            _ = conn.apply(.rtspStepOk)
        }
        _ = conn.apply(.controlConnected)
        XCTAssertEqual(conn.phase, .streaming)
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0 ..< 100 where !predicate() {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    func testTheLifecycleStepsThroughTheReducerAndHandsBackTheEffects() {
        let conn = connection()
        XCTAssertEqual(conn.phase, .idle)
        XCTAssertFalse(conn.hasSession)
        XCTAssertEqual(conn.apply(.startRequested), [.fetchServerInfo])
        XCTAssertEqual(conn.phase, .checkingInfo)
        XCTAssertTrue(conn.hasSession, "a converge waits on a session coming up instead of opening a second")
        XCTAssertEqual(conn.apply(.launchOk), [], "a stray completion is ignored")
        XCTAssertEqual(conn.phase, .checkingInfo)
        XCTAssertEqual(conn.apply(.serverInfoOk(paired: true, currentGame: 42, remembered: true, identityChanged: false)), [.sendLaunch])
        XCTAssertEqual(conn.machine, MoonlightSessionMachineState(phase: .launching, resuming: true))
        XCTAssertEqual(conn.apply(.stopRequested), [.teardown])
        XCTAssertEqual(conn.phase, .idle)
    }

    func testPadsPublishAsTheyComeAndGo() {
        let conn = connection()
        XCTAssertEqual(conn.acquirePad("a", as: xbox)?.number, 0)
        XCTAssertEqual(conn.acquirePad("b", as: xbox)?.number, 1)
        XCTAssertEqual(conn.pads.map(\.slotId), ["a", "b"])
        XCTAssertEqual(conn.padCount, 2)
        XCTAssertTrue(conn.hasRoom)
        XCTAssertEqual(conn.releasePad("a"), 1)
        XCTAssertEqual(conn.pads.map(\.number), [1])
        XCTAssertEqual(conn.reannouncePad("b", as: playStation)?.announced, playStation)
        XCTAssertEqual(conn.pads.first?.announced, playStation)
        XCTAssertEqual(conn.pad(for: "b")?.number, 1)
        XCTAssertNil(conn.pad(for: "a"))
    }

    func testAdoptAnnouncesThePadsStartsTheClockAndTeardownStopsEverything() async {
        let conn = connection()
        _ = conn.acquirePad("a", as: xbox)
        let live = RecordingLiveSession()
        XCTAssertNil(conn.controlRoundTripMs)
        conn.adopt(session: live, pinger: nil, appId: "7", appName: "Desktop")
        XCTAssertEqual(conn.sessionAppId, "7")
        XCTAssertEqual(conn.sessionAppName, "Desktop")
        XCTAssertEqual(conn.controlRoundTripMs, 7)
        XCTAssertEqual(live.sent.count, 2, "the pad announced, at rest")
        XCTAssertTrue(conn.link.isLive)
        let ticking = await waitUntil { live.ticks >= 2 }
        XCTAssertTrue(ticking, "the clock ticks the session")
        conn.teardown()
        XCTAssertTrue(live.stopped)
        XCTAssertFalse(conn.link.isLive)
        XCTAssertEqual(conn.padCount, 1, "the pads stay claimed by their bindings")
        XCTAssertNil(conn.controlRoundTripMs)
        let after = live.ticks
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(live.ticks, after, "the clock stopped")
    }

    func testTheHostsGoodbyeEndsTheSessionThroughTheReducer() async {
        let conn = connection()
        stream(conn)
        let effects = LockedBox<[MoonlightSessionEffect]>([])
        conn.setEffectsRunner { ran in effects.mutate { $0 += ran } }
        conn.receive(.termination(reason: 0x8003_0023))
        let ended = await waitUntil { conn.phase == .failed(.hostEnded) }
        XCTAssertTrue(ended)
        XCTAssertEqual(effects.get(), [.teardown, .notifyFailure])
    }

    func testADeadLinkIsADropUnderALiveSessionAndNothingWhileIdle() async {
        let idle = connection()
        let ran = LockedBox(0)
        idle.setEffectsRunner { _ in ran.mutate { $0 += 1 } }
        idle.linkClosed()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(idle.phase, .idle)
        XCTAssertEqual(ran.get(), 0, "an idle session has no link to lose")
        let live = connection()
        stream(live)
        live.setEffectsRunner { _ in ran.mutate { $0 += 1 } }
        live.linkClosed()
        let dropped = await waitUntil { live.phase == .failed(.dropped) }
        XCTAssertTrue(dropped, "the host usually lets a drop resume")
        XCTAssertEqual(ran.get(), 1)
    }

    func testMotionRequestsAreTheLinksAndTheRestIsFeedback() {
        let conn = connection()
        _ = conn.acquirePad("a", as: playStation)
        let seen = LockedBox<[MoonlightEvent]>([])
        conn.setFeedbackHandler { event in seen.mutate { $0.append(event) } }
        conn.receive(.motionRequest(controller: 0, rateHz: 100, type: MoonlightMotionType.gyro))
        XCTAssertTrue(conn.link.motionWanted("a"))
        conn.receive(.rumble(controller: 0, low: 1, high: 2))
        conn.receive(.rumbleTriggers(controller: 0, left: 3, right: 4))
        conn.receive(.rgbLed(controller: 0, red: 5, green: 6, blue: 7))
        conn.receive(.unknown(type: 0x0200))
        XCTAssertEqual(
            seen.get(),
            [
                .rumble(controller: 0, low: 1, high: 2),
                .rumbleTriggers(controller: 0, left: 3, right: 4),
                .rgbLed(controller: 0, red: 5, green: 6, blue: 7)
            ]
        )
    }
}
