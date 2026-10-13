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

        var dependencies: [String]? {
            guard let start = body.range(of: "dependencies: [") else { return nil }
            let list = body[start.upperBound...].prefix { $0 != "]" }
            return list
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "") }
                .filter { !$0.isEmpty }
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

    func testTheAppDependsOnTheEngineCoreAndKernel() {
        XCTAssertEqual(block("Dish")?.dependencies, ["DishEngine", "DishCore", "DishKernel"])
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
