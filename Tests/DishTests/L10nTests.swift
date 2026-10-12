// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation
import XCTest
@testable import Dish

/// The catalog as the app reads it: the compiled table of every language
/// ships in the bundle, every plain entry reads back as the catalog wrote
/// it, and plurals follow each language's rules rather than the system's.
/// `scripts/compile-catalog.sh` is what puts the tables there on a toolchain
/// whose SwiftPM copies the catalog verbatim; nothing reads a verbatim
/// catalog at run time.
final class L10nTests: XCTestCase {

    private static let translated = ["bs", "de", "es", "fr", "pt-BR"]

    private static let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/DishTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("Sources/Dish/Resources/Localizable.xcstrings")

    /// One language's words from its compiled table, under its own plural
    /// rules.
    private func words(_ code: String) throws -> L10n {
        let path = try XCTUnwrap(Bundle.module.path(forResource: code, ofType: "lproj"), "\(code).lproj must ship in the bundle")
        let bundle = try XCTUnwrap(Bundle(path: path))
        return L10n(catalog: StringCatalog(bundle: bundle, locale: Locale(identifier: code)))
    }

    /// key → language → value, for the entries without plural variations.
    private func plainEntries() throws -> [String: [String: String]] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.catalogURL)) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        var entries: [String: [String: String]] = [:]
        for (key, rawEntry) in strings {
            let entry = try XCTUnwrap(rawEntry as? [String: Any])
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            for (code, rawLocalization) in localizations {
                let localization = try XCTUnwrap(rawLocalization as? [String: Any])
                guard let unit = localization["stringUnit"] as? [String: Any] else { continue }
                entries[key, default: [:]][code] = try XCTUnwrap(unit["value"] as? String)
            }
        }
        return entries
    }

    // MARK: - The tables ship

    func testEveryLanguageShipsAsACompiledTable() {
        for code in Self.translated + ["en"] {
            XCTAssertNotNil(Bundle.module.path(forResource: code, ofType: "lproj"), "\(code).lproj is missing from the bundle")
        }
        XCTAssertNil(
            Bundle.module.url(forResource: "Localizable", withExtension: "xcstrings"),
            "a verbatim catalog in the bundle is one nothing reads"
        )
    }

    // MARK: - English, through the bundle the app reads

    func testTheEnglishWordIsTheKey() {
        XCTAssertEqual(L10n.app.scan, "Scan")
        XCTAssertEqual(L10n.app.appName, "Dish")
    }

    func testEnglishPluralsPickTheSingular() {
        XCTAssertEqual(L10n.app.activeConnections(1), "1 active connection")
        XCTAssertEqual(L10n.app.activeConnections(2), "2 active connections")
        XCTAssertEqual(L10n.app.paired(1), "1 paired")
    }

    func testAMissingKeyFallsBackToItself() {
        let catalog = StringCatalog(bundle: .module, locale: Locale(identifier: "en"))
        XCTAssertEqual(catalog.text("Not a key"), "Not a key")
    }

    func testTheDefaultLocaleFollowsTheBundlesLanguage() {
        let catalog = StringCatalog(bundle: .module)
        XCTAssertEqual(catalog.locale.identifier, Bundle.module.preferredLocalizations.first)
    }

    // MARK: - Every language, from its compiled table

    func testEveryPlainEntryReadsBackAsWritten() throws {
        let entries = try plainEntries()
        XCTAssertGreaterThan(entries.count, 80, "the sweep must see the whole catalog")
        for code in Self.translated {
            let catalog = try words(code).catalog
            for (key, values) in entries {
                let expected = try XCTUnwrap(values[code], "\(key) lacks \(code)")
                XCTAssertEqual(catalog.text(key), expected, "\(code): \(key)")
            }
        }
    }

    func testBosnianPluralsFollowItsThreeForms() throws {
        let bosnian = try words("bs")
        XCTAssertEqual(bosnian.paired(1), "1 uparen")
        XCTAssertEqual(bosnian.paired(2), "2 uparena")
        XCTAssertEqual(bosnian.paired(5), "5 uparenih")
        XCTAssertEqual(bosnian.paired(12), "12 uparenih")
        XCTAssertEqual(bosnian.paired(21), "21 uparen")
    }

    func testFormatArgumentsLandInEveryLanguage() throws {
        for code in Self.translated {
            let local = try words(code)
            XCTAssertTrue(local.pairWith("Box").contains("Box"), code)
            XCTAssertTrue(local.onlineOfTotal(1, 3).contains("1"), code)
            XCTAssertTrue(local.onlineOfTotal(1, 3).contains("3"), code)
            XCTAssertTrue(local.percent(42).contains("42"), code)
            XCTAssertTrue(local.unreachable("timeout").contains("timeout"), code)
        }
    }
}
