// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Facts a document repeats from code, tied to the code: the crash reporter's
// version, the protocol number, the pinned tools and the Xcode the workflows
// select. A bump that moves one copy fails here, and the message names the
// file to edit.

import XCTest

final class DocumentFactsTests: XCTestCase {

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    // MARK: sentry-cocoa

    func testThirdPartyNamesTheSentryVersionPackageResolvedPins() throws {
        let resolved = try RepoFiles.read("Package.resolved")
        let pinned = try XCTUnwrap(
            firstMatch(#""identity"\s*:\s*"sentry-cocoa"[^}]*?"version"\s*:\s*"([0-9.]+)""#, in: resolved),
            "Package.resolved has no sentry-cocoa pin"
        )
        let notice = try RepoFiles.read("THIRD_PARTY.md")
        let named = allMatches(#"sentry-cocoa(?:\]\([^)]*\))?(?: \|)? ([0-9]+\.[0-9]+\.[0-9]+)"#, in: notice)
        XCTAssertEqual(named.count, 2, "THIRD_PARTY.md names sentry-cocoa's version in the summary table and in section 2a")
        for version in named {
            let edit = "edit the version in THIRD_PARTY.md (summary row and section 2a), "
                + "then copy the file to Sources/Dish/Resources/THIRD_PARTY.md"
            XCTAssertEqual(version, pinned, "Package.resolved pins sentry-cocoa \(pinned): \(edit)")
        }
    }

    func testPackageSwiftPinsTheVersionPackageResolvedDoes() throws {
        let resolved = try RepoFiles.read("Package.resolved")
        let pinned = firstMatch(#""identity"\s*:\s*"sentry-cocoa"[^}]*?"version"\s*:\s*"([0-9.]+)""#, in: resolved)
        let manifest = try RepoFiles.read("Package.swift")
        XCTAssertEqual(
            firstMatch(#"sentry-cocoa[^)]*exact:\s*"([0-9.]+)""#, in: manifest),
            pinned,
            "Package.swift and Package.resolved must pin the same sentry-cocoa"
        )
    }

    func testThirdPartyDoesNotClaimTheAppHasNoPackageDependencies() throws {
        let notice = try RepoFiles.read("THIRD_PARTY.md").replacingOccurrences(of: "\n", with: " ")
        XCTAssertFalse(
            notice.contains("declares no package dependencies"),
            "Package.swift depends on sentry-cocoa; THIRD_PARTY.md must not say otherwise"
        )
    }

    // MARK: protocol

    func testTheDocumentsNameTheProtocolTheCodeOffers() throws {
        let constants = try RepoFiles.read("Sources/DishCore/ProtocolConstants.swift")
        let offered = try XCTUnwrap(
            firstMatch(#"static let protocolVersion\s*=\s*([0-9]+)"#, in: constants),
            "ProtocolConstants.protocolVersion not found"
        )
        let security = try RepoFiles.read("SECURITY.md")
        let named = allMatches(#"\(protocol ([0-9]+)"#, in: security)
        XCTAssertFalse(named.isEmpty, "SECURITY.md names the wire protocol in its scope list")
        for number in named {
            XCTAssertEqual(number, offered, "the client offers protocol \(offered) (ProtocolConstants.protocolVersion): edit SECURITY.md")
        }
        for path in ["README.md", "docs/contract.md"] {
            let text = try RepoFiles.read(path)
            let bold = allMatches(#"offers \*\*protocol ([0-9]+)\*\*"#, in: text)
            for number in bold {
                XCTAssertEqual(number, offered, "the client offers protocol \(offered): edit \(path)")
            }
        }
    }

    // MARK: tools

    private func toolsScript() throws -> String {
        try RepoFiles.read("scripts/tools.sh")
    }

    func testTheDocumentsNameTheToolVersionsToolsShPins() throws {
        let tools = try toolsScript()
        let format = try XCTUnwrap(firstMatch(#"SWIFTFORMAT_VERSION="([0-9.]+)""#, in: tools))
        let lint = try XCTUnwrap(firstMatch(#"SWIFTLINT_VERSION="([0-9.]+)""#, in: tools))
        let notice = try RepoFiles.read("THIRD_PARTY.md")
        let copies = "edit THIRD_PARTY.md and its copy under Sources/Dish/Resources"
        let namedFormat = firstMatch(#"\[SwiftFormat\]\([^)]*\) \| ([0-9.]+)"#, in: notice)
        XCTAssertEqual(namedFormat, format, "scripts/tools.sh pins SwiftFormat \(format): \(copies)")
        let namedLint = firstMatch(#"\[SwiftLint\]\([^)]*\) \| ([0-9.]+)"#, in: notice)
        XCTAssertEqual(namedLint, lint, "scripts/tools.sh pins SwiftLint \(lint): \(copies)")
        let contributing = try RepoFiles.read("CONTRIBUTING.md").replacingOccurrences(of: "\n", with: " ")
        XCTAssertTrue(contributing.contains("SwiftFormat \(format)"), "edit CONTRIBUTING.md: SwiftFormat \(format)")
        XCTAssertTrue(contributing.contains("SwiftLint \(lint)"), "edit CONTRIBUTING.md: SwiftLint \(lint)")
    }

    func testNoWorkflowOrScriptRepeatsAToolPin() throws {
        let tools = try toolsScript()
        for digestName in ["SWIFTFORMAT_SHA256", "SWIFTLINT_SHA256"] {
            let digest = try XCTUnwrap(firstMatch("\(digestName)=\"([0-9a-f]{64})\"", in: tools))
            XCTAssertEqual(digest.count, 64)
            for path in ["scripts/ci-local.sh", "scripts/check-format.sh", ".github/workflows/macos-ci.yml"] {
                let text = try RepoFiles.read(path)
                XCTAssertFalse(text.contains(digest), "\(path) repeats a pin: it belongs in scripts/tools.sh alone")
                XCTAssertFalse(text.contains("SWIFTFORMAT_VERSION=") || text.contains("SWIFTLINT_VERSION="), "\(path) repeats a pin")
            }
        }
    }

    // MARK: Xcode

    func testEveryWorkflowSelectsTheSameXcodeByVersion() throws {
        let directory = RepoFiles.url(".github/workflows")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".yml") }
        var selected = Set<String>()
        for name in names {
            let text = try RepoFiles.read(".github/workflows/\(name)")
            for line in text.split(separator: "\n") where line.contains("xcode-select") {
                let version = firstMatch(#"/Applications/Xcode_([0-9.]+)\.app"#, in: String(line))
                XCTAssertNotNil(version, "\(name) must select Xcode by version, not /Applications/Xcode.app: \(line)")
                version.map { _ = selected.insert($0) }
            }
        }
        XCTAssertEqual(selected.count, 1, "every workflow selects the same Xcode (got \(selected.sorted()))")
        let contributing = try RepoFiles.read("CONTRIBUTING.md").replacingOccurrences(of: "\n", with: " ")
        if let version = selected.first {
            XCTAssertTrue(contributing.contains("Xcode \(version)"), "edit CONTRIBUTING.md: the workflows select Xcode \(version)")
        }
    }
}
