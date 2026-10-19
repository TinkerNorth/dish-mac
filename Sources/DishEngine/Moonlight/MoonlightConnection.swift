// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// One Moonlight host as the dish holds it, the sibling of WifiConnection:
// the session's lifecycle as the pure reducer's state, the pads the
// bindings put on it, and the live session with its clocks. The manager
// owns pairing and launch and runs the reducer's effects; this owns the
// pads and the hot path. ONE SESSION PER HOST, reference counted by the
// bindings pointing at it: a Moonlight session carries up to four pads on
// one stream, so the first binding starts it, later bindings only announce
// their own pad, and the last unbind is what tears it down.

import Combine
import DishCore
import Foundation

/// The live session as the connection drives it: the control session in production.
protocol MoonlightLiveSession: MoonlightPadSending {
    var roundTripMs: Int64? { get }
    var linkReport: String { get }
    func tick()
    func stop()
}

extension MoonlightControlSession: MoonlightLiveSession {}

@MainActor
final class MoonlightConnection: ObservableObject, Identifiable {
    /// ENet's retransmits and pings, and the protocol's own keepalive, are
    /// paced from this clock.
    static let tickIntervalMs = 50

    let id: String
    @Published private(set) var host: MoonlightHost
    @Published private(set) var machine = MoonlightSessionMachineState()
    @Published private(set) var pads: [MoonlightPadTable.Pad] = []
    /// The app the session settled on, so a later binding can say what it
    /// is joining instead of guessing from the remembered pick.
    @Published private(set) var sessionAppId: String?
    @Published private(set) var sessionAppName: String?
    /// The hot path, read on the controller threads.
    nonisolated let link: MoonlightPadLink

    /// Rumble, trigger rumble and the lamp for the pad a host event names;
    /// installed from the main actor, called on the transport's queue.
    private let feedbackHandler = LockedBox<((MoonlightEvent) -> Void)?>(nil)
    /// Runs the effects of an event the link raised itself: the host's
    /// goodbye, a dead link.
    private var effectsRunner: (([MoonlightSessionEffect]) -> Void)?
    private var session: MoonlightLiveSession?
    private var pinger: MoonlightMediaPinger?
    private var ticker: DispatchSourceTimer?
    private let tickQueue = DispatchQueue(label: "dish.moonlight.tick", qos: .userInteractive)

    init(id: String, host: MoonlightHost, link: MoonlightPadLink = MoonlightPadLink()) {
        self.id = id
        self.host = host
        self.link = link
    }

    var phase: MoonlightSessionPhase {
        machine.phase
    }

    var isStreaming: Bool {
        machine.phase == .streaming
    }

    /// A session being brought up or live: a converge waits or announces,
    /// never opens a second.
    var hasSession: Bool {
        !moonlightSessionNeedsStart(machine.phase)
    }

    var padCount: Int {
        link.count
    }

    var hasRoom: Bool {
        !link.isFull
    }

    var controlRoundTripMs: Int64? {
        session?.roundTripMs
    }

    func updateHost(_ host: MoonlightHost) {
        self.host = host
    }

    func setFeedbackHandler(_ handler: @escaping (MoonlightEvent) -> Void) {
        feedbackHandler.set(handler)
    }

    func setEffectsRunner(_ runner: @escaping ([MoonlightSessionEffect]) -> Void) {
        effectsRunner = runner
    }

    // MARK: - The lifecycle

    /// One step of the session's lifecycle; the effects are the manager's to
    /// run. The reducer ignores a stray late completion, so a phase is never
    /// corrupted by one.
    func apply(_ event: MoonlightSessionEvent) -> [MoonlightSessionEffect] {
        let reduction = reduceMoonlightSession(machine, event)
        guard let next = reduction.next else { return [] }
        machine = next
        return reduction.effects
    }

    /// The `startStreaming` effect: the connected session adopted, every
    /// pad announced on it at rest, its clocks ticking, the media pings
    /// running on.
    func adopt(session: MoonlightLiveSession, pinger: MoonlightMediaPinger?, appId: String?, appName: String?) {
        self.session = session
        self.pinger = pinger
        sessionAppId = appId
        sessionAppName = appName
        link.install(session)
        startTicking(session)
    }

    /// The `sendTermination` effect: the session is told it is ending.
    func sendTermination() {
        session?.stop()
    }

    /// The `teardown` effect: the clocks and the pings stopped, the session
    /// stopped and forgotten, the host-side pad state forgotten. The pads
    /// stay claimed by their bindings.
    func teardown() {
        ticker?.cancel()
        ticker = nil
        pinger?.stop()
        pinger = nil
        session?.stop()
        session = nil
        link.clear()
    }

    // MARK: - Pads

    func acquirePad(_ slotId: String, as wanted: MoonlightAnnouncedPad) -> MoonlightPadTable.Pad? {
        defer { pads = link.pads }
        return link.acquire(slotId, as: wanted)
    }

    /// Drop the slot's pad and report how many remain.
    func releasePad(_ slotId: String) -> Int {
        defer { pads = link.pads }
        return link.release(slotId)
    }

    func reannouncePad(_ slotId: String, as wanted: MoonlightAnnouncedPad) -> MoonlightPadTable.Pad? {
        defer { pads = link.pads }
        return link.reannounce(slotId, as: wanted)
    }

    func pad(for slotId: String) -> MoonlightPadTable.Pad? {
        link.pad(for: slotId)
    }

    // MARK: - From the link's queues

    /// What the host says on the control stream, on the transport's queue:
    /// a motion request is the link's, a termination the lifecycle's, the
    /// rest is feedback for a pad.
    nonisolated func receive(_ event: MoonlightEvent) {
        switch event {
        case let .motionRequest(controller, rateHz, type):
            link.onMotionRequest(controller: controller, rateHz: rateHz, type: type)
        case .termination:
            Task { @MainActor in self.linkEvent(.hostTerminated) }
        case .rumble, .rumbleTriggers, .rgbLed:
            feedbackHandler.get()?(event)
        case .unknown:
            break
        }
    }

    /// The link died: a drop under a live session, which the host usually
    /// lets resume; a refusal while it was coming up.
    nonisolated func linkClosed() {
        Task { @MainActor in self.linkEvent(.controlLost) }
    }

    private func linkEvent(_ event: MoonlightSessionEvent) {
        let effects = apply(event)
        if !effects.isEmpty { effectsRunner?(effects) }
    }

    private func startTicking(_ session: MoonlightLiveSession) {
        ticker?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: tickQueue)
        timer.schedule(
            deadline: .now() + .milliseconds(Self.tickIntervalMs),
            repeating: .milliseconds(Self.tickIntervalMs),
            leeway: .milliseconds(5)
        )
        timer.setEventHandler { session.tick() }
        ticker = timer
        timer.resume()
    }
}
