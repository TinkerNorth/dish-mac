// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation
import XCTest

/// A view is layout (docs/UI_CONTRACT.md, "View purity"): every file under
/// `Sources/Dish` that declares a `View` draws a mapper's state and calls
/// intents. It reads no clock, does no IO, formats no words, subscribes to
/// nothing, observes no engine object and makes no domain decision.
///
/// The rules, each with what catches it and where it applies (the table in
/// docs/UI_CONTRACT.md is this list):
///
/// - V1 no clock: `Date()`, `TimelineView`. Every view.
/// - V2 no IO: `NSPasteboard`, `NSWorkspace`, `UserDefaults`, `URLSession`.
///   Every view.
/// - V3 no waiting: `Task.sleep`, `Timer.`, `DispatchQueue.`. Every view.
/// - V4 no subscriptions: `.sink(`. Every view.
/// - V5 no formatting: `String(format:`, `.formatted(`, any `…Formatter`.
///   Every view.
/// - V6 three objects observed: an `@EnvironmentObject`, `@ObservedObject`
///   or `@StateObject` of any type but `AppModel`, `NavigationStore` and
///   `DishNotificationCenter`. Every view.
/// - V7 no engine objects: `wifi.`, `moonlight.`, `updates.`, `crashLog.`,
///   `diagnostics.`, `diagnosticsLog.`, `inspector.`, `settings.`,
///   `keepAwake.`, `theme.`, `background.`, `updatePreferences.`,
///   `crashReporting.`, `input.`, `hub.`. Every view.
/// - V8 the model is facts and intents: `model.<name>` where `<name>` is
///   neither a fact (an `@Published` or computed `var` of an `AppModel`
///   file) nor an intent (a `func` of one). Every view.
/// - V9 no decision on the model: `if`, `guard` or `switch` over a fact (an
///   intent's answer, `if model.addByAddress(…)`, is the model's decision),
///   a ternary on `model.…`, a lookup (`.first`, `.filter`, `.contains`,
///   `.isEmpty`, `.count`, `.map`) on a fact. Every view.
/// - V10 no token picked: a ternary between `DishTheme` or `DishFont`
///   tokens or `Color.clear`. Pages.
/// - V11 no boolean rules: `&&`, `||`. Pages.
/// - V12 no fallback words: `??`, `.isEmpty ?`. Pages.
///
/// "Pages" are every view but the components, which own their states (K2):
/// the kit, the brand glyphs, the loaders and the theme's button styles.
final class ViewPurityTests: XCTestCase {

    private enum Scope {
        case everyView
        case pages
    }

    private struct Rule {
        let name: String
        let pattern: String
        let scope: Scope
    }

    private static let engineObjects = [
        "wifi", "moonlight", "updates", "crashLog", "diagnostics", "diagnosticsLog", "inspector", "settings", "keepAwake", "theme",
        "background", "updatePreferences", "crashReporting", "input", "hub"
    ]
    private static let observable: Set = ["AppModel", "NavigationStore", "DishNotificationCenter"]
    private static let lookups = "first|filter|contains|isEmpty|count|map"

