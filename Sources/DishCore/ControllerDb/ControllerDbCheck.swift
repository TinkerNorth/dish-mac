// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The check against the website (section 6.3 and 6.4), as decisions: when
// to ask, what the manifest's answer means, and what the downloaded files
// make of the cache. The engine performs the requests these name and
// nothing else; with the switch off it performs none.

import Foundation

/// The last check's result, in the bundle's and Diagnostics' words.
public enum ControllerDbCheckResult: String, CaseIterable, Equatable, Sendable {
    case upToDate
    case updated
    case offline
    case invalid
    case off
}

public enum ControllerDbSchedule {
    /// Ten seconds after launch.
    public static let firstCheckDelayMs = 10000
    /// Then every six hours while the app runs.
    public static let intervalMs = 6 * 60 * 60 * 1000
    public static let baseURLString = "https://dish.tinkernorth.com/controllers/v1/"
}

/// Whether a check may send anything.
public enum ControllerDbGate: Equatable, Sendable {
    case ask
    /// The switch is off: nothing leaves the Mac.
    case stay(ControllerDbCheckResult)
}

public func controllerDbGate(checksEnabled: Bool) -> ControllerDbGate {
    checksEnabled ? .ask : .stay(.off)
}

/// The manifest request's answer.
public enum ManifestReply: Equatable, Sendable {
    /// 304 to our `If-None-Match`.
    case notModified
    case body(Data, etag: String?)
    /// No answer, or a status that carries no manifest.
    case unreachable
}

public enum ManifestStep: Equatable, Sendable {
    case done(ControllerDbCheckResult)
    /// A newer version: fetch every file it names.
    case download(ControllerDbManifest)
}

/// 304 and a version no newer than the one in force are done; a body that
/// is not a schema 1 manifest is invalid.
public func manifestStep(_ reply: ManifestReply, activeVersion: Int) -> ManifestStep {
    switch reply {
    case .notModified: .done(.upToDate)
    case .unreachable: .done(.offline)
    case let .body(data, _): manifestBodyStep(data, activeVersion: activeVersion)
    }
}

private func manifestBodyStep(_ data: Data, activeVersion: Int) -> ManifestStep {
    guard case let .success(manifest) = decodeControllerDbManifest(data) else { return .done(.invalid) }
    guard manifest.dbVersion > activeVersion else { return .done(.upToDate) }
    return .download(manifest)
}

public enum InstallStep: Equatable, Sendable {
    case done(ControllerDbCheckResult)
    /// Swap the cache to these files, whole.
    case install(ControllerDbSet, files: [String: Data])
}

/// Files that did not all arrive are offline; files that arrived and do not
/// verify or parse are invalid; the previous cache stays either way.
public func installStep(manifest: ControllerDbManifest, files: [String: Data]?) -> InstallStep {
    guard let files else { return .done(.offline) }
    guard let set = verifiedControllerDbSet(manifest: manifest, files: files) else { return .done(.invalid) }
    return .install(set, files: files)
}

/// What the Settings row and Diagnostics show of the data.
public struct ControllerDbStatus: Equatable, Sendable {
    public var bundledVersion: Int
    public var activeVersion: Int
    public var source: ControllerDbOrigin
    public var checksEnabled: Bool
    /// Milliseconds since the Unix epoch; nil before the first check.
    public var lastCheckAtMs: Int64?
    public var lastCheckResult: ControllerDbCheckResult?
    public var checking = false

    public init(
        bundledVersion: Int = 0,
        activeVersion: Int = 0,
        source: ControllerDbOrigin = .bundled,
        checksEnabled: Bool = true,
        lastCheckAtMs: Int64? = nil,
        lastCheckResult: ControllerDbCheckResult? = nil
    ) {
        self.bundledVersion = bundledVersion
        self.activeVersion = activeVersion
        self.source = source
        self.checksEnabled = checksEnabled
        self.lastCheckAtMs = lastCheckAtMs
        self.lastCheckResult = lastCheckResult
    }
}
