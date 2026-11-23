// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The published set's manifest and the check that turns downloaded bytes
// into a set: every file the manifest names, its SHA-256 and its size
// against the manifest, then parsed, then schema 1, and only then a set the
// cache may take. A manifest names the paths the cache writes under, so it
// may name nothing but the database and a locale's strings. Signing the
// manifest is the next integrity step
// (section 11); schema 1 relies on HTTPS and these digests.

import CryptoKit
import Foundation

public struct ControllerDbFileEntry: Equatable, Sendable {
    /// Lowercase hex.
    public let sha256: String
    public let bytes: Int

    public init(sha256: String, bytes: Int) {
        self.sha256 = sha256
        self.bytes = bytes
    }
}

public struct ControllerDbManifest: Equatable, Sendable {
    public let dbVersion: Int
    public let publishedAt: String?
    /// By the path under `/controllers/v1/`: "controllers.json", "strings/en.json".
    public let files: [String: ControllerDbFileEntry]

    public init(dbVersion: Int, publishedAt: String? = nil, files: [String: ControllerDbFileEntry]) {
        self.dbVersion = dbVersion
        self.publishedAt = publishedAt
        self.files = files
    }
}

public enum ControllerDbFiles {
    public static let manifest = "manifest.json"
    public static let controllers = "controllers.json"

    public static func strings(_ locale: String) -> String {
        "strings/\(locale).json"
    }
}

public enum ControllerDbLimits {
    /// No served file is larger; today's `controllers.json` is about 370 KB.
    public static let maxFileBytes = 4 * 1024 * 1024
}

/// The database, or one locale's strings: a path that cannot reach outside
/// the folder it is written under.
public func isControllerDbPath(_ path: String) -> Bool {
    path.wholeMatch(of: #/controllers\.json|strings\/[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})?\.json/#) != nil
}

private struct ManifestFile: Decodable {
    struct Entry: Decodable {
        let sha256: String
        let bytes: Int
    }

    let schema: Int?
    let dbVersion: Int?
    let publishedAt: String?
    let files: [String: Entry]?
}

/// A manifest of version 1 or above that names the database and English,
/// nothing outside the database's paths, and no file over the cap.
public func decodeControllerDbManifest(_ data: Data) -> Result<ControllerDbManifest, ControllerDbError> {
    guard let file = try? JSONDecoder().decode(ManifestFile.self, from: data) else { return .failure(.badJson) }
    guard file.schema == ControllerDbSchema.version else { return .failure(.unsupportedSchema) }
    guard let dbVersion = file.dbVersion, dbVersion >= 1, let entries = file.files else { return .failure(.badJson) }
    let namesTheDatabase = entries[ControllerDbFiles.controllers] != nil
    let namesEnglish = entries[ControllerDbFiles.strings(ControllerStrings.fallbackLocale)] != nil
    let namesOnlyDatabasePaths = entries.keys.allSatisfy(isControllerDbPath)
    let fitsTheCap = entries.values.allSatisfy { (0 ... ControllerDbLimits.maxFileBytes).contains($0.bytes) }
    guard namesTheDatabase, namesEnglish, namesOnlyDatabasePaths, fitsTheCap else { return .failure(.badJson) }
    let files = entries.mapValues { ControllerDbFileEntry(sha256: $0.sha256.lowercased(), bytes: $0.bytes) }
    return .success(ControllerDbManifest(dbVersion: dbVersion, publishedAt: file.publishedAt, files: files))
}

public func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// The exact bytes the manifest names: its size and its digest.
public func fileMatches(_ data: Data, _ entry: ControllerDbFileEntry) -> Bool {
    let sizeMatches = data.count == entry.bytes
    return sizeMatches && sha256Hex(data) == entry.sha256
}

/// One published version, whole: the records, the words and the manifest
/// they came with.
public struct ControllerDbSet: Equatable, Sendable {
    public let manifest: ControllerDbManifest
    public let database: ControllerDatabase
    public let strings: ControllerStrings

    public init(manifest: ControllerDbManifest, database: ControllerDatabase, strings: ControllerStrings) {
        self.manifest = manifest
        self.database = database
        self.strings = strings
    }

    public var dbVersion: Int {
        database.dbVersion
    }
}

/// The files of one version, verified against its manifest and parsed. A
/// file the manifest names that is missing or differs, a database that does
/// not parse, is not schema 1 or is not the manifest's version, and a strings
/// file that does not parse all refuse the whole set.
public func verifiedControllerDbSet(manifest: ControllerDbManifest, files: [String: Data]) -> ControllerDbSet? {
    let everyFileMatches = manifest.files.allSatisfy { path, entry in
        files[path].map { fileMatches($0, entry) } ?? false
    }
    guard everyFileMatches else { return nil }
    return parsedControllerDbSet(manifest: manifest, files: files)
}

/// The same parse without the digests, for the copy the app was built with.
public func parsedControllerDbSet(manifest: ControllerDbManifest, files: [String: Data]) -> ControllerDbSet? {
    guard let body = files[ControllerDbFiles.controllers],
          case let .success(database) = decodeControllerDatabase(body),
          database.dbVersion == manifest.dbVersion else { return nil }
    var tables: [String: [String: String]] = [:]
    for locale in ControllerStrings.locales {
        guard let data = files[ControllerDbFiles.strings(locale)] else { continue }
        guard case let .success(table) = decodeControllerStrings(data) else { return nil }
        tables[locale] = table
    }
    return ControllerDbSet(manifest: manifest, database: database, strings: ControllerStrings(tables: tables))
}
