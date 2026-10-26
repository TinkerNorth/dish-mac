// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import DishKernel
import Foundation

/// The transport the checker fetches the manifest through. A test supplies
/// a scripted one.
protocol ManifestGateway: AnyObject {
    func fetchManifest() async -> Result<Data, UpdateError>
}

/// GET of the release permalink; any transport failure or non-200 is `.http`.
final class URLSessionManifestGateway: ManifestGateway {
    private let session: URLSession
    private let url: URL

    init(session: URLSession = .shared, url: URL) {
        self.session = session
        self.url = url
    }

    func fetchManifest() async -> Result<Data, UpdateError> {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return .failure(.http) }
        return .success(data)
    }
}

/// A notice the app words: the engine never vends a sentence.
package struct UpdateNoticeEvent: Equatable {
    package let notice: UpdateNotice
    package let version: String
}

/// How long the first check waits after a launch: the usual startup delay,
/// or the rest of the minimum gap since the last completed check, so a
/// relaunch loop cannot hammer the permalink. A last check in the future
/// (a clock that stepped back) reads as due.
func startupCheckDelayMs(lastCheckMs: Int64, nowMs: Int64) -> Int {
    let elapsed = nowMs - lastCheckMs
    if lastCheckMs <= 0 || elapsed < 0 || elapsed >= UpdateSchedule.minCheckGapMs {
        return UpdateSchedule.startupDelayMs
    }
    return Int(UpdateSchedule.minCheckGapMs - elapsed)
}

/// Drives `reduceUpdate` over the manifest gateway and a schedule. The
/// reachable phases stop at `available`: the Mac client never installs its
/// own update, the UI links out.
@MainActor
package final class UpdateChecker: StateSource<UpdateStatus> {

    /// Edge-detected, at most once per version per session.
    package let notices = PassthroughSubject<UpdateNoticeEvent, Never>()
    /// The last completed check against the time, for the words that say when.
    let clock: UpdateCheckClock

    private let preferences: UpdatePreferenceStore
    private let gateway: ManifestGateway
    private let now: () -> Int64
    private var prefsSubscription: AnyCancellable?
    private var pendingCheck: Task<Void, Never>?
    private(set) var pendingCheckDelayMs: Int?
    private var pendingTrigger = UpdateTrigger.startup
    private var fetch: Task<Void, Never>?
    private var lastManualMs: Int64 = 0
    private var announced: Set<String> = []
    private var started = false

    init(
        preferences: UpdatePreferenceStore,
        gateway: ManifestGateway,
        currentVersion: String,
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.preferences = preferences
        self.gateway = gateway
        self.now = now
        clock = UpdateCheckClock(lastCheckMs: { preferences.lastCheckMs }, now: now)
        super.init(initial: UpdateStatus(phase: .idle, currentVersion: currentVersion, checksEnabled: preferences.state.checksEnabled))
    }

    package var lastCheckMs: Int64 {
        preferences.lastCheckMs
    }

    /// Arms the startup schedule once; a second call is ignored. The kernel's
    /// lifecycle hooks are not isolated; the checker is driven from the main
    /// actor, where its callers already are.
    override package func start() {
        MainActor.assumeIsolated { startOnMain() }
    }

    override package func stop() {
        MainActor.assumeIsolated { stopOnMain() }
    }

    private func startOnMain() {
        guard !started else { return }
        started = true
        prefsSubscription = preferences.statePublisher.sink { [weak self] prefs in
            self?.dispatch(.prefsChanged(checksEnabled: prefs.checksEnabled, skippedVersion: prefs.skippedVersion))
        }
        if state.checksEnabled {
            schedule(delayMs: startupCheckDelayMs(lastCheckMs: preferences.lastCheckMs, nowMs: now()), trigger: .startup)
        }
    }

    private func stopOnMain() {
        pendingCheck?.cancel()
        pendingCheck = nil
        pendingCheckDelayMs = nil
        fetch?.cancel()
        fetch = nil
        prefsSubscription = nil
    }

    /// Bypasses the interval and the backoff, rate-limited so a held-down
    /// button cannot hammer the permalink.
    package func checkNow() {
        let at = now()
        guard at - lastManualMs >= UpdateSchedule.manualMinGapMs else { return }
        lastManualMs = at
        dispatch(.checkRequested(.manual))
    }

    /// Mutes the offered version until the manifest offers a newer one.
    package func skipAvailableVersion() {
        let version = state.availableVersion
        guard !version.isEmpty else { return }
        preferences.setSkippedVersion(version)
        dispatch(.skipRequested(version: version))
    }

    package func setOnline(_ online: Bool) {
        dispatch(.reachabilityChanged(online: online))
    }

    /// Runs the armed check now; the seam the schedule tests drive.
    func firePendingCheck() {
        pendingCheck?.cancel()
        pendingCheck = nil
        pendingCheckDelayMs = nil
        dispatch(.checkRequested(pendingTrigger))
    }

    // MARK: - The loop

    private func dispatch(_ event: UpdateEvent) {
        let reduction = reduceUpdate(state, event)
        setState(reduction.next)
        for effect in reduction.effects {
            execute(effect)
        }
    }

    private func execute(_ effect: UpdateEffect) {
        switch effect {
        case let .fetchManifest(manual):
            startFetch(manual: manual)
        case let .scheduleNextCheck(delayMs):
            schedule(delayMs: delayMs, trigger: state.phase == .failed ? .retry : .periodic)
        case .persistLastCheck:
            preferences.setLastCheckMs(now())
            clock.refresh()
        case let .notify(notice, version):
            announce(notice, version: version)
        }
    }

    private func startFetch(manual _: Bool) {
        fetch?.cancel()
        fetch = Task { [weak self] in
            guard let self else { return }
            let result = await gateway.fetchManifest()
            guard !Task.isCancelled else { return }
            arrived(result)
        }
    }

    private func arrived(_ result: Result<Data, UpdateError>) {
        switch result {
        case let .success(body):
            switch UpdateManifest.parse(body) {
            case let .success(manifest): dispatch(.manifestArrived(manifest))
            case .failure: dispatch(.checkFailed(.manifestInvalid))
            }
        case let .failure(error):
            dispatch(.checkFailed(error))
        }
    }

    /// Re-scheduling supersedes the armed check. Checks are off: nothing is
    /// armed, so no timer survives a disable.
    private func schedule(delayMs: Int, trigger: UpdateTrigger) {
        pendingCheck?.cancel()
        guard state.checksEnabled else {
            pendingCheckDelayMs = nil
            return
        }
        pendingCheckDelayMs = delayMs
        pendingTrigger = trigger
        pendingCheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delayMs, 0)) * 1_000_000)
            guard !Task.isCancelled, let self else { return }
            pendingCheckDelayMs = nil
            dispatch(.checkRequested(trigger))
        }
    }

    private func announce(_ notice: UpdateNotice, version: String) {
        let key = "\(notice)-\(version)"
        guard announced.insert(key).inserted else { return }
        notices.send(UpdateNoticeEvent(notice: notice, version: version))
    }
}
