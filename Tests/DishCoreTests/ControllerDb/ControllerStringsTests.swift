// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The database's words: a locale's own table, else its language's, else English.
final class ControllerStringsTests: XCTestCase {

    private let strings = ControllerStrings(tables: [
        "en": ["controller.pad.name": "Pad", "issue.x.title": "Broken", "issue.x.body": "It is broken."],
        "de": ["issue.x.title": "Kaputt"],
        "pt-BR": ["issue.x.title": "Quebrado"]
    ])

    func testALocaleReadsItsOwnTable() {
        XCTAssertEqual(strings.issueTitle("x", locale: "de"), "Kaputt")
    }

    func testAKeyALocaleLeavesOutReadsInEnglish() {
        XCTAssertEqual(strings.issueBody("x", locale: "de"), "It is broken.")
        XCTAssertEqual(strings.controllerName("pad", locale: "de"), "Pad", "proper nouns live in en alone")
    }

    func testARegionalLocaleReadsItsLanguagesTable() {
        XCTAssertEqual(strings.issueTitle("x", locale: "de-AT"), "Kaputt")
        XCTAssertEqual(strings.issueTitle("x", locale: "pt"), "Quebrado")
        XCTAssertEqual(strings.issueTitle("x", locale: "pt_PT"), "Quebrado")
    }

    func testALocaleWithNoTableReadsInEnglish() {
        XCTAssertEqual(strings.issueTitle("x", locale: "ja"), "Broken")
    }

    func testAKeyNoTableHasIsNil() {
        XCTAssertNil(strings.controllerName("ghost", locale: "en"))
    }

    func testAStringsFileIsAFlatObjectAndNonStringValuesAreLeftOut() throws {
        let data = Data(#"{"a":"one","b":2,"c":{"d":"e"}}"#.utf8)
        XCTAssertEqual(try decodeControllerStrings(data).get(), ["a": "one"])
        XCTAssertEqual(decodeControllerStrings(Data("[]".utf8)), .failure(.badJson))
    }
}
