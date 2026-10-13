// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The one reader of latest.json: every requirement a typed error, the
/// notes link advisory, unknown fields ignored.
final class UpdateManifestTests: XCTestCase {

    private func body(_ overrides: [String: Any] = [:], dropping: [String] = []) throws -> Data {
        var json: [String: Any] = [
            "schema": 1,
            "product": "dish-mac",
            "version": "0.2.0",
            "channel": "stable",
            "publishedAt": "2026-10-12T20:00:00Z",
            "minimumSupportedVersion": "0.1.0",
            "releaseNotesUrl": "https://github.com/TinkerNorth/dish-mac/releases/tag/0.2.0"
        ]
        for (key, value) in overrides {
            json[key] = value
        }
        for key in dropping {
            json.removeValue(forKey: key)
        }
        return try JSONSerialization.data(withJSONObject: json)
    }

    func testAWellFormedManifestParses() throws {
        let manifest = try XCTUnwrap(try UpdateManifest.parse(body()).get())
        XCTAssertEqual(manifest.version, "0.2.0")
        XCTAssertEqual(manifest.minimumSupportedVersion, "0.1.0")
        XCTAssertEqual(manifest.publishedAt, "2026-10-12T20:00:00Z")
        XCTAssertEqual(manifest.releaseNotesUrl, "https://github.com/TinkerNorth/dish-mac/releases/tag/0.2.0")
        XCTAssertEqual(manifest.schema, 1)
    }

    func testUnknownFieldsAreIgnored() throws {
        XCTAssertNoThrow(try UpdateManifest.parse(body(["future": ["x": 1]])).get())
    }

    func testEveryRequirementHasItsError() throws {
        XCTAssertEqual(UpdateManifest.parse(Data(repeating: 0x20, count: UpdateManifest.maxBytes + 1)), .failure(.oversize))
        XCTAssertEqual(UpdateManifest.parse(Data("<html>portal</html>".utf8)), .failure(.badJson))
        XCTAssertEqual(UpdateManifest.parse(Data("[1,2]".utf8)), .failure(.badJson))
        XCTAssertEqual(try UpdateManifest.parse(body(["schema": 2])), .failure(.unsupportedSchema))
        XCTAssertEqual(try UpdateManifest.parse(body(dropping: ["schema"])), .failure(.unsupportedSchema))
        XCTAssertEqual(try UpdateManifest.parse(body(["product": "dish-linux"])), .failure(.wrongProduct))
        XCTAssertEqual(try UpdateManifest.parse(body(["channel": "beta"])), .failure(.wrongChannel))
        XCTAssertEqual(try UpdateManifest.parse(body(["version": "v0.2.0"])), .failure(.badVersion))
        XCTAssertEqual(
            try UpdateManifest.parse(body(["minimumSupportedVersion": "0.3.0"])),
            .failure(.badMinimum),
            "a floor above the version"
        )
        XCTAssertEqual(try UpdateManifest.parse(body(dropping: ["minimumSupportedVersion"])), .failure(.badMinimum))
    }

    func testTheNotesLinkIsDroppedNotFatal() throws {
        XCTAssertEqual(try UpdateManifest.parse(body(["releaseNotesUrl": "http://github.com/x"])).get().releaseNotesUrl, "", "not https")
        XCTAssertEqual(
            try UpdateManifest.parse(body(["releaseNotesUrl": "https://example.com/x"])).get().releaseNotesUrl,
            "",
            "not github.com"
        )
        XCTAssertEqual(try UpdateManifest.parse(body(["releaseNotesUrl": 42])).get().releaseNotesUrl, "", "not a string")
        XCTAssertEqual(try UpdateManifest.parse(body(dropping: ["releaseNotesUrl"])).get().releaseNotesUrl, "")
    }

    func testTheBodyLimitIsAppliedBeforeParsing() {
        var huge = Data("{\"schema\":1".utf8)
        huge.append(Data(repeating: 0x20, count: UpdateManifest.maxBytes))
        XCTAssertEqual(UpdateManifest.parse(huge), .failure(.oversize))
    }
}
