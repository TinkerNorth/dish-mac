// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// A host's document kept as it came: whole numbers stay whole, and every
/// string, keys included, can be passed through a scrub.
final class JSONValueTests: XCTestCase {

    func testADocumentRoundTripsWithItsWholeNumbersWhole() throws {
        let text = #"{"atMs":1763586000000,"rtt":2.5,"ok":true,"none":null,"list":["a",1]}"#
        let value = try XCTUnwrap(parseJSONValue(Data(text.utf8)))
        XCTAssertEqual(value["atMs"], .integer(1_763_586_000_000))
        XCTAssertEqual(value["rtt"], .number(2.5))
        XCTAssertEqual(value["ok"], .bool(true))
        XCTAssertEqual(value["none"], .null)
        let again = try XCTUnwrap(parseJSONValue(JSONEncoder().encode(value)))
        XCTAssertEqual(again, value)
    }

    func testNotJSONIsNothing() {
        XCTAssertNil(parseJSONValue(Data("nope".utf8)))
    }

    func testEveryStringAndEveryKeyPassesThroughTheTransform() {
        let value = JSONValue.object(["PC": .array([.string("PC said hi"), .integer(3)])])
        let scrubbed = value.mappingStrings { $0.replacingOccurrences(of: "PC", with: "Host 1") }
        XCTAssertEqual(scrubbed, .object(["Host 1": .array([.string("Host 1 said hi"), .integer(3)])]))
    }
}
