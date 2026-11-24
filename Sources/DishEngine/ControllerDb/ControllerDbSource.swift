// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The controller data in force and its check against the website: the
// bundled copy, or the cached download when it is newer; a check ten
// seconds after launch and every six hours while the app runs, or when
// asked; nothing at all while the switch is off. The decisions are the
// core's (`controllerDbGate`, `manifestStep`, `installStep`); this source
// performs the requests they name, swaps the cache whole and says what
// happened.

import Combine
import DishCore
import DishKernel
import Foundation

@MainActor
package final class ControllerDbSource: StateSource<ControllerDbStatus> {

    /// The index the Direct path and Diagnostics read.
    package let index: StateSource<ControllerIndex>

    private let bundled: ControllerDbSet
    private let cache: ControllerDbCache
    private let gateway: ControllerDbGateway
    private let preferences: ControllerDbPreferenceStore
    private let now: () -> Int64
    private var pendingCheck: Task<Void, Never>?
    private(set) var pendingCheckDelayMs: Int?
    private var running: Task<Void, Never>?
    private var started = false
    private var prefsSubscription: AnyCancellable?

    init(
        bundled: ControllerDbSet,
        cache: ControllerDbCache,
        gateway: ControllerDbGateway,
        preferences: ControllerDbPreferenceStore,
        now: @escaping () -> Int64 = { wallClockMs() }
    ) {
        self.bundled = bundled
        self.cache = cache
        self.gateway = gateway
        self.preferences = preferences
        self.now = now
        let active = activeControllerIndex(bundled: bundled, cached: cache.load())
        index = StateSource(initial: active)
        super.init(initial: ControllerDbStatus(
            bundledVersion: bundled.dbVersion,
            activeVersion: active.dbVersion,
            source: active.source,
            checksEnabled: preferences.state,
            lastCheckAtMs: preferences.lastCheckMs,
            lastCheckResult: preferences.lastResult
        ))
    }

    /// Arms the first check; a second call is ignored.
    override package func start() {
        MainActor.assumeIsolated { startOnMain() }
    }

    override package func stop() {
        MainActor.assumeIsolated {
            pendingCheck?.cancel()
            pendingCheck = nil
            pendingCheckDelayMs = nil
            running?.cancel()
            running = nil
            prefsSubscription = nil
        }
    }

    private func startOnMain() {
        guard !started else { return }
        started = true
        prefsSubscription = preferences.statePublisher.dropFirst().sink { [weak self] enabled in self?.switchChanged(enabled) }
        schedule(delayMs: ControllerDbSchedule.firstCheckDelayMs)
    }

    /// One check now, whatever the schedule; with the switch off it records
    /// `off` and sends nothing.
    package func checkNow() {
        runCheck()
    }

    /// Runs the armed check now: the seam the schedule tests drive.
    func firePendingCheck() {
        pendingCheck?.cancel()
        pendingCheck = nil
        pendingCheckDelayMs = nil
        runCheck()
        schedule(delayMs: ControllerDbSchedule.intervalMs)
    }

    /// The check in flight, for a test to wait on.
    func settle() async {
        await running?.value
    }

    private func switchChanged(_ enabled: Bool) {
        updateState { var next = $0
            next.checksEnabled = enabled
            return next
        }
        guard enabled else {
            pendingCheck?.cancel()
            pendingCheck = nil
            pendingCheckDelayMs = nil
            return
        }
        if pendingCheck == nil {
            schedule(delayMs: ControllerDbSchedule.firstCheckDelayMs, enabled: enabled)
        }
    }

    /// Nothing is armed with the switch off, so no timer survives a disable.
    /// A change hands in the emitted value: `@Published` delivers before
    /// the store's own state lands.
    private func schedule(delayMs: Int, enabled: Bool? = nil) {
        pendingCheck?.cancel()
        guard enabled ?? preferences.state else {
            pendingCheck = nil
            pendingCheckDelayMs = nil
            return
        }
        pendingCheckDelayMs = delayMs
        pendingCheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delayMs, 0)) * 1_000_000)
            guard !Task.isCancelled, let self else { return }
            firePendingCheck()
        }
    }

    // MARK: - One check

    private func runCheck() {
        switch controllerDbGate(checksEnabled: preferences.state) {
        case let .stay(result): finish(result)
        case .ask: startAsking()
        }
    }

    private func startAsking() {
        guard running == nil else { return }
        updateState { var next = $0
            next.checking = true
            return next
        }
        running = Task { [weak self] in
            guard let self else { return }
            let result = await ask()
            running = nil
            finish(result)
        }
    }

    private func ask() async -> ControllerDbCheckResult {
        let reply = await gateway.fetchManifest(etag: preferences.etag)
        switch manifestStep(reply, activeVersion: index.state.dbVersion) {
        case let .done(result):
            if case let .body(_, etag) = reply, result == .upToDate {
                preferences.setEtag(etag)
            }
            return result
        case let .download(manifest):
            return await download(manifest, served: servedManifest(reply))
        }
    }

    private func download(_ manifest: ControllerDbManifest, served: ServedManifest) async -> ControllerDbCheckResult {
        let files = await fetchAll(manifest)
        switch installStep(manifest: manifest, files: files) {
        case let .done(result):
            return result
        case let .install(set, files: fetched):
            return install(set, files: fetched, served: served)
        }
    }

    /// Every file the manifest names, or nil when one did not arrive.
    private func fetchAll(_ manifest: ControllerDbManifest) async -> [String: Data]? {
        var files: [String: Data] = [:]
        for path in manifest.files.keys.sorted() {
            guard let data = await gateway.fetchFile(path) else { return nil }
            files[path] = data
        }
        return files
    }

    /// The manifest's own bytes are stored with the files it vouches for,
    /// so the cache verifies itself as it loads.
    private func install(_ set: ControllerDbSet, files: [String: Data], served: ServedManifest) -> ControllerDbCheckResult {
        var stored = files
        stored[ControllerDbFiles.manifest] = served.body
        guard cache.replaceAll(stored) else { return .invalid }
        preferences.setEtag(served.etag)
        index.setState(activeControllerIndex(bundled: bundled, cached: set))
        return .updated
    }

    private func finish(_ result: ControllerDbCheckResult) {
        let at = now()
        preferences.recordCheck(result, atMs: at)
        let active = index.state
        updateState { var next = $0
            next.checking = false
            next.lastCheckAtMs = at
            next.lastCheckResult = result
            next.activeVersion = active.dbVersion
            next.source = active.source
            return next
        }
    }
}

/// The manifest as the website served it.
private struct ServedManifest {
    let body: Data
    let etag: String?
}

private func servedManifest(_ reply: ManifestReply) -> ServedManifest {
    guard case let .body(body, etag) = reply else { return ServedManifest(body: Data(), etag: nil) }
    return ServedManifest(body: body, etag: etag)
}
