// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The version gate (mirrors satellite's VERSION ↔ version.h ↔ installer.iss
// check): `VERSION` is the single source of truth and `bundle.sh` must
// derive the plist versions from it — a hardcoded plist literal would make
// every build self-report the same number, which is fatal for the
// "update both" protocol-mismatch UX.

import XCTest

final class VersionConsistencyTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/DishTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    func testVersionFileExistsAndIsSemverShaped() throws {
        let raw = try String(contentsOf: repoRoot.appendingPathComponent("VERSION"), encoding: .utf8)
        let version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(version.isEmpty, "VERSION is the version source of truth — it must not be empty")
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertGreaterThanOrEqual(parts.count, 2, "VERSION must be dotted (got '\(version)')")
        for part in parts {
            XCTAssertTrue(
                !part.isEmpty && part.allSatisfy(\.isNumber),
                "VERSION component '\(part)' must be numeric (got '\(version)')"
            )
        }
    }

    func testBundleScriptDerivesPlistVersionsFromVersionFile() throws {
        let script = try String(
            contentsOf: repoRoot.appendingPathComponent("bundle.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(
            script.contains("< \"$PWD/VERSION\""),
            "bundle.sh must read the VERSION file"
        )
        for key in ["CFBundleVersion", "CFBundleShortVersionString"] {
            let line = try XCTUnwrap(
                script.split(separator: "\n").first { $0.contains("<key>\(key)</key>") },
                "bundle.sh must write \(key)"
            )
            XCTAssertTrue(
                line.contains("<string>${VERSION}</string>"),
                "\(key) must interpolate ${VERSION}, not a hardcoded literal: \(line)"
            )
        }
    }
}
