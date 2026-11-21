// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation
import XCTest
@testable import Dish

/// The controller data's words follow the language the app's own pages
/// show: the bundle's pick among its six localizations for the person's
/// preferred language (the one `StringCatalog` reads), then that
/// language's strings file, and English for any key the file leaves out.
final class ControllerStringsLanguageTests: XCTestCase {

    private let strings = ControllerStrings(tables: [
        "en": ["issue.x.title": "Broken", "issue.x.body": "It is broken."],
        "bs": ["issue.x.title": "Pokvareno", "issue.x.body": "Ne radi."],
        "de": ["issue.x.title": "Kaputt"],
        "es": ["issue.x.title": "Roto", "issue.x.body": "Está roto."],
        "fr": ["issue.x.title": "Cassé", "issue.x.body": "C’est cassé."],
        "pt-BR": ["issue.x.title": "Quebrado", "issue.x.body": "Está quebrado."]
    ])

    /// The language the bundle shows a person whose first language is
    /// `preference`.
    private func uiLanguage(_ preference: String) throws -> String {
        try XCTUnwrap(Bundle.preferredLocalizations(from: Bundle.module.localizations, forPreferences: [preference]).first)
    }

    /// The pages' words in that language, from its compiled table.
    private func words(_ code: String) throws -> L10n {
        let path = try XCTUnwrap(Bundle.module.path(forResource: code, ofType: "lproj"), "\(code).lproj must ship in the bundle")
        let bundle = try XCTUnwrap(Bundle(path: path))
        return L10n(catalog: StringCatalog(bundle: bundle, locale: Locale(identifier: code)))
    }

    /// The issue as a card shows it to a person with this preference.
    private func shown(to preference: String) throws -> String {
        try issueText(ControllerIssue(id: "x"), strings: strings, words: words(uiLanguage(preference)))
    }

    func testAustrianGermanReadsGerman() throws {
        XCTAssertEqual(try uiLanguage("de-AT"), "de")
        XCTAssertEqual(try shown(to: "de-AT"), "Kaputt: It is broken.", "the body German lacks reads in English, for that key alone")
    }

    func testBosnianInLatinScriptForBosniaReadsBosnian() throws {
        XCTAssertEqual(try uiLanguage("bs-Latn-BA"), "bs")
        XCTAssertEqual(try shown(to: "bs-Latn-BA"), "Pokvareno: Ne radi.")
    }

    func testEuropeanPortugueseReadsBrazilianPortuguese() throws {
        XCTAssertEqual(try uiLanguage("pt-PT"), "pt-BR")
        XCTAssertEqual(try shown(to: "pt-PT"), "Quebrado: Está quebrado.")
    }

    func testBrazilianPortugueseReadsBrazilianPortuguese() throws {
        XCTAssertEqual(try uiLanguage("pt-BR"), "pt-BR")
        XCTAssertEqual(try shown(to: "pt-BR"), "Quebrado: Está quebrado.")
    }

    func testCanadianFrenchReadsFrench() throws {
        XCTAssertEqual(try uiLanguage("fr-CA"), "fr")
        XCTAssertEqual(try shown(to: "fr-CA"), "Cassé: C’est cassé.")
    }

    func testLatinAmericanSpanishReadsSpanish() throws {
        XCTAssertEqual(try uiLanguage("es-419"), "es")
        XCTAssertEqual(try shown(to: "es-419"), "Roto: Está roto.")
    }

    func testBritishEnglishReadsEnglish() throws {
        XCTAssertEqual(try uiLanguage("en-GB"), "en")
        XCTAssertEqual(try shown(to: "en-GB"), "Broken: It is broken.")
    }

    func testJapaneseReadsEnglishSinceTheAppHasNoJapanese() throws {
        XCTAssertEqual(try uiLanguage("ja-JP"), "en")
        XCTAssertEqual(try shown(to: "ja-JP"), "Broken: It is broken.")
    }

    func testTheDataFollowsThePagesLanguageNotTheSystemsRegion() throws {
        XCTAssertEqual(try words("de").language, "de", "the catalog's language, which StringCatalog takes from the bundle")
    }
}
