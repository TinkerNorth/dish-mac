// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation
import XCTest

/// One catalog, one funnel (CONTRIBUTING, "Touching the UI" and
/// "Translations"): every key `L10n` uses is in the catalog, every catalog
/// entry is used, every entry is translated into every language with its
/// placeholders intact, and no view holds an English literal.
final class LocalizationTests: XCTestCase {

    private static let languages: Set = ["bs", "de", "es", "fr", "pt-BR"]
    private static let funnel = "Sources/Dish/L10n"
    private static let reader = "Sources/Dish/L10n/StringCatalog.swift"
    private static let catalogPath = "Sources/Dish/Resources/Localizable.xcstrings"
    private static let allowedSpecifiers: Set = ["%%", "%@", "%lld"]

    private struct Entry {
        let key: String
        /// language → the value of a plain entry.
        let plain: [String: String]
        /// language → CLDR plural category → value.
        let plural: [String: [String: String]]
        let states: [String]

        var languages: Set<String> {
            Set(plain.keys).union(plural.keys)
        }
    }

    private var usedKeys: Set<String> = []
    private var entries: [Entry] = []
    private var sourceLanguage = ""

    override func setUpWithError() throws {
        usedKeys = try Set(RepoFiles.swiftFiles(under: Self.funnel).flatMap { try Self.keysUsed(in: RepoFiles.read($0)) })
        (sourceLanguage, entries) = try Self.parseCatalog(RepoFiles.read(Self.catalogPath))
    }

    // MARK: - Reading the two sources

