// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// What each host says of itself in the diagnostics bundle (dish-website
// `docs/diagnostics-bundle.md`, "The hosts, from both ends"): a Satellite of
// 2.3.0 or later answers its connection's diagnostics route; an older one,
// or one that cannot answer now, is told by what the client already fetched
// from it; a Moonlight host by the serverinfo fields the client parsed,
// never its name.

import Foundation

public enum HostSnapshotPolicy {
    /// The route under `/api/connections/{connectionId}`.
    public static let routeSuffix = "diagnostics"
    /// How long a report waits for one host.
    public static let timeoutSeconds = 2.0
    public static let satelliteFormat = "satellite-connection-diagnostics.v1"
    public static let capabilitiesFormat = "satellite-capabilities"
    public static let moonlightFormat = "moonlight-serverinfo"
    /// The first Satellite with the route.
    public static let firstVersionWithRoute = "2.3.0"
}

/// Whether to ask a Satellite at all, by the version its capabilities
/// probe gave: one older than the route, or one that named no version it
/// could be ranked by, is never asked. A 404 cannot tell an older host from
/// a 2.3.0 host that does not know the connection.
public func satelliteAnswersDiagnostics(serverVersion: String) -> Bool {
    guard let order = compareVersions(serverVersion, HostSnapshotPolicy.firstVersionWithRoute) else { return false }
    return order >= 0
}

/// Why a host's own view is missing, in the contract's words.
public enum HostSnapshotError: String, Equatable, Sendable {
    case offline
    case unauthorized
    case olderSatellite
    case timeout
    /// A Satellite with the route that does not know this connection as
    /// this device's.
    case unknownConnection
    /// The host answered with something that is not the document: a server
    /// error, or a body of another shape.
    case badReply
}

/// What the client's gateway saw of one diagnostics request.
public struct HostSnapshotReply: Equatable, Sendable {
    /// 0 when no response came.
    public let status: Int
    public let body: Data
    public let timedOut: Bool

    public init(status: Int, body: Data, timedOut: Bool) {
        self.status = status
        self.body = body
        self.timedOut = timedOut
    }
}

public enum HostSnapshotVerdict: Equatable, Sendable {
    case snapshot(JSONValue)
    case failed(HostSnapshotError)
}

private let httpNoResponse = 0
private let httpOk = 200
private let httpUnauthorized = 401
private let httpForbidden = 403
private let httpNotFound = 404

/// One reply from a Satellite that has the route: the document when it is
/// the contract's, else why not. No response is offline; a 404 is a
/// connection it does not know; any other answer that is not the document
/// is a bad reply.
public func hostSnapshotVerdict(_ reply: HostSnapshotReply) -> HostSnapshotVerdict {
    if reply.timedOut { return .failed(.timeout) }
    switch reply.status {
    case httpOk: return satelliteDocument(reply.body)
    case httpNotFound: return .failed(.unknownConnection)
    case httpUnauthorized, httpForbidden: return .failed(.unauthorized)
    case httpNoResponse: return .failed(.offline)
    default: return .failed(.badReply)
    }
}

private func satelliteDocument(_ body: Data) -> HostSnapshotVerdict {
    guard let document = parseJSONValue(body), document["format"]?.stringValue == HostSnapshotPolicy.satelliteFormat else {
        return .failed(.badReply)
    }
    return .snapshot(document)
}

/// What a Satellite's capabilities probe and catalog said, kept for the
/// bundle when the host cannot speak for itself.
public struct SatelliteCapabilitiesFacts: Equatable, Sendable {
    public let serverVersion: String
    public let protocolVersion: Int
    /// The `backends` array as the probe listed it; nil when it had none.
    public let backends: JSONValue?
    /// Nil when the probe carried no `controllerAudio` block.
    public let controllerAudio: HostAudioBlock?
    /// Nil until the catalog was read.
    public let catalogVersion: Int?

    public init(serverVersion: String, protocolVersion: Int, backends: JSONValue?, controllerAudio: HostAudioBlock?, catalogVersion: Int?) {
        self.serverVersion = serverVersion
        self.protocolVersion = protocolVersion
        self.backends = backends
        self.controllerAudio = controllerAudio
        self.catalogVersion = catalogVersion
    }
}

/// The probe's `controllerAudio` switches, as the host sent them.
public struct HostAudioBlock: Equatable, Sendable {
    public let enabled: Bool
    public let mic: Bool
    public let speaker: Bool
    public let hapticAudio: Bool

    public init(enabled: Bool, mic: Bool, speaker: Bool, hapticAudio: Bool) {
        self.enabled = enabled
        self.mic = mic
        self.speaker = speaker
        self.hapticAudio = hapticAudio
    }
}

/// The older Satellite's stand-in document, marked by its format.
public func capabilitiesSnapshot(_ facts: SatelliteCapabilitiesFacts) -> JSONValue {
    var fields: [String: JSONValue] = [
        "format": .string(HostSnapshotPolicy.capabilitiesFormat),
        "serverVersion": .string(facts.serverVersion),
        "protocol": .array([.integer(Int64(ProtocolConstants.protocolVersionMin)), .integer(Int64(facts.protocolVersion))]),
        "backends": facts.backends ?? .array([])
    ]
    fields["controllerAudio"] = facts.controllerAudio.map(audioBlockValue)
    fields["catalogVersion"] = facts.catalogVersion.map { .integer(Int64($0)) }
    return .object(fields)
}

private func audioBlockValue(_ block: HostAudioBlock) -> JSONValue {
    .object([
        "enabled": .bool(block.enabled),
        "mic": .bool(block.mic),
        "speaker": .bool(block.speaker),
        "hapticAudio": .bool(block.hapticAudio)
    ])
}

/// A Moonlight host's serverinfo as the client parsed it: the server's
/// version alone. `state` and `pairStatus` are null because the plaintext
/// serverinfo reports every host free and every caller unpaired. Never its
/// hostname, its id, its addresses or its MAC.
public func moonlightSnapshot(_ info: MoonlightServerInfo) -> JSONValue {
    let fields: [String: JSONValue] = [
        "format": .string(HostSnapshotPolicy.moonlightFormat),
        "appVersion": info.appVersion.map(JSONValue.string) ?? .null,
        "state": .null,
        "pairStatus": .null
    ]
    return .object(fields)
}

/// The host entry's `snapshot` and `snapshotError`.
public struct BundleHostSnapshot: Equatable, Sendable {
    public let snapshot: JSONValue?
    public let error: HostSnapshotError?

    public init(snapshot: JSONValue?, error: HostSnapshotError?) {
        self.snapshot = snapshot
        self.error = error
    }
}

/// A Satellite's entry: its own document when it gave one, else the stand-in
/// with the reason. A host no live link reached was not asked: offline.
public func satelliteHostSnapshot(_ verdict: HostSnapshotVerdict?, fallback: SatelliteCapabilitiesFacts?) -> BundleHostSnapshot {
    let standIn = fallback.map(capabilitiesSnapshot)
    switch verdict {
    case let .snapshot(document): return BundleHostSnapshot(snapshot: document, error: nil)
    case let .failed(error): return BundleHostSnapshot(snapshot: standIn, error: error)
    case nil: return BundleHostSnapshot(snapshot: standIn, error: .offline)
    }
}

/// A Moonlight host's entry: what its serverinfo said, or offline when the
/// client never read it.
public func moonlightHostSnapshot(_ info: MoonlightServerInfo?) -> BundleHostSnapshot {
    guard let info else { return BundleHostSnapshot(snapshot: nil, error: .offline) }
    return BundleHostSnapshot(snapshot: moonlightSnapshot(info), error: nil)
}
