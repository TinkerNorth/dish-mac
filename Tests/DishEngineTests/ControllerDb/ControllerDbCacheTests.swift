// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishKernelProbes
import XCTest
@testable import DishEngine

/// The downloaded data on disk: a repository like any, swapped whole.
final class ControllerDbCacheTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = scratchDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testTheCacheHonoursTheRepositoryContract() {
        let contract = RepositoryContract(
            makeEmpty: { ControllerDbCache(directory: scratchDirectory()) },
            keyA: "controllers.json",
            valueA: Data("a".utf8),
            keyB: "strings/en.json",
            valueB: Data("b".utf8)
        )
        XCTAssertEqual(contract.violations(), [])
    }

    func testASwapReplacesTheWholeSet() {
        let cache = ControllerDbCache(directory: directory)
        XCTAssertTrue(cache.replaceAll(["controllers.json": Data("1".utf8), "strings/de.json": Data("de".utf8)]))
        XCTAssertTrue(cache.replaceAll(["controllers.json": Data("2".utf8)]))
        XCTAssertEqual(cache.files(), ["controllers.json": Data("2".utf8)], "nothing of the old set survives")
    }

    func testASwapLeavesNoStagingFolderBehind() throws {
        let cache = ControllerDbCache(directory: directory)
        XCTAssertTrue(cache.replaceAll(["controllers.json": Data("1".utf8)]))
        XCTAssertTrue(cache.replaceAll(["controllers.json": Data("2".utf8)]))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.deletingLastPathComponent().path)
        XCTAssertFalse(siblings.contains(directory.lastPathComponent + ".staging"))
    }

    func testACachedSetLoadsOnlyWhenItVerifiesAgainstItsManifest() throws {
        let served = try ServedVersion(dbVersion: 2)
        let cache = ControllerDbCache(directory: directory)
        var files = served.files
        files[ControllerDbFiles.manifest] = served.manifestData
        XCTAssertTrue(cache.replaceAll(files))
        XCTAssertEqual(cache.load()?.dbVersion, 2)
        cache.put(Data("{}".utf8), for: ControllerDbFiles.controllers)
        XCTAssertNil(cache.load(), "a file changed on disk is not loaded")
    }

    func testASwapNamingAPathOutsideTheDatabaseWritesNothing() {
        let cache = ControllerDbCache(directory: directory.appendingPathComponent("controllers-v1"))
        let escape = "../../escaped.txt"
        let outside = directory.appendingPathComponent("controllers-v1").appendingPathComponent(escape).standardizedFileURL
        defer { try? FileManager.default.removeItem(at: outside) }
        XCTAssertFalse(cache.replaceAll(["controllers.json": Data("1".utf8), escape: Data("x".utf8)]))
        cache.put(Data("x".utf8), for: escape)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path), "nothing lands outside the cache")
        XCTAssertNil(cache.get(escape))
        XCTAssertEqual(cache.files(), [:], "and the refused set left nothing behind")
    }

    func testAnEmptyCacheLoadsNothing() {
        XCTAssertNil(ControllerDbCache(directory: directory).load())
    }
}
