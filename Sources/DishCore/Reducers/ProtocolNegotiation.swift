// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The client half of contract §Versioning. The client offers
// `ProtocolConstants.protocolVersion` on pairing and the session PUT; the
// satellite accepts its whole [supportedMin, supported] range, settles the
// session on the offer and echoes the settled version, or answers 409 with
// the two bounds. Two facts make this more than a comparison: a
// pre-versioning satellite never answers 409 and echoes 1 whatever was
// offered, so the SETTLED version keys the wire frames; and a 409 whose
// range still overlaps ours is a working session one re-offer away.

import Foundation

/// What a pairing or session response said about the protocol version.
public enum ProtocolVerdict: Equatable, Sendable {
    /// The session speaks `settledVersion`; the wire frames key off it.
    case settled
    /// 409, but the ranges overlap: re-offer `settledVersion`.
    case retryLower
    /// The satellite's floor is above what this client speaks.
    case updateDish
    /// The satellite's ceiling is below this client's floor.
    case updateSatellite
    /// A 409 whose bounds are missing or inverted; neither end can be blamed.
    case unusable
}

public struct ProtocolOutcome: Equatable, Sendable {
    public var verdict: ProtocolVerdict
    /// The version in force (`settled`) or the version to offer next
    /// (`retryLower`); the client's own version otherwise.
    public var settledVersion: Int
    /// `settled` only, and never an error: the satellite works but is older
    /// than this client, so the row shows the soft update hint.
    public var satelliteBehind: Bool

    public init(verdict: ProtocolVerdict, settledVersion: Int = ProtocolConstants.protocolVersion, satelliteBehind: Bool = false) {
        self.verdict = verdict
        self.settledVersion = settledVersion
        self.satelliteBehind = satelliteBehind
    }
}

/// The range this client speaks, `[floor, version]`. The defaults are the
/// build's; a test passes another range to reach every arm.
public struct ClientProtocolRange: Equatable, Sendable {
    public var version: Int
    public var floor: Int

    public init(version: Int = ProtocolConstants.protocolVersion, floor: Int = ProtocolConstants.protocolVersionMin) {
        self.version = version
        self.floor = floor
    }

    public static let current = ClientProtocolRange()
}

/// The 200 path. `echoedVersion` is the response's `protocolVersion`; the
/// caller passes 1 when the field is absent, which is what the contract says
/// an omitted field means. An echo above our offer is clamped to our own
/// version so we only ever encode frames we know; one below our floor is
/// clamped to the floor and the session fails on its own terms rather than
/// mis-framing silently.
public func settleAccepted(echoedVersion: Int, client: ClientProtocolRange = .current) -> ProtocolOutcome {
    if echoedVersion >= client.version {
        return ProtocolOutcome(verdict: .settled, settledVersion: client.version, satelliteBehind: false)
    }
    return ProtocolOutcome(verdict: .settled, settledVersion: max(echoedVersion, client.floor), satelliteBehind: true)
}

/// The 409 path. `supported` and `supportedMin` come from the error body;
/// 0 stands for a field the body did not carry.
public func settleRejected(supported: Int, supportedMin: Int, client: ClientProtocolRange = .current) -> ProtocolOutcome {
    if supported <= 0 || supportedMin <= 0 || supportedMin > supported {
        return ProtocolOutcome(verdict: .unusable, settledVersion: client.version)
    }
    if supportedMin > client.version {
        return ProtocolOutcome(verdict: .updateDish, settledVersion: client.version)
    }
    if supported < client.floor {
        return ProtocolOutcome(verdict: .updateSatellite, settledVersion: client.version)
    }
    // The ranges overlap, and a 409 for our offer means `supported` is below
    // it: the highest common version is the satellite's ceiling.
    return ProtocolOutcome(verdict: .retryLower, settledVersion: min(supported, client.version))
}

/// Whether a rejection ends the attempt. `retryLower` does not: the caller
/// re-PUTs at the lower offer.
public func protocolVerdictIsTerminal(_ verdict: ProtocolVerdict) -> Bool {
    switch verdict {
    case .updateDish, .updateSatellite, .unusable: true
    case .settled, .retryLower: false
    }
}

/// The compatibility chip a satellite row carries, the same five states the
/// other clients show, so every client says the same thing about the same
/// satellite. A newer satellite that still accepts this build reads
/// `current`: the negotiation settled, so nothing is required of the user.
public enum ProtocolCompat: Equatable, Sendable {
    /// Nothing negotiated yet, or a 409 nobody could read.
    case unknown
    /// The session speaks this build's version.
    case current
    /// The link works and the satellite is older: the soft amber hint.
    case satelliteUpdateAvailable
    /// The satellite's ceiling is below our floor: red.
    case satelliteUpdateRequired
    /// The satellite's floor is above our ceiling: red.
    case dishUpdateRequired
}

public func compatForOutcome(_ outcome: ProtocolOutcome) -> ProtocolCompat {
    switch outcome.verdict {
    case .settled: outcome.satelliteBehind ? .satelliteUpdateAvailable : .current
    case .updateDish: .dishUpdateRequired
    case .updateSatellite: .satelliteUpdateRequired
    // Not settled yet, or unreadable: the chip must not guess.
    case .retryLower, .unusable: .unknown
    }
}

/// The two Required states mean the session cannot open at all; the soft
/// hint is only a hint.
public func protocolCompatBlocks(_ compat: ProtocolCompat) -> Bool {
    switch compat {
    case .satelliteUpdateRequired, .dishUpdateRequired: true
    case .unknown, .current, .satelliteUpdateAvailable: false
    }
}
