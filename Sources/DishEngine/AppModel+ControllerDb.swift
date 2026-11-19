// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The controller data and the diagnostics bundle as the pages reach them:
// the switch and "Check now", the person's answer after a test, and the
// bundle written for their own mail app. Nothing here sends anything.

import Combine
import DishCore
import Foundation

package extension AppModel {

    func setControllerUpdatesEnabled(_ enabled: Bool) {
        controllerDbPreferences.setChecksEnabled(enabled)
    }

    func checkControllerUpdatesNow() {
        controllerDb.checkNow()
    }

    /// "Did it work?" answered for the test the pad ran last.
    func answerTestOutcome(slotId: String, worked: Bool) {
        outcomes.answer(slotId: slotId, worked: worked)
    }

    /// The bundle's bytes as of now, the support capture riding the pad it
    /// was taken of.
    func diagnosticsBundleData(atMs: Int64) -> Data {
        diagnosticsBundleJSON(diagnosticsBundleFacts(bundleInputs(atMs: atMs)))
    }

    /// The bundle written to a fresh temporary folder under its contract
    /// name, for the mail app to attach; nil when the disk refused it.
    func writeDiagnosticsBundle() -> URL? {
        let atMs = wallClockMs()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dish-diagnostics-\(UUID().uuidString)")
        let file = folder.appendingPathComponent(diagnosticsBundleFileName(app: BundleIdentity.appName, atMs: atMs))
        let made = (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
        guard made else { return nil }
        let written = (try? diagnosticsBundleData(atMs: atMs).write(to: file, options: .atomic)) != nil
        return written ? file : nil
    }

    /// The mail's subject facts: the app's version and the Mac's model.
    var diagnosticsMailFacts: DiagnosticsMailFacts {
        DiagnosticsMailFacts(version: appVersion, model: machine.model)
    }
}

/// What the subject line names; the app words it.
package struct DiagnosticsMailFacts: Equatable {
    package let version: String
    package let model: String

    package init(version: String, model: String) {
        self.version = version
        self.model = model
    }
}

/// The bundle's `app` block for this client.
enum BundleIdentity {
    static let appName = "dish-mac"
    /// Every Mac build is the GitHub release's.
    static let flavor = "github"
}

extension AppModel {

    /// The data the app was built with, the cache and the website, or what
    /// a test hands in; a root built outside the app asks nobody.
    static func controllerDbSource(
        _ preferences: ControllerDbPreferenceStore,
        gateway: ControllerDbGateway?,
        cache: ControllerDbCache?
    ) -> ControllerDbSource {
        ControllerDbSource(
            bundled: BundledControllerDb.load() ?? BundledControllerDb.empty,
            cache: cache ?? ControllerDbCache(directory: scratchCacheDirectory()),
            gateway: gateway ?? OfflineControllerDbGateway(),
            preferences: preferences
        )
    }

    /// The website's controller data, read through URLSession.
    static func controllerDbClient() -> ControllerDbGateway {
        guard let base = URL(string: ControllerDbSchedule.baseURLString) else { return OfflineControllerDbGateway() }
        return ControllerDbHTTPClient(base: base)
    }

    /// A composition root built outside the app keeps its downloads to itself.
    private static func scratchCacheDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("dish-controller-db-\(UUID().uuidString)")
    }

    func bundleInputs(atMs: Int64) -> DiagnosticsBundleInputs {
        DiagnosticsBundleInputs(
            createdAtMs: atMs,
            app: BundleAppFacts(name: BundleIdentity.appName, version: appVersion, build: appVersion, flavor: BundleIdentity.flavor),
            machine: machine,
            snapshot: diagnostics.state,
            events: diagnosticsLog.state,
            outcomes: outcomes.state,
            capture: input.paths.support.lastFinished,
            hostVersions: wifi.capabilities.mapValues(\.serverVersion)
        )
    }

    /// The index follows the data in force into the Direct path and
    /// Diagnostics; the status and the answers into the shell's facts.
    func observeControllerDb() {
        diagnostics.useControllerData(
            index: { [weak self] in self?.controllerDb.index.state ?? ControllerIndex(BundledControllerDb.empty, source: .bundled) },
            status: { [weak self] in self?.controllerDb.state ?? ControllerDbStatus() }
        )
        controllerDb.index.statePublisher
            .sink { [weak self] index in self?.input.paths.useControllerIndex(index) }
            .store(in: &cancellables)
        controllerDb.statePublisher
            .sink { [weak self] status in self?.shellFacts.controllerDb = status }
            .store(in: &cancellables)
        outcomes.statePublisher
            .sink { [weak self] outcomes in self?.shellFacts.outcomes = outcomes }
            .store(in: &cancellables)
    }
}
