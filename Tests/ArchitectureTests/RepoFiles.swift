// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// The repository as the architecture tests see it: the root, every Swift
/// file under a directory, and the import lines of a file.
enum RepoFiles {

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/ArchitectureTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root

    static func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    static func read(_ relativePath: String) throws -> String {
        try String(contentsOf: url(relativePath), encoding: .utf8)
    }

    /// Every `.swift` file under `relativeDirectory`, sorted, as repo-relative paths.
    static func swiftFiles(under relativeDirectory: String) -> [String] {
        let directory = url(relativeDirectory)
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        let prefix = root.path + "/"
        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { $0.path.replacingOccurrences(of: prefix, with: "") }
            .sorted()
    }

    /// The modules a file imports (`import Foo`, `@testable import Foo`,
    /// `import Foo.Bar` reads as `Foo`).
    static func imports(of source: String) -> [String] {
        source
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap(importedModule)
    }

    private static func importedModule(_ line: String) -> String? {
        let withoutTestable = line.replacingOccurrences(of: "@testable import ", with: "import ")
        guard withoutTestable.hasPrefix("import ") else { return nil }
        let afterKeyword = withoutTestable.dropFirst("import ".count)
        let moduleWithSubmodule = afterKeyword.split(separator: " ").first.map(String.init) ?? ""
        return moduleWithSubmodule.split(separator: ".").first.map(String.init)
    }

    /// `file:line` for every line of `source` that `predicate` matches, for
    /// a failure message that points at the offender.
    static func offendingLines(in relativePath: String, where predicate: (String) -> Bool) throws -> [String] {
        let source = try read(relativePath)
        return source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .filter { predicate(String($0.element)) }
            .map { "\(relativePath):\($0.offset + 1)" }
    }
}
