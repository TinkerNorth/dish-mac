// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// latest.json (schema 1): the one reader of update metadata, so the reducer
// and the checker downstream trust a parsed manifest completely. Every
// violated requirement is a typed error, and the caller treats every error
// as a failed check. The release assets are not modelled: the Mac client
// never downloads its own update; it reads the version and the notes link.

import Foundation

public enum ManifestError: Error, Equatable, Sendable {
    /// The body is larger than `UpdateManifest.maxBytes` before parsing; a
    /// captive portal's splash page can be any size.
    case oversize
    /// Unparseable, or the root is not an object.
    case badJson
    /// `schema` is not 1; a greater schema means a newer client is needed.
    case unsupportedSchema
    /// `product` is not this client's.
    case wrongProduct
    /// `channel` is not `stable`.
    case wrongChannel
    /// `version` is not strict MAJOR.MINOR.PATCH.
    case badVersion
    /// `minimumSupportedVersion` is malformed or above `version`.
    case badMinimum
}

public struct UpdateManifest: Equatable, Sendable {
    /// GitHub's Latest permalink; no API host.
    public static let latestManifestURLString = "https://github.com/TinkerNorth/dish-mac/releases/latest/download/latest.json"
    /// The body is size-checked before the JSON parse.
    public static let maxBytes = 64 * 1024
    public static let product = "dish-mac"
    public static let channel = "stable"

    public var schema = 1
    public var product: String
    public var version: String
    public var channel: String
    /// Display only, never ordered on.
    public var publishedAt: String
    public var minimumSupportedVersion: String
    /// Empty when absent or dropped (not https, not github.com).
    public var releaseNotesUrl: String

    public init(
        product: String = UpdateManifest.product,
        version: String,
        channel: String = UpdateManifest.channel,
        publishedAt: String = "",
        minimumSupportedVersion: String,
        releaseNotesUrl: String = ""
    ) {
        self.product = product
        self.version = version
        self.channel = channel
        self.publishedAt = publishedAt
        self.minimumSupportedVersion = minimumSupportedVersion
        self.releaseNotesUrl = releaseNotesUrl
    }

    /// Unknown extra fields are ignored: schema 1 is additive only.
    public static func parse(_ body: Data) -> Result<UpdateManifest, ManifestError> {
        guard body.count <= maxBytes else { return .failure(.oversize) }
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return .failure(.badJson) }
        guard let schema = root["schema"] as? Int, schema == 1 else { return .failure(.unsupportedSchema) }
        let product = root["product"] as? String ?? ""
        guard product == Self.product else { return .failure(.wrongProduct) }
        let channel = root["channel"] as? String ?? ""
        guard channel == Self.channel else { return .failure(.wrongChannel) }
        let version = root["version"] as? String ?? ""
        guard isValidVersion(version) else { return .failure(.badVersion) }
        let minimum = root["minimumSupportedVersion"] as? String ?? ""
        guard isValidVersion(minimum), !isStrictlyNewer(minimum, than: version) else { return .failure(.badMinimum) }
        return .success(UpdateManifest(
            product: product,
            version: version,
            channel: channel,
            publishedAt: root["publishedAt"] as? String ?? "",
            minimumSupportedVersion: minimum,
            releaseNotesUrl: sanitizedNotesUrl(root["releaseNotesUrl"])
        ))
    }

    /// The notes link is advisory: a bad value is dropped, never fatal, so
    /// the link can never take the whole check down.
    static func sanitizedNotesUrl(_ value: Any?) -> String {
        guard let text = value as? String, let components = URLComponents(string: text),
              components.scheme == "https", components.host == "github.com" else { return "" }
        return text
    }
}
