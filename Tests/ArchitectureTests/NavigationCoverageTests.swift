// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation
import XCTest

/// Every place the window can be (docs/UI_CONTRACT.md, "Pages") is whole:
/// each `Destination` and `Page` case has its title worded in
/// `ShellMappers`, its `<Name>Page.swift`, a `<Name>MappersTests.swift` for
/// its mapper, and a branch of the shell's switch that draws it.
final class NavigationCoverageTests: XCTestCase {

    private static let machine = "Sources/Dish/Navigation/NavigationMachine.swift"
    private static let shellMappers = "Sources/Dish/UI/Mappers/ShellMappers.swift"
    private static let shellView = "Sources/Dish/UI/Shell/ShellView.swift"

    /// The case names of `enum <name>` in the navigation machine.
    private static func cases(of enumName: String) throws -> [String] {
        let source = try RepoFiles.read(machine)
        let body = try section(of: source, after: "enum \(enumName):", closing: "\n}")
        return body.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("case ") }
            .map { String($0.dropFirst("case ".count).prefix { $0.isLetter || $0.isNumber }) }
    }

    /// The text after `marker` up to the first `closing` that follows it.
    private static func section(of source: String, after marker: String, closing: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: marker), "\(marker) not found")
        let rest = source[start.upperBound...]
        let end = rest.range(of: closing)?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    private static func capitalized(_ name: String) -> String {
        name.prefix(1).uppercased() + name.dropFirst()
    }

    private static func mentions(_ name: String, in text: String, pattern: String) -> Bool {
        let regex = pattern.replacingOccurrences(of: "NAME", with: NSRegularExpression.escapedPattern(for: name))
        return text.range(of: regex, options: .regularExpression) != nil
    }

    private var destinations: [String] {
        get throws {
            try Self.cases(of: "Destination")
        }
    }

    private var pages: [String] {
        get throws {
            try Self.cases(of: "Page")
        }
    }

    func testTheSweepSeesEveryDestinationAndPage() throws {
        XCTAssertEqual(try destinations, ["home", "controllers", "connections", "support", "settings"])
        XCTAssertTrue(try pages.contains("configureBinding"), "the sweep must read the Page enum")
    }

    func testEveryDestinationAndPageHasAWordedTitle() throws {
        let source = try RepoFiles.read(Self.shellMappers)
        let destinationTitles = try Self.section(of: source, after: "func destinationTitle(", closing: "\n}")
        let pageTitles = try Self.section(of: source, after: "func pushedPageTitle(", closing: "\n}")
        let worded = #"case [^\n]*\.NAME\b[^\n]*: words\.\w+"#
        for name in try destinations {
            XCTAssertTrue(Self.mentions(name, in: destinationTitles, pattern: worded), "Destination.\(name) has no L10n title")
        }
        for name in try pages {
            XCTAssertTrue(Self.mentions(name, in: pageTitles, pattern: worded), "Page.\(name) has no L10n title")
        }
    }

    func testEveryDestinationAndPageHasItsPageAndItsMapperTests() throws {
        for name in try destinations + pages {
            let stem = Self.capitalized(name)
            let page = "Sources/Dish/UI/Pages/\(stem)Page.swift"
            let tests = "Tests/DishTests/Mappers/\(stem)MappersTests.swift"
            XCTAssertTrue(FileManager.default.fileExists(atPath: RepoFiles.url(page).path), "\(name) has no \(page)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: RepoFiles.url(tests).path), "\(name) has no \(tests)")
        }
    }

    func testTheShellDrawsEveryDestinationAndPage() throws {
        let source = try RepoFiles.read(Self.shellView)
        let root = try Self.section(of: source, after: "private var root: some View {", closing: "\n    }\n")
        let pushed = try Self.section(of: source, after: "private func pushed(", closing: "\n    }\n")
        let drawn = #"case (let )?[^\n]*\.NAME\b"#
        for name in try destinations {
            XCTAssertTrue(Self.mentions(name, in: root, pattern: drawn), "the shell's root switch does not draw .\(name)")
        }
        for name in try pages {
            XCTAssertTrue(Self.mentions(name, in: pushed, pattern: drawn), "the shell's pushed switch does not draw .\(name)")
        }
    }
}