    private static let rules = [
        Rule(name: "V1 no clock", pattern: #"Date\(\)|TimelineView"#, scope: .everyView),
        Rule(name: "V2 no IO", pattern: #"NSPasteboard|NSWorkspace|UserDefaults|URLSession"#, scope: .everyView),
        Rule(name: "V3 no waiting", pattern: #"Task\.sleep|\bTimer\.|DispatchQueue\."#, scope: .everyView),
        Rule(name: "V4 no subscriptions", pattern: #"\.sink\("#, scope: .everyView),
        Rule(name: "V5 no formatting", pattern: #"String\(format:|\.formatted\(|\b\w*Formatter\b"#, scope: .everyView),
        Rule(name: "V7 no engine objects", pattern: #"(?<![\w.$])("# + engineObjects.joined(separator: "|") + #")\."#, scope: .everyView),
        Rule(
            name: "V9 no decision on the model",
            pattern: #"\b(if|guard|switch)\b.*\bmodel\.\w+\b(?!\()|\bmodel\.[\w.]+\s+\?\s|\bmodel\.\w+(\.\w+)*\.("# + lookups + #")\b"#,
            scope: .everyView
        ),
        Rule(name: "V10 no token picked", pattern: #"\?\s*(DishTheme\.\w+|DishFont\.\w+|Color\.clear)\s*:"#, scope: .pages),
        Rule(name: "V11 no boolean rules", pattern: #"&&|\|\|"#, scope: .pages),
        Rule(name: "V12 no fallback words", pattern: #"\?\?|\.isEmpty\s*\?"#, scope: .pages)
    ]

    /// The one exception the contract makes: the loaders animate on the
    /// display's clock, which says nothing about the domain.
    private static let allowed: [String: Set<String>] = [
        "Sources/Dish/UI/DishLoaders.swift": ["V1 no clock"]
    ]

    /// The scene and its seams are not views: they are where the clock, the
    /// pasteboard and the workspace are allowed to live.
    private static let notViews = ["Sources/Dish/DishApp.swift", "Sources/Dish/AppKitLifecycle.swift", "Sources/Dish/Services"]

    /// Components own their states (K2) and may pick a token by their own flag.
    private static let components = [
        "Sources/Dish/UI/Kit/", "Sources/Dish/UI/BrandIcon", "Sources/Dish/UI/DishLoaders.swift", "Sources/Dish/UI/Theme.swift"
    ]

    private static func declaresAView(_ source: String) -> Bool {
        source.range(of: #"(struct|extension)\s+\w+(<[^>]*>)?\s*:\s*([\w, ]*,\s*)?View\b"#, options: .regularExpression) != nil
    }

    private static func isNotAView(_ file: String) -> Bool {
        notViews.contains { file.hasPrefix($0) }
    }

    private var viewFiles: [String] {
        get throws {
            try RepoFiles.swiftFiles(under: "Sources/Dish").filter { try Self.declaresAView(RepoFiles.read($0)) }
        }
    }

    /// The code of a line: a whole-line comment is not code.
    private static func isCode(_ line: String) -> Bool {
        !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }

    private static func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
        regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private static func applies(_ rule: Rule, to file: String) -> Bool {
        let exempt = allowed[file, default: []].contains(rule.name)
        let isComponent = components.contains { file.hasPrefix($0) }
        switch rule.scope {
        case .everyView: return !exempt
        case .pages: return !exempt && !isComponent
        }
    }

    private func offenders(of rule: Rule, in files: [String]) throws -> [String] {
        let regex = try NSRegularExpression(pattern: rule.pattern)
        return try files.filter { Self.applies(rule, to: $0) }.flatMap { file in
            try RepoFiles.offendingLines(in: file) { Self.isCode($0) && Self.matches(regex, $0) }
        }
    }

    // MARK: - The rules

    func testTheSweepSeesThePagesAndNotTheScene() throws {
        let files = try viewFiles
        XCTAssertGreaterThan(files.count, 40, "the sweep must see every page, the shell and the kit")
        XCTAssertTrue(files.contains("Sources/Dish/UI/Pages/SettingsPage.swift"))
        XCTAssertTrue(files.contains("Sources/Dish/UI/Shell/ShellView.swift"))
        XCTAssertEqual(files.filter(Self.isNotAView), [], "the scene and its seams declare no view")
    }

    func testAViewBreaksNoPurityRule() throws {
        let files = try viewFiles
        for rule in Self.rules {
            XCTAssertEqual(try offenders(of: rule, in: files), [], "\(rule.name): see docs/UI_CONTRACT.md, View purity")
        }
    }

    func testAViewObservesOnlyTheModelTheStoreAndTheToasts() throws {
        let pattern = #"@(EnvironmentObject|ObservedObject|StateObject)\s+(private\s+)?var\s+\w+\s*:\s*(\w+)"#
        let regex = try NSRegularExpression(pattern: pattern)
        for file in try viewFiles {
            let source = try RepoFiles.read(file)
            let observed = regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
                Range(match.range(at: 3), in: source).map { String(source[$0]) }
            }
            XCTAssertEqual(observed.filter { !Self.observable.contains($0) }, [], "V6: \(file) observes an engine object")
        }
    }

    func testAViewReadsOnlyTheModelsFactsAndIntents() throws {
        let known = try Self.modelFacts().union(Self.modelIntents())
        XCTAssertTrue(known.isSuperset(of: ["slots", "shellFacts", "pageAppeared", "startScan"]), "the sweep must read AppModel")
        let regex = try NSRegularExpression(pattern: #"\bmodel\.(\w+)"#)
        for file in try viewFiles {
            let source = try RepoFiles.read(file).split(separator: "\n").map(String.init).filter(Self.isCode).joined(separator: "\n")
            let reads = regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
                Range(match.range(at: 1), in: source).map { String(source[$0]) }
            }
            XCTAssertEqual(Set(reads).subtracting(known).sorted(), [], "V8: \(file) reaches past the model's facts and intents")
        }
    }

    func testEveryAllowanceIsStillNeeded() throws {
        for (file, names) in Self.allowed {
            for rule in Self.rules where names.contains(rule.name) {
                let regex = try NSRegularExpression(pattern: rule.pattern)
                let lines = try RepoFiles.offendingLines(in: file) { Self.isCode($0) && Self.matches(regex, $0) }
                XCTAssertFalse(lines.isEmpty, "\(file) no longer needs \(rule.name); drop the allowance")
            }
        }
    }

    // MARK: - What the model offers

    private static var modelFiles: [String] {
        RepoFiles.swiftFiles(under: "Sources/DishEngine").filter { $0.hasPrefix("Sources/DishEngine/AppModel") }
    }

    /// Every `@Published` property of `AppModel` and every computed one its
    /// extensions derive: the facts a view may draw.
    private static func modelFacts() throws -> Set<String> {
        let model = try RepoFiles.read("Sources/DishEngine/AppModel.swift")
        let published = try names(in: model, pattern: #"@Published\s+[\w\s()]*?\bvar\s+(\w+)"#)
        let computed = #"^\s*(package\s+)?var\s+(\w+)\s*:[^=\n]*\{\s*$"#
        let derived = try modelFiles.reduce(into: Set<String>()) { all, file in
            try all.formUnion(names(in: RepoFiles.read(file), pattern: computed, group: 2))
        }
        return published.union(derived)
    }

    /// Every function an `AppModel` file declares: the intents a view may call.
    private static func modelIntents() throws -> Set<String> {
        try modelFiles.reduce(into: Set<String>()) { all, file in
            try all.formUnion(names(in: RepoFiles.read(file), pattern: #"^\s*(package\s+)?(@discardableResult\s+)?func\s+(\w+)"#, group: 3))
        }
    }

    private static func names(in source: String, pattern: String, group: Int = 1) throws -> Set<String> {
        let regex = try NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        return Set(matches.compactMap { match in Range(match.range(at: group), in: source).map { String(source[$0]) } })
    }
}
