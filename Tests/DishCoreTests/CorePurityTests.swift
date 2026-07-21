// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The gate behind the "pure core" claim: DishCore may import Foundation +
// CryptoKit ONLY. SwiftPM enforces the package dependency graph but nothing
// stops a stray `import Network`/`AppKit` inside the target — this does
// (the Swift analogue of satellite's check_core_purity idea).

import XCTest

final class CorePurityTests: XCTestCase {

    private static let allowedImports: Set = ["Foundation", "CryptoKit"]

    func testDishCoreImportsOnlyFoundationAndCryptoKit() throws {
        let coreDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/DishCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Sources/DishCore")
        let files = try XCTUnwrap(
            FileManager.default.enumerator(at: coreDir, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" }
        )
        XCTAssertFalse(files.isEmpty, "no DishCore sources found at \(coreDir.path)")
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                let module = trimmed.dropFirst("import ".count)
                    .split(separator: " ").first.map(String.init) ?? ""
                XCTAssertTrue(
                    Self.allowedImports.contains(module),
                    "\(file.lastPathComponent) imports \(module) — DishCore is Foundation + CryptoKit only"
                )
            }
        }
    }
}
