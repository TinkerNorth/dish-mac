// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation
import XCTest

/// The bench's test names live twice: in the core's `InspectorTest`, and in
/// `Tests/PARITY.md`'s section 6, which says on which path each one runs.
/// Every test the Mac runs has its row there, and so do the lamp's, which no
/// Mac path carries.
final class BenchParityTests: XCTestCase {

    private static let testsSource = "Sources/DishCore/ControllerDb/ControllerDiagnostics.swift"
    private static let parity = "Tests/PARITY.md"
    private static let benchSection = "## 6. The Diagnostics bench, item by path"

    /// The raw values of `InspectorTest`'s cases, in declaration order.
    private func inspectorTests() throws -> [String] {
        let source = try RepoFiles.read(Self.testsSource)
        let start = try XCTUnwrap(source.range(of: "public enum InspectorTest"))
        let body = source[start.upperBound...].prefix { $0 != "}" }
        let regex = try NSRegularExpression(pattern: #"case \w+ = "([\w.]+)""#)
        let text = String(body)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// Section 6's table, up to the evidence below it.
    private func benchTable() throws -> String {
        let parity = try RepoFiles.read(Self.parity)
        let start = try XCTUnwrap(parity.range(of: Self.benchSection), "PARITY.md has no bench section")
        let section = parity[start.upperBound...]
        let evidence = section.range(of: "\n- (a)")?.lowerBound ?? section.endIndex
        return String(section[..<evidence])
    }

    /// A test name as the table writes it: in full, or as `.variant` after
    /// the lane's first name in the same row.
    private func tableNames(_ table: String) -> Set<String> {
        var names: Set<String> = []
        for row in table.split(separator: "\n") where row.hasPrefix("| ") {
            let cell = row.split(separator: "|").first.map(String.init) ?? ""
            let tokens = cell.components(separatedBy: "`").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
            let lane = tokens.first?.components(separatedBy: ".").first ?? ""
            for token in tokens {
                names.insert(token.hasPrefix(".") ? lane + token : token)
            }
        }
        return names
    }

    func testEveryTestTheMacRunsHasItsRowInTheBenchSection() throws {
        let tests = try inspectorTests()
        XCTAssertEqual(tests.count, 14, "the enum was read")
        let named = try tableNames(benchTable())
        XCTAssertEqual(tests.filter { !named.contains($0) }, [])
    }

    func testTheLampsTestsHaveTheirRowThoughNoMacPathCarriesThem() throws {
        let named = try tableNames(benchTable())
        XCTAssertTrue(named.isSuperset(of: ["lamp.on", "lamp.pulse"]))
        XCTAssertFalse(try inspectorTests().contains("lamp.on"))
    }
}
