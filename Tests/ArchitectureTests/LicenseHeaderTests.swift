// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest

/// Every source file opens with the SPDX line and the copyright line
/// (CONTRIBUTING, "License headers"). The manifest's tools-version comment
/// must come first, so it carries them on lines two and three.
final class LicenseHeaderTests: XCTestCase {

    private static let spdx = "// SPDX-License-Identifier: LGPL-3.0-or-later"
    private static let copyright = "// Copyright (C) 2026 Dish contributors."

    private func firstLines(_ relativePath: String, count: Int) throws -> [String] {
        try Array(RepoFiles.read(relativePath).split(separator: "\n", omittingEmptySubsequences: false).prefix(count)).map(String.init)
    }

    func testEverySwiftSourceStartsWithTheLicenseHeader() throws {
        let files = RepoFiles.swiftFiles(under: "Sources") + RepoFiles.swiftFiles(under: "Tests")
        XCTAssertGreaterThan(files.count, 100, "the sweep must see the whole tree")
        for file in files {
            let lines = try firstLines(file, count: 2)
            XCTAssertEqual(lines.first, Self.spdx, "\(file) lacks the SPDX line")
            XCTAssertEqual(lines.dropFirst().first, Self.copyright, "\(file) lacks the copyright line")
        }
    }

    func testTheManifestCarriesTheHeaderAfterItsToolsVersion() throws {
        let lines = try firstLines("Package.swift", count: 3)
        XCTAssertTrue(lines[0].hasPrefix("// swift-tools-version:"))
        XCTAssertEqual(lines[1], Self.spdx)
        XCTAssertEqual(lines[2], Self.copyright)
    }
}