    /// The literal passed to every `catalog.text("…")` and `catalog.format("…"`.
    private static func keysUsed(in source: String) throws -> Set<String> {
        let regex = try NSRegularExpression(pattern: #"catalog\.(?:text|format)\("((?:[^"\\]|\\.)*)""#)
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        return Set(matches.compactMap { match in Range(match.range(at: 1), in: source).map { String(source[$0]) } })
    }

    private static func parseCatalog(_ json: String) throws -> (String, [Entry]) {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let entries = try strings.map { key, raw in try parseEntry(key: key, raw) }.sorted { $0.key < $1.key }
        return (root["sourceLanguage"] as? String ?? "", entries)
    }

    private static func parseEntry(key: String, _ raw: Any) throws -> Entry {
        let entry = try XCTUnwrap(raw as? [String: Any], key)
        let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
        var plain: [String: String] = [:]
        var plural: [String: [String: String]] = [:]
        var states: [String] = []
        for (code, rawLocalization) in localizations {
            let localization = try XCTUnwrap(rawLocalization as? [String: Any], "\(key) in \(code)")
            if let unit = localization["stringUnit"] as? [String: Any] {
                plain[code] = unit["value"] as? String ?? ""
                states.append(unit["state"] as? String ?? "")
            }
            guard let variations = localization["variations"] as? [String: Any],
                  let forms = variations["plural"] as? [String: Any] else { continue }
            var byForm: [String: String] = [:]
            for (form, rawForm) in forms {
                let unit = (rawForm as? [String: Any])?["stringUnit"] as? [String: Any]
                byForm[form] = unit?["value"] as? String ?? ""
                states.append(unit?["state"] as? String ?? "")
            }
            plural[code] = byForm
        }
        return Entry(key: key, plain: plain, plural: plural, states: states)
    }

    /// The format specifiers of a string, in order. An unknown specifier
    /// comes back as the percent sign and the character after it.
    private static func specifiers(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "%(?:%|@|lld|.)") else { return ["<bad regex>"] }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    // MARK: - The funnel and the catalog agree

    func testTheFunnelUsesEveryCatalogEntryAndNothingElse() {
        let catalogKeys = Set(entries.map(\.key))
        XCTAssertGreaterThan(usedKeys.count, 80, "the sweep must see the whole funnel")
        XCTAssertEqual(usedKeys.subtracting(catalogKeys).sorted(), [], "keys L10n uses that the catalog lacks")
        XCTAssertEqual(catalogKeys.subtracting(usedKeys).sorted(), [], "catalog entries no code uses")
    }

    func testKeysAreCFormatStringsFromASmallVocabulary() {
        for key in usedKeys {
            XCTAssertFalse(key.contains("\\"), "\(key): a key is a literal, never an interpolation or an escape")
            let unknown = Set(Self.specifiers(in: key)).subtracting(Self.allowedSpecifiers)
            XCTAssertEqual(unknown, [], "\(key) uses a specifier outside \(Self.allowedSpecifiers.sorted())")
        }
    }

    func testTheSourceLanguageIsEnglish() {
        XCTAssertEqual(sourceLanguage, "en")
    }

    // MARK: - Every entry, every language

    func testEveryEntryIsTranslatedIntoEveryLanguage() {
        for entry in entries {
            XCTAssertEqual(Self.languages.subtracting(entry.languages).sorted(), [], "\(entry.key) lacks languages")
            for (code, value) in entry.plain {
                XCTAssertFalse(value.isEmpty, "\(entry.key) is blank in \(code)")
            }
            for (code, forms) in entry.plural {
                XCTAssertNotNil(forms["one"], "\(entry.key) in \(code) lacks the singular")
                XCTAssertNotNil(forms["other"], "\(entry.key) in \(code) lacks the plural")
                if code == "bs" { XCTAssertNotNil(forms["few"], "\(entry.key): Bosnian has a paucal form") }
                for (form, value) in forms {
                    XCTAssertFalse(value.isEmpty, "\(entry.key) is blank in \(code)/\(form)")
                }
            }
        }
    }

    func testEveryTranslationIsMarkedTranslated() {
        for entry in entries {
            XCTAssertEqual(Set(entry.states), ["translated"], entry.key)
        }
    }

    func testTranslationsKeepThePlaceholders() {
        for entry in entries {
            let expected = Self.specifiers(in: entry.key)
            for (code, value) in entry.plain {
                XCTAssertEqual(Self.specifiers(in: value), expected, "\(entry.key) in \(code)")
            }
            for (code, forms) in entry.plural {
                for (form, value) in forms {
                    XCTAssertEqual(Self.specifiers(in: value), expected, "\(entry.key) in \(code)/\(form)")
                }
            }
        }
    }

    // MARK: - Nothing else reads the catalog or holds a word

    private static func isInTheFunnel(_ file: String) -> Bool {
        file.hasPrefix(funnel + "/")
    }

    func testOnlyTheCatalogReaderReadsTheTables() throws {
        let readers = ["localizedString(forKey", "String(localized", "NSLocalizedString(", "LocalizedStringKey"]
        for file in RepoFiles.swiftFiles(under: "Sources/Dish") where file != Self.reader {
            let offenders = try RepoFiles.offendingLines(in: file) { line in readers.contains { line.contains($0) } }
            XCTAssertEqual(offenders, [], "the tables are read in StringCatalog.swift and nowhere else")
        }
    }

    func testOnlyTheFunnelNamesAKey() throws {
        let lookups = ["catalog.text(", "catalog.format(", "Bundle.module"]
        for file in RepoFiles.swiftFiles(under: "Sources/Dish") where !Self.isInTheFunnel(file) {
            let offenders = try RepoFiles.offendingLines(in: file) { line in lookups.contains { line.contains($0) } }
            XCTAssertEqual(offenders, [], "a key is named in the L10n files and nowhere else")
        }
    }

    /// The SwiftUI entry points that take words. A literal after one of
    /// them, other than the empty string, is English in a view.
    private static let literalEntryPoints = [
        "Text(\"", "Button(\"", "TextField(\"", "SecureField(\"", "Toggle(\"", "Picker(\"", "Label(\"",
        "WindowGroup(\"", ".help(\"", ".help(Text(\"", ".accessibilityLabel(\"", ".navigationTitle(\"",
        "SectionHeader(title: \"", "ErrorBanner(message: \""
    ]

    private static func holdsALiteral(_ line: String) -> Bool {
        literalEntryPoints.contains { entry in
            var rest = line[...]
            while let range = rest.range(of: entry) {
                if rest[range.upperBound...].first != "\"" { return true }
                rest = rest[range.upperBound...]
            }
            return false
        }
    }

    func testViewsHoldNoEnglishLiterals() throws {
        for file in RepoFiles.swiftFiles(under: "Sources/Dish") where !Self.isInTheFunnel(file) {
            let offenders = try RepoFiles.offendingLines(in: file, where: Self.holdsALiteral)
            XCTAssertEqual(offenders, [], "a view reads its words from L10n")
        }
    }

    func testTheBundleScriptShipsTheCatalog() throws {
        let script = try RepoFiles.read("bundle.sh")
        XCTAssertTrue(script.contains("Dish_Dish.bundle"), "bundle.sh must copy the SwiftPM resource bundle")
        XCTAssertTrue(script.contains("Contents/Resources"), "the resource bundle goes where Bundle.module looks")
    }
}
