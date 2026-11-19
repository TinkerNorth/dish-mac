// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The manifest and the set it vouches for: every file it names, its size
/// and digest, then the parse; one file astray refuses the whole set.
final class ControllerDbManifestTests: XCTestCase {

    func testAManifestNamesEachFilesDigestAndSize() throws {
        let published = try PublishedSet(dbVersion: 3)
        XCTAssertEqual(published.manifest.dbVersion, 3)
        XCTAssertEqual(published.manifest.publishedAt, "2026-11-19T00:00:00Z")
        let entry = try XCTUnwrap(published.manifest.files[ControllerDbFiles.controllers])
        XCTAssertEqual(entry.bytes, published.files[ControllerDbFiles.controllers]?.count)
    }

    func testAManifestOfAnotherSchemaOrNoVersionIsRefused() {
        let noSchema = Data(#"{"dbVersion":1,"files":{"controllers.json":{"sha256":"a","bytes":1}}}"#.utf8)
        let zero = Data(#"{"schema":1,"dbVersion":0,"files":{"controllers.json":{"sha256":"a","bytes":1}}}"#.utf8)
        let noDatabase = Data(#"{"schema":1,"dbVersion":1,"files":{}}"#.utf8)
        XCTAssertEqual(decodeControllerDbManifest(noSchema), .failure(.unsupportedSchema))
        XCTAssertEqual(decodeControllerDbManifest(zero), .failure(.badJson))
        XCTAssertEqual(decodeControllerDbManifest(noDatabase), .failure(.badJson))
        XCTAssertEqual(decodeControllerDbManifest(Data("nope".utf8)), .failure(.badJson))
    }

    func testTheDigestIsSha256InLowercaseHex() {
        XCTAssertEqual(sha256Hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testAFileMatchesOnlyAtItsSizeAndDigest() {
        let data = Data("abc".utf8)
        let digest = sha256Hex(data)
        XCTAssertTrue(fileMatches(data, ControllerDbFileEntry(sha256: digest, bytes: 3)))
        XCTAssertFalse(fileMatches(data, ControllerDbFileEntry(sha256: digest, bytes: 4)), "the size is checked too")
        XCTAssertFalse(fileMatches(data, ControllerDbFileEntry(sha256: sha256Hex(Data("abd".utf8)), bytes: 3)))
    }

    func testAVerifiedSetCarriesTheRecordsAndTheWords() throws {
        let set = try XCTUnwrap(try PublishedSet(dbVersion: 2).set)
        XCTAssertEqual(set.dbVersion, 2)
        XCTAssertEqual(set.database.records.map(\.id), ["sony-dualsense"])
        XCTAssertEqual(set.strings.controllerName("sony-dualsense", locale: "en"), "DualSense Wireless Controller")
    }

    func testAMissingFileRefusesTheSet() throws {
        let published = try PublishedSet(dbVersion: 2)
        var files = published.files
        files.removeValue(forKey: ControllerDbFiles.strings("en"))
        XCTAssertNil(verifiedControllerDbSet(manifest: published.manifest, files: files))
    }

    func testAChangedByteRefusesTheSet() throws {
        let published = try PublishedSet(dbVersion: 2)
        var files = published.files
        var body = try XCTUnwrap(files[ControllerDbFiles.controllers])
        body[body.startIndex] = 0x20
        files[ControllerDbFiles.controllers] = body
        XCTAssertNil(verifiedControllerDbSet(manifest: published.manifest, files: files))
    }

    func testADatabaseOfAnotherVersionThanItsManifestRefusesTheSet() throws {
        let published = try PublishedSet(dbVersion: 2)
        let other = try PublishedSet(dbVersion: 3)
        var files = published.files
        files[ControllerDbFiles.controllers] = other.files[ControllerDbFiles.controllers]
        XCTAssertNil(parsedControllerDbSet(manifest: published.manifest, files: files))
    }

    func testAStringsFileThatDoesNotParseRefusesTheSet() throws {
        let published = try PublishedSet(dbVersion: 2)
        var files = published.files
        files[ControllerDbFiles.strings("de")] = Data("[1]".utf8)
        XCTAssertNil(parsedControllerDbSet(manifest: published.manifest, files: files))
    }

    func testADatabaseOfAnotherSchemaRefusesTheSet() throws {
        let published = try PublishedSet(dbVersion: 2)
        var files = published.files
        files[ControllerDbFiles.controllers] = try databaseData(schema: 2, dbVersion: 2, records: [])
        XCTAssertNil(parsedControllerDbSet(manifest: published.manifest, files: files))
    }
}
