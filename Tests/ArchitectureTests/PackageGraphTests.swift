// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest

/// The dependency arrows point one way: core and kernel depend on nothing,
/// the engine on both, the app on all three. Read from the manifest's text,
/// so a dependency added in the wrong direction fails here before anyone
/// reads the diff.
final class PackageGraphTests: XCTestCase {

    /// One `.target(...)` / `.executableTarget(...)` / `.testTarget(...)`
    /// block of the manifest, by name.
    private struct TargetBlock {
        let name: String
        let body: String

        /// The list as names: a sibling module by its string, a product of
        /// another package as `package/product`, so the arrow to the one
        /// third-party package reads in the assertions below.
        var dependencies: [String]? {
            guard let start = body.range(of: "dependencies: [") else { return nil }
            let list = String(body[start.upperBound...].prefix { $0 != "]" })
            return Self.entries(in: list)
        }

        private static func entries(in list: String) -> [String] {
            let pattern = #"\.product\(name: "([^"]+)", package: "([^"]+)"\)|"([^"]+)""#
            let regex = try? NSRegularExpression(pattern: pattern)
            let whole = NSRange(list.startIndex..., in: list)
            return regex?.matches(in: list, range: whole).map { match in
                if let product = Range(match.range(at: 1), in: list), let package = Range(match.range(at: 2), in: list) {
                    return "\(list[package])/\(list[product])"
                }
                return Range(match.range(at: 3), in: list).map { String(list[$0]) } ?? ""
            } ?? []
        }

        var treatsWarningsAsErrors: Bool {
            body.contains("swiftSettings: warningsAreErrors")
        }

        var suppressesWarnings: Bool {
            body.contains("-suppress-warnings")
        }
    }

    private var blocks: [TargetBlock] = []

    override func setUpWithError() throws {
        blocks = try Self.targetBlocks(in: RepoFiles.read("Package.swift"))
    }

    /// Splits the manifest into target blocks by walking parentheses, so a
    /// nested `.process("Resources")` cannot end a block early.
    private static func targetBlocks(in manifest: String) -> [TargetBlock] {
        let openers = [".target(", ".executableTarget(", ".testTarget("]
        var blocks: [TargetBlock] = []
        var searchStart = manifest.startIndex
        while let opener = openers.compactMap({ manifest.range(of: $0, range: searchStart ..< manifest.endIndex) })
            .min(by: { $0.lowerBound < $1.lowerBound })
        {
            let body = balancedBody(of: manifest, from: opener.upperBound)
            if let name = targetName(in: body) {
                blocks.append(TargetBlock(name: name, body: body))
            }
            searchStart = opener.upperBound
        }
        return blocks
    }

    private static func balancedBody(of manifest: String, from start: String.Index) -> String {
        var depth = 1
        var index = start
        while index < manifest.endIndex, depth > 0 {
            if manifest[index] == "(" { depth += 1 }
            if manifest[index] == ")" { depth -= 1 }
            index = manifest.index(after: index)
        }
        return String(manifest[start ..< index])
    }

    private static func targetName(in body: String) -> String? {
        guard let start = body.range(of: "name: \"") else { return nil }
        return String(body[start.upperBound...].prefix { $0 != "\"" })
    }

    private func block(_ name: String) -> TargetBlock? {
        let found = blocks.first { $0.name == name }
        XCTAssertNotNil(found, "Package.swift declares no target named \(name)")
        return found
    }

    func testCoreAndKernelDependOnNothing() {
        XCTAssertNil(block("DishCore")?.dependencies)
        XCTAssertNil(block("DishKernel")?.dependencies)
    }

    func testTheEngineDependsOnCoreAndKernelOnly() {
        XCTAssertEqual(block("DishEngine")?.dependencies, ["DishCore", "DishKernel"])
    }

    func testTheAppDependsOnTheEngineCoreKernelAndTheCrashUploader() {
        XCTAssertEqual(block("Dish")?.dependencies, ["DishEngine", "DishCore", "DishKernel", "DishCrashUpload"])
    }

    /// The one third-party package reaches the tree through one module, so
    /// the engine's list above stays Apple-only.
    func testOnlyTheCrashUploaderDependsOnTheSdk() {
        XCTAssertEqual(block("DishCrashUpload")?.dependencies, ["DishEngine", "DishCore", "sentry-cocoa/Sentry"])
        let withSdk = blocks.filter { ($0.dependencies ?? []).contains { $0.hasPrefix("sentry-cocoa/") } }.map(\.name)
        XCTAssertEqual(withSdk, ["DishCrashUpload"])
    }

    /// The SDK is pinned exactly, like the lint tools: a range would let a
    /// resolve move the crash reporter under a release.
    func testTheSdkIsPinnedExactly() throws {
        let manifest = try RepoFiles.read("Package.swift")
        XCTAssertTrue(manifest.contains(#".package(url: "https://github.com/getsentry/sentry-cocoa", exact: ""#))
        XCTAssertFalse(manifest.contains("from: \""), "no open-ended package ranges")
    }

    func testEveryFirstPartyTargetTreatsWarningsAsErrors() {
        let exempt: Set = ["LegacyFileKeychain"]
        XCTAssertGreaterThan(blocks.count, 8, "the sweep must see every target")
        for block in blocks where !exempt.contains(block.name) {
            XCTAssertTrue(block.treatsWarningsAsErrors, "\(block.name) must build with warnings as errors")
        }
    }

    func testOnlyTheLegacyKeychainTargetSuppressesWarnings() {
        let suppressing = blocks.filter(\.suppressesWarnings).map(\.name)
        XCTAssertEqual(suppressing, ["LegacyFileKeychain"])
    }

    func testTheLanguageModeStaysSwiftFive() throws {
        XCTAssertTrue(try RepoFiles.read("Package.swift").contains("swiftLanguageModes: [.v5]"))
    }
}
