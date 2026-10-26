// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation
import XCTest

/// Every design value is a token (CONTRIBUTING, "Touching the UI"): a view
/// outside `Theme.swift` writes no raw colour, derives no colour from a
/// token, and sets no raw font size; DESIGN.md lists every token.
final class ThemeTokenTests: XCTestCase {

    private static let theme = "Sources/Dish/UI/Theme.swift"
    private static let rawColours = [
        "Color(hex:", "Color(red:", "Color(white:", "Color(.sRGB", "Color(.displayP3", "Color(nsColor:",
        "Color.white", "Color.black", "Color.gray", ".white.opacity(", ".black.opacity("
    ]
    private static let rawFonts = [".system(size:", "Font.system(", "Font.custom("]
    /// The cross-repo palette stays whole even where this client has no use
    /// for a name yet.
    private static let sharedPalette: Set = [
        "background", "surface", "surfaceDim", "primary", "primaryDark", "onPrimary", "onSurface", "muted",
        "outline", "success", "error", "warning", "cardStroke"
    ]

    private struct Token {
        let namespace: String
        let name: String

        var reference: String {
            "\(namespace).\(name)"
        }
    }

    private var viewFiles: [String] {
        RepoFiles.swiftFiles(under: "Sources/Dish").filter { $0 != Self.theme }
    }

    /// Every `static let` declared inside an `enum` of `Theme.swift`.
    private static func tokens() throws -> [Token] {
        var namespace = ""
        var tokens: [Token] = []
        for rawLine in try RepoFiles.read(theme).split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("enum ") {
                namespace = String(line.dropFirst("enum ".count).prefix { $0 != " " })
            } else if rawLine.hasPrefix("}") {
                namespace = ""
            }
            guard !namespace.isEmpty, line.hasPrefix("static let ") else { continue }
            tokens.append(Token(namespace: namespace, name: String(line.dropFirst("static let ".count).prefix { $0 != " " && $0 != ":" })))
        }
        return tokens
    }

    private func assertNoLine(matching needles: [String], message: String) throws {
        for file in viewFiles {
            let offenders = try RepoFiles.offendingLines(in: file) { line in needles.contains { line.contains($0) } }
            XCTAssertEqual(offenders, [], message)
        }
    }

    func testAViewWritesNoRawColour() throws {
        try assertNoLine(matching: Self.rawColours, message: "a colour is a DishTheme token")
    }

    func testAViewDerivesNoColourFromAToken() throws {
        let regex = try NSRegularExpression(pattern: #"DishTheme\.\w+\.opacity\("#)
        for file in viewFiles {
            let offenders = try RepoFiles.offendingLines(in: file) { line in
                regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
            }
            XCTAssertEqual(offenders, [], "an alpha-tinted colour is its own token")
        }
    }

    func testAViewSetsNoRawFontSize() throws {
        try assertNoLine(matching: Self.rawFonts, message: "a font is a DishFont token")
    }

    /// A kit component draws from the tokens alone (docs/UI_CONTRACT.md, K7):
    /// no raw spacing, padding, corner, frame or glyph size.
    func testAKitComponentSetsNoRawSize() throws {
        let regex =
            try NSRegularExpression(pattern: #"(\b(spacing|cornerRadius|width|height|size|minLength): *|\.padding\((\.\w+, *)?)[1-9]"#)
        for file in RepoFiles.swiftFiles(under: "Sources/Dish/UI/Kit") {
            let offenders = try RepoFiles.offendingLines(in: file) { line in
                regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
            }
            XCTAssertEqual(offenders, [], "a kit size is a DishSize or DishSpace token")
        }
    }

    func testTheDesignDocumentListsEveryToken() throws {
        let design = try RepoFiles.read("DESIGN.md")
        let tokens = try Self.tokens()
        XCTAssertGreaterThan(tokens.count, 30, "the sweep must see both token sets")
        for token in tokens {
            XCTAssertTrue(design.contains("`\(token.reference)`"), "DESIGN.md lacks \(token.reference)")
        }
    }

    func testEveryTokenOutsideTheSharedPaletteIsDrawn() throws {
        let sources = try RepoFiles.swiftFiles(under: "Sources/Dish").map(RepoFiles.read).joined(separator: "\n")
        for token in try Self.tokens() where !(token.namespace == "DishTheme" && Self.sharedPalette.contains(token.name)) {
            let pattern = NSRegularExpression.escapedPattern(for: token.reference) + "\\b"
            XCTAssertNotNil(sources.range(of: pattern, options: .regularExpression), "\(token.reference) is declared but never drawn")
        }
    }
}
