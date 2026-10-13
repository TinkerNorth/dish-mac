// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The one version grammar: strict triples, ordered as tuples, and nothing
/// malformed ever ranks above a real version.
final class UpdateVersionTests: XCTestCase {

    func testStrictTriplesParse() {
        XCTAssertEqual(UpdateVersion.parse("1.2.3"), UpdateVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(UpdateVersion.parse("0.1.0"), UpdateVersion(major: 0, minor: 1, patch: 0))
        XCTAssertEqual(UpdateVersion.parse("10.0.99"), UpdateVersion(major: 10, minor: 0, patch: 99))
    }

    func testAnythingElseIsRejected() {
        for text in [
            "",
            "1",
            "1.2",
            "1.2.3.4",
            "v1.2.3",
            "1.2.3-rc1",
            "1.2.3+build",
            " 1.2.3",
            "1..3",
            "1.-2.3",
            "a.b.c",
            "1.2.x",
            "99999999999999999999.0.0"
        ] {
            XCTAssertNil(UpdateVersion.parse(text), text)
            XCTAssertFalse(isValidVersion(text), text)
        }
    }

    func testOrderingIsByTupleNotByString() {
        XCTAssertEqual(compareVersions("0.10.0", "0.9.0"), 1)
        XCTAssertEqual(compareVersions("1.0.0", "0.99.99"), 1)
        XCTAssertEqual(compareVersions("1.2.3", "1.2.3"), 0)
        XCTAssertEqual(compareVersions("1.2.3", "1.2.4"), -1)
    }

    func testAMalformedSideCannotBeCompared() {
        XCTAssertNil(compareVersions("1.2", "1.2.3"))
        XCTAssertNil(compareVersions("1.2.3", "latest"))
        XCTAssertFalse(isStrictlyNewer("latest", than: "1.2.3"))
        XCTAssertFalse(isStrictlyNewer("1.2.3", than: "latest"))
    }

    func testStrictlyNewerIsStrict() {
        XCTAssertTrue(isStrictlyNewer("1.2.4", than: "1.2.3"))
        XCTAssertFalse(isStrictlyNewer("1.2.3", than: "1.2.3"))
        XCTAssertFalse(isStrictlyNewer("1.2.2", than: "1.2.3"))
    }
}
